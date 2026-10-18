import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'buttons.dart';
import 'cover.dart';
import 'feedback.dart';
import 'interactive.dart';

/// 播放器几何档位（`DESIGN.md` §3.4 / §6.3 / §8）。
///
/// `TyIconSize` / `TySize` 里没有对应档位的控件尺寸集中在这里，布局中不出现裸数字。
abstract final class TyPlayerSize {
  /// 舞台：随机 / 重复的图标。
  static const double stageSideIcon = TyIconSize.toolbar;

  /// 舞台：上一 / 下一的图标。
  static const double stageKeyIcon = 32;

  /// 舞台：播放主控圆直径。
  static const double stagePlay = TyIconSize.playControl;

  /// 传输条：随机 / 重复的图标。
  static const double barSideIcon = TyIconSize.compact;

  /// 传输条：上一 / 下一的图标。
  static const double barKeyIcon = TySpace.x20;

  /// 传输条：播放主控圆直径。
  static const double barPlay = 36;

  /// 播放主控图标 / 圆直径。
  static const double playIconRatio = 0.56;

  /// 传输主控的最小命中区（`DESIGN.md` §8：传输主控 ≥ 48）。
  static const double transportHitTarget = 48;

  /// `TyFocusRing` 占用的外框（2px 环 + 2px 偏移）。
  static const double focusRingCost = TySpace.x8;

  /// 传输条：封面边长。
  static const double barCover = 56;

  /// 传输条：左侧信息块最大宽度。
  static const double barLeadingMaxWidth = 320;

  /// 传输条：传输行 / 进度行的最大宽度。
  static const double barTransportMaxWidth = 420;
  static const double barProgressMaxWidth = 640;

  /// 传输条：进度行的命中高度（整条 72 高，传输行已占掉 40）。
  static const double barSeekHitHeight = TySpace.x24;

  /// 进度条：时间列宽、轨道高、hover-drag 轨道高、手柄直径。
  static const double timeColumn = TySpace.x64;
  static const double track = 4;
  static const double trackActive = 8;
  static const double thumb = 12;

  /// 拖拽时间 tooltip 的宽度与高度（浮在轨道上方）。
  static const double timeLabelWidth = TySpace.x64;
  static const double timeLabelHeight = TySpace.x24;

  /// 进度条：缓冲区占 30%（`DESIGN.md` §6.3）。
  static const double bufferOpacity = 0.3;

  /// 进度条：松手后等引擎回传的容差与超时。
  static const double settleToleranceMs = 1500;
  static const Duration settleTimeout = Duration(seconds: 2);

  /// 音量：滑条展开宽度、轨道命中高度。
  static const double volumeSlider = 96;
  static const double volumeTrackHitHeight = TySpace.x20;
}

/// 传输键行：随机 / 上一 / 播放主控 / 下一 / 重复。
///
/// 五个等宽槽（`DESIGN.md` §6.3）：各键宽度不同（大播放键 vs 图标键）时，
/// 「固定间隔 + 整体居中」会把中心距撑得忽宽忽窄，等宽槽才让中心距一致、两侧留白对称。
/// 舞台与传输条共用同一份实现，靠尺寸参数区分（§10.3：不留两套近似组件）。
class TyTransportRow extends StatelessWidget {
  const TyTransportRow({
    super.key,
    required this.playing,
    required this.onPlayPause,
    this.onPrevious,
    this.onNext,
    this.loading = false,
    this.shuffled = false,
    this.onToggleShuffle,
    this.repeatActive = false,
    this.repeatIcon = Icons.repeat_rounded,
    this.repeatTooltip = '列表循环',
    this.onCycleRepeat,
    this.sideIconSize = TyPlayerSize.stageSideIcon,
    this.keyIconSize = TyPlayerSize.stageKeyIcon,
    this.playSize = TyPlayerSize.stagePlay,
    this.hitSize = TyPlayerSize.transportHitTarget,
  });

  /// 当前是否在出声（决定播放键画「暂停」还是「播放」）。
  final bool playing;

  /// 首次装载（还没出任何进度）时播放键显示载入态。
  final bool loading;

  final VoidCallback? onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  final bool shuffled;
  final VoidCallback? onToggleShuffle;

