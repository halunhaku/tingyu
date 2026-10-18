import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme.dart';
import '../tokens/color.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'buttons.dart';
import 'interactive.dart';

/// 骨架块：加载态的唯一表达（`DESIGN.md` §2.4）。禁止页面级转圈。
class TySkeleton extends StatefulWidget {
  const TySkeleton({
    super.key,
    this.width,
    this.height = 12,
    this.radius = TyRadius.xs,
  });

  /// 文本行骨架：宽度占满、高度按行高。
  const TySkeleton.line({super.key, this.width = double.infinity})
    : height = 12,
      radius = TyRadius.xs;

  final double? width;
  final double height;
  final double radius;

  @override
  State<TySkeleton> createState() => _TySkeletonState();
}

class _TySkeletonState extends State<TySkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: TyDuration.shimmer,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TyColors colors = context.ty.colors;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      if (_controller.isAnimating) {
        _controller.stop();
      }
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: reduceMotion
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: colors.skeletonBase,
                borderRadius: BorderRadius.circular(widget.radius),
              ),
            )
          : AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                final double t = _controller.value;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    gradient: LinearGradient(
                      begin: Alignment(-1.6 + 3.2 * t, 0),
                      end: Alignment(-0.6 + 3.2 * t, 0),
                      colors: <Color>[
                        colors.skeletonBase,
                        colors.skeletonHighlight,
                        colors.skeletonBase,
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 线性进度：确定值（扫描 / 同步）与不确定值（等待首个事件）。
class TyProgressBar extends StatelessWidget {
  const TyProgressBar({
    super.key,
    this.value,
    this.height = 3,
    this.semanticLabel,
  });

  /// `null` = 不确定进度。
  final double? value;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final TyColors c = context.ty.colors;
    final double v = (value ?? 0).clamp(0, 1).toDouble();
    return Semantics(
      label: semanticLabel,
      value: value == null ? null : '${(v * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ColoredBox(color: c.border),
              if (value == null)
                const _IndeterminateBar()
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: v,
                    child: ColoredBox(color: c.accent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IndeterminateBar extends StatefulWidget {
  const _IndeterminateBar();

  @override
  State<_IndeterminateBar> createState() => _IndeterminateBarState();
}

class _IndeterminateBarState extends State<_IndeterminateBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = context.ty.colors.accent;
    if (MediaQuery.disableAnimationsOf(context)) {
      return Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: 0.3,
          child: ColoredBox(color: accent),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return Align(
          alignment: Alignment(-1 + 2.4 * _controller.value, 0),
          child: FractionallySizedBox(
            widthFactor: 0.35,
            child: ColoredBox(color: accent),
          ),
        );
      },
    );
  }
}

/// 小徽标：来源类型、数量、状态。
enum TyBadgeTone { neutral, accent, success, warning, danger }

class TyBadge extends StatelessWidget {
  const TyBadge({
    super.key,
    required this.label,
    this.tone = TyBadgeTone.neutral,
    this.icon,
  });

  final String label;
  final TyBadgeTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final (Color background, Color foreground) = switch (tone) {
      TyBadgeTone.neutral => (ty.colors.surfaceSunken, ty.colors.textSecondary),
      TyBadgeTone.accent => (ty.colors.accentSoft, ty.colors.accent),
      TyBadgeTone.success => (
        Color.alphaBlend(ty.colors.success.withValues(alpha: 0.14), ty.colors.surface),
        ty.colors.success,
      ),
      TyBadgeTone.warning => (
        Color.alphaBlend(ty.colors.warning.withValues(alpha: 0.16), ty.colors.surface),
        ty.colors.warning,
      ),
      TyBadgeTone.danger => (
        Color.alphaBlend(ty.colors.danger.withValues(alpha: 0.14), ty.colors.surface),
        ty.colors.danger,
      ),
    };
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: TySpace.x8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: TyRadius.xsAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: TyIconSize.inline, color: foreground),
            const SizedBox(width: TySpace.x4),
          ],
          Text(label, style: ty.typography.labelS.copyWith(color: foreground)),
        ],
      ),
    );
  }
}

