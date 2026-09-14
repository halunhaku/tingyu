import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/playback_controller.dart';
import '../../app/providers.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/format.dart';

/// 播放传送器：进度条 + 时间 + 上一首 / 播放暂停 / 下一首。
///
/// 数据只来自 [playbackProvider]，指令只走 `PlaybackController`；
/// [large] 为真时整体放大，供"正在播放"全屏舞台用，紧凑形态留给播放条一类场景。
class PlaybackControls extends ConsumerWidget {
  const PlaybackControls({super.key, this.large = false});

  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackSnapshot snapshot = ref.watch(playbackProvider);
    final PlaybackController controller = ref.read(playbackProvider.notifier);

    final double iconSize = large ? 30 : 20;
    final double playSize = large ? 60 : 40;
    // 只有"首次装载"才让按钮变成转圈：缓冲中仍然允许暂停。
    final bool loading = snapshot.processing == PlaybackProcessing.loading;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SeekBar(
          position: snapshot.position,
          duration: snapshot.duration,
          large: large,
          onSeek: controller.seek,
        ),
        SizedBox(height: large ? 14 : 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
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
                        snapshot.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: playSize * 0.56,
                      ),
              ),
            ),
            SizedBox(width: large ? 22 : 10),
            IconButton(
              onPressed: controller.next,
              iconSize: iconSize,
              tooltip: '下一首',
              icon: const Icon(Icons.skip_next_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

/// 进度条 + 两端时间。
///
/// 拖动期间只更新本地预览值，松手（`onChangeEnd`）才把目标位置交给引擎：
/// seek 是异步的，若边拖边写回，引擎回传的旧位置会把滑块反复拽回去（抖动）。
/// 松手后仍以本地目标值显示，直到引擎位置跟上（或 2s 超时）才交还控制权。
class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.position,
    required this.duration,
    required this.large,
    required this.onSeek,
  });

  final Duration position;

  final Duration duration;

  final bool large;

  final ValueChanged<Duration> onSeek;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// 拖动中的本地预览（秒）。
  double? _dragSeconds;

  /// 松手后等待引擎回传期间的显示值（秒）。
  double? _settleSeconds;

  Timer? _settleTimer;

  @override
  void didUpdateWidget(_SeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final double? settle = _settleSeconds;
    // 引擎位置已经跟上目标：交还显示控制权（随后必然重新 build，无需 setState）。
    if (settle != null &&
        (widget.position.inMilliseconds / 1000 - settle).abs() < 1.5) {
      _settleTimer?.cancel();
      _settleTimer = null;
      _settleSeconds = null;
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  void _onChangeStart(double value) {
    _settleTimer?.cancel();
    _settleTimer = null;
    setState(() {
      _dragSeconds = value;
      _settleSeconds = null;
    });
  }

  void _onChanged(double value) {
    setState(() => _dragSeconds = value);
  }

  void _onChangeEnd(double value) {
    widget.onSeek(Duration(milliseconds: (value * 1000).round()));
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _settleSeconds = null);
      }
    });
    setState(() {
      _dragSeconds = null;
      _settleSeconds = value;
    });
  }

  /// 与 [formatDuration] 的唯一差别：0 显示 `0:00` 而不是 `--:--`。
  String _clock(Duration duration) =>
      duration <= Duration.zero ? '0:00' : formatDuration(duration);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme text = theme.textTheme;
    final bool enabled = widget.duration > Duration.zero;

    final double maxSeconds =
        math.max(widget.duration.inMilliseconds / 1000, 1.0);
    final double rawSeconds =
        _dragSeconds ?? _settleSeconds ?? widget.position.inMilliseconds / 1000;
    final double value = rawSeconds.clamp(0, maxSeconds).toDouble();
    final Duration shown = Duration(milliseconds: (value * 1000).round());

    final TextStyle base = (widget.large ? text.bodySmall : text.labelSmall) ??
        const TextStyle(fontSize: 12);
    final TextStyle timeStyle = base.copyWith(
      color: scheme.onSurfaceVariant,
      // 等宽数字：播放时两侧时间不会左右跳动。
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    return Row(
      children: <Widget>[
        SizedBox(
          width: widget.large ? 56 : 44,
          child: Text(_clock(shown), style: timeStyle, textAlign: TextAlign.right),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: widget.large ? 5 : 3,
              thumbShape: RoundSliderThumbShape(
                enabledThumbRadius: widget.large ? 8 : 6,
              ),
              overlayShape: RoundSliderOverlayShape(
                overlayRadius: widget.large ? 18 : 14,
              ),
            ),
            child: Slider(
              value: value,
              max: maxSeconds,
              onChanged: enabled ? _onChanged : null,
              onChangeStart: enabled ? _onChangeStart : null,
              onChangeEnd: enabled ? _onChangeEnd : null,
            ),
          ),
        ),
        SizedBox(
          width: widget.large ? 56 : 44,
          child: Text(_clock(widget.duration), style: timeStyle),
        ),
      ],
    );
  }
}
