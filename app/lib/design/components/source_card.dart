import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
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
    this.trackCount,
    this.ordinal,
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

  /// 来源内的曲目数；未知时不要传。
  final int? trackCount;

  /// 列表中的显示序号；不参与业务排序。
  final int? ordinal;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool compact = context.formFactor.isCompact;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ty.colors.surfaceRaised,
        borderRadius: TyRadius.smAll,
        border: Border.all(color: ty.colors.border),
      ),
      child: ClipRRect(
        borderRadius: TyRadius.smAll,
        child: TyInteractive(
          onTap: onTap,
          semanticLabel: <String>[
            name,
            typeLabel,
            statusLabel,
            if (trackCount != null) '$trackCount 首曲目',
            ?detail,
          ].join('，'),
          builder: (BuildContext context, TyInteractionState state) {
            return ColoredBox(
              color: state.overlay(ty.colors),
              child: Stack(
                children: <Widget>[
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(
                      color: _toneColor(
                        ty.colors,
                        syncing ? TySourceStatusTone.idle : statusTone,
                      ).withValues(alpha: 0.78),
                      child: const SizedBox(width: 3),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? TySpace.x16 : TySpace.x20,
                      compact ? TySpace.x16 : TySpace.x16,
                      TySpace.x8,
                      compact ? TySpace.x16 : TySpace.x16,
                    ),
                    child: compact
                        ? _compactContent(context)
                        : _wideContent(context),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _wideContent(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _SourceTypeMark(
          icon: typeIcon,
          color: _toneColor(
            context.ty.colors,
            syncing ? TySourceStatusTone.idle : statusTone,
          ),
          ordinal: ordinal,
        ),
        const SizedBox(width: TySpace.x16),
        Expanded(child: _identityAndStatus(context)),
        if (trackCount != null) ...<Widget>[
          const SizedBox(width: TySpace.x24),
          _SourceMetric(label: '曲目', value: '$trackCount', width: TySpace.x64),
        ],
        if (primaryAction != null) ...<Widget>[
          const SizedBox(width: TySpace.x16),
          _PrimaryAction(action: primaryAction!),
        ],
        if (menuActions.isNotEmpty) ...<Widget>[
          const SizedBox(width: TySpace.x4),
          _SourceMenuButton(actions: menuActions),
        ],
      ],
    );
  }

  Widget _compactContent(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool enlargeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _SourceTypeMark(
              icon: typeIcon,
              color: _toneColor(
                ty.colors,
                syncing ? TySourceStatusTone.idle : statusTone,
              ),
              ordinal: ordinal,
              compact: true,
            ),
            const SizedBox(width: TySpace.x12),
            Expanded(child: _identityAndStatus(context)),
            if (menuActions.isNotEmpty) ...<Widget>[
              const SizedBox(width: TySpace.x4),
              _SourceMenuButton(actions: menuActions),
            ],
          ],
        ),
        if (primaryAction != null) ...<Widget>[
          const SizedBox(height: TySpace.x12),
          Row(
            children: <Widget>[
              if (trackCount != null)
                _SourceMetric(label: '曲目', value: '$trackCount'),
              const Spacer(),
              if (!enlargeText) _PrimaryAction(action: primaryAction!),
            ],
          ),
          if (enlargeText) ...<Widget>[
            const SizedBox(height: TySpace.x8),
            _PrimaryAction(action: primaryAction!, expand: true),
          ],
        ],
      ],
    );
  }

  Widget _identityAndStatus(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool stackStatus =
        context.formFactor.isCompact &&
        MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final Widget title = Text(
      name,
      maxLines: context.formFactor.isCompact ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: ty.typography.titleM.copyWith(
        color: ty.colors.textPrimary,
        fontWeight: FontWeight.w700,
      ),
    );
    final Widget status = _SourceStatusPill(
      label: syncing
          ? '同步中'
          : switch (statusTone) {
              TySourceStatusTone.connected => '已连接',
              TySourceStatusTone.warning => '需要处理',
              TySourceStatusTone.failed => '需恢复',
              TySourceStatusTone.idle => '待同步',
            },
      tone: syncing ? TySourceStatusTone.idle : statusTone,
      emphasized: syncing,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (stackStatus) ...<Widget>[
          title,
          const SizedBox(height: TySpace.x6),
          status,
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: title),
              const SizedBox(width: TySpace.x8),
              status,
            ],
          ),
        const SizedBox(height: TySpace.x2),
        Text(
          '$typeLabel · $statusLabel',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: ty.typography.bodyS.copyWith(color: ty.colors.textSecondary),
        ),
        if (detail != null) ...<Widget>[
          const SizedBox(height: TySpace.x2),
          Text(
            detail!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ty.typography.bodyS.copyWith(
              color: statusTone == TySourceStatusTone.failed
                  ? ty.colors.danger
                  : ty.colors.textTertiary,
            ),
          ),
        ],
        if (syncing) ...<Widget>[
          const SizedBox(height: TySpace.x8),
          Semantics(
            liveRegion: true,
            value: progressLabel,
            child: TyProgressBar(value: progress, semanticLabel: '来源同步进度'),
          ),
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

  static Color _toneColor(TyColors colors, TySourceStatusTone tone) {
    return switch (tone) {
      TySourceStatusTone.connected => colors.success,
      TySourceStatusTone.warning => colors.warning,
      TySourceStatusTone.failed => colors.danger,
      TySourceStatusTone.idle => colors.accent,
    };
  }
}

