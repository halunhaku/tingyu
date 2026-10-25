import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/tokens.dart';
import 'inputs.dart';
import 'interactive.dart';

/// 导航目的地：侧栏 / 图标 rail / 底部 Tab 共用。
@immutable
class TyNavDestination {
  const TyNavDestination({
    required this.label,
    required this.icon,
    required this.route,
    this.selectedIcon,
    this.detail,
  });

  final String label;
  final IconData icon;
  final IconData? selectedIcon;
  final String route;

  /// 右侧次级信息（来源曲目数、计数）。
  final String? detail;
}

/// 侧栏分组：标题 + 条目 + 可选尾部动作。
@immutable
class TySidebarSection {
  const TySidebarSection({
    this.title,
    required this.destinations,
    this.action,
    this.hint,
  });

  final String? title;
  final List<TyNavDestination> destinations;

  /// 分组标题右侧的动作（如「新建播放列表」）。
  final Widget? action;

  /// 无条目时的提示；与 [destinations] 互斥。
  final String? hint;
}

/// 桌面展开侧栏（`DESIGN.md` §6.1）：搜索 + 分组导航 + 底部设置。
class TySidebar extends StatelessWidget {
  const TySidebar({
    super.key,
    required this.width,
    required this.searchController,
    required this.searchHint,
    this.searchFocusNode,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.sections,
    required this.selectedRoute,
    required this.onNavigate,
    required this.footer,
    this.header,
    this.showSearch = true,
  });

  final double width;
  final TextEditingController searchController;
  final String searchHint;

  /// `⌘F` 聚焦用；为空时由 `TySearchField` 自建。
  final FocusNode? searchFocusNode;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final List<TySidebarSection> sections;
  final String selectedRoute;
  final ValueChanged<String> onNavigate;
  final List<TyNavDestination> footer;

  /// 用于已迁移页面展示品牌与来源摘要；为空时保持旧侧栏。
  final Widget? header;

  /// 曲库把搜索移到内容区后关闭侧栏搜索；其它页面保持默认显示。
  final bool showSearch;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Container(
      width: width,
      color: ty.colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                TySpace.x16,
                TySpace.x16,
                TySpace.x16,
                TySpace.x12,
              ),
              child: header!,
            ),
          if (showSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                TySpace.x12,
                TySpace.x12,
                TySpace.x12,
                TySpace.x8,
              ),
              child: TySearchField(
                controller: searchController,
                focusNode: searchFocusNode,
                hint: searchHint,
                onChanged: onSearchChanged,
                onClear: onClearSearch,
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: TySpace.x8),
              children: <Widget>[
                for (final TySidebarSection section in sections)
                  _SidebarGroup(
                    section: section,
                    selectedRoute: selectedRoute,
                    onNavigate: onNavigate,
                  ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: ty.colors.border),
          Padding(
            padding: const EdgeInsets.all(TySpace.x8),
            child: Column(
              children: <Widget>[
                for (final TyNavDestination destination in footer)
                  _SidebarRow(
                    destination: destination,
                    selected: _matches(selectedRoute, destination.route),
                    onTap: () => onNavigate(destination.route),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarGroup extends StatelessWidget {
  const _SidebarGroup({
    required this.section,
    required this.selectedRoute,
    required this.onNavigate,
  });

  final TySidebarSection section;
  final String selectedRoute;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (section.title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              TySpace.x8,
              TySpace.x16,
              TySpace.x4,
              TySpace.x4,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    section.title!,
                    style: ty.typography.labelS.copyWith(
                      color: ty.colors.textTertiary,
                    ),
                  ),
                ),
                ?section.action,
              ],
            ),
          ),
        if (section.hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              TySpace.x8,
              TySpace.x4,
              TySpace.x8,
              TySpace.x4,
            ),
            child: Text(
              section.hint!,
              style: ty.typography.bodyS.copyWith(
                color: ty.colors.textTertiary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        for (final TyNavDestination destination in section.destinations)
          _SidebarRow(
            destination: destination,
            selected: _matches(selectedRoute, destination.route),
            onTap: () => onNavigate(destination.route),
          ),
      ],
    );
  }
}

bool _matches(String current, String route) =>
    current == route || current.startsWith('$route/');

