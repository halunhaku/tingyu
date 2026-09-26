import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/current_track.dart';
import 'lrc_parser.dart';

/// 歌词面板：按播放进度高亮当前行并自动滚动。
///
/// 纯文本歌词（没有时间轴）退化为可滚动文本；没有歌词时给一个"抓取"按钮，
/// 直接复用 M3 的富化服务（QQ 音乐 / LRCLIB / 网易云管道）。
class LyricsPanel extends ConsumerStatefulWidget {
  const LyricsPanel({super.key});

  @override
  ConsumerState<LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends ConsumerState<LyricsPanel> {
  final ScrollController _scrollController = ScrollController();

  int _lastActiveIndex = -1;

  /// 已解析的歌词文本与结果：面板每个 tick 都要按进度重算高亮，
  /// 缓存下来免得每 tick 重新解析整份 LRC。
  String? _parsedLyrics;

  LrcDocument? _parsedDocument;

  bool _fetching = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 曲目来自当前播放身份（换曲才变），进度单独订阅：
    // 这样进度 tick 只重建歌词行高亮，不会连带重建整张快照依赖。
    final Track? track = ref.watch(currentTrackProvider);
    final Duration position = ref.watch(
      playbackProvider.select((PlaybackSnapshot snapshot) => snapshot.position),
    );

    if (track == null) {
      return const _LyricsHint('未在播放');
    }

    final LrcDocument document = _documentFor(track.lyrics);
    if (document.isEmpty) {
      return _LyricsHint(
        '暂无歌词',
        action: FilledButton.tonal(
          onPressed: _fetching ? null : () => _fetchLyrics(track),
          child: Text(_fetching ? '抓取中…' : '抓取歌词'),
        ),
      );
    }

    final int active = document.isSynced ? document.indexAt(position) : -1;
    if (active != _lastActiveIndex && active >= 0) {
      _lastActiveIndex = active;
      // 面板被侧栏收起或切回封面时整棵子树已被移除，此时既没有滚动控制器
      // 也不该再排滚动；`mounted` 与 `_scrollTo` 的挂载检查各挡一层。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollTo(active);
        }
      });
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      itemCount: document.lines.length,
      itemBuilder: (BuildContext context, int lineIndex) {
        final LrcLine line = document.lines[lineIndex];
        final bool isActive = lineIndex == active;
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 180),
            style: Theme.of(context).textTheme.titleMedium!.copyWith(
                  color: isActive ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                ),
            child: Text(line.text.isEmpty ? '♪' : line.text),
          ),
        );
      },
    );
  }

  /// 解析结果按歌词文本缓存；换曲（或歌词被重新抓取）时连高亮进度一起重置。
  LrcDocument _documentFor(String? lyrics) {
    if (_parsedLyrics == lyrics && _parsedDocument != null) {
      return _parsedDocument!;
    }
    _parsedLyrics = lyrics;
    _lastActiveIndex = -1;
    return _parsedDocument = LrcParser.parse(lyrics);
  }

  void _scrollTo(int index) {
    // 面板不可见时没有挂载的滚动视图，自动滚动就到此为止。
    if (!_scrollController.hasClients) {
      return;
    }
    // 每行约 44px（正文 + 内边距），把当前行滚到视口 1/3 处。
    final double target = (index * 44.0) - 120;
    _scrollController.animateTo(
      target.clamp(0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
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

class _LyricsHint extends StatelessWidget {
  const _LyricsHint(this.text, {this.action});

  final String text;

  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          if (action != null) ...<Widget>[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}
