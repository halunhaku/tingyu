import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/preferences.dart';
import '../../app/providers.dart';
import '../../design/theme.dart';
import '../../design/tokens/motion.dart';
import 'stage_palette.dart';

/// 舞台背景几何与压平层（`DESIGN.md` §2.5）。
abstract final class TyStageBackground {
  /// 主色 → 次色线性渐变的角度（160°）。
  static const double angle = math.pi * 160 / 180;

  /// 压平层：`canvas @ 35%`（`DESIGN.md` §2.5 第 5 条）。
  static const double flattenOpacity = 0.35;

  /// 漂移幅度：只插值渐变的起止点，颜色不动。
  static const double drift = 0.35;
}

/// 舞台背景：单层渐变 + 一层压平，颜色来自封面取色。
///
/// - 取色走 [stagePaletteProvider]（`DESIGN.md` §2.5）：本地封面 → 主 / 次色；
///   取色关闭、没有本地封面、灰封面、失败都退回 [StagePalette.neutral]；
/// - 漂移只插值渐变起止点，24s 一个周期；`disableAnimations` 时停在固定相位；
/// - 动画层与内容各一个 [RepaintBoundary]：每帧只重绘这层渐变，不重建页面内容。
class FluidBackground extends ConsumerStatefulWidget {
  const FluidBackground({super.key, required this.child, this.coverPath});

  /// 舞台内容；[RepaintBoundary] 隔开，漂移不会触发它重绘。
  final Widget child;

  /// 当前曲目的本地封面文件名（`CoverStore` 里的名字）；null/空 表示没有本地封面。
  final String? coverPath;

  @override
  ConsumerState<FluidBackground> createState() => _FluidBackgroundState();
}

class _FluidBackgroundState extends ConsumerState<FluidBackground>
    with SingleTickerProviderStateMixin {
  /// 一个完整漂移周期：足够慢，肉眼只感到「呼吸」。
  static const Duration _period = TyDuration.ambient;

  /// 系统开启「减少动态效果」时停在这个相位，构图依然完整。
  static const double _stillPhase = 0.35;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = _stillPhase;
      return;
    }
    if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 当前曲目的配色；解析不出本地封面时就是中性渐变。
  ///
  /// 换歌时封面路径变了 → provider 换实例，上一首的结果不会涂到这首上
  /// （`DESIGN.md` §2.5 第 7 条「只接受当前曲目的取色结果」）。
  StagePalette _palette(Brightness brightness) {
    final StagePalette fallback = StagePalette.neutral(brightness);
    final bool tint = ref.watch(
      preferencesProvider.select(
        (AsyncValue<PreferencesState> value) =>
            value.value?.preferences.coverTint ?? true,
      ),
    );
    if (!tint) {
      return fallback;
    }
    final String? name = widget.coverPath;
    if (name == null || name.isEmpty) {
      return fallback;
    }
    final String? path = ref.watch(coverFileProvider(name)).value?.path;
    if (path == null) {
      return fallback;
    }
    return ref
            .watch(stagePaletteProvider((path: path, brightness: brightness)))
            .value ??
        fallback;
  }

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    final StagePalette palette = _palette(brightness);
    final Color flatten = context.ty.colors.canvas.withValues(
      alpha: TyStageBackground.flattenOpacity,
    );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        RepaintBoundary(
          child: CustomPaint(
            painter: _StageBackgroundPainter(
              animation: _controller,
              palette: palette,
              flatten: flatten,
            ),
          ),
        ),
        RepaintBoundary(child: widget.child),
      ],
    );
  }
}

/// 一层渐变 + 一层压平；每帧两次 `drawRect`，不做模糊、不做多光斑。
class _StageBackgroundPainter extends CustomPainter {
  _StageBackgroundPainter({
    required this.animation,
    required this.palette,
    required this.flatten,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final StagePalette palette;
  final Color flatten;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    // 起止点在两端之间往返，颜色固定：漂移的是「光的方向」，不是配色。
    final double phase = math.sin(animation.value * 2 * math.pi) * 0.5 + 0.5;
    final Alignment begin = Alignment.lerp(
      Alignment.topLeft,
      const Alignment(-TyStageBackground.drift, -1),
      phase,
    )!;
    final Alignment end = Alignment.lerp(
      Alignment.bottomRight,
      const Alignment(TyStageBackground.drift, 1),
      phase,
    )!;
    final Paint paint = Paint()
      ..shader = LinearGradient(
        begin: begin,
        end: end,
        colors: <Color>[palette.primary, palette.secondary],
        transform: const GradientRotation(TyStageBackground.angle),
      ).createShader(rect);
    canvas.drawRect(rect, paint);
    canvas.drawRect(rect, Paint()..color = flatten);
  }

  @override
  bool shouldRepaint(_StageBackgroundPainter oldDelegate) =>
      oldDelegate.palette.primary != palette.primary ||
      oldDelegate.palette.secondary != palette.secondary ||
      oldDelegate.flatten != flatten;
}