class _SourceTypeMark extends StatelessWidget {
  const _SourceTypeMark({
    required this.icon,
    required this.color,
    required this.ordinal,
    this.compact = false,
  });

  final IconData icon;
  final Color color;
  final int? ordinal;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final double size = compact ? TySpace.x48 : 54;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ty.colors.surfaceSunken,
        borderRadius: TyRadius.smAll,
        border: Border.all(color: ty.colors.border),
      ),
      child: Stack(
        children: <Widget>[
          Center(
            child: Icon(
              icon,
              size: compact ? TyIconSize.normal : TyIconSize.toolbar,
              color: color,
            ),
          ),
          if (ordinal != null && !compact)
            Positioned(
              left: TySpace.x4,
              top: TySpace.x2,
              child: Text(
                ordinal!.toString().padLeft(2, '0'),
                style: ty.typography.labelS.copyWith(
                  color: ty.colors.textTertiary,
                  letterSpacing: 0.6,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SourceStatusPill extends StatelessWidget {
  const _SourceStatusPill({
    required this.label,
    required this.tone,
    this.emphasized = false,
  });

  final String label;
  final TySourceStatusTone tone;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final Color foreground = TySourceCard._toneColor(ty.colors, tone);
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: TySpace.x8),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          foreground.withValues(alpha: emphasized ? 0.16 : 0.10),
          ty.colors.surfaceRaised,
        ),
        borderRadius: TyRadius.xsAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TySourceStatusDot(tone: tone),
          const SizedBox(width: TySpace.x6),
          Text(label, style: ty.typography.labelS.copyWith(color: foreground)),
        ],
      ),
    );
  }
}

class _SourceMetric extends StatelessWidget {
  const _SourceMetric({required this.label, required this.value, this.width});

  final String label;
  final String value;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: ty.typography.labelS.copyWith(color: ty.colors.textTertiary),
          ),
          const SizedBox(height: TySpace.x2),
          Text(
            value,
            style: ty.typography.numericM.copyWith(
              color: ty.colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 8px 状态点（`DESIGN.md` §6.4）；颜色承载状态，形状不承载信息。
class TySourceStatusDot extends StatelessWidget {
  const TySourceStatusDot({super.key, required this.tone});

  final TySourceStatusTone tone;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // 状态点本身不是信息载体：颜色语义交给状态行文字，读屏不重复播报。
      excludeSemantics: true,
      child: Container(
        width: TySpace.x8,
        height: TySpace.x8,
        decoration: BoxDecoration(
          color: TySourceCard._toneColor(context.ty.colors, tone),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({required this.action, this.expand = false});

  final TySourceAction action;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return TyButton(
      label: action.label,
      icon: action.icon,
      variant: TyButtonVariant.secondary,
      dense: !expand,
      expand: expand,
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
