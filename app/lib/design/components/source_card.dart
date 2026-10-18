import 'package:flutter/material.dart';

import '../tokens/color.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/tokens.dart';
import 'buttons.dart';
import 'context_menu.dart';
import 'feedback.dart';
import 'interactive.dart';

/// 状态点的语义档（`DESIGN.md` §6.4）：已连接 / 需注意 / 失败 / 未生效。
enum TySourceStatusTone { connected, warning, failed, idle }

/// 来源卡片的主操作（同步 / 重试 / 重新登录）。
@immutable
class TySourceAction {
  const TySourceAction({
    required this.label,
    this.icon,
    this.onPressed,
    this.busy = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// 进行中：按钮置灰但不消失（消失会让人以为操作没发生）。
  final bool busy;
}

/// 来源卡片（`DESIGN.md` §6.4）。
///
/// 结构：类型徽标 + 名称 `titleM` + 状态行 `bodyS`（8px 状态点）+ 右对齐主操作 + ⋯ 菜单；
/// 同步中在状态行下方追加 `TyProgressBar`（`total` 未知时走不定态）。
///
/// 纯展示：props 进、回调出，不读 provider；来源状态机（未配置 / 登录中 / 已连接 /
/// 失败 / 同步中）由页面翻译成 [statusLabel] + [statusTone]。
class TySourceCard extends StatelessWidget {
  const TySourceCard({
    super.key,
    required this.name,
    required this.typeLabel,
    required this.typeIcon,
    required this.statusLabel,
    required this.statusTone,
    this.detail,
    this.syncing = false,
    this.progress,
    this.progressLabel,
    this.primaryAction,
    this.menuActions = const <TyMenuAction>[],
    this.onTap,
  });

  final String name;

  /// 类型徽标（「本地目录」/「WebDAV」/「夸克网盘」）。
  final String typeLabel;
  final IconData typeIcon;

  /// 状态行文案，例：`已连接 · 128 首 · 上次同步 3 分钟前`。
  final String statusLabel;
  final TySourceStatusTone statusTone;

  /// 第二行元数据：目录路径 / 账号 / 失败原因。
  final String? detail;

  /// 是否正在同步（扫描 / 补全元数据）。
  final bool syncing;

  /// 0..1；`syncing` 且为 null 时进度条走不定态（来源边翻页边发现条目）。
  final double? progress;

  /// 进度文案，例：`已扫描 128 / 540`；同时作为读屏 `liveRegion` 的值。
  final String? progressLabel;

  final TySourceAction? primaryAction;
  final List<TyMenuAction> menuActions;

  /// 打开来源详情。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ty.colors.surface,
        borderRadius: TyRadius.lgAll,
        border: Border.all(color: ty.colors.border),
      ),
      child: ClipRRect(
        borderRadius: TyRadius.lgAll,
        child: TyInteractive(
          onTap: onTap,
          semanticLabel: '$name，$typeLabel，$statusLabel',
          builder: (BuildContext context, TyInteractionState state) {
            return ColoredBox(
              color: state.overlay(ty.colors),
              child: Padding(
                padding: const EdgeInsets.all(TySpace.x16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(child: _body(context)),
                    if (primaryAction != null) ...<Widget>[
                      const SizedBox(width: TySpace.x12),
                      _PrimaryAction(action: primaryAction!),
                    ],
                    if (menuActions.isNotEmpty) ...<Widget>[
                      const SizedBox(width: TySpace.x4),
                      _SourceMenuButton(actions: menuActions),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final TyTokens ty = context.ty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            TyBadge(label: typeLabel, icon: typeIcon),
            const SizedBox(width: TySpace.x8),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ty.typography.titleM.copyWith(
                  color: ty.colors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: TySpace.x6),
        Semantics(
          liveRegion: syncing,
          value: syncing ? progressLabel : null,
          child: Row(
            children: <Widget>[
              TySourceStatusDot(tone: statusTone),
              const SizedBox(width: TySpace.x6),
              Flexible(
                child: Text(
                  statusLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ty.typography.bodyS.copyWith(
                    color: ty.colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (detail != null) ...<Widget>[
          const SizedBox(height: TySpace.x2),
          Text(
            detail!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ty.typography.bodyS.copyWith(color: ty.colors.textTertiary),
          ),
        ],
        if (syncing) ...<Widget>[
          const SizedBox(height: TySpace.x8),
          TyProgressBar(value: progress, semanticLabel: progressLabel),
          if (progressLabel != null) ...<Widget>[
            const SizedBox(height: TySpace.x4),
            Text(
              progressLabel!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ty.typography.numericS.copyWith(
                color: ty.colors.textSecondary,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// 8px 状态点（`DESIGN.md` §6.4）；颜色承载状态，形状不承载信息。
class TySourceStatusDot extends StatelessWidget {
  const TySourceStatusDot({super.key, required this.tone});

  final TySourceStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final TyColors c = context.ty.colors;
    final Color color = switch (tone) {
      TySourceStatusTone.connected => c.success,
      TySourceStatusTone.warning => c.warning,
      TySourceStatusTone.failed => c.danger,
      TySourceStatusTone.idle => c.textTertiary,
    };
    return Semantics(
      // 状态点本身不是信息载体：颜色语义交给状态行文字，读屏不重复播报。
      excludeSemantics: true,
      child: Container(
        width: TySpace.x8,
        height: TySpace.x8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({required this.action});

  final TySourceAction action;

  @override
  Widget build(BuildContext context) {
    return TyButton(
      label: action.label,
      icon: action.icon,
      variant: TyButtonVariant.secondary,
      dense: true,
      onPressed: action.busy ? null : action.onPressed,
    );
  }
}

/// ⋯ 菜单按钮：定位到按钮右下角弹出与桌面右键同一份菜单（`DESIGN.md` §6.4）。
class _SourceMenuButton extends StatelessWidget {
  const _SourceMenuButton({required this.actions});

  final List<TyMenuAction> actions;

  @override
  Widget build(BuildContext context) {
    return TyIconAction(
      icon: Icons.more_horiz,
      semanticLabel: '更多操作',
      tooltip: '更多操作',
      onPressed: () => _open(context),
    );
  }

  Future<void> _open(BuildContext context) async {
    final RenderBox box = context.findRenderObject()! as RenderBox;
    final Offset origin = box.localToGlobal(Offset.zero);
    await TyContextMenu.show(
      context,
      position: origin + Offset(box.size.width, box.size.height),
      actions: actions,
    );
  }
}
