import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../playback/playback_item.dart';
import '../../data/db/database.dart';
import '../shared/cover_art.dart';
import '../shared/current_track.dart';
import '../shared/empty_state.dart';
import 'fluid_background.dart';
import 'lyrics_panel.dart';
import 'playback_controls.dart';
import 'queue_panel.dart';

/// 正在播放：只保留封面舞台；歌词 / 队列按需让位。
///
/// 桌面：歌词与队列都是右侧滑出的面板。
/// 手机：**点封面切到歌词、点歌词切回封面**（对齐常见播放器，不再单设歌词按钮）；
/// 队列仍是底部弹层。
class NowPlayingPage extends ConsumerStatefulWidget {
  const NowPlayingPage({super.key});

  @override
  ConsumerState<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends ConsumerState<NowPlayingPage> {
  bool _lyricsOpen = false;
  bool _queueOpen = false;

  void _toggleLyrics() => setState(() => _lyricsOpen = _lyricsOpen == false);

  void _toggleQueue({required bool narrow}) {
    if (narrow) {
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        // 弹层贴着屏幕底部，得自己让开全面屏手势条。
        builder: (BuildContext sheetContext) => const SafeArea(
          top: false,
          child: SizedBox(height: 420, child: QueuePanel()),
        ),
      );
      return;
    }
    setState(() => _queueOpen = _queueOpen == false);
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅"当前是哪一首"：进度 tick 不再重建封面舞台与光晕背景
    // （传送器、歌词、队列各自订阅自己需要的部分）。
    final CurrentTrackRef current = ref.watch(currentTrackRefProvider);
    final Track? track = ref.watch(currentTrackProvider);
    final PlaybackItem? item = current.item;
    final bool narrow = MediaQuery.sizeOf(context).width < 720;

    final Widget stageContent = (track == null && item == null)
        ? const EmptyState(
            icon: Icons.headphones_outlined,
            title: '未在播放',
            message: '从曲库中选一首歌开始播放',
          )
        : _Stage(
            track: track,
            item: item,
            onTapCover: narrow ? _toggleLyrics : null,
          );

    final Widget stage = FluidBackground(
      seed: track?.coverArtPath ??
          track?.coverArtUrl ??
          item?.artUri?.toString() ??
          item?.id,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            // 这一页整页出血，顶栏自己让开状态栏（桌面安全区为 0，无影响）。
            padding: EdgeInsets.fromLTRB(
              10,
              8 + MediaQuery.paddingOf(context).top,
              10,
              0,
            ),
            child: Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: () =>
                      context.canPop() ? context.pop() : context.go('/library'),
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text('返回'),
                ),
                const Spacer(),
                if (narrow == false)
                  IconButton(
                    tooltip: '歌词',
                    isSelected: _lyricsOpen,
                    icon: Icon(
                      _lyricsOpen ? Icons.lyrics : Icons.lyrics_outlined,
                    ),
                    onPressed: _toggleLyrics,
                  ),
                IconButton(
                  tooltip: '播放队列',
                  isSelected: narrow ? false : _queueOpen,
                  icon: Icon(_queueOpen && narrow == false
                      ? Icons.queue_music
                      : Icons.queue_music_outlined),
                  onPressed: () => _toggleQueue(narrow: narrow),
                ),
              ],
            ),
          ),
          Expanded(
            child: narrow == false
                ? stageContent
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _lyricsOpen
                        ? _LyricsStage(
                            key: const ValueKey<String>('lyrics'),
                            onTap: _toggleLyrics,
                          )
                        : KeyedSubtree(
                            key: const ValueKey<String>('stage'),
                            child: stageContent,
                          ),
                  ),
          ),
        ],
      ),
    );

    if (narrow) {
      return stage;
    }

    return Row(
      children: <Widget>[
        Expanded(child: stage),
        _SidePanel(
          open: _lyricsOpen,
          width: 360,
          title: '歌词',
          onClose: () => setState(() => _lyricsOpen = false),
          child: const LyricsPanel(),
        ),
        _SidePanel(
          open: _queueOpen,
          width: 320,
          title: '接下来播放',
          onClose: () => setState(() => _queueOpen = false),
          child: const QueuePanel(),
        ),
      ],
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({
    required this.open,
    required this.width,
    required this.title,
    required this.onClose,
    required this.child,
  });

  final bool open;

  final double width;

  final String title;

  final VoidCallback onClose;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        width: open ? width : 0,
        child: open
            ? SizedBox(
                width: width,
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 4, 0),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                title,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: onClose,
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(child: child),
                    ],
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// 手机上的歌词：整块可点，点回封面。
///
/// 面板里的按钮（如「抓取歌词」）是它的后代，手势竞技场逐层判定，
/// 按钮自己吃掉点击，只有歌词与空白回到封面。
class _LyricsStage extends StatelessWidget {
  const _LyricsStage({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: const LyricsPanel(),
    );
  }
}

