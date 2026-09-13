import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/playback_controller.dart';
import '../../app/providers.dart';
import '../../playback/playback_item.dart';
import '../../data/db/database.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/cover_art.dart';
import '../shared/empty_state.dart';
import 'fluid_background.dart';
import 'lyrics_panel.dart';
import 'playback_controls.dart';
import 'queue_panel.dart';

/// 正在播放：只保留封面舞台；歌词 / 队列用按钮打开。
///
/// 桌面：侧栏滑出。手机：歌词整页、队列底部弹层。对齐常见播放器，不再把三块挤在一屏。
class NowPlayingPage extends ConsumerStatefulWidget {
  const NowPlayingPage({super.key});

  @override
  ConsumerState<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends ConsumerState<NowPlayingPage> {
  bool _lyricsOpen = false;
  bool _queueOpen = false;

  void _toggleLyrics({required bool narrow}) {
    if (narrow) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const _LyricsPage()),
      );
      return;
    }
    setState(() => _lyricsOpen = _lyricsOpen == false);
  }

  void _toggleQueue({required bool narrow}) {
    if (narrow) {
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (BuildContext sheetContext) => const SizedBox(
          height: 420,
          child: QueuePanel(),
        ),
      );
      return;
    }
    setState(() => _queueOpen = _queueOpen == false);
  }

  @override
  Widget build(BuildContext context) {
    final PlaybackSnapshot snapshot = ref.watch(playbackProvider);
    final PlaybackController controller = ref.read(playbackProvider.notifier);

    final List<String> ids = controller.trackIds;
    final int index = snapshot.index;
    final String? trackId = (index >= 0 && index < ids.length) ? ids[index] : null;
    final Track? track =
        trackId == null ? null : ref.watch(trackByIdProvider(trackId)).value;
    final PlaybackItem? item = controller.currentItem;
    final bool narrow = MediaQuery.sizeOf(context).width < 720;

    final Widget stage = FluidBackground(
      seed: track?.coverArtPath ??
          track?.coverArtUrl ??
          item?.artUri?.toString() ??
          item?.id,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: () =>
                      context.canPop() ? context.pop() : context.go('/library'),
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text('返回'),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '歌词',
                  isSelected: narrow ? false : _lyricsOpen,
                  icon: Icon(_lyricsOpen && narrow == false
                      ? Icons.lyrics
                      : Icons.lyrics_outlined),
                  onPressed: () => _toggleLyrics(narrow: narrow),
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
            child: (track == null && item == null)
                ? const EmptyState(
                    icon: Icons.headphones_outlined,
                    title: '未在播放',
                    message: '从曲库中选一首歌开始播放',
                  )
                : _Stage(track: track, item: item),
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

class _LyricsPage extends StatelessWidget {
  const _LyricsPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('歌词'),
      ),
      body: const LyricsPanel(),
    );
  }
}

/// 封面舞台：只放封面、曲目信息和传送器。
class _Stage extends StatelessWidget {
  const _Stage({required this.track, required this.item});

  final Track? track;

  final PlaybackItem? item;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double coverSize = math.min(
          math.min(constraints.maxWidth - 48, constraints.maxHeight * 0.48),
          340,
        ).clamp(120.0, 340.0).toDouble();
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: _StageBlock(track: track, item: item, coverSize: coverSize),
          ),
        );
      },
    );
  }
}

class _StageBlock extends StatelessWidget {
  const _StageBlock({required this.track, required this.item, required this.coverSize});

  final Track? track;

  final PlaybackItem? item;

  final double coverSize;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String album = track?.album ?? item?.album ?? '';
    final bool showAlbum = album.isNotEmpty && isPlaceholderAlbum(album) == false;
    final TextStyle? muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
          const SizedBox(height: 24),
          const PlaybackControls(large: true),
        ],
      ),
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
