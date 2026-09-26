import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/playback_controller.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../playback/playback_item.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/cover_art.dart';
import '../shared/current_track.dart';
import '../shared/format.dart';
import 'seek_bar.dart';

/// 底部悬浮播放条（对齐旧版 `MacOSNowPlayingToolbar` 的紧凑形态）。
///
/// 展示的元数据取自库里的曲目行（抓取富化后会即时更新），而不是播放条目里的快照。
/// 窄窗口下按宽度逐级收敛：先去掉音量，再去掉进度条与时间，避免任何溢出。
///
/// 这一层只订阅"当前是哪一首"：进度 tick 不再重建封面与标题（重建封面就可能重解图片），
/// 播放键、进度条、音量各自订阅自己那几项。
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CurrentTrackRef current = ref.watch(currentTrackRefProvider);
    final Track? track = ref.watch(currentTrackProvider);
    final PlaybackController controller = ref.read(playbackProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 队列由外部设置时没有 id 映射，用引擎条目兜底。
    final PlaybackItem? item = current.item;
    final bool hasTrack = track != null || item != null;
    final String title = track?.title ?? item?.title ?? '未在播放';
    final String artist = track?.artist ?? item?.artist ?? '';
    final Uri? artUri = item?.artUri;
    final String? remoteArt =
        (artUri != null &&
            (artUri.scheme == 'http' || artUri.scheme == 'https'))
        ? artUri.toString()
        : null;

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
                    constraints: BoxConstraints(
                      maxWidth: showFullTitles ? 200 : 110,
                    ),
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
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
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
                  _PlayPauseButton(enabled: hasTrack),
                  IconButton(
                    tooltip: '下一首',
                    icon: const Icon(Icons.skip_next),
                    onPressed: hasTrack ? controller.next : null,
                  ),
                  if (showProgress) ...<Widget>[
                    const SizedBox(width: 4),
                    Expanded(child: _ProgressBar(enabled: hasTrack)),
                  ] else
                    const Spacer(),
                  const SizedBox(width: 8),
                  if (showVolume)
                    const Tooltip(
                      message: '音量',
                      child: SizedBox(width: 92, child: _VolumeSlider()),
                    ),
                  IconButton(
                    tooltip: '正在播放',
                    icon: const Icon(Icons.open_in_full),
                    onPressed: hasTrack
                        ? () => context.push('/now-playing')
                        : null,
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

/// 播放/暂停键：单独订阅 `playing`，进度 tick 与音量都不会重建它。
class _PlayPauseButton extends ConsumerWidget {
  const _PlayPauseButton({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool playing = ref.watch(
      playbackProvider.select((PlaybackSnapshot snapshot) => snapshot.playing),
    );
    return IconButton(
      tooltip: playing ? '暂停' : '播放',
      icon: Icon(
        playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
        size: 34,
      ),
      onPressed: enabled
          ? ref.read(playbackProvider.notifier).togglePlayPause
          : null,
    );
  }
}

/// 进度条：单独订阅 position/duration。
///
/// 也是唯一会随进度 tick 重建的部分；拖动只在松手时 seek 一次（见 [SeekBar]）。
class _ProgressBar extends ConsumerWidget {
  const _ProgressBar({required this.enabled});

  /// 有曲目才允许拖动（无曲目时进度条只是摆设）。
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ({Duration position, Duration duration}) progress = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot snapshot) => (
          position: snapshot.position,
          duration: snapshot.duration,
        ),
      ),
    );
    return SeekBar(
      position: progress.position,
      duration: progress.duration,
      // 时长未知时滑块没有可信的刻度，仍保持播放条原先的禁用策略。
      enabled: enabled && progress.duration > Duration.zero,
      // 播放条沿用 `--:--` 的时长口径，与正在播放页的 `0:00` 各自保留原样。
      format: formatDuration,
      onSeek: ref.read(playbackProvider.notifier).seek,
    );
  }
}

/// 音量条：单独订阅 `volume`，它与进度互不牵连。
class _VolumeSlider extends ConsumerWidget {
  const _VolumeSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double volume = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot snapshot) => snapshot.volume.clamp(0, 1).toDouble(),
      ),
    );
    return Slider(
      value: volume,
      onChanged: ref.read(playbackProvider.notifier).setVolume,
    );
  }
}