  final bool repeatActive;
  final IconData repeatIcon;

  /// 循环模式的 tooltip：文案由宿主给（顺序 / 列表 / 单曲）。
  final String repeatTooltip;
  final VoidCallback? onCycleRepeat;

  final double sideIconSize;
  final double keyIconSize;
  final double playSize;

  /// 每个键的命中区边长（舞台 48，传输条取 `metrics.hitTarget`）。
  final double hitSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _slot(
          _TransportKey(
            icon: Icons.shuffle_rounded,
            size: sideIconSize,
            hitSize: hitSize,
            tooltip: shuffled ? '随机播放：开' : '随机播放：关',
            active: shuffled,
            onPressed: onToggleShuffle,
          ),
        ),
        _slot(
          _TransportKey(
            icon: Icons.skip_previous_rounded,
            size: keyIconSize,
            hitSize: hitSize,
            tooltip: '上一首',
            onPressed: onPrevious,
          ),
        ),
        _slot(
          _PlayControl(
            size: playSize,
            hitSize: hitSize,
            playing: playing,
            loading: loading,
            onPressed: onPlayPause,
          ),
        ),
        _slot(
          _TransportKey(
            icon: Icons.skip_next_rounded,
            size: keyIconSize,
            hitSize: hitSize,
            tooltip: '下一首',
            onPressed: onNext,
          ),
        ),
        _slot(
          _TransportKey(
            icon: repeatIcon,
            size: sideIconSize,
            hitSize: hitSize,
            tooltip: repeatTooltip,
            active: repeatActive,
            onPressed: onCycleRepeat,
          ),
        ),
      ],
    );
  }

  Widget _slot(Widget child) => Expanded(child: Center(child: child));
}

/// 图标传输键：视觉尺寸由参数给，命中区固定 [hitSize]。
class _TransportKey extends StatelessWidget {
  const _TransportKey({
    required this.icon,
    required this.size,
    required this.hitSize,
    required this.tooltip,
    this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final double size;
  final double hitSize;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool enabled = onPressed != null;
    final Color color = !enabled
        ? ty.colors.textDisabled
        : (active ? ty.colors.accent : ty.colors.textSecondary);
    return Tooltip(
      message: tooltip,
      child: TyInteractive(
        onTap: onPressed,
        semanticLabel: tooltip,
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, TyInteractionState state) =>
            TyFocusRing(
              focused: state.focused,
              radius: TyRadius.sm,
              child: Container(
                // 焦点环始终占位，命中区因此恒等于 [hitSize]。
                width: hitSize - TyPlayerSize.focusRingCost,
                height: hitSize - TyPlayerSize.focusRingCost,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: state.overlay(ty.colors),
                  borderRadius: TyRadius.smAll,
                ),
                child: Icon(icon, size: size, color: color),
              ),
            ),
      ),
    );
  }
}

/// 播放主控：强调色圆形，图标随播放态切换。
class _PlayControl extends StatelessWidget {
  const _PlayControl({
    required this.size,
    required this.hitSize,
    required this.playing,
    required this.loading,
    this.onPressed,
  });

  final double size;
  final double hitSize;
  final bool playing;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool enabled = onPressed != null;
    final double iconSize = size * TyPlayerSize.playIconRatio;
    final String label = loading ? '正在载入' : (playing ? '暂停' : '播放');
    return Tooltip(
      message: label,
      child: TyInteractive(
        onTap: onPressed,
        semanticLabel: label,
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, TyInteractionState state) {
          final Color background = !enabled
              ? ty.colors.textDisabled
              : state.pressed
              ? ty.colors.accentPressed
              : state.hovered
              ? ty.colors.accentHover
              : ty.colors.accent;
          final Widget content = loading
              // 行内瞬时反馈用 `TyProgressBar`（`DESIGN.md` §0.5 禁止转圈）。
              ? SizedBox(
                  width: iconSize,
                  child: TyProgressBar(
                    height: TyPlayerSize.track,
                    semanticLabel: label,
                  ),
                )
              : Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: iconSize,
                  color: ty.colors.onAccent,
                );
          final Widget circle = AnimatedContainer(
            duration: TyDuration.fast,
            curve: TyCurve.standard,
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
            ),
            child: content,
          );
          final Widget ringed = TyFocusRing(
            focused: state.focused,
            radius: TyRadius.full,
            child: circle,
          );
          // 命中区不足 [hitSize] 时只撑大外层，圆钮视觉尺寸不变。
          final double outer = size + TyPlayerSize.focusRingCost;
          if (outer >= hitSize) {
            return ringed;
          }
          return SizedBox(
            width: hitSize,
            height: hitSize,
            child: Center(child: ringed),
          );
        },
      ),
    );
  }
}

