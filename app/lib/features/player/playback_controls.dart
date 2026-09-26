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

/// 正在播放页的传送器：进度条 + 时间 + 随机 / 上一首 / 播放暂停 / 下一首 / 循环。
///
/// 数据只来自 [playbackProvider]，指令只走 `PlaybackController`。
/// 此前还有一个 `large: false` 的紧凑形态，但除了本页以外没有任何调用方
/// （桌面播放条用的是自己那套控件），留着只是两套从未被执行的布局，已删除。
class PlaybackControls extends ConsumerWidget {
  const PlaybackControls({super.key});

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

    // 传送键（上一首/下一首）与播放键的尺寸；两个模式键见 [_sideIconSize]。
    const double iconSize = 30;
    const double playSize = 60;
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
        _TransportSeekBar(onSeek: controller.seek),
        const SizedBox(height: 14),
        // 五个键均分整行（各自一个等宽槽），而不是"固定间隔 + 居中"：
        // 后者会因为各键宽度不同（大播放键 vs 普通图标）把间距撑得忽宽忽窄，
        // 实测中心距曾是 88.5 / 107 / 99.5 / 93.5 —— 左右两个模式键明显贴得近。
        // 等宽槽后中心距一致、两侧留白自动对称（对齐 QQ 音乐那排控件的观感）。
        Row(
          children: <Widget>[
            _TransportSlot(
              child: IconButton(
                onPressed: controller.toggleShuffle,
                iconSize: _sideIconSize,
                style: _iconButtonStyle,
                tooltip: isShuffle ? '随机播放：开' : '随机播放：关',
                color: isShuffle ? scheme.primary : scheme.onSurfaceVariant,
                icon: const Icon(Icons.shuffle_rounded),
              ),
            ),
            _TransportSlot(
              child: IconButton(
                onPressed: controller.previous,
                iconSize: iconSize,
                style: _iconButtonStyle,
                tooltip: '上一首',
                icon: const Icon(Icons.skip_previous_rounded),
              ),
            ),
            _TransportSlot(
              child: SizedBox(
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
            ),
            _TransportSlot(
              child: IconButton(
                onPressed: controller.next,
                iconSize: iconSize,
                style: _iconButtonStyle,
                tooltip: '下一首',
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ),
            _TransportSlot(
              child: IconButton(
                onPressed: controller.cycleRepeatMode,
                iconSize: _sideIconSize,
                style: _iconButtonStyle,
                tooltip: repeatTooltip,
                color: isRepeat ? scheme.primary : scheme.onSurfaceVariant,
                icon: Icon(repeatIcon),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 图标键的点击区域下限。
  ///
  /// M3 的 IconButton 默认是"图标尺寸 + 左右各 8dp 内边距"：图标 24/28/30 时分别只有
  /// 40/44/46dp，四个键全都低于 48dp 的最小触控目标（图标越小越难点）。
  /// 这里只撑大可点区域，图标视觉尺寸不变。
  static final ButtonStyle _iconButtonStyle = IconButton.styleFrom(
    minimumSize: const Size(48, 48),
  );

  /// 左右两个"模式键"（随机 / 循环）的图标尺寸。
  ///
  /// 与传送键（30）刻意只差一点点：QQ 音乐同样让上一首/下一首略大，
  /// 而此前的 24 vs 30 差幅太大，两个模式键看起来像被缩小过的次级控件。
  static const double _sideIconSize = 28;
}

/// 传送器里的一个等宽槽：让五个键的中心距一致、两侧留白对称。
class _TransportSlot extends StatelessWidget {
  const _TransportSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Expanded(child: Center(child: child));
}

/// 传送器里的进度条：唯一订阅 position/duration 的地方，
/// 进度 tick 因此不会波及上面的按钮行。
class _TransportSeekBar extends ConsumerWidget {
  const _TransportSeekBar({required this.onSeek});

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
      // 时长未知但已经在出进度时也要能拖：位置才是"能 seek"的依据。
      enabled:
          progress.position > Duration.zero ||
          progress.duration > Duration.zero,
      onSeek: onSeek,
    );
  }
}
