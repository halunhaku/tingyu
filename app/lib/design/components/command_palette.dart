import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'buttons.dart';
import 'feedback.dart';
import 'interactive.dart';

/// 面板固定宽（`DESIGN.md` §6.4）。
const double _paletteWidth = 640;

/// 面板最高：约 8 行结果 + 输入框 + 页脚，再多就让结果区自己滚。
const double _paletteMaxHeight = 480;

/// 输入框高（`DESIGN.md` §6.4）。
const double _paletteFieldHeight = 56;

/// 分组头高（`DESIGN.md` §6.4）。
const double _paletteGroupHeight = 28;

/// 结果行高（`DESIGN.md` §6.4）。
const double _paletteRowHeight = 44;

/// 页脚快捷键提示行高。
const double _paletteFooterHeight = 32;

/// 空态区高（给 `TyEmptyState` 一个稳定的落点，避免面板高度忽大忽小）。
const double _paletteEmptyHeight = 200;

/// 加载骨架行数。
const int _paletteSkeletonRows = 3;

/// 命令面板结果条目（`DESIGN.md` §6.4）。
///
/// 条目**已由调用方排好序**，同 `group` 必须连续：面板只负责分组渲染与键盘选中，
/// 不重排结果，否则「搜索排序」会有两套口径（页面一套、面板一套）。
@immutable
class TyPaletteEntry {
  const TyPaletteEntry({
    required this.group,
    required this.label,
    this.subtitle,
    this.icon,
    this.hint,
    this.key,
  });

  /// 「歌曲」「专辑」「艺人」「歌单」「快捷入口」。
  final String group;
  final String label;
  final String? subtitle;
  final IconData? icon;

  /// 快捷键 / 路径提示（行尾小字）。
  final String? hint;

  /// 调用方识别用（例如曲目 id、路由路径）。
  final String? key;
}

/// 命令面板：输入框 + 分组结果（`DESIGN.md` §6.4）。
///
/// 只做呈现：查询防抖、结果拼装与跳转都由调用方通过 [onQueryChanged] / [onSelected]
/// 注入，因此 `/search` 页与 ⌘K 浮层可以共用同一次搜索。
class TyCommandPalette extends StatefulWidget {
  const TyCommandPalette({
    super.key,
    required this.entries,
    required this.onQueryChanged,
    required this.onSelected,
    this.initialQuery = '',
    this.loading = false,
    this.onClosed,
    this.hint = '搜索歌曲、专辑、艺人、歌单',
  });

  /// 已排好序、同 group 连续的结果。
  final List<TyPaletteEntry> entries;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<TyPaletteEntry> onSelected;
  final String initialQuery;

  /// 加载中：显示骨架行，而不是一片空白。
  final bool loading;

  /// `Esc`（或调用方自己的关闭手势）触发。
  final VoidCallback? onClosed;
  final String hint;

  @override
  State<TyCommandPalette> createState() => _TyCommandPaletteState();
}

