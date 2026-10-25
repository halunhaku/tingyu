import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/tokens.dart';
import 'interactive.dart';

/// 搜索框：侧栏、列表工具条、搜索页共用。
///
/// 输入态**不吞空格**（修 I2）：这里只做视觉，不改键盘语义。
class TySearchField extends StatefulWidget {
  const TySearchField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint = '搜索歌曲、专辑、艺术家',
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.onClear,
    this.autofocus = false,
    this.readOnly = false,
    this.expand = true,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// 只读时点击（侧栏点击跳转到搜索页）。
  final VoidCallback? onTap;
  final VoidCallback? onClear;
  final bool autofocus;
  final bool readOnly;
  final bool expand;

  @override
  State<TySearchField> createState() => _TySearchFieldState();
}

class _TySearchFieldState extends State<TySearchField> {
  TextEditingController? _internal;
  FocusNode? _internalFocus;
  bool _focused = false;
  bool _hasText = false;

  TextEditingController get _controller =>
      widget.controller ?? (_internal ??= TextEditingController());

  FocusNode get _focusNode => widget.focusNode ?? (_internalFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _hasText = _controller.text.isNotEmpty;
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(TySearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _internal)?.removeListener(_onTextChanged);
      _controller.addListener(_onTextChanged);
      _hasText = _controller.text.isNotEmpty;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _internalFocus)?.removeListener(_onFocusChanged);
      _focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _internal?.dispose();
    _internalFocus?.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final bool next = _controller.text.isNotEmpty;
    if (next != _hasText) {
      setState(() => _hasText = next);
    }
  }

  void _onFocusChanged() {
    if (_focused != _focusNode.hasFocus) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  void _clear() {
    _controller.clear();
    widget.onClear?.call();
    widget.onChanged?.call('');
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final TyMetrics metrics = context.metrics;
    final Widget field = Container(
      height: metrics.searchHeight,
      padding: const EdgeInsets.symmetric(horizontal: TySpace.x12),
      decoration: BoxDecoration(
        color: ty.colors.surfaceSunken,
        borderRadius: TyRadius.smAll,
        border: Border.all(
          color: _focused ? ty.colors.borderStrong : Colors.transparent,
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.search,
            size: TyIconSize.normal,
            color: _focused ? ty.colors.textSecondary : ty.colors.textTertiary,
          ),
          const SizedBox(width: TySpace.x8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              readOnly: widget.readOnly,
              autofocus: widget.autofocus,
              onTap: widget.onTap,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              textInputAction: TextInputAction.search,
              cursorColor: ty.colors.accent,
              cursorWidth: 1.5,
              style: ty.typography.bodyM.copyWith(color: ty.colors.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: ty.typography.bodyM.copyWith(
                  color: ty.colors.textTertiary,
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_hasText)
            _ClearButton(onPressed: _clear)
          else
            Padding(
              padding: const EdgeInsets.only(left: TySpace.x8),
              child: Text(
                _shortcutHint(context),
                style: ty.typography.numericS.copyWith(
                  color: ty.colors.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
    return widget.expand
        ? SizedBox(width: double.infinity, child: field)
        : field;
  }

  String _shortcutHint(BuildContext context) {
    if (context.formFactor == FormFactor.compact) {
      return '';
    }
    return context.traits.primaryModifierIsMeta ? '⌘F' : 'Ctrl F';
  }
}

class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return TyInteractive(
      onTap: onPressed,
      semanticLabel: '清除搜索',
      builder: (BuildContext context, TyInteractionState state) {
        return Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: state.overlay(ty.colors),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.close,
            size: TyIconSize.inline,
            color: ty.colors.textSecondary,
          ),
        );
      },
    );
  }
}

/// 表单文本输入（WebDAV / 夸克 / AI 配置共用）。
class TyTextField extends StatelessWidget {
  const TyTextField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.errorText,
    this.helperText,
    this.obscureText = false,
    this.enabled = true,
    this.autofocus = false,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.suffix,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final String? errorText;
  final String? helperText;
  final bool obscureText;
  final bool enabled;
  final bool autofocus;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool hasError = errorText != null && errorText!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (label != null) ...<Widget>[
          Text(
            label!,
            style: ty.typography.labelM.copyWith(color: ty.colors.textSecondary),
          ),
          const SizedBox(height: TySpace.x6),
        ],
        Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: TySpace.x12),
          decoration: BoxDecoration(
            color: enabled ? ty.colors.surfaceSunken : ty.colors.canvas,
            borderRadius: TyRadius.smAll,
            border: Border.all(
              color: hasError ? ty.colors.danger : ty.colors.border,
            ),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: enabled,
                  autofocus: autofocus,
                  obscureText: obscureText,
                  keyboardType: keyboardType,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  style: ty.typography.bodyM.copyWith(
                    color: enabled ? ty.colors.textPrimary : ty.colors.textDisabled,
                  ),
                  cursorColor: ty.colors.accent,
                  cursorWidth: 1.5,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: hint,
                    hintStyle: ty.typography.bodyM.copyWith(
                      color: ty.colors.textTertiary,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: TySpace.x12,
                    ),
                  ),
                ),
              ),
              ?suffix,
            ],
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: TySpace.x6),
            child: Text(
              errorText!,
              style: ty.typography.bodyS.copyWith(color: ty.colors.danger),
            ),
          )
        else if (helperText != null)
          Padding(
            padding: const EdgeInsets.only(top: TySpace.x6),
            child: Text(
              helperText!,
              style: ty.typography.bodyS.copyWith(
                color: ty.colors.textTertiary,
              ),
            ),
          ),
      ],
    );
  }
}

/// 桌面快捷键守卫：输入框聚焦时把 `Space` 交还给文本，而不是触发播放。
///
/// 用法：在页面的 `Shortcuts/Actions` 之上包一层；`Space` 是否被消费由
/// `FocusManager.instance.primaryFocus` 的上下文类型决定（`EditableText` 子类）。
bool tyIsTextInputFocused() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) {
    return false;
  }
  return context.findAncestorStateOfType<EditableTextState>() != null ||
      context.widget is EditableText;
}
