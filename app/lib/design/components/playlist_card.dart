import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'cover.dart';
import 'highlight.dart';
import 'interactive.dart';

/// 歌单网格瓦片：2×2 封面拼贴（`DESIGN.md` §6.2）。
///
/// 歌单没有单一「封面」字段（库内就是一组曲目各自的封面），所以拼贴是这个
/// 数据形态的直译；不足 4 张时用确定性占位块补齐，保持网格行高一致。
class TyPlaylistCard extends StatelessWidget {
  const TyPlaylistCard({
    super.key,
    required this.title,
    this.subtitle,
    this.coverPaths = const <String>[],
    this.width,
    this.onTap,
    this.onPlay,
    this.onSecondaryTapDown,
    this.trailing,
    this.highlightQuery,
  });

  final String title;
  final String? subtitle;

  /// 搜索命中词：给了就把标题里的命中子串点亮。
  final String? highlightQuery;

  /// 0..4 张本地封面文件名（`CoverStore` 里的相对名）。
  final List<String> coverPaths;

  /// 网格列宽；`null` 时取父约束，仍无界再退到 [TyMetrics.gridMinTile]。
  final double? width;
  final VoidCallback? onTap;

  /// 非空时指针悬停/聚焦才在拼贴中央出现播放钮。
  final VoidCallback? onPlay;
  final void Function(TapDownDetails details)? onSecondaryTapDown;

  /// 非空时悬停（触控形态常显）出现在拼贴右上角。
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
            final bool touch = context.traits.touchPrimary;
            final bool revealed = !touch && (state.hovered || state.focused);
            return SizedBox(
              width: tile,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AnimatedContainer(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : TyDuration.fast,
                    curve: TyCurve.decelerate,
                    transform: revealed
                        ? Matrix4.translationValues(0, -TySpace.x2, 0)
                        : Matrix4.identity(),
                    child: _CollageLayer(
                      tile: tile,
                      revealed: revealed,
                      touch: touch,
                      title: title,
                      coverPaths: coverPaths,
                      onPlay: onPlay,
                      trailing: trailing,
                    ),
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

/// 拼贴 + 悬停播放钮 / 右上角控件。
///
/// 与 [TyAlbumCard] 的封面层是同一种语汇，但封面本体（拼贴 vs 单图）不同，
/// 所以各自持有自身的私有实现，而不是把卡片抽象成一个可替换封面的容器。
class _CollageLayer extends StatelessWidget {
  const _CollageLayer({
    required this.tile,
    required this.revealed,
    required this.touch,
    required this.title,
    required this.coverPaths,
    required this.onPlay,
    required this.trailing,
  });

  final double tile;
  final bool revealed;
  final bool touch;
  final String title;
  final List<String> coverPaths;
  final VoidCallback? onPlay;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Stack(
      children: <Widget>[
        SizedBox(
          width: tile,
          height: tile,
          child: Container(
            // 四个块由外层统一裁剪：单块各自圆角会在拼缝处露出背景色。
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: TyRadius.mdAll,
              border: Border.all(color: ty.colors.border),
            ),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: Row(
                    children: <Widget>[
                      _slot(context, 0),
                      _slot(context, 1),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    children: <Widget>[
                      _slot(context, 2),
                      _slot(context, 3),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
              opacity: revealed || touch ? 1 : 0,
              child: IgnorePointer(
                ignoring: !revealed && !touch,
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
    );
  }

  /// 第 [index] 格：有封面就画封面，没有就画一张确定性占位块（种子固定，重建不闪色）。
  Widget _slot(BuildContext context, int index) {
    final bool hasCover = index < coverPaths.length;
    final String? path = hasCover ? coverPaths[index] : null;
    return Expanded(
      child: TyCover(
        path: path,
        seed: path ?? '$title-$index',
        size: tile / 2,
        // 0 圆角：圆角由外层裁剪统一负责。
        radius: 0,
      ),
    );
  }
}

/// 拼贴中央播放钮（与专辑卡同一形态，但压在拼贴上需要更实的底）。
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

/// 网格首位（或工具条末位）的「新建歌单」瓦片：与 [TyPlaylistCard] 同尺寸、同标题位置。
class TyNewPlaylistCard extends StatelessWidget {
  const TyNewPlaylistCard({
    super.key,
    this.title = '新建歌单',
    this.width,
    this.onTap,
  });

  final String title;
  final double? width;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double tile =
            width ??
            (constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : context.metrics.gridMinTile);
        return SizedBox(
          width: tile,
          child: TyInteractive(
            onTap: onTap,
            cursor: SystemMouseCursors.click,
            semanticLabel: title,
            builder: (BuildContext context, TyInteractionState state) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: tile,
                    height: tile,
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(
                        state.overlay(ty.colors),
                        ty.colors.surfaceSunken,
                      ),
                      borderRadius: TyRadius.mdAll,
                      border: Border.all(color: ty.colors.border),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.add_rounded,
                      size: TyIconSize.toolbar,
                      color: ty.colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: TySpace.x8),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ty.typography.bodyM.copyWith(
                      color: ty.colors.textPrimary,
                    ),
                  ),
                  // 留出 TyPlaylistCard 的副标题行高：同排瓦片的标题必须落在同一基线上，
                  // 否则「新建」瓦片比邻居矮一截。行高从排版令牌算，不写死像素。
                  SizedBox(
                    height: ty.typography.bodyS.fontSize! *
                        ty.typography.bodyS.height!,
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