class _TyCommandPaletteState extends State<TyCommandPalette> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'TyCommandPalette');
  final ScrollController _scroll = ScrollController();

  /// 当前键盘选中项（只数结果行，分组头不参与）。
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    // 方向键与 `Esc` 必须在**输入框自己的焦点节点**上先处理：文本编辑的默认快捷键
    // 会把上下键吃成「光标上下移」，挂到祖先 `Shortcuts` 上已经太晚。
    // `Enter` 不在这里处理：单行输入框的 Enter 走 `onSubmitted`，两处都收会双击发两次。
    _focus.onKeyEvent = _onKey;
  }

  @override
  void didUpdateWidget(TyCommandPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entries.length != widget.entries.length) {
      // 结果集换了（新一轮搜索回来）：选中项回到第一条，否则会停在一行已经不存在的项上。
      _selected = 0;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _query => _controller.text;

  bool get _hasEntries => widget.entries.isNotEmpty;

  int get _lastIndex => _hasEntries ? widget.entries.length - 1 : 0;

  int get _currentIndex => _selected.clamp(0, _lastIndex);

  void _onQueryChanged() {
    setState(() => _selected = 0);
    widget.onQueryChanged(_query);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      widget.onClosed?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int delta) {
    if (!_hasEntries) {
      return;
    }
    final int next = (_currentIndex + delta).clamp(0, _lastIndex);
    if (next == _currentIndex) {
      return;
    }
    setState(() => _selected = next);
    _reveal(next);
  }

  void _activate() {
    if (!_hasEntries) {
      return;
    }
    widget.onSelected(widget.entries[_currentIndex]);
  }

  /// 把选中行滚进可视区（键盘导航时选中项可能正好在边缘之外）。
  void _reveal(int index) {
    if (!_scroll.hasClients) {
      return;
    }
    double offset = 0;
    for (final _PaletteRow row in _rows()) {
      if (!row.isHeader && row.index == index) {
        break;
      }
      offset += row.height;
    }
    final double current = _scroll.offset;
    final double viewport = _scroll.position.viewportDimension;
    double target = current;
    if (offset < current) {
      target = offset;
    } else if (offset + _paletteRowHeight > current + viewport) {
      target = offset + _paletteRowHeight - viewport;
    }
    if (target == current) {
      return;
    }
    target = target.clamp(0, _scroll.position.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: TyDuration.fast,
        curve: TyCurve.standard,
      );
    }
  }

  /// 扁平化行序列：分组头与结果行同列，键盘索引只数结果行。
  List<_PaletteRow> _rows() {
    final List<_PaletteRow> rows = <_PaletteRow>[];
    String? group;
    int index = 0;
    for (final TyPaletteEntry entry in widget.entries) {
      if (entry.group != group) {
        group = entry.group;
        rows.add(_PaletteRow.header(group));
      }
      rows.add(_PaletteRow.entry(entry, index));
      index++;
    }
    return rows;
  }

  double _bodyHeight(List<_PaletteRow> rows) {
    if (widget.loading) {
      return _paletteRowHeight * _paletteSkeletonRows;
    }
    if (!_hasEntries) {
      return _paletteEmptyHeight;
    }
    double total = TySpace.x12; // 列表上下留白
    for (final _PaletteRow row in rows) {
      total += row.height;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return CallbackShortcuts(
      // 焦点落在结果行上时（Tab 过去）这些键仍要能用；焦点在输入框时由焦点节点先接管，
      // 因此不会重复触发。
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            widget.onClosed?.call(),
      },
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: TySpace.x48),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 窄屏（如 412 宽手机）留 32 的左右边距，不让面板贴边。
              final double width = math.min(
                _paletteWidth,
                math.max(TySpace.x64, constraints.maxWidth - TySpace.x32),
              );
              final List<_PaletteRow> rows = _rows();
              final double body = _bodyHeight(rows);
              final bool footer = context.traits.keyboardShortcuts;
              final double total =
                  _paletteFieldHeight +
                  body +
                  (footer ? _paletteFooterHeight : 0);
              final double available = constraints.maxHeight.isFinite
                  ? constraints.maxHeight - TySpace.x48 * 2
                  : _paletteMaxHeight;
              final double height = math.min(
                total,
                math.max(_paletteFieldHeight + _paletteRowHeight, available),
              );
              return SizedBox(
                width: width,
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ty.colors.surfaceOverlay,
                    borderRadius: TyRadius.lgAll,
                    border: Border.all(color: ty.colors.border),
                    boxShadow: ty.elevation(TyElevation.palette),
                  ),
                  child: ClipRRect(
                    borderRadius: TyRadius.lgAll,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _field(context),
                        Flexible(
                          child: SizedBox(
                            height: body,
                            child: _body(context, rows),
                          ),
                        ),
                        if (footer) _footer(context),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _field(BuildContext context) {
    final TyTokens ty = context.ty;
    return Container(
      height: _paletteFieldHeight,
      padding: const EdgeInsets.symmetric(horizontal: TySpace.x16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ty.colors.border)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.search_rounded,
            size: TyIconSize.normal,
            color: ty.colors.textTertiary,
          ),
          const SizedBox(width: TySpace.x12),
          Expanded(
            // 这里不用 `TySearchField`：面板输入框是 56 高、bodyL 字号（§6.4），
            // 与列表工具条那支 36–44 高的搜索框不是同一个控件。
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _activate(),
              cursorColor: ty.colors.accent,
              style: ty.typography.bodyL.copyWith(color: ty.colors.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: ty.typography.bodyL.copyWith(
                  color: ty.colors.textTertiary,
                ),
              ),
            ),
          ),
          if (_query.isNotEmpty)
            TyIconAction(
              icon: Icons.close_rounded,
              semanticLabel: '清除搜索',
              tooltip: '清除',
              onPressed: () => _controller.clear(),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, List<_PaletteRow> rows) {
    if (widget.loading) {
      return Column(
        children: <Widget>[
          for (int i = 0; i < _paletteSkeletonRows; i++)
            SizedBox(
              height: _paletteRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: TySpace.x16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TySkeleton(
                    height: TySpace.x12,
                    width: TySpace.x64 * (_paletteSkeletonRows - i + 2),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    if (!_hasEntries) {
      return Center(
        child: TyEmptyState(
          icon: Icons.search_rounded,
          title: _query.isEmpty ? '输入以搜索' : '没有匹配的结果',
          description: _query.isEmpty ? null : '换个关键词试试',
          compact: true,
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: TySpace.x6),
      itemCount: rows.length,
      itemBuilder: (BuildContext context, int i) {
        final _PaletteRow row = rows[i];
        return row.isHeader
            ? _GroupHeader(label: row.group!)
            : _entryRow(context, row);
      },
    );
  }

  Widget _entryRow(BuildContext context, _PaletteRow row) {
    final TyTokens ty = context.ty;
    final TyPaletteEntry entry = row.entry!;
    final bool selected = row.index == _currentIndex;
    return TyInteractive(
      onTap: () {
        setState(() => _selected = row.index);
        widget.onSelected(entry);
      },
      cursor: SystemMouseCursors.click,
      semanticLabel: entry.subtitle == null
          ? entry.label
          : '${entry.label} · ${entry.subtitle}',
      semanticSelected: selected,
      builder: (BuildContext context, TyInteractionState state) {
        return Container(
          height: _paletteRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: TySpace.x16),
          color: selected ? ty.colors.surfaceSelected : state.overlay(ty.colors),
          child: Row(
            children: <Widget>[
              if (entry.icon != null) ...<Widget>[
                Icon(
                  entry.icon,
                  size: TyIconSize.normal,
                  color: selected ? ty.colors.accent : ty.colors.textSecondary,
                ),
                const SizedBox(width: TySpace.x12),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ty.typography.bodyM.copyWith(
                        color: ty.colors.textPrimary,
                      ),
                    ),
                    if (entry.subtitle != null)
                      Text(
                        entry.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ty.typography.bodyS.copyWith(
                          color: ty.colors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (entry.hint != null) ...<Widget>[
                const SizedBox(width: TySpace.x16),
                Text(
                  entry.hint!,
                  style: ty.typography.labelM.copyWith(
                    color: ty.colors.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _footer(BuildContext context) {
    final TyTokens ty = context.ty;
    return Container(
      height: _paletteFooterHeight,
      padding: const EdgeInsets.symmetric(horizontal: TySpace.x16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ty.colors.border)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            '↑↓ 选择 · Enter 打开 · Esc 关闭',
            style: ty.typography.labelM.copyWith(color: ty.colors.textTertiary),
          ),
          const Spacer(),
          if (_hasEntries)
            Text(
              '${widget.entries.length} 项',
              style: ty.typography.numericS.copyWith(
                color: ty.colors.textTertiary,
              ),
            ),
        ],
      ),
    );
  }
}

/// 分组头：不参与键盘选中，只做视觉分段。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return SizedBox(
      height: _paletteGroupHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: TySpace.x16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ty.typography.labelM.copyWith(color: ty.colors.textTertiary),
          ),
        ),
      ),
    );
  }
}

/// 结果列表的一行：分组头或结果条目。
@immutable
class _PaletteRow {
  const _PaletteRow({this.group, this.entry, this.index = -1});

  factory _PaletteRow.header(String group) => _PaletteRow(group: group);

  factory _PaletteRow.entry(TyPaletteEntry entry, int index) =>
      _PaletteRow(entry: entry, index: index);

  final String? group;
  final TyPaletteEntry? entry;

  /// 结果行的键盘索引（分组头为 -1）。
  final int index;

  bool get isHeader => entry == null;

  double get height => isHeader ? _paletteGroupHeight : _paletteRowHeight;
}