/// 进度条（`DESIGN.md` §6.3）。
///
/// - 已播放 `accent`、缓冲 `accent @ 30%`、剩余 `borderStrong`；
/// - 高 4，hover / 拖拽时 8，拖拽手柄 12 + 时间 tooltip；
/// - 点击任意位置跳转；键盘 `←/→` ±5s、`⇧←/→` ±30s（焦点态可见）；
/// - 拖动期间只更新本地预览，松手（或键盘步进）才调用 [onSeek]：
///   seek 是异步的，边拖边写回会让引擎回传的旧位置把滑块反复拽回去；
///   松手后仍以目标值显示，直到引擎位置跟上（或 2s 超时）才交还控制权。
/// - 语义：`Semantics(value: '1:23 / 4:05')` + 增减动作。
class TySeekBar extends StatefulWidget {
  const TySeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.buffered = Duration.zero,
    this.enabled = true,
    this.hitHeight,
    this.showTimes = true,
    this.semanticLabel = '播放进度',
    this.focusNode,
  });

  /// 引擎回传的当前位置。
  final Duration position;

  /// 当前曲目总时长；`Duration.zero` 表示未知（直链没有 Content-Length）。
  final Duration duration;

  /// 已缓冲到的位置。
  final Duration buffered;

  /// 松手 / 步进后才回调的目标位置。
  final ValueChanged<Duration> onSeek;

  final bool enabled;

  /// 命中高度；缺省取 `metrics.hitTarget`。传输条里传 [TyPlayerSize.barSeekHitHeight]。
  final double? hitHeight;

  /// 是否在进度条两侧显示 `numericM` 时间（传输条与舞台都要）。
  final bool showTimes;

  final String semanticLabel;

  /// 供宿主（测试 / 快捷键焦点）指定焦点节点。
  final FocusNode? focusNode;

  /// 键盘步进：`←/→` 与 `⇧←/→`（`DESIGN.md` §6.3）。
  static const Duration step = Duration(seconds: 5);
  static const Duration jump = Duration(seconds: 30);

  @override
  State<TySeekBar> createState() => _TySeekBarState();
}

class _TySeekBarState extends State<TySeekBar> {
  /// 拖动中的本地预览。
  Duration? _preview;

  /// 松手后等待引擎回传期间的显示值。
  Duration? _settle;

  Timer? _settleTimer;

  bool _focused = false;

  Duration get _shown => _preview ?? _settle ?? widget.position;

  double get _maxSeconds =>
      math.max(widget.duration.inMilliseconds / 1000, _minSeconds);

  static const double _minSeconds = 1;

