import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../sources/scraper/lrclib_provider.dart';
import '../../sources/scraper/metadata_provider.dart';
import '../../sources/scraper/netease_provider.dart';
import '../../sources/scraper/qq_music_provider.dart';
import '../shared/cover_art.dart';

/// 人工匹配：先填歌名 / 歌手 / 专辑，再搜候选并选定。
///
/// 对齐旧版 `ManualMatchSheet`，但打开时**不**自动搜索——夸克曲目的文件名
/// 经常是噪声，一打开就搜会打出一堆无关结果。占位专辑/歌手不预填进输入框。
Future<void> showManualMatchDialog(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => _ManualMatchDialog(track: track),
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
  String? _error;

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

  Future<void> _search() async {
    final String title = _title.text.trim();
    if (title.isEmpty) {
      setState(() {
        _error = '请先填写歌名';
        _candidates = const <MetadataCandidate>[];
        _didSearch = false;
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
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
      if (results.isEmpty) {
        _error = '没有找到候选，换个关键词试试';
      }
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
        coverPath = await ref
            .read(coverStoreProvider)
            .save(widget.track.id, bytes);
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
    return AlertDialog(
      title: const Text('匹配元数据'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _title,
                    decoration: const InputDecoration(
                      labelText: '歌名',
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      if (canSearch) {
                        _search();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _artist,
                    decoration: const InputDecoration(
                      labelText: '歌手（选填）',
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) {
                      if (canSearch) {
                        _search();
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _album,
                    decoration: const InputDecoration(
                      labelText: '专辑（选填）',
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) {
                      if (canSearch) {
                        _search();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: canSearch ? _search : null,
                  child: const Text('搜索'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '当前：${widget.track.title} · ${widget.track.artist} · ${widget.track.album}',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const Divider(height: 16),
            Expanded(
              child: _searching
                  ? const Center(child: CircularProgressIndicator())
                  : _candidates.isEmpty
                  ? Center(
                      child: Text(
                        _error ??
                            (_didSearch ? '没有找到候选，换个关键词试试' : '先填写歌名，再点搜索'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      itemCount: _candidates.length,
                      itemBuilder: (BuildContext context, int index) {
                        final MetadataCandidate candidate = _candidates[index];
                        return ListTile(
                          dense: true,
                          leading: CoverArt(
                            coverArtUrl: candidate.coverUrl,
                            size: 40,
                            radius: 4,
                          ),
                          title: Text(
                            candidate.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${candidate.artist} · ${candidate.album} · ${candidate.provider}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: TextButton(
                            onPressed: _applying
                                ? null
                                : () => _apply(candidate),
                            child: const Text('使用'),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _applying ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
