import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../shared/format.dart';

/// 进度条 + 两端时间：正在播放页与底部播放条共用。
///
/// 拖动期间只更新本地预览值，松手（`onChangeEnd`）才把目标位置交给引擎：
/// seek 是异步的，若边拖边写回，引擎回传的旧位置会把滑块反复拽回去（抖动）。
/// 松手后仍以本地目标值显示，直到引擎位置跟上（或 2s 超时）才交还控制权。
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.large = false,
    this.enabled = true,
    this.format,
  });

  /// 引擎回传的当前位置。
  final Duration position;

  /// 当前曲目总时长；`Duration.zero` 表示未知（直链没有 Content-Length）。
  final Duration duration;

  /// 松手后才回调的目标位置。
  final ValueChanged<Duration> onSeek;

  /// 放大形态：正在播放页用；紧凑形态留给播放条一类场景。
  final bool large;

  /// 是否允许拖动。引擎位置不可信时（时长未知且还没出进度）传 false。
  final bool enabled;

  /// 时间文案；缺省时 0 显示 `0:00`（播放条要 `--:--` 的那种传 `formatDuration`）。
  final String Function(Duration duration)? format;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  /// 拖动中的本地预览（秒）。
  double? _dragSeconds;

  /// 松手后等待引擎回传期间的显示值（秒）。
  double? _settleSeconds;

  Timer? _settleTimer;

  @override
  void didUpdateWidget(SeekBar oldWidget) {
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

  /// 与 `formatDuration` 的唯一差别：0 显示 `0:00` 而不是 `--:--`。
  String _clock(Duration duration) =>
      duration <= Duration.zero ? '0:00' : formatDuration(duration);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme text = theme.textTheme;
    final String Function(Duration) clock = widget.format ?? _clock;
    final bool enabled = widget.enabled;

    final double maxSeconds = math.max(
      widget.duration.inMilliseconds / 1000,
      1.0,
    );
    final double rawSeconds =
        _dragSeconds ?? _settleSeconds ?? widget.position.inMilliseconds / 1000;
    final double value = rawSeconds.clamp(0, maxSeconds).toDouble();
    final Duration shown = Duration(milliseconds: (value * 1000).round());

    final TextStyle base =
        (widget.large ? text.bodySmall : text.labelSmall) ??
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
          child: Text(
            clock(shown),
            style: timeStyle,
            textAlign: TextAlign.right,
          ),
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
              // 读屏软件默认只报"百分比"；这里报"当前位置 / 总时长"，
              // 盲操作时才知道自己在歌里的哪一段。
              semanticFormatterCallback: (double seconds) {
                final Duration at = Duration(
                  milliseconds: (seconds * 1000).round(),
                );
                return '${clock(at)} / ${clock(widget.duration)}';
              },
            ),
          ),
        ),
        SizedBox(
          width: widget.large ? 56 : 44,
          child: Text(clock(widget.duration), style: timeStyle),
        ),
      ],
    );
  }
}
