import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/playback_controller.dart';
import '../../app/providers.dart';
import '../../playback/playback_snapshot.dart';
import 'seek_bar.dart';

/// 传送器按钮行要的状态：都不随进度变化，所以进度 tick 不会重建按钮。
typedef _ButtonState = ({
  /// 还没出任何进度的首次装载：此时播放键显示转圈。
  bool firstLoad,
  bool playing,
  PlayOrder playOrder,
  PlaybackRepeatMode repeatMode,
});

/// 播放传送器：进度条 + 时间 + 上一首 / 播放暂停 / 下一首。
///
/// 数据只来自 [playbackProvider]，指令只走 `PlaybackController`；
/// [large] 为真时整体放大，供"正在播放"全屏舞台用，紧凑形态留给播放条一类场景。
class PlaybackControls extends ConsumerWidget {
  const PlaybackControls({super.key, this.large = false});

  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 按钮们只跟这几项有关：进度 tick 不重建它们，进度条自己订阅 position/duration。
    final _ButtonState state = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot snapshot) => (
          // 只有"还没出任何进度"的首次装载才让按钮变转圈：缓冲中仍然允许暂停，
          // 直链没有 Content-Length 时引擎会一首歌都报 loading，但那时音频已经在放了。
          firstLoad:
              snapshot.processing == PlaybackProcessing.loading &&
              snapshot.position <= Duration.zero,
          playing: snapshot.playing,
          playOrder: snapshot.playOrder,
          repeatMode: snapshot.repeatMode,
        ),
      ),
    );
    final PlaybackController controller = ref.read(playbackProvider.notifier);

    final double iconSize = large ? 30 : 20;
    final double playSize = large ? 60 : 40;
    final bool loading = state.firstLoad;
    final bool isShuffle = state.playOrder == PlayOrder.shuffle;
    final bool isRepeat = state.repeatMode != PlaybackRepeatMode.off;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final IconData repeatIcon = switch (state.repeatMode) {
      PlaybackRepeatMode.all => Icons.repeat_rounded,
      PlaybackRepeatMode.one => Icons.repeat_one_rounded,
      PlaybackRepeatMode.off => Icons.repeat_rounded,
    };
    final String repeatTooltip = switch (state.repeatMode) {
      PlaybackRepeatMode.all => '列表循环',
      PlaybackRepeatMode.one => '单曲循环',
      PlaybackRepeatMode.off => '顺序播放（播完停止）',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _TransportSeekBar(large: large, onSeek: controller.seek),
        SizedBox(height: large ? 14 : 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton(
              onPressed: controller.toggleShuffle,
              iconSize: large ? 24 : 18,
              tooltip: isShuffle ? '随机播放：开' : '随机播放：关',
              color: isShuffle
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.6),
              icon: const Icon(Icons.shuffle_rounded),
            ),
            SizedBox(width: large ? 16 : 6),
            IconButton(
              onPressed: controller.previous,
              iconSize: iconSize,
              tooltip: '上一首',
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            SizedBox(width: large ? 22 : 10),
            SizedBox(
              width: playSize,
              height: playSize,
              child: FilledButton(
                onPressed: controller.togglePlayPause,
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                ),
                child: loading
                    ? SizedBox(
                        width: playSize * 0.4,
                        height: playSize * 0.4,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        state.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: playSize * 0.56,
                      ),
              ),
            ),
            SizedBox(width: large ? 20 : 10),
            IconButton(
              onPressed: controller.next,
              iconSize: iconSize,
              tooltip: '下一首',
              icon: const Icon(Icons.skip_next_rounded),
            ),
            SizedBox(width: large ? 16 : 6),
            IconButton(
              onPressed: controller.cycleRepeatMode,
              iconSize: large ? 24 : 18,
              tooltip: repeatTooltip,
              color: isRepeat
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.6),
              icon: Icon(repeatIcon),
            ),
          ],
        ),
      ],
    );
  }
}

/// 传送器里的进度条：唯一订阅 position/duration 的地方，
/// 进度 tick 因此不会波及上面的按钮行。
class _TransportSeekBar extends ConsumerWidget {
  const _TransportSeekBar({required this.large, required this.onSeek});

  final bool large;

  final ValueChanged<Duration> onSeek;

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
      large: large,
      // 时长未知但已经在出进度时也要能拖：位置才是"能 seek"的依据。
      enabled:
          progress.position > Duration.zero ||
          progress.duration > Duration.zero,
      onSeek: onSeek,
    );
  }
}
