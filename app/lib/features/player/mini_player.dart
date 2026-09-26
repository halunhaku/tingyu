import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../playback/playback_item.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/cover_art.dart';
import '../shared/current_track.dart';

/// 迷你播放条：紧贴底部 Tab 栏上方的一行当前曲目。
///
/// 对应旧版 `Sources/UI/iOS/IOSMiniPlayer.swift`：封面 + 标题/艺术家 + 播放/暂停 +
/// 下一首，整行点击展开「正在播放」。元数据优先取曲库里的曲目行（抓取富化后会即时
/// 更新），队列由外部设置（调试入口 / 系统恢复）时回退到播放条目自身。
///
/// 这一层只订阅"当前是哪一首"，播放/暂停单独由 [_MiniPlayPause] 订阅：
/// 进度 tick 不再重建封面（重建一次封面就可能重解一次图片）。
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  /// 行高；与 Tab 栏叠加构成底部区域（触摸目标 ≥44pt）。
  static const double height = 56;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CurrentTrackRef current = ref.watch(currentTrackRefProvider);
    final Track? track = ref.watch(currentTrackProvider);
    final PlaybackItem? item = current.item;
    final List<String> ids = ref.read(playbackProvider.notifier).trackIds;

    if (ids.isEmpty && item == null) {
      return const SizedBox.shrink();
    }

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final String title = track?.title ?? item?.title ?? '未在播放';
    final String artist = track?.artist ?? item?.artist ?? '';
    final Uri? artUri = item?.artUri;
    final String? remoteArt =
        (artUri != null &&
            (artUri.scheme == 'http' || artUri.scheme == 'https'))
        ? artUri.toString()
        : null;

    return Material(
      color: scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => context.push('/now-playing'),
        child: SizedBox(
          height: height,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 12),
              CoverArt(
                coverArtPath: track?.coverArtPath,
                coverArtUrl: track?.coverArtUrl ?? remoteArt,
                size: 36,
                radius: 6,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const _MiniPlayPause(),
              IconButton(
                tooltip: '下一首',
                onPressed: ref.read(playbackProvider.notifier).next,
                icon: const Icon(Icons.skip_next),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// 迷你条的播放/暂停键：只订阅 `playing`，切一次播放状态不动封面与标题。
class _MiniPlayPause extends ConsumerWidget {
  const _MiniPlayPause();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool playing = ref.watch(
      playbackProvider.select((PlaybackSnapshot snapshot) => snapshot.playing),
    );
    return IconButton(
      tooltip: playing ? '暂停' : '播放',
      onPressed: ref.read(playbackProvider.notifier).togglePlayPause,
      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
    );
  }
}
