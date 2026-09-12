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

/// 正在播放页：左侧全屏舞台（动态背景 + 封面 + 传送器 + 歌词），右侧待播队列。
///
/// 信息架构对齐旧版 `MacOSNowPlayingStage`：封面居中，下面是曲目信息与传送器，
/// 歌词与封面并排；队列沿用 `UpNextQueueView` 的位置（右侧固定栏）。
class NowPlayingPage extends ConsumerWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackSnapshot snapshot = ref.watch(playbackProvider);
    final PlaybackController controller = ref.read(playbackProvider.notifier);

    final List<String> ids = controller.trackIds;
    final int index = snapshot.index;
    final String? trackId = (index >= 0 && index < ids.length) ? ids[index] : null;
    final Track? track =
        trackId == null ? null : ref.watch(trackByIdProvider(trackId)).value;
    // 队列可能不是经控制器设置的（调试入口 / 系统恢复）：此时用引擎条目兜底展示。
    final PlaybackItem? item = controller.currentItem;

    // 窄屏（手机）放不下 320px 的固定队列栏，改为"舞台铺满 + 队列用底部弹层"，
    // 与旧版 iOS 的 `IOSNowPlayingSheet` + 队列按钮的形态一致。
    final bool narrow = MediaQuery.sizeOf(context).width < 720;

    final Widget stage = FluidBackground(
            // 换色种子用封面标识：同一首歌永远得到同一套配色。
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
                        // 桌面是页面跳转，移动端是从曲库 push 进来的，直接返回即可。
                        onPressed: () => context.canPop() ? context.pop() : context.go('/library'),
                        icon: const Icon(Icons.arrow_back_rounded, size: 18),
                        label: const Text('返回'),
                      ),
                      const Spacer(),
                      // 窄屏没有固定队列栏，用底部弹层给队列入口。
                      if (narrow)
                        IconButton(
                          tooltip: '播放队列',
                          icon: const Icon(Icons.queue_music),
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            showDragHandle: true,
                            builder: (BuildContext sheetContext) => const SizedBox(
                              height: 420,
                              child: QueuePanel(),
                            ),
                          ),
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
        const VerticalDivider(width: 1),
        const SizedBox(width: 320, child: QueuePanel()),
      ],
    );
  }
}

/// 舞台：宽度够就封面与歌词并排，不够就上下叠（窄窗口下仍然可用）。
class _Stage extends StatelessWidget {
  const _Stage({required this.track, required this.item});

  final Track? track;

  final PlaybackItem? item;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool sideBySide = constraints.maxWidth >= 620;
        final double coverSize = sideBySide
            ? math.min(constraints.maxWidth * 0.38, 280.0)
            : math.max(math.min(constraints.maxWidth - 48, 220.0), 120.0);
        final Widget block = _StageBlock(track: track, item: item, coverSize: coverSize);

        if (!sideBySide) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              children: <Widget>[
                block,
                const SizedBox(height: 24),
                const SizedBox(height: 300, child: LyricsPanel()),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                flex: 4,
                child: Center(child: SingleChildScrollView(child: block)),
              ),
              const SizedBox(width: 32),
              const Expanded(flex: 5, child: LyricsPanel()),
            ],
          ),
        );
      },
    );
  }
}

/// 封面 + 曲目信息 + 传送器。
class _StageBlock extends StatelessWidget {
  const _StageBlock({required this.track, required this.item, required this.coverSize});

  /// 库里的曲目行（可能为空：队列由外部设置时没有 id 映射）。
  final Track? track;

  /// 引擎侧条目，作为 [track] 缺失时的展示来源。
  final PlaybackItem? item;

  final double coverSize;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String album = track?.album ?? item?.album ?? '';
    final bool showAlbum = album.isNotEmpty && !isPlaceholderAlbum(album);
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

/// 引擎条目的封面只有在是 http(s) 地址时才能交给 `CoverArt` 走网络加载。
String? _remoteArt(PlaybackItem? item) {
  final Uri? uri = item?.artUri;
  if (uri == null) {
    return null;
  }
  return (uri.scheme == 'http' || uri.scheme == 'https') ? uri.toString() : null;
}
