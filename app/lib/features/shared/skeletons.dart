import 'package:flutter/material.dart';

import '../../design/components/feedback.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';

/// 曲目列表的加载骨架（`DESIGN.md` §6.5「列表：封面块 + 两条文本块」）。
///
/// 专辑 / 艺人 / 歌单详情的曲目区共用一份；行高与封面尺寸取自 [TyMetrics]，
/// 骨架不会和真实行高错位。
class TrackRowsSkeleton extends StatelessWidget {
  const TrackRowsSkeleton({super.key, this.rows = 8});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final TyMetrics metrics = context.metrics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < rows; i++)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: metrics.pagePadding,
              vertical: TySpace.x8,
            ),
            child: Row(
              children: <Widget>[
                TySkeleton(
                  width: metrics.coverList,
                  height: metrics.coverList,
                  radius: TyRadius.xs,
                ),
                const SizedBox(width: TySpace.x12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const TySkeleton.line(),
                      const SizedBox(height: TySpace.x6),
                      const TySkeleton.line(width: 120),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 封面网格的加载骨架：3 行 × 当前列数（`DESIGN.md` §6.5）。
///
/// 列数与瓦片高度和真实网格同源（[tyGridColumns] / [tyTileExtent]），
/// 加载完成时不会跳一下。
class GridSkeleton extends StatelessWidget {
  const GridSkeleton({super.key, this.rows = 3, this.shortSubtitle = false});

  final int rows;

  /// 副标题只有一行小字时（歌单卡）用更短的骨架块。
  final bool shortSubtitle;

  @override
  Widget build(BuildContext context) {
    final TyMetrics metrics = context.metrics;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = tyGridColumns(constraints.maxWidth, metrics);
        final double tile =
            (constraints.maxWidth -
                TySpace.x2 * metrics.pagePadding -
                (columns - 1) * metrics.gridGap) /
            columns;
        return GridView.builder(
          padding: EdgeInsets.symmetric(
            horizontal: metrics.pagePadding,
            vertical: TySpace.x8,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: metrics.gridGap,
            mainAxisSpacing: metrics.gridGap,
            mainAxisExtent: tyTileExtent(context, tile),
          ),
          itemCount: columns * rows,
          itemBuilder: (BuildContext context, int index) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TySkeleton(height: tile, radius: TyRadius.md),
              const SizedBox(height: TySpace.x8),
              const TySkeleton.line(),
              const SizedBox(height: TySpace.x4),
              TySkeleton.line(width: shortSubtitle ? 56 : 96),
            ],
          ),
        );
      },
    );
  }
}
