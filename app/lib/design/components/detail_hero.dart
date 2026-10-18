import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/tokens.dart';
import 'cover.dart';

/// 详情页封面造型。
enum TyDetailHeroShape {
  /// 专辑 / 歌单：圆角方图。
  square,

  /// 艺人：圆形（与行内头像同一语汇）。
  circle,
}

/// 详情页头图：封面 + 主标题 + 元数据行 + 动作行（`DESIGN.md` §6.1）。
///
/// compact 垂直堆叠并居中，medium / expanded 水平排列：宽度不足时把封面挤成一条，
/// 比缩小到读不出来的封面更糟。
class TyDetailHero extends StatelessWidget {
  const TyDetailHero({
    super.key,
    required this.title,
    this.eyebrow,
    this.header,
    this.meta,
    this.coverPath,
    this.coverUrl,
    this.coverBytes,
    this.coverSeed,
    this.coverShape = TyDetailHeroShape.square,
    this.actions = const <Widget>[],
    this.trailing,
  });

  /// 主标题（`displayM`）。
  final String title;

  /// 类别标签（「专辑」「艺人」「歌单」等，`labelM`）。
  final String? eyebrow;

  /// 顶部行（返回按钮等），可为空。
  final Widget? header;

  /// 已拼好的「· 分隔」元数据行，可为空。
  final String? meta;

  final String? coverPath;
  final String? coverUrl;

  /// 内存封面/头像数据（艺人头像走这条）；优先于 path/url。
  final Uint8List? coverBytes;
  final String? coverSeed;
  final TyDetailHeroShape coverShape;

  /// 动作行（播放、收藏等），按顺序排列。
  final List<Widget> actions;

  /// expanded 右侧槽（例如「更多」或来源信息）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final TyMetrics metrics = context.metrics;
    final bool compact = context.formFactor.isCompact;
    final Widget cover = _cover(context, metrics.coverDetail);
    final Widget info = _info(context, compact: compact);

    final Widget body = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              cover,
              const SizedBox(height: TySpace.x16),
              info,
              if (trailing != null) ...<Widget>[
                const SizedBox(height: TySpace.x16),
                trailing!,
              ],
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              cover,
              const SizedBox(width: TySpace.x24),
              Expanded(child: info),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: TySpace.x16),
                trailing!,
              ],
            ],
          );

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (header != null) ...<Widget>[
              header!,
              const SizedBox(height: TySpace.x16),
            ],
            body,
          ],
        ),
      ),
    );
  }

  Widget _cover(BuildContext context, double size) {
    final TyTokens ty = context.ty;
    return TyCover(
      bytes: coverBytes,
      path: coverPath,
      url: coverUrl,
      seed: coverSeed ?? title,
      size: size,
      radius: coverShape == TyDetailHeroShape.circle
          ? TyRadius.full
          : TyRadius.md,
      border: coverShape == TyDetailHeroShape.circle
          ? null
          : BorderSide(color: ty.colors.border),
    );
  }

  Widget _info(BuildContext context, {required bool compact}) {
    final TyTokens ty = context.ty;
    return Column(
      crossAxisAlignment: compact
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (eyebrow != null)
          Padding(
            padding: const EdgeInsets.only(bottom: TySpace.x4),
            child: Text(
              eyebrow!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ty.typography.labelM.copyWith(
                color: ty.colors.textTertiary,
              ),
            ),
          ),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: compact ? TextAlign.center : TextAlign.start,
          style: ty.typography.displayM.copyWith(color: ty.colors.textPrimary),
        ),
        if (meta != null)
          Padding(
            padding: const EdgeInsets.only(top: TySpace.x8),
            child: Text(
              meta!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: compact ? TextAlign.center : TextAlign.start,
              style: ty.typography.bodyS.copyWith(
                color: ty.colors.textSecondary,
              ),
            ),
          ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: TySpace.x20),
            child: Wrap(
              spacing: TySpace.x12,
              runSpacing: TySpace.x8,
              children: actions,
            ),
          ),
      ],
    );
  }
}
