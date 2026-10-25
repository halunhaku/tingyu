import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/lyrics_view.dart';
import '../../design/theme.dart';
import '../../design/tokens/metrics.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/current_track.dart';
import 'lrc_parser.dart';

/// 歌词面板（`DESIGN.md` §6.3 `TyLyricsView` 的数据接线）。
///
/// 这一层只管三件事：按进度算当前行、没有歌词时触发一次抓取、把行数据交给
/// `TyLyricsView` 渲染（舞台右栏、`/lyrics` 整页、检查器共用同一份）。
class LyricsPanel extends ConsumerStatefulWidget {
  const LyricsPanel({super.key, this.compact = false});
  final bool compact;

  @override
  ConsumerState<LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends ConsumerState<LyricsPanel> {
  /// 已解析的歌词文本与结果：每个 tick 都要按进度重算高亮，
  /// 缓存下来免得每 tick 重新解析整份 LRC。
  String? _parsedLyrics;

  LrcDocument? _parsedDocument;

  bool _fetching = false;

  @override
  Widget build(BuildContext context) {
    // 曲目来自当前播放身份（换曲才变），进度单独订阅：
    // 进度 tick 只重建歌词行高亮，不会连带重建整张快照依赖。
    final Track? track = ref.watch(currentTrackProvider);
    final Duration position = ref.watch(
      playbackProvider.select((PlaybackSnapshot snapshot) => snapshot.position),
    );

    if (track == null) {
      // 队列由外部设置（直链 / 调试入口）时没有曲库行：这时候「未在播放」是错的，
      // 该说的是「这首歌取不到歌词」。真的没在播放才说没在播放。
      final bool playingSomething = ref.watch(
        currentTrackRefProvider.select(
          (CurrentTrackRef value) => value.item != null,
        ),
      );
      if (widget.compact) {
        return _emptyPreview(context, playingSomething ? '这首没有歌词' : '未在播放');
      }
      return TyLyricsView(
        lines: const <TyLyricLine>[],
        emptyTitle: playingSomething ? '这首没有歌词' : '未在播放',
        emptyDescription: playingSomething ? '曲库外的曲目拿不到歌词信息' : '从曲库中选一首歌开始播放',
      );
    }

    final LrcDocument document = _documentFor(track.lyrics);
    if (widget.compact && document.lines.isEmpty) {
      return _emptyPreview(
        context,
        '未找到歌词',
        action: TextButton(
          onPressed: _fetching ? null : () => _fetchLyrics(track),
          child: Text(_fetching ? '抓取中…' : '抓取歌词'),
        ),
      );
    }
    return TyLyricsView(
      lines: <TyLyricLine>[
        for (final LrcLine line in document.lines)
          TyLyricLine(time: line.time, text: line.text),
      ],
      activeIndex: document.isSynced ? document.indexAt(position) : null,
      onLineTap: document.isSynced
          ? (TyLyricLine line) =>
                ref.read(playbackProvider.notifier).seek(line.time)
          : null,
      onRematch: _fetching ? null : () => _fetchLyrics(track),
      rematchLabel: _fetching ? '抓取中…' : '抓取歌词',
      emptyTitle: '未找到歌词',
      emptyDescription: '可以按歌名与歌手在 LRCLIB / 网易云 / QQ 音乐里重新匹配',
    );
  }

  Widget _emptyPreview(BuildContext context, String title, {Widget? action}) =>
      SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(TySpace.x8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                style: context.ty.typography.bodyS.copyWith(
                  color: context.ty.colors.textSecondary,
                ),
              ),
              ?action,
            ],
          ),
        ),
      );

  /// 解析结果按歌词文本缓存；换曲（或歌词被重新抓取）时连高亮进度一起重置。
  LrcDocument _documentFor(String? lyrics) {
    if (_parsedLyrics == lyrics && _parsedDocument != null) {
      return _parsedDocument!;
    }
    _parsedLyrics = lyrics;
    return _parsedDocument = LrcParser.parse(lyrics);
  }

  Future<void> _fetchLyrics(Track track) async {
    setState(() => _fetching = true);
    try {
      await ref.read(enrichmentServiceProvider).enrichTrack(track);
      ref.invalidate(trackByIdProvider(track.id));
    } finally {
      if (mounted) {
        setState(() => _fetching = false);
      }
    }
  }
}
