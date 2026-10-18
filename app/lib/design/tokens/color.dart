import 'package:flutter/material.dart';

/// 语义化颜色令牌（`DESIGN.md` §2）。
///
/// 规则：
/// - 中性色与品牌色解耦：中性灰是冷灰，不含红色分量；专辑封面是页面上唯一的高彩度物体。
/// - 品牌红（[accent]）只作强调：播放中、选中、进度、主按钮、焦点环，绝不用于大面积背景。
/// - 深色用亮度分层，浅色用描边分层：深色下不使用装饰性投影。
///
/// 交互态叠加色（[surfaceHover]/[surfacePressed]/[surfaceSelected]）使用带 alpha 的颜色，
/// 以便在任意底色上正确合成；括号内是其在 `canvas`/`surface` 上的等效实色（与文档一致）。
@immutable
class TyColors extends ThemeExtension<TyColors> {
  const TyColors({
    required this.canvas,
    required this.surface,
    required this.surfaceSunken,
    required this.surfaceRaised,
    required this.surfaceOverlay,
    required this.surfaceHover,
    required this.surfacePressed,
    required this.surfaceSelected,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.accent,
    required this.accentHover,
    required this.accentPressed,
    required this.accentSoft,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.focusRing,
    required this.scrim,
    required this.skeletonBase,
    required this.skeletonHighlight,
    required this.coverPlaceholder,
  });

  /// 窗口底色。
  final Color canvas;

  /// 卡片 / 面板 / 列表底。
  final Color surface;

  /// 输入框 / 分段控件槽 / chip 底。
  final Color surfaceSunken;

  /// 深色下的抬升层（卡片、传输条、检查器）；浅色下与 [surface] 相同。
  final Color surfaceRaised;

  /// 菜单 / 浮层 / 对话框。
  final Color surfaceOverlay;

  /// 行 / 卡片 hover（浅色 `textPrimary @ 4%` ≈ #EEEEF0，深色 `white @ 6%` ≈ #222226）。
  final Color surfaceHover;

  /// 按下（浅色 `textPrimary @ 8%` ≈ #E5E5E7，深色 `white @ 10%` ≈ #2C2C2F）。
  final Color surfacePressed;

  /// 选中行 / 选中导航（浅色 `accent @ 12%` ≈ #FCEDEF，深色 `accent @ 14%` ≈ #2F1E24）。
  final Color surfaceSelected;

  /// 1px 分隔 / 卡片描边。
  final Color border;

  /// 输入框描边 / 强分隔。
  final Color borderStrong;

  /// 标题与正文（浅 16.9:1 / 深 17.8:1 on canvas）。
  final Color textPrimary;

  /// 次信息：艺术家、计数（浅 6.35:1 / 深 8.12:1）。
  final Color textSecondary;

  /// 第三级元数据、时间（浅 4.99:1 / 深 5.88:1）。
  final Color textTertiary;

  /// 禁用态（对比度豁免，但不得承载信息）。
  final Color textDisabled;

  /// 品牌强调色（浅 #D81E32 4.73:1 on canvas；深 #FF5C6E 6.13:1 on surface）。
  final Color accent;

  /// 强调色 hover。
  final Color accentHover;

  /// 强调色按下。
  final Color accentPressed;

  /// 强调色浅底（徽标 / 选中底）。
  final Color accentSoft;

  /// 强调底上的文字（浅色白字 5.06:1；深色画布色 6.52:1）。
  final Color onAccent;

  /// 成功：已连接、同步完成。
  final Color success;

  /// 警告：需注意。
  final Color warning;

  /// 失败 / 危险操作。
  final Color danger;

  /// 键盘焦点环（= [accent]）。
  final Color focusRing;

  /// 模态遮罩。
  final Color scrim;

  /// 骨架屏底色 / 微光色。
  final Color skeletonBase;
  final Color skeletonHighlight;

  /// 缺失封面占位底色。
  final Color coverPlaceholder;

