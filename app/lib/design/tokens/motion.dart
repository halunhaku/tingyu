import 'package:flutter/animation.dart';

/// 动效时长令牌（`DESIGN.md` §7.1）。
abstract final class TyDuration {
  /// 按下缩放、overlay 反馈。
  static const Duration micro = Duration(milliseconds: 90);

  /// hover 淡入、颜色切换。
  static const Duration fast = Duration(milliseconds: 120);

  /// 常规过渡：分段切换、面板、条收起。
  static const Duration base = Duration(milliseconds: 200);

  /// 抽屉 / 上下文菜单。
  static const Duration sheet = Duration(milliseconds: 240);

  /// 舞台展开 / 收起。
  static const Duration stage = Duration(milliseconds: 320);

  /// 封面交叉淡入。
  static const Duration cover = Duration(milliseconds: 180);

  /// 骨架微光周期。
  static const Duration shimmer = Duration(milliseconds: 1400);

  /// 舞台背景极缓漂移周期。
  static const Duration ambient = Duration(seconds: 24);
}

/// 动效曲线令牌（`DESIGN.md` §7.1）。
abstract final class TyCurve {
  /// 常规进出。
  static const Curve standard = Cubic(0.2, 0.0, 0.0, 1.0);

  /// 进入（减速）。
  static const Curve decelerate = Cubic(0.05, 0.7, 0.1, 1.0);

  /// 退出（加速）。
  static const Curve accelerate = Cubic(0.3, 0.0, 0.8, 0.15);

  /// 进度 / 骨架。
  static const Curve linear = Curves.linear;
}
