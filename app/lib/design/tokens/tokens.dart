import 'package:flutter/material.dart';

import 'color.dart';
import 'typography.dart';

/// 界面密度（用户可在设置中切换；`compact` 形态忽略紧凑密度，触控最小 44px 为硬约束）。
enum TyDensity {
  /// 舒适：行高 48 / 表格行 44 / 内边距 16（桌面默认）。
  comfortable,

  /// 紧凑：行高 40 / 表格行 40 / 内边距 12。
  compact;

  bool get isCompact => this == TyDensity.compact;
}

/// 设计系统主题扩展：随亮度与密度变化的令牌集合。
///
/// 这里只承载**运行时可变**的部分（颜色、排版、密度、亮度）：间距 / 圆角 / 图标尺寸 /
/// 时长 / 曲线都是编译期常量，直接引用 `TySpace`、`TyRadius`、`TyIconSize`、
/// `TyDuration`、`TyCurve`，不必经过主题查找。
/// 尺寸类令牌（行高、控件高、网格）依赖窗口宽度，见 `lib/design/layout/form_factor.dart`。
@immutable
class TyTokens extends ThemeExtension<TyTokens> {
  const TyTokens({
    required this.brightness,
    required this.density,
    required this.colors,
    required this.typography,
  });

  final Brightness brightness;
  final TyDensity density;
  final TyColors colors;

  /// 排版令牌。注意：不能叫 `type`——`ThemeExtension` 已定义同名成员。
  final TyType typography;

  bool get isDark => brightness == Brightness.dark;

  /// 供 Material 内建控件使用的深/浅阴影策略（深色不使用装饰性投影）。
  List<BoxShadow> elevation(List<BoxShadow> shadows) =>
      TyElevationForBrightness.resolve(brightness, shadows);

  @override
  TyTokens copyWith({
    Brightness? brightness,
    TyDensity? density,
    TyColors? colors,
    TyType? typography,
  }) {
    return TyTokens(
      brightness: brightness ?? this.brightness,
      density: density ?? this.density,
      colors: colors ?? this.colors,
      typography: typography ?? this.typography,
    );
  }

  @override
  TyTokens lerp(covariant TyTokens? other, double t) {
    if (other == null) {
      return this;
    }
    return TyTokens(
      brightness: t < 0.5 ? brightness : other.brightness,
      density: t < 0.5 ? density : other.density,
      colors: colors.lerp(other.colors, t),
      typography: t < 0.5 ? typography : other.typography,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is TyTokens &&
        other.brightness == brightness &&
        other.density == density &&
        other.colors == colors &&
        other.typography == typography;
  }

  @override
  int get hashCode => Object.hash(brightness, density, colors, typography);
}

/// 深色下不使用装饰性投影（仅保留模态层阴影，`DESIGN.md` §3.5）。
abstract final class TyElevationForBrightness {
  static List<BoxShadow> resolve(Brightness brightness, List<BoxShadow> shadows) {
    if (brightness != Brightness.dark) {
      return shadows;
    }
    // 深色下所有浮层都用「更亮的 surface + border」表达，因此一律不投影。
    return const <BoxShadow>[];
  }
}
