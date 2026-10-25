import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/color.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'interactive.dart';

/// 按钮变体（`DESIGN.md` §6.4）。
enum TyButtonVariant {
  /// 强调填充：页面上唯一的主操作。
  primary,

  /// 描边：次操作。
  secondary,

  /// 透明 + hover 底：工具栏、行内操作。
  ghost,

  /// 危险操作（删除 / 清洗 / 移除）。
  danger,
}

/// 统一按钮：高度、内边距、圆角、状态色全部来自 token。
class TyButton extends StatelessWidget {
  const TyButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.variant = TyButtonVariant.primary,
    this.dense = false,
    this.expand = false,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final TyButtonVariant variant;

  /// 小尺寸（表格工具条 / 表单内）。
  final bool dense;

  /// 撑满可用宽度。
  final bool expand;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final TyMetrics metrics = context.metrics;
    final bool enabled = onPressed != null;
    final double height = dense ? metrics.buttonHeightSmall : metrics.buttonHeight;

    Widget button = TyInteractive(
      onTap: onPressed,
      semanticLabel: label,
      builder: (BuildContext context, TyInteractionState state) {
        final (Color background, Color foreground, Color? border) = _palette(
          ty,
          state,
          enabled,
          onDanger: Theme.of(context).colorScheme.onError,
        );
        return AnimatedContainer(
          duration: TyDuration.fast,
          curve: TyCurve.standard,
          height: height,
          padding: EdgeInsets.symmetric(
            horizontal: dense ? TySpace.x12 : TySpace.x16,
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: TyRadius.smAll,
            border: border == null ? null : Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: TyIconSize.compact + 2, color: foreground),
                const SizedBox(width: TySpace.x6),
              ],
              Text(
                label,
                style: ty.typography.labelL.copyWith(color: foreground),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      },
    );

    button = TyFocusRing(
      focused: false,
      radius: TyRadius.sm,
      child: button,
    );

    if (expand) {
      button = SizedBox(width: double.infinity, child: button);
    }
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }

  (Color, Color, Color?) _palette(
    TyTokens ty,
    TyInteractionState state,
    bool enabled, {
    required Color onDanger,
  }) {
    final TyColors c = ty.colors;
    if (!enabled) {
      return (c.surfaceSunken, c.textDisabled, null);
    }
    switch (variant) {
      case TyButtonVariant.primary:
        final Color background = state.pressed
            ? c.accentPressed
            : (state.hovered ? c.accentHover : c.accent);
        return (background, c.onAccent, null);
      case TyButtonVariant.secondary:
        return (
          Color.alphaBlend(state.overlay(c), c.surface),
          c.textPrimary,
          state.focused ? c.accent : c.borderStrong,
        );
      case TyButtonVariant.ghost:
        return (state.overlay(c), c.textPrimary, null);
      case TyButtonVariant.danger:
        final HSLColor base = HSLColor.fromColor(c.danger);
        Color shaded(double amount) => base
            .withLightness((base.lightness - amount).clamp(0.0, 1.0))
            .toColor();
        final Color background = state.pressed
            ? shaded(0.10)
            : (state.hovered ? shaded(0.05) : c.danger);
        return (background, onDanger, null);
    }
  }
}

/// 图标按钮：视觉 20，命中区按形态取 32/36/44，必带 tooltip 与语义标签。
class TyIconAction extends StatelessWidget {
  const TyIconAction({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
    this.tooltip,
    this.size = TyIconSize.normal,
    this.color,
    this.activeColor,
    this.active = false,
    this.radius,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final Color? color;

  /// 激活态（如已收藏、正在播放）时的颜色，默认强调色。
  final Color? activeColor;
  final bool active;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final TyMetrics metrics = context.metrics;
    final bool enabled = onPressed != null;
    final Color effective = !enabled
        ? ty.colors.textDisabled
        : active
        ? (activeColor ?? ty.colors.accent)
        : (color ?? ty.colors.textSecondary);

    Widget button = TyInteractive(
      onTap: onPressed,
      semanticLabel: semanticLabel,
      builder: (BuildContext context, TyInteractionState state) {
        return Container(
          width: metrics.hitTarget,
          height: metrics.hitTarget,
          decoration: BoxDecoration(
            color: state.overlay(ty.colors),
            borderRadius: BorderRadius.circular(radius ?? TyRadius.sm),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: size, color: effective),
        );
      },
    );

    button = Tooltip(
      message: tooltip ?? semanticLabel,
      child: button,
    );
    return button;
  }
}