  /// 浅色主题（`DESIGN.md` §2.2）。
  static const TyColors light = TyColors(
    canvas: Color(0xFFF7F7F9),
    surface: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFF1F1F4),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceOverlay: Color(0xFFFFFFFF),
    surfaceHover: Color(0x0A16161A), // textPrimary 4%
    surfacePressed: Color(0x1416161A), // textPrimary 8%
    surfaceSelected: Color(0x1FD81E32), // accent 12%
    border: Color(0xFFE4E4EA),
    borderStrong: Color(0xFFD3D3DC),
    textPrimary: Color(0xFF16161A),
    textSecondary: Color(0xFF5A5A66),
    textTertiary: Color(0xFF6A6A76),
    textDisabled: Color(0xFFA0A0AC),
    accent: Color(0xFFD81E32),
    accentHover: Color(0xFFC0182B),
    accentPressed: Color(0xFFA81226),
    accentSoft: Color(0x1FD81E32),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1C7A4A),
    warning: Color(0xFF96560A),
    danger: Color(0xFFB32219),
    focusRing: Color(0xFFD81E32),
    scrim: Color(0x66000000),
    skeletonBase: Color(0xFFEAEAF0),
    skeletonHighlight: Color(0xFFF5F5F8),
    coverPlaceholder: Color(0xFFE7E7EC),
  );

  /// 深色主题（`DESIGN.md` §2.3）：不使用投影，浮层靠 [surfaceOverlay] + [border] 表达。
  static const TyColors dark = TyColors(
    canvas: Color(0xFF0C0C0F),
    surface: Color(0xFF141418),
    surfaceSunken: Color(0xFF101014),
    surfaceRaised: Color(0xFF1B1B21),
    surfaceOverlay: Color(0xFF232329),
    surfaceHover: Color(0x0FFFFFFF), // white 6%
    surfacePressed: Color(0x1AFFFFFF), // white 10%
    surfaceSelected: Color(0x24FF5C6E), // accent 14%
    border: Color(0xFF2A2A33),
    borderStrong: Color(0xFF3A3A45),
    textPrimary: Color(0xFFF4F4F7),
    textSecondary: Color(0xFFA6A6B3),
    textTertiary: Color(0xFF8C8C99),
    textDisabled: Color(0xFF5A5A64),
    accent: Color(0xFFFF5C6E),
    accentHover: Color(0xFFFF7A89),
    accentPressed: Color(0xFFE8455A),
    accentSoft: Color(0x24FF5C6E),
    onAccent: Color(0xFF0C0C0F),
    success: Color(0xFF5BD98F),
    warning: Color(0xFFF0B45C),
    danger: Color(0xFFFF7066),
    focusRing: Color(0xFFFF5C6E),
    scrim: Color(0x99000000),
    skeletonBase: Color(0xFF1E1E24),
    skeletonHighlight: Color(0xFF2A2A32),
    coverPlaceholder: Color(0xFF22222A),
  );

  /// 按亮度取色板。
  static TyColors of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// 舞台背景的中性渐变（动态取色关闭 / 灰封面 / 提取失败时使用，`DESIGN.md` §2.5.8）。
  List<Color> get stageFallbackGradient => identical(this, dark)
      ? const <Color>[Color(0xFF101014), Color(0xFF17171C)]
      : const <Color>[Color(0xFFF0F0F4), Color(0xFFE7E7EC)];

  @override
  TyColors copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceSunken,
    Color? surfaceRaised,
    Color? surfaceOverlay,
    Color? surfaceHover,
    Color? surfacePressed,
    Color? surfaceSelected,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textDisabled,
    Color? accent,
    Color? accentHover,
    Color? accentPressed,
    Color? accentSoft,
    Color? onAccent,
    Color? success,
    Color? warning,
    Color? danger,
    Color? focusRing,
    Color? scrim,
    Color? skeletonBase,
    Color? skeletonHighlight,
    Color? coverPlaceholder,
  }) {
    return TyColors(
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceOverlay: surfaceOverlay ?? this.surfaceOverlay,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      surfacePressed: surfacePressed ?? this.surfacePressed,
      surfaceSelected: surfaceSelected ?? this.surfaceSelected,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      textDisabled: textDisabled ?? this.textDisabled,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      accentPressed: accentPressed ?? this.accentPressed,
      accentSoft: accentSoft ?? this.accentSoft,
      onAccent: onAccent ?? this.onAccent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      focusRing: focusRing ?? this.focusRing,
      scrim: scrim ?? this.scrim,
      skeletonBase: skeletonBase ?? this.skeletonBase,
      skeletonHighlight: skeletonHighlight ?? this.skeletonHighlight,
      coverPlaceholder: coverPlaceholder ?? this.coverPlaceholder,
    );
  }

  @override
  TyColors lerp(covariant TyColors? other, double t) {
    if (other == null) {
      return this;
    }
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return TyColors(
      canvas: mix(canvas, other.canvas),
      surface: mix(surface, other.surface),
      surfaceSunken: mix(surfaceSunken, other.surfaceSunken),
      surfaceRaised: mix(surfaceRaised, other.surfaceRaised),
      surfaceOverlay: mix(surfaceOverlay, other.surfaceOverlay),
      surfaceHover: mix(surfaceHover, other.surfaceHover),
      surfacePressed: mix(surfacePressed, other.surfacePressed),
      surfaceSelected: mix(surfaceSelected, other.surfaceSelected),
      border: mix(border, other.border),
      borderStrong: mix(borderStrong, other.borderStrong),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      textDisabled: mix(textDisabled, other.textDisabled),
      accent: mix(accent, other.accent),
      accentHover: mix(accentHover, other.accentHover),
      accentPressed: mix(accentPressed, other.accentPressed),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccent: mix(onAccent, other.onAccent),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      focusRing: mix(focusRing, other.focusRing),
      scrim: mix(scrim, other.scrim),
      skeletonBase: mix(skeletonBase, other.skeletonBase),
      skeletonHighlight: mix(skeletonHighlight, other.skeletonHighlight),
      coverPlaceholder: mix(coverPlaceholder, other.coverPlaceholder),
    );
  }
}
