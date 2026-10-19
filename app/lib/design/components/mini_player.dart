import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/tokens.dart';
import 'buttons.dart';
import 'cover.dart';
import 'interactive.dart';
import 'player_stage.dart';

/// 迷你播放条（`DESIGN.md` §6.3 / §5.1，compact 形态）。
///
/// 高 56，`surfaceRaised` + 顶部圆角 `xl` + 上边 2px 进度线；
/// 左：封面 40（Hero 共享元素）+ 曲名/艺术家（1 行）+ ♥；右：播放 / 暂停、下一首。
/// 整行点击 → 舞台（[onOpenStage]），长按 → 快捷菜单（[onLongPress]）。
class TyMiniPlayer extends StatelessWidget {
  const TyMiniPlayer({
    super.key,
    this.visible = true,
    this.coverPath,
    this.coverUrl,
    this.coverSeed,
    this.title = '',
    this.artist = '',
    this.favorite = false,
    this.onToggleFavorite,
    this.onOpenStage,
    this.onLongPress,
    this.playing = false,
    this.onPlayPause,
    this.onNext,
    this.progressLine,
    this.heroTag = TyHeroTags.nowPlayingCover,
  });

  /// 队列为空时整条不占位。
  final bool visible;

  final String? coverPath;
  final String? coverUrl;
  final String? coverSeed;

  final String title;
  final String artist;

  final bool favorite;
  final VoidCallback? onToggleFavorite;

  final VoidCallback? onOpenStage;
  final VoidCallback? onLongPress;

  final bool playing;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;

  /// 顶部进度线（由宿主接线的独立订阅者给，避免进度 tick 重建整条迷你条）。
  ///
  /// 传 null 时不画进度线。
  final Widget? progressLine;

  final String heroTag;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return const SizedBox.shrink();
    }
    final TyTokens ty = context.ty;
    final double height = context.metrics.miniPlayerHeight;

    return ClipRRect(
      borderRadius: TyRadius.miniPlayerTop,
      child: DecoratedBox(
        decoration: BoxDecoration(color: ty.colors.surfaceRaised),
        child: SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 上边 2px 进度线：由宿主的独立订阅者给（进度 tick 只重建它）。
              ?progressLine,
              Expanded(
                child: TyInteractive(
                  onTap: onOpenStage,
                  onLongPress: onLongPress,
                  semanticLabel:
                      '正在播放 $title${artist.isEmpty ? '' : ' · $artist'}',
                  cursor: SystemMouseCursors.click,
                  builder: (BuildContext context, TyInteractionState state) =>
                      Container(
                        color: state.overlay(ty.colors),
                        padding: const EdgeInsets.symmetric(
                          horizontal: TySpace.x12,
                        ),
                        child: Row(
                          children: <Widget>[
                            Hero(
                              tag: heroTag,
                              child: TyCover(
                                path: coverPath,
                                url: coverUrl,
                                seed: coverSeed,
                                size: TyMiniPlayerSize.cover,
                                radius: TyRadius.xs,
                              ),
                            ),
                            const SizedBox(width: TySpace.x12),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: <InlineSpan>[
                                    TextSpan(
                                      text: title,
                                      style: ty.typography.bodyM.copyWith(
                                        color: ty.colors.textPrimary,
                                      ),
                                    ),
                                    if (artist.isNotEmpty)
                                      TextSpan(
                                        text: ' · $artist',
                                        style: ty.typography.bodyS.copyWith(
                                          color: ty.colors.textSecondary,
                                        ),
                                      ),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (onToggleFavorite != null)
                              TyIconAction(
                                icon: favorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                semanticLabel: favorite ? '取消收藏' : '收藏',
                                tooltip: favorite ? '取消收藏' : '收藏',
                                active: favorite,
                                onPressed: onToggleFavorite,
                              ),
                            const SizedBox(width: TySpace.x4),
                            TyIconAction(
                              icon: playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              semanticLabel: playing ? '暂停' : '播放',
                              tooltip: playing ? '暂停' : '播放',
                              size: TyIconSize.toolbar,
                              color: ty.colors.textPrimary,
                              onPressed: onPlayPause,
                            ),
                            TyIconAction(
                              icon: Icons.skip_next_rounded,
                              semanticLabel: '下一首',
                              tooltip: '下一首',
                              size: TyIconSize.toolbar,
                              color: ty.colors.textPrimary,
                              onPressed: onNext,
                            ),
                          ],
                        ),
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 迷你条几何档位（`DESIGN.md` §6.3）。
abstract final class TyMiniPlayerSize {
  /// 封面边长。
  static const double cover = 40;

  /// 顶部进度线高。
  static const double progressLine = TySpace.x2;
}