/// 空态：图标 + 标题 + 一句说明 + 最多一个主操作。
class TyEmptyState extends StatelessWidget {
  const TyEmptyState({
    super.key,
    required this.title,
    this.icon = Icons.music_note_outlined,
    this.description,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final String title;
  final IconData icon;
  final String? description;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? TySpace.x16 : TySpace.x32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: compact ? 24 : 32,
              color: ty.colors.textTertiary,
            ),
            SizedBox(height: compact ? TySpace.x8 : TySpace.x12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: ty.typography.titleM.copyWith(color: ty.colors.textPrimary),
            ),
            if (description != null) ...<Widget>[
              const SizedBox(height: TySpace.x6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  description!,
                  textAlign: TextAlign.center,
                  style: ty.typography.bodyS.copyWith(
                    color: ty.colors.textSecondary,
                  ),
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: TySpace.x16),
              TyButton(
                label: actionLabel!,
                onPressed: onAction,
                variant: TyButtonVariant.secondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误态：原因 + 重试。`compact` 用于播放条 / 面板内联。
class TyErrorView extends StatelessWidget {
  const TyErrorView({
    super.key,
    required this.title,
    this.detail,
    this.onRetry,
    this.retryLabel = '重试',
    this.compact = false,
  });

  final String title;
  final String? detail;
  final VoidCallback? onRetry;
  final String retryLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final Widget content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.error_outline, size: TyIconSize.normal, color: ty.colors.danger),
        const SizedBox(width: TySpace.x8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                maxLines: compact ? 2 : 3,
                overflow: TextOverflow.ellipsis,
                style: (compact ? ty.typography.bodyS : ty.typography.bodyM)
                    .copyWith(color: ty.colors.textPrimary),
              ),
              if (detail != null && !compact) ...<Widget>[
                const SizedBox(height: TySpace.x4),
                Text(
                  detail!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: ty.typography.bodyS.copyWith(
                    color: ty.colors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (onRetry != null) ...<Widget>[
          const SizedBox(width: TySpace.x12),
          TyButton(
            label: retryLabel,
            onPressed: onRetry,
            variant: TyButtonVariant.secondary,
            dense: true,
          ),
        ],
      ],
    );

    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: TySpace.x12,
          vertical: TySpace.x6,
        ),
        child: content,
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(TySpace.x32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: content,
        ),
      ),
    );
  }
}

/// 四态入口：loading → 骨架；error → `TyErrorView`；empty → `TyEmptyState`；data → 内容。
///
/// 这是唯一允许接 `AsyncValue` 的呈现组件（`DESIGN.md` §0.4）。
class TyAsyncView<T> extends StatelessWidget {
  const TyAsyncView({
    super.key,
    required this.value,
    required this.data,
    this.loading,
    this.error,
    this.empty,
    this.isEmpty,
    this.isEmptyError = false,
  });

  final AsyncValue<T> value;
  final Widget Function(BuildContext context, T data) data;

  /// 默认是 3 行骨架；列表页传自己的骨架。
  final WidgetBuilder? loading;
  final Widget Function(BuildContext context, Object error, StackTrace? stack)? error;
  final WidgetBuilder? empty;
  final bool Function(T data)? isEmpty;

  /// 是否把「数据为空」视为错误（例如扫描结果为 0 首且请求要求非空）。
  final bool isEmptyError;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () =>
          loading?.call(context) ??
          const Padding(
            padding: EdgeInsets.all(TySpace.x16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TySkeleton(height: 16, width: 180),
                SizedBox(height: TySpace.x12),
                TySkeleton.line(),
                SizedBox(height: TySpace.x8),
                TySkeleton.line(width: 240),
              ],
            ),
          ),
      error: (Object errorValue, StackTrace stack) =>
          error?.call(context, errorValue, stack) ??
          TyErrorView(
            title: '加载失败',
            detail: errorValue.toString(),
            onRetry: null,
          ),
      data: (T dataValue) {
        if (isEmpty?.call(dataValue) ?? false) {
          if (isEmptyError) {
            return TyErrorView(title: '没有可用的数据');
          }
          return empty?.call(context) ??
              const TyEmptyState(title: '暂无内容');
        }
        return data(context, dataValue);
      },
    );
  }
}

/// 统一确认对话框：危险操作必须走这里（`DESIGN.md` §6.4）。
Future<bool> tyConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  String cancelLabel = '取消',
  bool destructive = false,
}) async {
  final TyTokens ty = context.ty;
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        backgroundColor: ty.colors.surfaceOverlay,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: TyRadius.lgAll),
        title: Text(title, style: ty.typography.titleM),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            message,
            style: ty.typography.bodyM.copyWith(color: ty.colors.textSecondary),
          ),
        ),
        actions: <Widget>[
          TyButton(
            label: cancelLabel,
            variant: TyButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          TyButton(
            label: confirmLabel,
            variant: destructive
                ? TyButtonVariant.danger
                : TyButtonVariant.primary,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// 让 `TyInteractive` 的焦点环在组件内可用（避免各处重复包一层）。
class TyFocusable extends StatelessWidget {
  const TyFocusable({super.key, required this.focused, required this.radius, required this.child});

  final bool focused;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      TyFocusRing(focused: focused, radius: radius, child: child);
}

/// 轻量底部反馈：一句话 + 可选动作，不承载错误详情（`DESIGN.md` §6.4）。
///
/// 错误详情走 `TyErrorView` / 对话框；这里只用于「已复制」「已加入队列」这类即时确认。
abstract final class TySnack {
  static void show(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final TyTokens ty = context.ty;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: ty.typography.bodyM.copyWith(color: ty.colors.canvas),
          ),
          backgroundColor: ty.colors.textPrimary,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(TySpace.x16),
          shape: const RoundedRectangleBorder(borderRadius: TyRadius.mdAll),
          action: actionLabel == null || onAction == null
              ? null
              : SnackBarAction(
                  label: actionLabel,
                  textColor: ty.colors.accent,
                  onPressed: onAction,
                ),
        ),
      );
  }
}