  @override
  void didUpdateWidget(TySeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Duration? settle = _settle;
    // 引擎位置已经跟上目标：交还显示控制权（随后必然重新 build，无需 setState）。
    if (settle != null &&
        widget.position != oldWidget.position &&
        (widget.position - settle).inMilliseconds.abs() <
            TyPlayerSize.settleToleranceMs) {
      _settleTimer?.cancel();
      _settleTimer = null;
      _settle = null;
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  Duration _at(double fraction) => Duration(
    milliseconds: (fraction.clamp(0, 1) * _maxSeconds * 1000).round(),
  );

  double _fractionOf(Duration value) =>
      (value.inMilliseconds / 1000 / _maxSeconds).clamp(0, 1).toDouble();

  Duration _clamped(Duration value) {
    final Duration total = widget.duration;
    Duration result = value;
    if (result < Duration.zero) {
      result = Duration.zero;
    }
    if (total > Duration.zero && result > total) {
      result = total;
    }
    return result;
  }

  void _previewAt(double fraction) {
    setState(() {
      _preview = _at(fraction);
      _settle = null;
    });
  }

  /// 松手 / 键盘步进的唯一出口：回调宿主 + 进入等待回传的显示态。
  void _commit(Duration target) {
    final Duration clamped = _clamped(target);
    widget.onSeek(clamped);
    _settleTimer?.cancel();
    _settleTimer = Timer(TyPlayerSize.settleTimeout, () {
      if (mounted) {
        setState(() => _settle = null);
      }
    });
    setState(() {
      _preview = null;
      _settle = clamped;
    });
  }

  void _nudge(Duration delta) => _commit(_shown + delta);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final bool forward = key == LogicalKeyboardKey.arrowRight;
    if (!forward && key != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    final Duration step = HardwareKeyboard.instance.isShiftPressed
        ? TySeekBar.jump
        : TySeekBar.step;
    _nudge(forward ? step : -step);
    return KeyEventResult.handled;
  }

  /// 与 `formatDuration` 的唯一差别：0 显示 `0:00` 而不是 `--:--`。
  String _clock(Duration duration) =>
      duration <= Duration.zero ? '0:00' : formatDuration(duration);

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final double hitHeight = widget.hitHeight ?? context.metrics.hitTarget;
    final Duration shown = _shown;
    final double fraction = _fractionOf(shown);

    final Widget track = _TrackSurface(
      height: hitHeight,
      enabled: widget.enabled,
      onJump: widget.enabled ? (double f) => _commit(_at(f)) : null,
      onDragUpdate: widget.enabled ? _previewAt : null,
      onDragEnd: widget.enabled
          ? () {
              final Duration? preview = _preview;
              if (preview != null) {
                _commit(preview);
              }
            }
          : null,
      builder: (BuildContext context, bool hovered, bool dragging) =>
          _track(context, hovered, dragging, fraction, shown),
    );

    Widget bar = Stack(
      // 拖拽时的时间 tooltip 要浮到轨道上方，不能被裁掉。
      clipBehavior: Clip.none,
      children: <Widget>[
        track,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: TyRadius.smAll,
                border: Border.all(
                  color: _focused ? ty.colors.focusRing : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          ),
        ),
      ],
    );

    bar = Focus(
      focusNode: widget.focusNode,
      canRequestFocus: widget.enabled,
      onFocusChange: (bool value) {
        if (_focused != value) {
          setState(() => _focused = value);
        }
      },
      onKeyEvent: _onKey,
      child: Semantics(
        container: true,
        slider: true,
        label: widget.semanticLabel,
        value: '${_clock(shown)} / ${_clock(widget.duration)}',
        increasedValue: '+${TySeekBar.step.inSeconds} 秒',
        decreasedValue: '-${TySeekBar.step.inSeconds} 秒',
        onIncrease: widget.enabled ? () => _nudge(TySeekBar.step) : null,
        onDecrease: widget.enabled ? () => _nudge(-TySeekBar.step) : null,
        child: bar,
      ),
    );

    if (!widget.showTimes) {
      return bar;
    }
    final TextStyle time = ty.typography.numericM.copyWith(
      color: ty.colors.textTertiary,
    );
    return Row(
      children: <Widget>[
        SizedBox(
          width: TyPlayerSize.timeColumn,
          child: Text(_clock(shown), style: time, textAlign: TextAlign.right),
        ),
        const SizedBox(width: TySpace.x12),
        Expanded(child: bar),
        const SizedBox(width: TySpace.x12),
        SizedBox(
          width: TyPlayerSize.timeColumn,
          child: Text(
            _clock(widget.duration),
            style: time,
            textAlign: TextAlign.left,
          ),
        ),
      ],
    );
  }

