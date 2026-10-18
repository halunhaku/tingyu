import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/tokens.dart';

/// 一条上下文菜单动作（桌面右键 / 触控长按共用同一份数据）。
@immutable
class TyMenuAction {
  const TyMenuAction({
    required this.label,
    this.icon,
    this.onSelected,
    this.destructive = false,
    this.enabled = true,
    this.hint,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onSelected;

  /// 用 `danger` 文字色（删除 / 移除 / 清洗）。
  final bool destructive;
  final bool enabled;

  /// 右侧快捷键提示。
  final String? hint;
}

/// 上下文菜单：桌面右键与触控长按共用（`DESIGN.md` §6.4）。
///
/// 定位、贴边翻转、焦点陷阱与 `Esc` 全部交给 `showMenu`：自己搭 overlay 定位
/// 会在多窗口 / 安全区 / RTL 上各踩一遍坑，而这些是框架已经解决的问题。
abstract final class TyContextMenu {
  /// 浮层最小宽（`DESIGN.md` §6.4）。
  static const double _minWidth = 220;

  /// 阴影档位：`showMenu` 只接受 elevation 驱动的框架阴影，无法直接注入
  /// `TyElevation.popover` 的 BoxShadow，因此取最接近的档位并复用 token 阴影色；
  /// 深色主题本来就不投影（§3.5），那里 elevation 归零。
  static const double _popoverElevation = 8;

  /// 行高：桌面 32，但不低于形态命中区（触控 44 是硬约束，不能为了好看压到 32）。
  static double _rowHeight(BuildContext context) =>
      math.max(TySpace.x32, context.metrics.hitTarget);

  /// [position] 为全局坐标（`TapDownDetails.globalPosition` 或鼠标位置）。
  static Future<void> show(
    BuildContext context, {
    required Offset position,
    required List<TyMenuAction> actions,
  }) async {
    if (actions.isEmpty) {
      return;
    }
    final TyTokens ty = context.ty;
    final List<BoxShadow> shadow = ty.elevation(TyElevation.popover);
    final RenderBox overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()!
            as RenderBox;
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: _items(context, actions),
      color: ty.colors.surfaceOverlay,
      surfaceTintColor: Colors.transparent,
      elevation: shadow.isEmpty ? 0 : _popoverElevation,
      shadowColor: shadow.isEmpty ? Colors.transparent : shadow.first.color,
      shape: RoundedRectangleBorder(
        borderRadius: TyRadius.mdAll,
        side: BorderSide(color: ty.colors.border),
      ),
      constraints: const BoxConstraints(minWidth: _minWidth),
      clipBehavior: Clip.antiAlias,
    );
  }

  static List<PopupMenuEntry<void>> _items(
    BuildContext context,
    List<TyMenuAction> actions,
  ) {
    final double height = _rowHeight(context);
    final List<PopupMenuEntry<void>> entries = <PopupMenuEntry<void>>[];
    bool separated = false;
    for (int i = 0; i < actions.length; i++) {
      final TyMenuAction action = actions[i];
      // 危险项自成一组：误点代价最高的那一项要和普通动作隔开。
      if (action.destructive && !separated && i > 0) {
        entries.add(const PopupMenuDivider(height: TySpace.x12));
        separated = true;
      }
      // 菜单项用 `PopupMenuItem` 自带的 InkWell 处理点击：它点击后要由路由关闭菜单并
      // 交还焦点。这里套 `TyInteractive` 会把点击从路由手里抢走（菜单不关、焦点不还）。
      // 悬停 / 焦点高亮由主题的 hoverColor / focusColor 提供（`TyTheme` 已设 hoverColor）。
      entries.add(
        PopupMenuItem<void>(
          height: height,
          enabled: action.enabled,
          onTap: action.onSelected,
          padding: const EdgeInsets.symmetric(horizontal: TySpace.x12),
          child: _MenuRow(action: action),
        ),
      );
    }
    return entries;
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.action});

  final TyMenuAction action;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    // 约定：leading 图标为 check 的项即「当前项」，用 accent 勾选。
    // 这样菜单项数据模型不必再长出 checked 字段，排序菜单也复用了同一套外观。
    final bool checked = action.icon == Icons.check;
    final Color foreground = !action.enabled
        ? ty.colors.textDisabled
        : (action.destructive ? ty.colors.danger : ty.colors.textPrimary);
    final Color iconColor = !action.enabled
        ? ty.colors.textDisabled
        : (checked
              ? ty.colors.accent
              : (action.destructive
                    ? ty.colors.danger
                    : ty.colors.textSecondary));
    return Row(
      children: <Widget>[
        if (action.icon != null) ...<Widget>[
          Icon(action.icon, size: TyIconSize.compact, color: iconColor),
          const SizedBox(width: TySpace.x8),
        ],
        Expanded(
          child: Text(
            action.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ty.typography.bodyM.copyWith(color: foreground),
          ),
        ),
        if (action.hint != null) ...<Widget>[
          const SizedBox(width: TySpace.x16),
          Text(
            action.hint!,
            style: ty.typography.labelM.copyWith(color: ty.colors.textTertiary),
          ),
        ],
      ],
    );
  }
}
