import 'package:flutter/material.dart';

import 'buttons.dart';
import 'context_menu.dart';

/// 排序方向（`DESIGN.md` §6.4 的「升序 / 降序」）。
enum TySortDirection { ascending, descending }

/// 一个排序选项：值给页面，标签给用户看。
///
/// 泛型而不是字符串枚举：曲库的排序维度在页面层是 enum，在 URL 里是 query 参数，
/// 组件不该被迫认识任何一种。
@immutable
class TySortOption<T> {
  const TySortOption({required this.value, required this.label});

  final T value;
  final String label;
}

/// 排序菜单入口：次级按钮 + 当前选项名，点击弹出选项与方向（`DESIGN.md` §6.4）。
///
/// 弹层复用 [TyContextMenu]，因此排序与其他右键菜单在视觉、键盘行为上完全一致；
/// 按钮位置由这里换算，浮层落点仍由 `showMenu` 决定。
class TySortMenu<T> extends StatelessWidget {
  const TySortMenu({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.direction,
    this.onDirectionChanged,
    this.label = '排序',
  });

  final T value;
  final List<TySortOption<T>> options;
  final ValueChanged<T> onChanged;

  /// `null` → 菜单里不出现方向项。
  final TySortDirection? direction;
  final ValueChanged<TySortDirection>? onDirectionChanged;

  /// 无障碍名称（按钮上的文字是当前选项名，读屏需要知道这是在排序）。
  final String label;

  @override
  Widget build(BuildContext context) {
    TySortOption<T>? current;
    for (final TySortOption<T> option in options) {
      if (option.value == value) {
        current = option;
      }
    }
    final TySortDirection? dir = direction;
    return Builder(
      builder: (BuildContext context) {
        return TyButton(
          // 匹配不到选项时不编造名字，退回「排序」。
          label: current?.label ?? label,
          icon: dir == null
              ? Icons.swap_vert_rounded
              : (dir == TySortDirection.ascending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded),
          variant: TyButtonVariant.secondary,
          tooltip: label,
          onPressed: options.isEmpty ? null : () => _open(context, current, dir),
        );
      },
    );
  }

  Future<void> _open(
    BuildContext buttonContext,
    TySortOption<T>? current,
    TySortDirection? dir,
  ) async {
    final RenderBox box = buttonContext.findRenderObject()! as RenderBox;
    final Offset origin = box.localToGlobal(Offset.zero);
    await TyContextMenu.show(
      buttonContext,
      position: origin + Offset(0, box.size.height),
      actions: <TyMenuAction>[
        for (final TySortOption<T> option in options)
          TyMenuAction(
            label: option.label,
            icon: identical(option, current) ? Icons.check : null,
            onSelected: () => onChanged(option.value),
          ),
        if (dir != null) ...<TyMenuAction>[
          TyMenuAction(
            label: '升序',
            icon: dir == TySortDirection.ascending ? Icons.check : null,
            // 没有回调就不可选：菜单里出现一个点了没反应的项比不出现更糟。
            enabled: onDirectionChanged != null,
            onSelected: () =>
                onDirectionChanged?.call(TySortDirection.ascending),
          ),
          TyMenuAction(
            label: '降序',
            icon: dir == TySortDirection.descending ? Icons.check : null,
            enabled: onDirectionChanged != null,
            onSelected: () =>
                onDirectionChanged?.call(TySortDirection.descending),
          ),
        ],
      ],
    );
  }
}
