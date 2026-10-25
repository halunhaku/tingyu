import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'interactive.dart';

/// 筛选 / 状态 chip。选中态用 `accentSoft`，未选用描边。
class TyChip extends StatelessWidget {
  const TyChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  /// 右侧计数（真实计数才显示）。
  final int? count;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final double height = context.metrics.chipHeight + 2;
    return TyInteractive(
      onTap: onTap,
      semanticLabel: label,
      semanticEnabled: selected,
      builder: (BuildContext context, TyInteractionState state) {
        final Color background = selected
            ? ty.colors.accentSoft
            : Color.alphaBlend(state.overlay(ty.colors), ty.colors.surface);
        final Color foreground = selected
            ? ty.colors.accent
            : ty.colors.textSecondary;
        return AnimatedContainer(
          duration: TyDuration.fast,
          curve: TyCurve.standard,
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: TySpace.x12),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(height / 2),
            border: Border.all(
              color: selected ? Colors.transparent : ty.colors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: TyIconSize.inline, color: foreground),
                const SizedBox(width: TySpace.x6),
              ],
              Text(
                label,
                style: ty.typography.labelM.copyWith(color: foreground),
              ),
              if (count != null) ...<Widget>[
                const SizedBox(width: TySpace.x6),
                Text(
                  '$count',
                  style: ty.typography.numericS.copyWith(
                    color: selected ? ty.colors.accent : ty.colors.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 分段控件：曲库四段、收藏两段、设置分组。
///
/// 指示块按等分宽度滑动；段数 ≤ 5 时使用，超出请改用 `TyChip` 行。
class TySegmentedControl extends StatelessWidget {
  const TySegmentedControl({
    super.key,
    required this.segments,
    required this.index,
    required this.onChanged,
    this.maxWidth = TySegmentedControl.defaultMaxWidth,
  });

  /// 分段控件的默认宽度上限。
  ///
  /// 段数少（2–5 段）时铺满 1200 宽只会变成一条空槽：用户既看不出「有哪几段」，
  /// 点区也散掉。窄屏（手机）需要铺满，因为容器本来就比这个值窄。
  static const double defaultMaxWidth = 480;

  final List<String> segments;
  final int index;
  final ValueChanged<int> onChanged;

  /// 宽度上限；传 null 表示铺满可用宽度（例如窄屏的分段切换）。
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final double height = context.metrics.segmentedHeight + 2;
    final int active = index.clamp(0, segments.length - 1);
    final Widget control = Container(
      height: height,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: ty.colors.surfaceSunken,
        borderRadius: BorderRadius.circular(TyRadius.sm),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double segmentWidth = constraints.maxWidth / segments.length;
          return Stack(
            children: <Widget>[
              AnimatedPositioned(
                duration: TyDuration.base,
                curve: TyCurve.standard,
                left: segmentWidth * active,
                top: 0,
                bottom: 0,
                width: segmentWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ty.colors.surface,
                    borderRadius: BorderRadius.circular(TyRadius.xs + 2),
                    boxShadow: ty.elevation(TyElevation.popover),
                  ),
                ),
              ),
              Row(
                children: <Widget>[
                  for (int i = 0; i < segments.length; i++)
                    Expanded(
                      child: TyInteractive(
                        onTap: i == active ? null : () => onChanged(i),
                        semanticLabel: segments[i],
                        semanticEnabled: i == active,
                        builder:
                            (BuildContext context, TyInteractionState state) {
                              return Center(
                                child: AnimatedDefaultTextStyle(
                                  duration: TyDuration.fast,
                                  style: ty.typography.labelM.copyWith(
                                    color: i == active
                                        ? ty.colors.textPrimary
                                        : ty.colors.textSecondary,
                                    fontWeight: i == active
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                  child: Text(segments[i]),
                                ),
                              );
                            },
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
    final double? maxWidth = this.maxWidth;
    if (maxWidth == null) {
      return control;
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: control,
      ),
    );
  }
}
