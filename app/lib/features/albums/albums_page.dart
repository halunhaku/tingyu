import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/models/library_summaries.dart';
import '../shared/cover_art.dart';
import '../shared/empty_state.dart';

/// 专辑页：按 `artist + album` 聚合的自适应封面网格（对齐旧版 `AlbumGridView`）。
///
/// 列宽在 [_minTile] ~ [_maxTile] 之间自适应，窗口越宽列数越多，封面不被拉伸。
class AlbumsPage extends ConsumerWidget {
  const AlbumsPage({super.key});

  /// 单列最小宽度（旧版 `GridItem(.adaptive(minimum: 150, maximum: 190))`）。
  static const double _minTile = 150;

  /// 单列最大宽度；超过它封面不再跟着变宽。
  static const double _maxTile = 190;

  static const double _spacing = 16;

  /// 封面下方的文字区高度（专辑名 + 艺术家 + 年份）。
  static const double _captionHeight = 76;

  static const double _sidePadding = 20;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<AlbumSummary>> albums = ref.watch(albumsProvider);
    final TextTheme text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(_sidePadding, 16, _sidePadding, 0),
          child: Row(
            children: <Widget>[
              Expanded(child: Text('专辑', style: text.titleLarge)),
              albums.maybeWhen(
                data: (List<AlbumSummary> list) => Text('${list.length} 张', style: text.bodySmall),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
        ),
        Expanded(
          child: albums.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, StackTrace stack) => EmptyState(
              icon: Icons.error_outline,
              title: '专辑列表读取失败',
              message: '$error',
            ),
            data: (List<AlbumSummary> list) {
              if (list.isEmpty) {
                return const EmptyState(
                  icon: Icons.album_outlined,
                  title: '还没有专辑',
                  message: '添加来源并同步曲库后，这里会按专辑聚合展示',
                );
              }
              return LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final double available = constraints.maxWidth - _sidePadding * 2;
                  final int columns = ((available + _spacing) / (_minTile + _spacing))
                      .floor()
                      .clamp(1, 12);
                  final double tile = math.max(
                    _minTile,
                    (available - _spacing * (columns - 1)) / columns,
                  );
                  final double cover = tile < _maxTile ? tile : _maxTile;

                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(
                      _sidePadding,
                      12,
                      _sidePadding,
                      24,
                    ),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: _spacing,
                      mainAxisSpacing: 20,
                      childAspectRatio: tile / (cover + _captionHeight),
                    ),
                    itemCount: list.length,
                    itemBuilder: (BuildContext context, int index) =>
                        _AlbumTile(album: list[index], cover: cover),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 网格单元：封面 + 专辑名 + 艺术家 + 年份；整块可点击进专辑详情。
class _AlbumTile extends StatelessWidget {
  const _AlbumTile({required this.album, required this.cover});

  final AlbumSummary album;

  final double cover;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () => context.go(
        '/albums/${Uri.encodeComponent(album.artist)}/${Uri.encodeComponent(album.album)}',
      ),
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CoverArt(coverArtPath: album.coverArtPath, size: cover, radius: 8),
          const SizedBox(height: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  album.album,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  album.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                Text(
                  // 年份缺失时用曲目数占位，保持格子高度一致。
                  album.year?.toString() ?? '${album.trackCount} 首',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