  Widget _track(
    BuildContext context,
    bool hovered,
    bool dragging,
    double fraction,
    Duration shown,
  ) {
    final TyTokens ty = context.ty;
    final double height = hovered || dragging
        ? TyPlayerSize.trackActive
        : TyPlayerSize.track;
    final int totalMs = widget.duration.inMilliseconds;
    final double bufferFraction = totalMs > 0
        ? (widget.buffered.inMilliseconds / totalMs).clamp(0, 1).toDouble()
        : 0;
    final Color played = widget.enabled
        ? ty.colors.accent
        : ty.colors.textDisabled;
    final Color buffer = played.withValues(alpha: TyPlayerSize.bufferOpacity);
    final Color rest = widget.enabled
        ? ty.colors.borderStrong
        : ty.colors.border;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double thumbX =
            fraction * (width - TyPlayerSize.thumb) + TyPlayerSize.thumb / 2;
        final double labelLeft = (thumbX - TyPlayerSize.timeLabelWidth / 2)
            .clamp(0, math.max(0, width - TyPlayerSize.timeLabelWidth))
            .toDouble();
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Center(
              child: SizedBox(
                height: height,
                width: width,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(height / 2),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      ColoredBox(color: rest),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: bufferFraction,
                        child: ColoredBox(color: buffer),
                      ),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: fraction,
                        child: ColoredBox(color: played),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (dragging || hovered)
              Positioned(
                left: thumbX - TyPlayerSize.thumb / 2,
                top: (constraints.maxHeight - TyPlayerSize.thumb) / 2,
                child: Container(
                  width: TyPlayerSize.thumb,
                  height: TyPlayerSize.thumb,
                  decoration: BoxDecoration(
                    color: played,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            if (dragging)
              Positioned(
                left: labelLeft,
                top: -TyPlayerSize.timeLabelHeight,
                child: Container(
                  width: TyPlayerSize.timeLabelWidth,
                  height: TyPlayerSize.timeLabelHeight,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: ty.colors.surfaceOverlay,
                    borderRadius: TyRadius.smAll,
                    border: Border.all(color: ty.colors.border),
                  ),
                  child: Text(
                    _clock(shown),
                    style: ty.typography.numericS.copyWith(
                      color: ty.colors.textPrimary,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 横向轨道的指针交互：点击跳转 + 拖拽 + hover 状态。
///
/// 只把局部横坐标换算成 0–1 的比例，绘制交给调用方（进度条与音量条共用）。
class _TrackSurface extends StatefulWidget {
  const _TrackSurface({
    required this.height,
    required this.builder,
    this.onJump,
    this.onDragUpdate,
    this.onDragEnd,
    this.enabled = true,
  });

  final double height;

  final Widget Function(BuildContext context, bool hovered, bool dragging)
  builder;

  final ValueChanged<double>? onJump;
  final ValueChanged<double>? onDragUpdate;
  final VoidCallback? onDragEnd;
  final bool enabled;

  @override
  State<_TrackSurface> createState() => _TrackSurfaceState();
}

class _TrackSurfaceState extends State<_TrackSurface> {
  bool _hovered = false;
  bool _dragging = false;

  double _fraction(Offset local, double width) =>
      width <= 0 ? 0 : (local.dx / width).clamp(0, 1).toDouble();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        return MouseRegion(
          cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) {
            if (widget.enabled && !_hovered) {
              setState(() => _hovered = true);
            }
          },
          onExit: (_) {
            if (_hovered) {
              setState(() => _hovered = false);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: widget.enabled && widget.onJump != null
                ? (TapDownDetails details) =>
                      widget.onJump!(_fraction(details.localPosition, width))
                : null,
            onHorizontalDragStart: widget.enabled && widget.onDragUpdate != null
                ? (DragStartDetails details) {
                    setState(() => _dragging = true);
                    widget.onDragUpdate!(
                      _fraction(details.localPosition, width),
                    );
                  }
                : null,
            onHorizontalDragUpdate: widget.enabled
                ? (DragUpdateDetails details) => widget.onDragUpdate?.call(
                    _fraction(details.localPosition, width),
                  )
                : null,
            onHorizontalDragEnd: widget.enabled
                ? (DragEndDetails details) {
                    setState(() => _dragging = false);
                    widget.onDragEnd?.call();
                  }
                : null,
            onHorizontalDragCancel: () {
              if (_dragging) {
                setState(() => _dragging = false);
              }
            },
            child: SizedBox(
              height: widget.height,
              child: widget.builder(context, _hovered, _dragging),
            ),
          ),
        );
      },
    );
  }
}

/// 音量：图标按钮 + 展开滑条（96px）。
///
/// - 未展开时点图标展开滑条；
/// - 展开后图标即静音开关，记忆上一次非零值（`DESIGN.md` §6.3）；
/// - 图标随音量档位变化；指针离开时收起（拖动中不收起）；
/// - 不做输出设备选择（引擎没有设备枚举）。
class TyVolumeControl extends StatefulWidget {
  const TyVolumeControl({
    super.key,
    required this.volume,
    required this.onChanged,
    this.enabled = true,
  });

  /// 0–1。
  final double volume;

  final ValueChanged<double> onChanged;

  final bool enabled;

  @override
  State<TyVolumeControl> createState() => _TyVolumeControlState();
}

class _TyVolumeControlState extends State<TyVolumeControl> {
  bool _expanded = false;
  bool _dragging = false;

  /// 静音切换要回到的那个值。
  late double _lastNonZero = widget.volume > 0 ? widget.volume : 1;

  @override
  void didUpdateWidget(TyVolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.volume > 0) {
      _lastNonZero = widget.volume;
    }
  }

  double get _volume => widget.volume.clamp(0, 1).toDouble();

  bool get _muted => _volume <= 0;

  IconData get _icon {
    if (_muted) {
      return Icons.volume_off_rounded;
    }
    if (_volume < _lowBand) {
      return Icons.volume_mute_rounded;
    }
    if (_volume < _highBand) {
      return Icons.volume_down_rounded;
    }
    return Icons.volume_up_rounded;
  }

  static const double _lowBand = 0.34;
  static const double _highBand = 0.67;

  void _toggleMute() {
    widget.onChanged(_muted ? _lastNonZero : 0);
  }

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool enabled = widget.enabled;
    final Widget toggle = TyIconAction(
      icon: _icon,
      semanticLabel: _expanded ? (_muted ? '取消静音' : '静音') : '音量',
      tooltip: _expanded ? (_muted ? '取消静音' : '静音') : '音量',
      color: _muted ? ty.colors.textTertiary : ty.colors.textSecondary,
      onPressed: !enabled
          ? null
          : _expanded
          ? _toggleMute
          : () => setState(() => _expanded = true),
    );

    return MouseRegion(
      onExit: (_) {
        if (_expanded && !_dragging) {
          setState(() => _expanded = false);
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          toggle,
          AnimatedSize(
            duration: TyDuration.fast,
            curve: TyCurve.standard,
            alignment: Alignment.centerLeft,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.only(right: TySpace.x8),
                    child: SizedBox(
                      width: TyPlayerSize.volumeSlider,
                      child: _slider(context),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _slider(BuildContext context) {
    final TyTokens ty = context.ty;
    final Widget track = _TrackSurface(
      height: TyPlayerSize.volumeTrackHitHeight,
      enabled: widget.enabled,
      onJump: (double f) => widget.onChanged(f),
      onDragUpdate: (double f) => widget.onChanged(f),
      onDragEnd: () {
        if (_dragging) {
          setState(() => _dragging = false);
        }
      },
      builder: (BuildContext context, bool hovered, bool dragging) => Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(TyPlayerSize.track),
          child: SizedBox(
            height: hovered || dragging
                ? TyPlayerSize.trackActive
                : TyPlayerSize.track,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(
                  color: widget.enabled
                      ? ty.colors.borderStrong
                      : ty.colors.border,
                ),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _volume,
                  child: ColoredBox(
                    color: widget.enabled
                        ? ty.colors.accent
                        : ty.colors.textDisabled,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Listener(
      onPointerDown: (_) {
        if (!_dragging) {
          setState(() => _dragging = true);
        }
      },
      onPointerUp: (_) {
        if (_dragging) {
          setState(() => _dragging = false);
        }
      },
      child: track,
    );
  }
}

/// 桌面传输条（`DESIGN.md` §6.3 / §5.1）。
///
/// 纯展示：读数与指令都来自宿主；中间的传输行与进度行由宿主按自己的订阅切片传入
/// （进度 tick 只重建那一小片，封面与标题不跟着重建）。
/// 队列为空时整条收起（`barCollapse` 200ms，高度 + 透明度）。
class TyTransportBar extends StatelessWidget {
  const TyTransportBar({
    super.key,
    this.visible = true,
    this.coverPath,
    this.coverUrl,
    this.coverSeed,
    this.title = '',
    this.artist = '',
    this.favorite = false,
    this.onToggleFavorite,
    this.onOpenStage,
    required this.transport,
    required this.progress,
    this.actions = const <Widget>[],
    this.error,
    this.errorDetail,
    this.onRetry,
  });

  /// 队列是否有内容；false 时整条收起（不留「未在播放」占位）。
  final bool visible;

  final String? coverPath;
  final String? coverUrl;
  final String? coverSeed;

  final String title;
  final String artist;

  final bool favorite;
  final VoidCallback? onToggleFavorite;

  /// 点击封面 / 标题 → 舞台。
  final VoidCallback? onOpenStage;

  /// 传输键行（宿主接线）。
  final Widget transport;

  /// 进度行（宿主接线）。
  final Widget progress;

  /// 右侧动作：歌词 / 队列 / 音量。
  final List<Widget> actions;

  /// 失败态：整条替换为 [TyErrorView] 内联形态。
  final String? error;
  final String? errorDetail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final Duration duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : TyDuration.base;
    final String? error = this.error;

    final Widget content = SizedBox(
      height: context.metrics.transportHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ty.colors.surfaceRaised,
          border: Border(top: BorderSide(color: ty.colors.border, width: 1)),
        ),
        child: error != null
            ? Center(
                child: TyErrorView(
                  title: error,
                  detail: errorDetail,
                  onRetry: onRetry,
                  compact: true,
                ),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: TySpace.x16),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: TyPlayerSize.barLeadingMaxWidth,
                      child: _leading(context),
                    ),
                    Expanded(child: _center()),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final Widget action in actions) ...<Widget>[
                          const SizedBox(width: TySpace.x4),
                          action,
                        ],
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );

    return ClipRect(
      child: AnimatedSize(
        duration: duration,
        curve: TyCurve.standard,
        alignment: Alignment.topCenter,
        child: AnimatedOpacity(
          duration: duration,
          curve: TyCurve.standard,
          opacity: visible ? 1 : 0,
          child: visible ? content : const SizedBox(width: double.infinity),
        ),
      ),
    );
  }

  Widget _center() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: TyPlayerSize.barTransportMaxWidth,
            ),
            child: transport,
          ),
        ),
        const SizedBox(height: TySpace.x2),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: TyPlayerSize.barProgressMaxWidth,
            ),
            child: progress,
          ),
        ),
      ],
    );
  }

