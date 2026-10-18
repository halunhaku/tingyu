import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../tokens/color.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';

/// 交互态快照：hover / pressed / focused / enabled。
///
/// 组件不自己拼状态色，统一用 [overlay] 取「叠加在该层之上的颜色」，
/// 这样浅色与深色的 hover/pressed 语义不会各写一遍。
@immutable
class TyInteractionState {
  const TyInteractionState({
    required this.hovered,
    required this.pressed,
    required this.focused,
    required this.enabled,
  });

  final bool hovered;
  final bool pressed;
  final bool focused;
  final bool enabled;

  /// 叠加色：按下优先于悬停（`DESIGN.md` §2.4）。
  Color overlay(TyColors colors) {
    if (!enabled) {
      return Colors.transparent;
    }
    if (pressed) {
      return colors.surfacePressed;
    }
    if (hovered) {
      return colors.surfaceHover;
    }
    return Colors.transparent;
  }

  @override
  bool operator ==(Object other) =>
      other is TyInteractionState &&
      other.hovered == hovered &&
      other.pressed == pressed &&
      other.focused == focused &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(hovered, pressed, focused, enabled);
}

/// 一切可交互表面的唯一原语：hover / press / focus / 键盘激活 / 右键 / 长按。
///
/// 为什么不用 `InkWell`：Material 的墨水扩散与 `splashColor` 与「安静、克制」的
/// 视觉语言冲突，且无法表达行内操作键「hover 才出现」这类语汇。这里只暴露状态，
/// 由组件决定画什么。
class TyInteractive extends StatefulWidget {
  const TyInteractive({
    super.key,
    required this.builder,
    this.onTap,
    this.onDoubleTap,
    this.onSecondaryTap,
    this.onSecondaryTapDown,
    this.onLongPress,
    this.onLongPressStart,
    this.enabled = true,
    this.cursor,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
    this.semanticButton = true,
    this.semanticEnabled,
    this.semanticValue,
    this.semanticSelected,
  });

  /// 由状态渲染内容。
  final Widget Function(BuildContext context, TyInteractionState state) builder;

  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  /// 右键（桌面）/ 长按（触控）触发上下文菜单。
  final VoidCallback? onSecondaryTap;
  final void Function(TapDownDetails details)? onSecondaryTapDown;
  final VoidCallback? onLongPress;
  final void Function(LongPressStartDetails details)? onLongPressStart;

  final bool enabled;
  final MouseCursor? cursor;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticLabel;
  final bool semanticButton;

  /// 覆盖语义层的可用性（例如只读行仍可点击但不标为 enabled）。
  final bool? semanticEnabled;
  final String? semanticValue;

  /// 导航/Tab 选中态（读屏播报「已选中」）。
  final bool? semanticSelected;

  @override
  State<TyInteractive> createState() => _TyInteractiveState();
}

class _TyInteractiveState extends State<TyInteractive> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _actionable =>
      widget.enabled &&
      (widget.onTap != null ||
          widget.onDoubleTap != null ||
          widget.onSecondaryTap != null ||
          widget.onLongPress != null);

  void _setPressed(bool value) {
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_actionable || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      widget.onTap?.call();
      // Space 必须被吞掉，否则会滚动页面（修 I2 的同类问题）。
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final TyInteractionState state = TyInteractionState(
      hovered: _hovered,
      pressed: _pressed,
      focused: _focused,
      enabled: widget.enabled,
    );

    Widget child = MouseRegion(
      cursor: _actionable
          ? (widget.cursor ?? SystemMouseCursors.click)
          : MouseCursor.defer,
      onEnter: (_) {
        if (widget.enabled && (_hovered == false)) {
          setState(() => _hovered = true);
        }
      },
      onExit: (_) {
        if (_hovered) {
          setState(() {
            _hovered = false;
            _pressed = false;
          });
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _actionable ? (_) => _setPressed(true) : null,
        onTapUp: _actionable ? (_) => _setPressed(false) : null,
        onTapCancel: _actionable ? () => _setPressed(false) : null,
        onTap: _actionable ? widget.onTap : null,
        onDoubleTap: widget.enabled ? widget.onDoubleTap : null,
        onSecondaryTap: widget.enabled ? widget.onSecondaryTap : null,
        onSecondaryTapDown:
            widget.enabled ? widget.onSecondaryTapDown : null,
        onLongPress: widget.enabled ? widget.onLongPress : null,
        onLongPressStart: widget.enabled ? widget.onLongPressStart : null,
        child: widget.builder(context, state),
      ),
    );

    if (widget.semanticButton || widget.semanticLabel != null) {
      child = Semantics(
        button: widget.semanticButton,
        enabled: widget.semanticEnabled ?? widget.enabled,
        label: widget.semanticLabel,
        value: widget.semanticValue,
        selected: widget.semanticSelected,
        onTap: _actionable ? widget.onTap : null,
        onLongPress: widget.enabled ? widget.onLongPress : null,
        child: child,
      );
    }

    if (widget.focusNode == null && !_actionable) {
      return child;
    }
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (bool value) {
        if (_focused != value) {
          setState(() => _focused = value);
        }
      },
      onKeyEvent: _onKey,
      child: child,
    );
  }
}

/// 焦点环：2px 强调色 + 2px 偏移（`DESIGN.md` §2.4）。
///
/// 始终占用 2px 外层空间，避免聚焦时布局跳动。
class TyFocusRing extends StatelessWidget {
  const TyFocusRing({
    super.key,
    required this.focused,
    required this.radius,
    required this.child,
  });

  final bool focused;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return AnimatedContainer(
      duration: TyDuration.fast,
      curve: TyCurve.standard,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius + 2),
        border: Border.all(
          color: focused ? ty.colors.focusRing : Colors.transparent,
          width: 2,
        ),
      ),
      child: child,
    );
  }
}
