import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'cover.dart';
import 'highlight.dart';
import 'interactive.dart';

/// 艺人行（`DESIGN.md` §6.2）：头像 + 名称 + 「N 张专辑 · M 首」+ 前进箭头。
///
/// 行高跟随 [TyMetrics.rowHeight]，与曲目行同源，混排列表的节奏才一致。
class TyArtistRow extends StatelessWidget {
  const TyArtistRow({
    super.key,
    required this.name,
    this.subtitle,
    this.avatarPath,
    this.avatarUrl,
    this.avatarBytes,
    this.onTap,
    this.onSecondaryTapDown,
    this.trailing,
    this.highlightQuery,
  });

  final String name;

  /// 搜索命中词：给了就把名字里的命中子串点亮。
  final String? highlightQuery;

  /// 「3 张专辑 · 28 首」，已由页面拼好。
  final String? subtitle;
  final String? avatarPath;
  final String? avatarUrl;

  /// 内存头像数据（`ArtistAvatarStore` 只给 bytes）；优先于 path/url。
  final Uint8List? avatarBytes;
  final VoidCallback? onTap;
  final void Function(TapDownDetails details)? onSecondaryTapDown;

  /// 行尾附加控件（⋯ / ♥），放在前进箭头左侧。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final double avatar = context.metrics.coverList;
    return TyInteractive(
      onTap: onTap,
      onSecondaryTapDown: onSecondaryTapDown,
      cursor: SystemMouseCursors.click,
      semanticLabel: subtitle == null ? name : '$name · $subtitle',
      builder: (BuildContext context, TyInteractionState state) {
        return Container(
          // 命中区不低于形态下限：行高令牌本身已 >= hitTarget，这里只是把它显式化。
          constraints: BoxConstraints(minHeight: context.metrics.hitTarget),
          height: context.metrics.rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: TySpace.x8),
          decoration: BoxDecoration(
            color: state.overlay(ty.colors),
            borderRadius: TyRadius.smAll,
          ),
          child: Row(
            children: <Widget>[
              // 有头像图时用 TyCover 画圆；否则交给 TyAvatar 画首字母，
              // 两者占位色同源（TyCoverPalette），不会出现两种灰。
              if (avatarBytes != null ||
                  avatarPath != null ||
                  avatarUrl != null)
                TyCover(
                  bytes: avatarBytes,
                  path: avatarPath,
                  url: avatarUrl,
                  seed: name,
                  size: avatar,
                  radius: TyRadius.full,
                )
              else
                TyAvatar(size: avatar, label: name, seed: name),
              const SizedBox(width: TySpace.x12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    TyHighlightedText(
                      text: name,
                      query: highlightQuery ?? '',
                      style: ty.typography.bodyM.copyWith(
                        color: ty.colors.textPrimary,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ty.typography.bodyS.copyWith(
                          color: ty.colors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: TySpace.x8),
                // 悬停才亮出：艺人行的主操作是「进入」，行内操作不该抢注意力。
                AnimatedOpacity(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : TyDuration.fast,
                  opacity:
                      context.traits.touchPrimary ||
                          state.hovered ||
                          state.focused
                      ? 1
                      : 0,
                  child: trailing,
                ),
              ],
              // 箭头只表示「点得进去」；没有 onTap 时画出来是骗人的。
              if (onTap != null) ...<Widget>[
                const SizedBox(width: TySpace.x4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: TyIconSize.compact,
                  color: ty.colors.textTertiary,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
