import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/playback_controller.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../playback/playback_item.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/cover_art.dart';

/// 迷你播放条：紧贴底部 Tab 栏上方的一行当前曲目。
///
/// 对应旧版 `Sources/UI/iOS/IOSMiniPlayer.swift`：封面 + 标题/艺术家 + 播放/暂停 +
/// 下一首，整行点击展开「正在播放」。元数据优先取曲库里的曲目行（抓取富化后会即时
/// 更新），队列由外部设置（调试入口 / 系统恢复）时回退到播放条目自身。
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  /// 行高；与 Tab 栏叠加构成底部区域（触摸目标 ≥44pt）。
  static const double height = 56;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackSnapshot snapshot = ref.watch(playbackProvider);
    final PlaybackController controller = ref.read(playbackProvider.notifier);

    final List<String> ids = controller.trackIds;
    final int index = snapshot.index;
    final String? trackId = (index >= 0 && index < ids.length) ? ids[index] : null;
    // 曲目行仍在读取或读取失败时回退到播放条目，迷你条不显示加载态。
    final Track? track = trackId == null ? null : ref.watch(trackByIdProvider(trackId)).value;
    final PlaybackItem? item = controller.currentItem;

    if (ids.isEmpty && item == null) {
      return const SizedBox.shrink();
    }

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final String title = track?.title ?? item?.title ?? '未在播放';
    final String artist = track?.artist ?? item?.artist ?? '';
    final Uri? artUri = item?.artUri;
    final String? remoteArt = (artUri != null && (artUri.scheme == 'http' || artUri.scheme == 'https'))
        ? artUri.toString()
        : null;

    return Material(
      color: scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => context.go('/now-playing'),
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
                      style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: snapshot.playing ? '暂停' : '播放',
                onPressed: controller.togglePlayPause,
                icon: Icon(snapshot.playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                tooltip: '下一首',
                onPressed: controller.next,
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