class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final TyNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final IconData icon = selected
        ? (destination.selectedIcon ?? destination.icon)
        : destination.icon;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: TyInteractive(
        onTap: onTap,
        semanticLabel: destination.label,
        semanticSelected: selected,
        semanticButton: true,
        builder: (BuildContext context, TyInteractionState state) {
          return Container(
            height: context.metrics.navRowHeight,
            padding: const EdgeInsets.symmetric(horizontal: TySpace.x8),
            decoration: BoxDecoration(
              color: selected
                  ? ty.colors.surfaceSelected
                  : (state.hovered ? ty.colors.surfaceHover : null),
              borderRadius: TyRadius.smAll,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  icon,
                  size: TyIconSize.compact,
                  color: selected ? ty.colors.accent : ty.colors.textSecondary,
                ),
                const SizedBox(width: TySpace.x12),
                Expanded(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ty.typography.labelM.copyWith(
                      color: selected
                          ? ty.colors.accent
                          : ty.colors.textPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (destination.detail != null)
                  Text(
                    destination.detail!,
                    style: ty.typography.numericS.copyWith(
                      color: ty.colors.textTertiary,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// medium 形态的图标导航（`DESIGN.md` §6.1）。
class TyNavRail extends StatelessWidget {
  const TyNavRail({
    super.key,
    required this.destinations,
    required this.selectedRoute,
    required this.onNavigate,
    this.footer = const <TyNavDestination>[],
  });

  final List<TyNavDestination> destinations;
  final String selectedRoute;
  final ValueChanged<String> onNavigate;
  final List<TyNavDestination> footer;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Container(
      width: context.metrics.railWidth,
      color: ty.colors.surface,
      child: Column(
        children: <Widget>[
          const SizedBox(height: TySpace.x8),
          // 目的地直接排在 Column 里：**不套 Expanded / 滚动容器**。
          // 滚动容器会给出「视口」，后面的目的地会被留在视口外（真机截图里 rail
          // 只画出过前四个，而部件树里六个都在）——直接排就没有视口可言。
          // 放不下只会是窗口矮于 TyLayoutScope.minWindowSize，外壳会先提示过小。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: TySpace.x8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final TyNavDestination destination in destinations)
                  _RailItem(
                    destination: destination,
                    selected: _matches(selectedRoute, destination.route),
                    onTap: () => onNavigate(destination.route),
                  ),
              ],
            ),
          ),
          const Spacer(),
          Divider(height: 1, thickness: 1, color: ty.colors.border),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: TySpace.x8,
              vertical: TySpace.x8,
            ),
            child: Column(
              children: <Widget>[
                for (final TyNavDestination destination in footer)
                  _RailItem(
                    destination: destination,
                    selected: _matches(selectedRoute, destination.route),
                    onTap: () => onNavigate(destination.route),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final TyNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TySpace.x2),
      child: Tooltip(
        message: destination.label,
        waitDuration: const Duration(milliseconds: 400),
        child: TyInteractive(
          onTap: onTap,
          semanticLabel: destination.label,
          semanticSelected: selected,
          semanticButton: true,
          builder: (BuildContext context, TyInteractionState state) {
            return Container(
              height: 44,
              decoration: BoxDecoration(
                color: selected
                    ? ty.colors.accentSoft
                    : (state.hovered ? ty.colors.surfaceHover : null),
                borderRadius: TyRadius.smAll,
              ),
              child: Icon(
                selected
                    ? (destination.selectedIcon ?? destination.icon)
                    : destination.icon,
                size: TyIconSize.toolbar,
                color: selected ? ty.colors.accent : ty.colors.textSecondary,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// compact 形态的底部 Tab（`DESIGN.md` §6.1）：四个真实根目的地。
class TyBottomNav extends StatelessWidget {
  const TyBottomNav({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<TyNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Container(
      height: context.metrics.navBarHeight,
      decoration: BoxDecoration(
        color: ty.colors.surface,
        border: Border(top: BorderSide(color: ty.colors.border)),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < destinations.length; i++)
            Expanded(
              child: _BottomNavItem(
                destination: destinations[i],
                selected: i == selectedIndex,
                onTap: () => onSelected(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final TyNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return TyInteractive(
      onTap: onTap,
      semanticLabel: destination.label,
      semanticSelected: selected,
      semanticButton: true,
      builder: (BuildContext context, TyInteractionState state) {
        final Color color = selected
            ? ty.colors.accent
            : ty.colors.textTertiary;
        return Container(
          color: state.pressed ? ty.colors.surfacePressed : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                selected
                    ? (destination.selectedIcon ?? destination.icon)
                    : destination.icon,
                size: TyIconSize.toolbar,
                color: color,
              ),
              const SizedBox(height: TySpace.x2),
              Text(
                destination.label,
                style: ty.typography.labelS.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