  Widget _leading(BuildContext context) {
    final TyTokens ty = context.ty;
    final Widget info = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ty.typography.bodyM.copyWith(color: ty.colors.textPrimary),
        ),
        Text(
          artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ty.typography.bodyS.copyWith(color: ty.colors.textSecondary),
        ),
      ],
    );

    return Semantics(
      container: true,
      liveRegion: true,
      label: '正在播放 $title${artist.isEmpty ? '' : ' · $artist'}',
      child: TyInteractive(
        onTap: onOpenStage,
        cursor: SystemMouseCursors.click,
        semanticLabel: onOpenStage == null ? null : '展开播放舞台',
        builder: (BuildContext context, TyInteractionState state) => Row(
          children: <Widget>[
            Transform.translate(
              offset: state.hovered
                  ? const Offset(0, -TySpace.x2)
                  : Offset.zero,
              child: TyCover(
                path: coverPath,
                url: coverUrl,
                seed: coverSeed,
                size: TyPlayerSize.barCover,
                radius: TyRadius.sm,
                border: BorderSide(color: ty.colors.border),
              ),
            ),
            const SizedBox(width: TySpace.x12),
            Flexible(child: info),
            if (onToggleFavorite != null) ...<Widget>[
              const SizedBox(width: TySpace.x4),
              TyIconAction(
                icon: favorite ? Icons.favorite : Icons.favorite_border,
                semanticLabel: favorite ? '取消收藏' : '收藏',
                tooltip: favorite ? '取消收藏' : '收藏',
                size: TyIconSize.normal,
                active: favorite,
                onPressed: onToggleFavorite,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
