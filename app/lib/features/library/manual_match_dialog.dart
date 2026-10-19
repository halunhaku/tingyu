import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/buttons.dart';
import '../../design/components/cover.dart';
import '../../design/components/dialogs.dart';
import '../../design/components/feedback.dart';
import '../../design/components/inputs.dart';
import '../../design/layout/form_factor.dart';
import '../../design/theme.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tokens/metrics.dart';
import '../../sources/scraper/lrclib_provider.dart';
import '../../sources/scraper/metadata_provider.dart';
import '../../sources/scraper/netease_provider.dart';
import '../../sources/scraper/qq_music_provider.dart';

/// 人工匹配：先填歌名 / 歌手 / 专辑，再搜候选并选定（`DESIGN.md` §6.4 的
/// `TyDialog` 表单：宽 480、逐字段 `errorText`）。
///
/// 打开时**不**自动搜索——夸克曲目的文件名经常是噪声，一打开就搜会打出一堆
/// 无关结果。占位专辑/歌手不预填进输入框。
Future<void> showManualMatchDialog(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  await showTyDialog<void>(
    context,
    child: _ManualMatchDialog(track: track),
  );
}

class _ManualMatchDialog extends ConsumerStatefulWidget {
  const _ManualMatchDialog({required this.track});

  final Track track;

  @override
  ConsumerState<_ManualMatchDialog> createState() => _ManualMatchDialogState();
}

