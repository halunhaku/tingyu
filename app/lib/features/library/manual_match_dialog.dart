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

/// 人工匹配：搜索候选并手动选定正确的元数据（对齐旧版 `ManualMatchSheet`）。
///
/// 自动抓取用的是"互相包含"的宽松判据，遇到翻唱/同名版本会命中错误条目；
/// 这里让用户直接指定，选定后写入歌手/专辑/标题/封面/歌词。
Future<void> showManualMatchDialog(BuildContext context, WidgetRef ref, Track track) async {
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
  late final TextEditingController _query = TextEditingController(text: widget.track.title);

  final QQMusicProvider _qq = QQMusicProvider();
  final NetEaseProvider _netease = NetEaseProvider();
  final LrclibProvider _lrclib = LrclibProvider();

  List<MetadataCandidate> _candidates = const <MetadataCandidate>[];
  bool _searching = false;
  bool _applying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _error = null;
    });
    final String query = _query.text.trim();
    final List<MetadataCandidate> results = <MetadataCandidate>[
      ...await _qq.searchCandidates(query, artist: _artistHint, limit: 8),
      ...await _netease.searchCandidates(query, artist: _artistHint, limit: 5),
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

  String get _artistHint {
    final String artist = widget.track.artist;
    return artist == '未知艺术家' ? '' : artist;
  }

  Future<void> _apply(MetadataCandidate candidate) async {
    setState(() => _applying = true);
    final Duration duration = Duration(milliseconds: (widget.track.duration * 1000).round());

    String? coverPath;
    if (candidate.coverUrl != null) {
      final Uint8List? bytes = await ImageDownloader().download(candidate.coverUrl!);
      if (bytes != null) {
        coverPath = await ref.read(coverStoreProvider).save(widget.track.id, bytes);
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
        LyricsQuery(title: candidate.title, artist: candidate.artist, album: candidate.album),
        candidate: candidate,
      );
    }

    await ref.read(trackRepositoryProvider).applyEnrichment(
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
    return AlertDialog(
      title: const Text('匹配元数据'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _query,
                    decoration: const InputDecoration(
                      labelText: '搜索关键词',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _searching ? null : _search,
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
                            _error ?? '输入关键词后点搜索',
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
                              title: Text(candidate.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${candidate.artist} · ${candidate.album} · ${candidate.provider}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: TextButton(
                                onPressed: _applying ? null : () => _apply(candidate),
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
