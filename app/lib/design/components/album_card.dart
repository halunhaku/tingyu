import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'cover.dart';
import 'highlight.dart';
import 'interactive.dart';

/// 专辑网格瓦片（`DESIGN.md` §6.2）。
///
/// [subtitle] 完全由页面拼好（「艺术家 · 2003 · 12 首」）：组件不做业务字段聚合，
/// 否则每个宿主都要把自己那份摘要再拆一遍，两处口径必然漂移。
class TyAlbumCard extends StatelessWidget {
  const TyAlbumCard({
    super.key,
    required this.title,
    this.subtitle,
    this.coverPath,
    this.coverUrl,
    this.coverSeed,
    this.width,
    this.onTap,
    this.onPlay,
    this.onSecondaryTapDown,
    this.trailing,
    this.highlightQuery,
  });

  final String title;

  /// 搜索命中词：给了就把标题里的命中子串点亮。
  final String? highlightQuery;

  /// 「艺术家 · 2003 · 12 首」，已由页面拼好。
  final String? subtitle;
  final String? coverPath;
  final String? coverUrl;

  /// 占位色种子（通常是「艺术家 · 专辑」）。
  final String? coverSeed;

  /// 网格列宽：用于按显示尺寸解码封面（`cacheWidth`）。
  ///
  /// `null` 时取父约束；父约束也无界（例如放进一个横向 Row）时退回
  /// [TyMetrics.gridMinTile]，宁可按最小瓦片画，也不给 `TyCover` 一个 0 尺寸。
  final double? width;

  final VoidCallback? onTap;

  /// 非空时指针悬停/聚焦才在封面中央出现播放钮。
  ///
  /// 触控形态不出现：那里单击瓦片本身就是「进入专辑」，多一个播放钮只会误触。
  final VoidCallback? onPlay;

  /// 桌面右键 / 触控长按的按下点（全局坐标），由页面转给 `TyContextMenu.show`。
  final void Function(TapDownDetails details)? onSecondaryTapDown;

  /// 非空时出现在封面右上角（页面传 ⋯ 或 ♥）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double tile =
            width ??
            (constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : context.metrics.gridMinTile);
        return TyInteractive(
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          cursor: SystemMouseCursors.click,
          semanticLabel: subtitle == null ? title : '$title · $subtitle',
          builder: (BuildContext context, TyInteractionState state) {
            // hover / focus 是「指针语汇」：触控形态没有 hover，行内操作必须常显，
            // 否则 ⋯ / ♥ 在这些设备上永远不可达。
            final bool touch = context.traits.touchPrimary;
            final bool revealed = !touch && (state.hovered || state.focused);
            return SizedBox(
              width: tile,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _Cover(
                    tile: tile,
                    revealed: revealed,
                    onPlay: onPlay,
                    trailing: trailing,
                    coverPath: coverPath,
                    coverUrl: coverUrl,
                    coverSeed: coverSeed ?? title,
                  ),
                  const SizedBox(height: TySpace.x8),
                  TyHighlightedText(
                    text: title,
                    query: highlightQuery ?? '',
                    style: context.ty.typography.bodyM.copyWith(
                      color: context.ty.colors.textPrimary,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.ty.typography.bodyS.copyWith(
                        color: context.ty.colors.textSecondary,
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// 封面 + 悬停浮起的行内操作。
///
/// 浮起不动布局（`transform` 而非 `margin`）：否则每张瓦片都会把下面的标题推来推去，
/// 网格行高跟着抖。
class _Cover extends StatelessWidget {
  const _Cover({
    required this.tile,
    required this.revealed,
    required this.onPlay,
    required this.trailing,
    required this.coverPath,
    required this.coverUrl,
    required this.coverSeed,
  });

  final double tile;
  final bool revealed;
  final VoidCallback? onPlay;
  final Widget? trailing;
  final String? coverPath;
  final String? coverUrl;
  final String? coverSeed;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedContainer(
      duration: reduceMotion ? Duration.zero : TyDuration.fast,
      curve: TyCurve.decelerate,
      transform: revealed
          ? Matrix4.translationValues(0, -TySpace.x2, 0)
          : Matrix4.identity(),
      child: Stack(
        children: <Widget>[
          TyCover(
            path: coverPath,
            url: coverUrl,
            seed: coverSeed,
            size: tile,
            radius: TyRadius.md,
            border: BorderSide(color: ty.colors.border),
          ),
          if (onPlay != null)
            Positioned.fill(
              child: Center(
                child: AnimatedOpacity(
                  duration: reduceMotion ? Duration.zero : TyDuration.fast,
                  opacity: revealed ? 1 : 0,
                  child: IgnorePointer(
                    ignoring: !revealed,
                    child: _PlayButton(onPlay: onPlay!),
                  ),
                ),
              ),
            ),
          if (trailing != null)
            Positioned(
              top: TySpace.x8,
              right: TySpace.x8,
              child: AnimatedOpacity(
                duration: reduceMotion ? Duration.zero : TyDuration.fast,
                // 触控形态下 revealed 恒为 false，这里放行让页面给的控件始终可点。
                opacity: revealed || context.traits.touchPrimary ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !revealed && !context.traits.touchPrimary,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: ty.colors.surfaceOverlay,
                      borderRadius: TyRadius.fullAll,
                    ),
                    child: trailing,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 封面中央播放钮：实心强调色圆 + 浮层描边，保证压在任何封面上都读得出来。
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.onPlay});

  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return TyInteractive(
      onTap: onPlay,
      semanticLabel: '播放',
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, TyInteractionState state) {
        final Color background = state.pressed
            ? ty.colors.accentPressed
            : (state.hovered ? ty.colors.accentHover : ty.colors.accent);
        return Container(
          width: TySpace.x40,
          height: TySpace.x40,
          decoration: BoxDecoration(
            color: background,
            shape: BoxShape.circle,
            border: Border.all(color: ty.colors.surfaceOverlay, width: 2),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.play_arrow_rounded,
            size: TyIconSize.toolbar,
            color: ty.colors.onAccent,
          ),
        );
      },
    );
  }
}
