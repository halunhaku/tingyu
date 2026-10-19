import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/tokens.dart';

/// 对话框宽度（`DESIGN.md` §6.4）：常规 420，表单 480。
///
/// 令牌层（`TySize`）没有「对话框宽度」这一档，规范把它直接写成数值，这里照规范取值；
/// 这是唯一写值点，将来要统一调整只改这里。
const double _dialogWidth = 420;
const double _dialogFormWidth = 480;

/// 高度上限比例（`DESIGN.md` §6.4：Sheet 最大高 90%）。
const double _maxHeightRatio = 0.9;

/// `Dialog` 只接受 elevation 驱动的框架阴影，无法直接注入 `TyElevation.sheet` 的
/// BoxShadow，所以取最接近的档位；深色本来就不投影（§3.5），那里归零。
const double _sheetElevation = 12;

/// 统一对话框容器（`DESIGN.md` §6.4）：标题 `titleL`、动作右对齐、圆角 `lg`
/// + `surfaceOverlay` + 1px `border`。
///
/// 纯展示：不读 provider、不自己弹窗；呈现方式（遮罩、焦点陷阱、路由）由使用方决定，
/// 需要现成的模态包装器用 [showTyDialog]。
///
/// - `form: true` 时按表单宽度 480，内容区可滚动（字段多时不撑破窗口）；
/// - 正文样式由传入的 `child` 自己取 token（正文默认 `bodyM`）；
/// - 危险操作的主按钮由调用方传 `TyButtonVariant.danger`。
class TyDialog extends StatelessWidget {
  const TyDialog({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const <Widget>[],
    this.form = false,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;

  /// 表单形态：宽度 480，内容可滚动。
  final bool form;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final List<BoxShadow> shadow = ty.elevation(TyElevation.sheet);
    final double maxHeight =
        MediaQuery.sizeOf(context).height * _maxHeightRatio;

    return Dialog(
      backgroundColor: ty.colors.surfaceOverlay,
      surfaceTintColor: Colors.transparent,
      elevation: shadow.isEmpty ? 0 : _sheetElevation,
      shadowColor: shadow.isEmpty ? Colors.transparent : shadow.last.color,
      insetPadding: const EdgeInsets.all(TySpace.x24),
      shape: RoundedRectangleBorder(
        borderRadius: TyRadius.lgAll,
        side: BorderSide(color: ty.colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SizedBox(
          width: form ? _dialogFormWidth : _dialogWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  TySpace.x24,
                  TySpace.x20,
                  TySpace.x24,
                  TySpace.x12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ty.typography.titleL.copyWith(
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
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: TySpace.x24),
                  child: form
                      ? SingleChildScrollView(child: child)
                      : child,
                ),
              ),
              if (actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    TySpace.x24,
                    TySpace.x20,
                    TySpace.x24,
                    TySpace.x16,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      for (final Widget action in actions) ...<Widget>[
                        const SizedBox(width: TySpace.x8),
                        action,
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 以 [TyDialog] 为内容的模态弹窗；返回 `Navigator.pop` 的值。
Future<T?> showTyDialog<T>(
  BuildContext context, {
  required Widget child,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (BuildContext context) => child,
  );
}

/// 移动端底部抽屉（`DESIGN.md` §6.4）：顶部 `xl` 圆角 + 抓手，最大高 90%，可下拉关闭。
///
/// 纯展示，和 [TyDialog] 一样；要模态呈现用 [showTySheet]。
class TySheet extends StatelessWidget {
  const TySheet({
    super.key,
    required this.child,
    this.title,
    this.showHandle = true,
  });

  final Widget child;

  /// 可选标题（`titleM`）。
  final String? title;

  /// 抓手只是「可下拉」的视觉提示，没有标题时更需要它。
  final bool showHandle;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Container(
      decoration: BoxDecoration(
        color: ty.colors.surfaceOverlay,
        borderRadius: TyRadius.sheetTop,
        border: Border(top: BorderSide(color: ty.colors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (showHandle)
            Padding(
              padding: const EdgeInsets.only(top: TySpace.x8),
              child: Center(
                child: Container(
                  width: TySpace.x40,
                  height: TySpace.x4,
                  decoration: BoxDecoration(
                    color: ty.colors.borderStrong,
                    borderRadius: TyRadius.fullAll,
                  ),
                ),
              ),
            ),
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                TySpace.x16,
                TySpace.x12,
                TySpace.x16,
                TySpace.x4,
              ),
              child: Text(
                title!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ty.typography.titleM.copyWith(
                  color: ty.colors.textPrimary,
                ),
              ),
            ),
          Flexible(child: child),
        ],
      ),
    );
  }
}

/// 从底部弹出 [TySheet]；下拉或点遮罩关闭（`DESIGN.md` §6.4）。
Future<T?> showTySheet<T>(
  BuildContext context, {
  required Widget child,
  bool dismissible = true,
}) {
  final double maxHeight =
      MediaQuery.sizeOf(context).height * _maxHeightRatio;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    enableDrag: dismissible,
    isDismissible: dismissible,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints(maxHeight: maxHeight),
    builder: (BuildContext context) => child,
  );
}
