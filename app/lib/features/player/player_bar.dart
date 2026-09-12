import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/playback_controller.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../playback/playback_item.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/cover_art.dart';
import '../shared/format.dart';

/// 底部悬浮播放条（对齐旧版 `MacOSNowPlayingToolbar` 的紧凑形态）。
///
/// 展示的元数据取自库里的曲目行（抓取富化后会即时更新），而不是播放条目里的快照。
/// 窄窗口下按宽度逐级收敛：先去掉音量，再去掉进度条与时间，避免任何溢出。
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackSnapshot snapshot = ref.watch(playbackProvider);
    final PlaybackController controller = ref.read(playbackProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final List<String> ids = controller.trackIds;
    final int index = snapshot.index;
    final String? trackId = (index >= 0 && index < ids.length) ? ids[index] : null;
    final Track? track = trackId == null ? null : ref.watch(trackByIdProvider(trackId)).value;
    // 队列由外部设置时没有 id 映射，用引擎条目兜底。
    final PlaybackItem? item = controller.currentItem;
    final bool hasTrack = track != null || item != null;
    final String title = track?.title ?? item?.title ?? '未在播放';
    final String artist = track?.artist ?? item?.artist ?? '';
    final Uri? artUri = item?.artUri;
    final String? remoteArt = (artUri != null && (artUri.scheme == 'http' || artUri.scheme == 'https'))
        ? artUri.toString()
        : null;

    final Duration duration = snapshot.duration;
    final double progress = duration.inMilliseconds <= 0
        ? 0
        : (snapshot.position.inMilliseconds / duration.inMilliseconds).clamp(0, 1).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        color: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double width = constraints.maxWidth;
              final bool showProgress = width >= 560;
              final bool showVolume = width >= 780;
              final bool showFullTitles = width >= 640;

              return Row(
                children: <Widget>[
                  CoverArt(
                    coverArtPath: track?.coverArtPath,
                    coverArtUrl: track?.coverArtUrl ?? remoteArt,
                    size: 44,
                    radius: 8,
                  ),
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: showFullTitles ? 200 : 110),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        if (showFullTitles)
                          Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '上一首',
                    icon: const Icon(Icons.skip_previous),
                    onPressed: hasTrack ? controller.previous : null,
                  ),
                  IconButton(
                    tooltip: snapshot.playing ? '暂停' : '播放',
                    icon: Icon(
                      snapshot.playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                      size: 34,
                    ),
                    onPressed: hasTrack ? controller.togglePlayPause : null,
                  ),
                  IconButton(
                    tooltip: '下一首',
                    icon: const Icon(Icons.skip_next),
                    onPressed: hasTrack ? controller.next : null,
                  ),
                  if (showProgress) ...<Widget>[
                    const SizedBox(width: 4),
                    Text(formatDuration(snapshot.position), style: Theme.of(context).textTheme.bodySmall),
                    Expanded(
                      child: Slider(
                        value: progress,
                        onChanged: hasTrack && duration.inMilliseconds > 0
                            ? (double value) => controller.seek(
                                  Duration(milliseconds: (value * duration.inMilliseconds).round()),
                                )
                            : null,
                      ),
                    ),
                    Text(formatDuration(duration), style: Theme.of(context).textTheme.bodySmall),
                  ] else
                    const Spacer(),
                  const SizedBox(width: 8),
                  if (showVolume)
                    Tooltip(
                      message: '音量',
                      child: SizedBox(
                        width: 92,
                        child: Slider(
                          value: snapshot.volume.clamp(0, 1).toDouble(),
                          onChanged: controller.setVolume,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: '正在播放',
                    icon: const Icon(Icons.open_in_full),
                    onPressed: hasTrack ? () => context.go('/now-playing') : null,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
