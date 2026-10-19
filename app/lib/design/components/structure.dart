import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/tokens.dart';
import 'interactive.dart';

/// 页面标题：`titleXL` + 可选副标题 + 右侧动作槽。
///
/// 页面负责水平留白（按断点），这里只管纵向节奏。
class TyPageHeader extends StatelessWidget {
  const TyPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  /// 与 [actions] 二选一的单个尾部控件（如搜索框）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Padding(
      padding: const EdgeInsets.only(bottom: TySpace.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ty.typography.titleXL.copyWith(
                        color: ty.colors.textPrimary,
                      ),
                    ),
                    if (subtitle != null) ...<Widget>[
                      const SizedBox(height: TySpace.x4),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ty.typography.bodyS.copyWith(
                          color: ty.colors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: TySpace.x16),
                trailing!,
              ],
              for (final Widget action in actions) ...<Widget>[
                const SizedBox(width: TySpace.x8),
                action,
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// `Sliver` 版本的页面标题（跟随滚动）。
class TyPageHeaderSliver extends StatelessWidget {
  const TyPageHeaderSliver({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.padding = const EdgeInsets.symmetric(horizontal: TySpace.x24),
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: padding,
        child: TyPageHeader(
          title: title,
          subtitle: subtitle,
          actions: actions,
        ),
      ),
    );
  }
}

/// 分组标题：`titleM` + 真实计数 + 右侧动作。
class TySectionHeader extends StatelessWidget {
  const TySectionHeader({
    super.key,
    required this.title,
    this.count,
    this.actionLabel,
    this.onAction,
    this.trailing,
  });

  final String title;

