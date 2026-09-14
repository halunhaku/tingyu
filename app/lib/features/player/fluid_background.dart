import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放页的动态光晕背景：纯 Flutter 自绘，不引入任何新依赖。
///
/// 与旧版 `FluidBackgroundView` 的差别：
/// - 颜色全部从 [ColorScheme] 派生（跟随明暗主题与主题色），[seed]（当前曲目的封面路径/URL）
///   只做确定性的选色轮转——同一首歌永远得到同一套配色；
/// - 一个完整周期 24s、位移幅度克制，看到的是"缓慢呼吸"，不是显眼的物体位移；
/// - 用 [RadialGradient] 的软衰减代替 `MaskFilter.blur`：省掉每帧一次离屏模糊。
class FluidBackground extends StatefulWidget {
  const FluidBackground({super.key, required this.child, this.seed});

  /// 光晕之上的内容；被 [RepaintBoundary] 隔开，动画不会触发它的重建。
  final Widget child;

  /// 换色种子：当前曲目的封面路径/URL；null 时用主题默认配色。
  final String? seed;

  @override
  State<FluidBackground> createState() => _FluidBackgroundState();
}

class _FluidBackgroundState extends State<FluidBackground>
    with SingleTickerProviderStateMixin {
  /// 一个完整流动周期：足够慢，肉眼只感到"呼吸"。
  static const Duration _period = Duration(seconds: 24);

  /// 系统开启"减少动态效果"时停在这个相位，构图依然完整。
  static const double _stillPhase = 0.35;

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: _period);

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

  /// 三枚光斑色：主色/第三色/次色/容器的固定轮转，按 [FluidBackground.seed] 偏移。
  ///
  /// 浅色主题下透明度压到约一半——大面积高饱和铺满窗口会刺眼，桌面端尤其明显。
  List<Color> _blobs(ColorScheme scheme) {
    final List<Color> roles = <Color>[
      scheme.primary,
      scheme.tertiary,
      scheme.secondary,
      scheme.primaryContainer,
      scheme.tertiaryContainer,
    ];
    final String? seed = widget.seed;
    final int offset = seed == null ? 0 : seed.hashCode.abs();
    final double scale = scheme.brightness == Brightness.dark ? 1 : 0.55;
    const List<double> alphas = <double>[0.30, 0.24, 0.18];
    return <Color>[
      for (int i = 0; i < alphas.length; i++)
        roles[(offset + i * 2) % roles.length]
            .withValues(alpha: alphas[i] * scale),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Color> blobs = _blobs(scheme);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 逐帧重绘只发生在这层：painter 由 Listenable 驱动，不经过 widget 重建。
        RepaintBoundary(
          child: CustomPaint(
            willChange: true,
            painter: _FluidPainter(
              animation: _controller,
              base: scheme.surface,
              blobA: blobs[0],
              blobB: blobs[1],
              blobC: blobs[2],
            ),
          ),
        ),
        RepaintBoundary(child: widget.child),
      ],
    );
  }
}

/// 底色 + 三枚软边光斑；每帧一次铺底、三次 `drawCircle`。
class _FluidPainter extends CustomPainter {
  _FluidPainter({
    required this.animation,
    required this.base,
    required this.blobA,
    required this.blobB,
    required this.blobC,
  }) : super(repaint: animation);

  final Animation<double> animation;

  /// 底色（主题表面色），避免背景与页面其它区域之间出现硬接缝。
  final Color base;

  final Color blobA;

  final Color blobB;

  final Color blobC;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    canvas.drawRect(Offset.zero & size, Paint()..color = base);

    final double maxSide = math.max(size.width, size.height);
    final double t = animation.value * 2 * math.pi;
    final Paint paint = Paint();
    _blob(canvas, paint, size, maxSide, t, 0, blobA);
    _blob(canvas, paint, size, maxSide, t, 1, blobB);
    _blob(canvas, paint, size, maxSide, t, 2, blobC);
  }

  /// 一枚缓慢游走的光斑：位置与半径走三条不同周期的正弦，避免三段轨迹同步成可见的循环。
  void _blob(
    Canvas canvas,
    Paint paint,
    Size size,
    double maxSide,
    double t,
    int i,
    Color color,
  ) {
    final double phase = t + i * 2.1;
    final Offset center = Offset(
      size.width * (0.5 + 0.30 * math.sin(phase * 0.60 + i * 1.3)),
      size.height * (0.5 + 0.26 * math.cos(phase * 0.45 + i * 1.9)),
    );
    final double radius = maxSide * (0.52 + 0.10 * math.sin(phase * 0.80 + i));
    paint.shader = RadialGradient(
      colors: <Color>[color, color.withValues(alpha: 0)],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_FluidPainter oldDelegate) =>
      oldDelegate.base != base ||
      oldDelegate.blobA != blobA ||
      oldDelegate.blobB != blobB ||
      oldDelegate.blobC != blobC;
}