class _ManualMatchDialogState extends ConsumerState<_ManualMatchDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.track.title,
  );
  late final TextEditingController _artist = TextEditingController(
    text: _editableArtist(widget.track.artist),
  );
  late final TextEditingController _album = TextEditingController(
    text: _editableAlbum(widget.track.album),
  );

  final QQMusicProvider _qq = QQMusicProvider();
  final NetEaseProvider _netease = NetEaseProvider();
  final LrclibProvider _lrclib = LrclibProvider();

  List<MetadataCandidate> _candidates = const <MetadataCandidate>[];
  bool _searching = false;
  bool _applying = false;
  bool _didSearch = false;

  /// 歌名的字段级错误（`DESIGN.md` §6.4 / `docs/UX_REDESIGN.md` I11）。
  String? _titleError;

  static String _editableArtist(String artist) =>
      artist.trim().isEmpty || artist == '未知艺术家' ? '' : artist;

  static String _editableAlbum(String album) =>
      isPlaceholderAlbum(album) ? '' : album;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    super.dispose();
  }

  void _clearTitleError() {
    if (_titleError != null) {
      setState(() => _titleError = null);
    }
  }

  Future<void> _search() async {
    final String title = _title.text.trim();
    if (title.isEmpty) {
      setState(() {
        _titleError = '请先填写歌名';
        _candidates = const <MetadataCandidate>[];
        _didSearch = false;
      });
      return;
    }
    setState(() {
      _searching = true;
      _titleError = null;
      _didSearch = true;
    });
    final String artist = _artist.text.trim();
    final String album = _album.text.trim();
    final List<MetadataCandidate> results = <MetadataCandidate>[
      ...await _qq.searchCandidates(
        title,
        artist: artist,
        album: album,
        limit: 8,
      ),
      ...await _netease.searchCandidates(
        title,
        artist: artist,
        album: album,
        limit: 5,
      ),
    ];
    if (!mounted) {
      return;
    }
    setState(() {
      _candidates = results;
      _searching = false;
    });
  }

  Future<void> _apply(MetadataCandidate candidate) async {
    setState(() => _applying = true);
    final Duration duration = Duration(
      milliseconds: (widget.track.duration * 1000).round(),
    );

    String? coverPath;
    if (candidate.coverUrl != null) {
      final Uint8List? bytes = await ImageDownloader().download(
        candidate.coverUrl!,
      );
      if (bytes != null) {
        coverPath = await ref.read(coverStoreProvider).save(bytes);
      }
    }

    // 歌词：LRCLIB 优先（带时间轴），拿不到再用同一候选的网易云条目。
    String? lyrics = await _lrclib.fetchLyrics(
      LyricsQuery(
        title: candidate.title,
        artist: candidate.artist,
        album: candidate.album,
        duration: duration,
      ),
    );
    if (lyrics == null && candidate.provider == 'netease') {
      lyrics = await _netease.fetchLyrics(
        LyricsQuery(
          title: candidate.title,
          artist: candidate.artist,
          album: candidate.album,
        ),
        candidate: candidate,
      );
    }

    await ref
        .read(trackRepositoryProvider)
        .applyEnrichment(
          id: widget.track.id,
          title: candidate.title,
          artist: candidate.artist.isEmpty ? null : candidate.artist,
          album: candidate.album.isEmpty ? null : candidate.album,
          lyrics: lyrics,
          coverArtPath: coverPath,
          coverArtUrl: candidate.coverUrl,
        );

    if (!mounted) {
      return;
    }
    setState(() => _applying = false);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final bool canSearch = !_searching && _title.text.trim().isNotEmpty;

    return TyDialog(
      title: '匹配元数据',
      subtitle:
          '当前：${widget.track.title} · ${widget.track.artist} · '
          '${widget.track.album}',
      form: true,
      actions: <Widget>[
        TyButton(
          label: '取消',
          variant: TyButtonVariant.secondary,
          dense: true,
          onPressed: _applying ? null : () => Navigator.pop(context),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TyTextField(
            controller: _title,
            label: '歌名',
            autofocus: true,
            errorText: _titleError,
            onChanged: (String _) => _clearTitleError(),
            onSubmitted: (String _) {
              if (canSearch) {
                _search();
              }
            },
          ),
          const SizedBox(height: TySpace.x12),
          TyTextField(
            controller: _artist,
            label: '歌手（选填）',
            onSubmitted: (String _) {
              if (canSearch) {
                _search();
              }
            },
          ),
          const SizedBox(height: TySpace.x12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: TyTextField(
                  controller: _album,
                  label: '专辑（选填）',
                  onSubmitted: (String _) {
                    if (canSearch) {
                      _search();
                    }
                  },
                ),
              ),
              const SizedBox(width: TySpace.x8),
              TyButton(
                label: '搜索',
                icon: Icons.search,
                variant: TyButtonVariant.secondary,
                dense: true,
                onPressed: canSearch ? _search : null,
              ),
            ],
          ),
          const SizedBox(height: TySpace.x16),
          if (_searching)
            const _CandidatesSkeleton()
          else if (_candidates.isEmpty)
            TyEmptyState(
              compact: true,
              icon: Icons.search,
              title: _didSearch ? '没有找到候选' : '还没有候选',
              description: _didSearch ? '换个关键词再搜一次' : '填好歌名后点「搜索」',
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final MetadataCandidate candidate in _candidates)
                  _CandidateRow(
                    candidate: candidate,
                    busy: _applying,
                    onUse: () => _apply(candidate),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 候选行：封面 + 标题/来源 + 「使用」。
class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.candidate,
    required this.busy,
    required this.onUse,
  });

  final MetadataCandidate candidate;
  final bool busy;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Padding(
      padding: const EdgeInsets.only(bottom: TySpace.x8),
      child: Row(
        children: <Widget>[
          TyCover(
            url: candidate.coverUrl,
            size: context.metrics.coverList,
            radius: TyRadius.xs,
            seed: candidate.title,
          ),
          const SizedBox(width: TySpace.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  candidate.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ty.typography.bodyM.copyWith(
                    color: ty.colors.textPrimary,
                  ),
                ),
                Text(
                  '${candidate.artist} · ${candidate.album} · '
                  '${candidate.provider}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ty.typography.bodyS.copyWith(
                    color: ty.colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: TySpace.x8),
          TyButton(
            label: '使用',
            variant: TyButtonVariant.secondary,
            dense: true,
            onPressed: busy ? null : onUse,
          ),
        ],
      ),
    );
  }
}

/// 搜索中的骨架（`DESIGN.md` §2.4：加载用骨架块，不用转圈）。
class _CandidatesSkeleton extends StatelessWidget {
  const _CandidatesSkeleton();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _CandidateSkeletonRow(),
      _CandidateSkeletonRow(),
      _CandidateSkeletonRow(),
    ],
  );
}

class _CandidateSkeletonRow extends StatelessWidget {
  const _CandidateSkeletonRow();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: TySpace.x8),
    child: Row(
      children: <Widget>[
        TySkeleton(
          width: context.metrics.coverList,
          height: context.metrics.coverList,
          radius: TyRadius.xs,
        ),
        const SizedBox(width: TySpace.x12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TySkeleton.line(),
              SizedBox(height: TySpace.x6),
              TySkeleton.line(width: 160),
            ],
          ),
        ),
      ],
    ),
  );
}