/// 封面舞台：只放封面、曲目信息和传送器。
class _Stage extends StatelessWidget {
  const _Stage({required this.track, required this.item, this.onTapCover});

  final Track? track;

  final PlaybackItem? item;

  /// 手机上点封面切歌词；桌面为 null（歌词走侧栏按钮）。
  final VoidCallback? onTapCover;

  @override
  Widget build(BuildContext context) {
    // 底部让开全面屏手势条；传送器就落在它上面 24dp 处（QQ 音乐同样把控件压在下缘）。
    final double bottomInset = MediaQuery.paddingOf(context).bottom + 24;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 封面用"宽度上限"和"高度的一部分"共同约束：高度放开到 0.56 是为了在竖屏高屏上
        // 别把余量全留给空白，同时仍然保证下方信息区与控件区放得下。
        final double coverSize = math.min(
          math.min(constraints.maxWidth - 48, constraints.maxHeight * 0.56),
          360,
        ).clamp(120.0, 360.0).toDouble();
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 8, 24, bottomInset),
          child: ConstrainedBox(
            // 内容比一屏矮时把这一列撑满一屏：多出来的高度由 _StageBlock 里的 Spacer
            // 吸收（落在封面信息与传送器之间），而不是像原先那样让整块居中、
            // 在控件下方留出一大块死白 —— 真机实测那里空了 127dp。
            constraints: BoxConstraints(
              minHeight: math.max(0, constraints.maxHeight - 8 - bottomInset),
            ),
            child: IntrinsicHeight(
              child: _StageBlock(
                track: track,
                item: item,
                coverSize: coverSize,
                onTapCover: onTapCover,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StageBlock extends StatelessWidget {
  const _StageBlock({
    required this.track,
    required this.item,
    required this.coverSize,
    this.onTapCover,
  });

  final Track? track;

  final PlaybackItem? item;

  final double coverSize;

  final VoidCallback? onTapCover;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String album = track?.album ?? item?.album ?? '';
    final bool showAlbum = album.isNotEmpty && isPlaceholderAlbum(album) == false;
    final TextStyle? muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    final Widget block = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.32),
                  blurRadius: 30,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: CoverArt(
              coverArtPath: track?.coverArtPath,
              coverArtUrl: track?.coverArtUrl ?? _remoteArt(item),
              size: coverSize,
              radius: 14,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            track?.title ?? item?.title ?? '未知曲目',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            track?.artist ?? item?.artist ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: muted,
          ),
          if (showAlbum) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          // 竖屏高屏上把余量放在这里（而不是控件下方）：传送器因此落在页面下缘，
          // 与 QQ 音乐一致；矮屏上 Spacer 收成 0，由外层滚动兜底。
          const Spacer(),
          const SizedBox(height: 24),
          const PlaybackControls(),
        ],
      ),
    );

    if (onTapCover == null) {
      return block;
    }
    // 整块（封面 + 曲目信息）都可点；传送器是后代，按钮与进度条自己吃掉手势。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTapCover,
      child: block,
    );
  }
}

String? _remoteArt(PlaybackItem? item) {
  final Uri? uri = item?.artUri;
  if (uri == null) {
    return null;
  }
  return (uri.scheme == 'http' || uri.scheme == 'https') ? uri.toString() : null;
}