  /// 真实计数；未知就不要传（禁止编造总数）。
  final int? count;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Padding(
      padding: const EdgeInsets.only(
        top: TySpace.x24,
        bottom: TySpace.x12,
      ),
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ty.typography.titleM.copyWith(color: ty.colors.textPrimary),
            ),
          ),
          if (count != null) ...<Widget>[
            const SizedBox(width: TySpace.x8),
            Text(
              '$count',
              style: ty.typography.numericS.copyWith(
                color: ty.colors.textTertiary,
              ),
            ),
          ],
          const Spacer(),
          ?trailing,
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: ty.colors.textSecondary,
                padding: const EdgeInsets.symmetric(horizontal: TySpace.x8),
                minimumSize: Size(0, context.metrics.hitTarget),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: ty.typography.labelM,
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

/// 面板 / 检查器容器：`surfaceRaised` + 1px `border` + `lg` 圆角。
class TyPanel extends StatelessWidget {
  const TyPanel({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.all(TySpace.x16),
    this.radius = TyRadius.lg,
    this.scrollable = false,
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsets padding;
  final double radius;

  /// 内容自行滚动（检查器/队列）。
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ty.colors.surfaceRaised,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: ty.colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (title != null)
            SizedBox(
              height: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: TySpace.x16),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        title!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ty.typography.labelL.copyWith(
                          color: ty.colors.textPrimary,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
            ),
          if (title != null)
            Divider(height: 1, thickness: 1, color: ty.colors.border),
          if (scrollable)
            Expanded(
              child: Padding(padding: padding, child: child),
            )
          else
            Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// 设置/表单分组：`surface` + `border` + `lg`，行之间 1px 分隔。
class TyInsetGroup extends StatelessWidget {
  const TyInsetGroup({
    super.key,
    required this.children,
    this.title,
    this.footer,
  });

  final List<Widget> children;
  final String? title;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(
              left: TySpace.x4,
              bottom: TySpace.x8,
            ),
            child: Text(
              title!,
              style: ty.typography.labelM.copyWith(
                color: ty.colors.textTertiary,
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: ty.colors.surface,
            borderRadius: TyRadius.lgAll,
            border: Border.all(color: ty.colors.border),
          ),
          child: ClipRRect(
            borderRadius: TyRadius.lgAll,
            // 组内容可能包含 Material 控件（ListTile 等）：这里提供最近的
            // Material 祖先，避免它们的水波纹画到组背景之下不可见。
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (int i = 0; i < children.length; i++) ...<Widget>[
                    if (i > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: ty.colors.border,
                      ),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.only(
              left: TySpace.x4,
              top: TySpace.x8,
            ),
            child: Text(
              footer!,
              style: ty.typography.bodyS.copyWith(
                color: ty.colors.textTertiary,
              ),
            ),
          ),
      ],
    );
  }
}

/// 设置行高（`DESIGN.md` §6.4：`TySettingsRow` 高 56）。
const double _settingsRowHeight = 56;

/// 设置行变体（`DESIGN.md` §6.4）。每种变体只决定尾部控件与点击语义，
/// 行本身的排版（标签 `bodyM` + 说明 `bodyS` + 控件右对齐）完全共用。
enum TySettingsRowKind { plain, switchRow, selectRow, navRow, actionRow }

/// 设置行：标签 + 说明 + 尾部控件；可点击时整行响应。
///
/// 四种变体：
/// - [TySettingsRow.switchRow]：尾部开关，点行等同切换；
/// - [TySettingsRow.selectRow]：尾部显示当前值 + 展开箭头，点行打开选择器；
/// - [TySettingsRow.navRow]：尾部 chevron，点行导航；
/// - [TySettingsRow.actionRow]：整行执行动作，`actionLabel` 以强调色收在尾部。
class TySettingsRow extends StatelessWidget {
  const TySettingsRow({
    super.key,
    required this.title,
    this.description,
    this.trailing,
    this.leading,
    this.onTap,
  }) : kind = TySettingsRowKind.plain,
       switchValue = false,
       onSwitchChanged = null,
       valueLabel = null,
       actionLabel = null,
       actionIcon = null,
       destructive = false,
       busy = false;

  /// 开关变体。
  const TySettingsRow.switchRow({
    super.key,
    required this.title,
    this.description,
    this.leading,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) : kind = TySettingsRowKind.switchRow,
       trailing = null,
       onTap = null,
       switchValue = value,
       onSwitchChanged = onChanged,
       valueLabel = null,
       actionLabel = null,
       actionIcon = null,
       destructive = false,
       busy = false;

  /// 选择变体：`value` 是当前值的可读文案（不是 id）。
  const TySettingsRow.selectRow({
    super.key,
    required this.title,
    this.description,
    this.leading,
    required String value,
    this.onTap,
  }) : kind = TySettingsRowKind.selectRow,
       trailing = null,
       switchValue = false,
       onSwitchChanged = null,
       valueLabel = value,
       actionLabel = null,
       actionIcon = null,
       destructive = false,
       busy = false;

  /// 导航变体。
  const TySettingsRow.navRow({
    super.key,
    required this.title,
    this.description,
    this.leading,
    this.onTap,
  }) : kind = TySettingsRowKind.navRow,
       trailing = null,
       switchValue = false,
       onSwitchChanged = null,
       valueLabel = null,
       actionLabel = null,
       actionIcon = null,
       destructive = false,
       busy = false;

  /// 动作变体：`busy` 为真时整行不可点（进行中），尾部文案由调用方给出。
  const TySettingsRow.actionRow({
    super.key,
    required this.title,
    this.description,
    this.leading,
    this.actionLabel,
    this.actionIcon,
    this.destructive = false,
    this.busy = false,
    this.onTap,
  }) : kind = TySettingsRowKind.actionRow,
       trailing = null,
       switchValue = false,
       onSwitchChanged = null,
       valueLabel = null;

  final String title;
  final String? description;
  final Widget? trailing;
  final Widget? leading;
  final VoidCallback? onTap;

  final TySettingsRowKind kind;
  final bool switchValue;
  final ValueChanged<bool>? onSwitchChanged;
  final String? valueLabel;
  final String? actionLabel;
  final IconData? actionIcon;

  /// 动作变体用危险色（删除 / 清理）。
  final bool destructive;

  /// 动作变体进行中。
  final bool busy;

  /// 整行的点击语义：开关变体点行即切换；进行中的动作行不可点。
  VoidCallback? get _effectiveOnTap => switch (kind) {
    TySettingsRowKind.switchRow =>
      onSwitchChanged == null ? null : () => onSwitchChanged!(!switchValue),
    TySettingsRowKind.actionRow => busy ? null : onTap,
    _ => onTap,
  };

  Widget? _trailing(BuildContext context) {
    final TyTokens ty = context.ty;
    switch (kind) {
      case TySettingsRowKind.plain:
        return trailing;
      case TySettingsRowKind.switchRow:
        return Switch(value: switchValue, onChanged: onSwitchChanged);
      case TySettingsRowKind.selectRow:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              valueLabel ?? '',
              style: ty.typography.bodyM.copyWith(
                color: ty.colors.textSecondary,
              ),
            ),
            const SizedBox(width: TySpace.x4),
            Icon(
              Icons.expand_more,
              size: TyIconSize.compact,
              color: ty.colors.textTertiary,
            ),
          ],
        );
      case TySettingsRowKind.navRow:
        return Icon(
          Icons.chevron_right,
          size: TyIconSize.compact,
          color: ty.colors.textTertiary,
        );
      case TySettingsRowKind.actionRow:
        if (actionLabel == null && actionIcon == null) {
          return null;
        }
        final Color color = destructive
            ? ty.colors.danger
            : ty.colors.accent;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (actionIcon != null) ...<Widget>[
              Icon(actionIcon, size: TyIconSize.inline, color: color),
              const SizedBox(width: TySpace.x4),
            ],
            if (actionLabel != null)
              Text(
                actionLabel!,
                style: ty.typography.labelL.copyWith(color: color),
              ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final Widget? trailing = _trailing(context);
    final Widget content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _settingsRowHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: TySpace.x16,
          vertical: TySpace.x12,
        ),
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[
              leading!,
              const SizedBox(width: TySpace.x12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ty.typography.bodyM.copyWith(
                      color: busy
                          ? ty.colors.textDisabled
                          : ty.colors.textPrimary,
                    ),
                  ),
                  if (description != null) ...<Widget>[
                    const SizedBox(height: TySpace.x2),
                    Text(
                      description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ty.typography.bodyS.copyWith(
                        color: ty.colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: TySpace.x12),
              trailing,
            ],
          ],
        ),
      ),
    );
    final VoidCallback? onTap = _effectiveOnTap;
    if (onTap == null) {
      return content;
    }
    return TyInteractive(
      onTap: onTap,
      semanticButton: false,
      builder: (BuildContext context, TyInteractionState state) {
        return ColoredBox(
          color: state.overlay(ty.colors),
          child: content,
        );
      },
    );
  }
}

/// 1px 分隔线。
class TyDivider extends StatelessWidget {
  const TyDivider({super.key, this.inset = 0});

  final double inset;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: Divider(
        height: 1,
        thickness: 1,
        color: context.ty.colors.border,
      ),
    );
  }
}
