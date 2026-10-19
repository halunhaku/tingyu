import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/models/library_summaries.dart';
import '../../design/components/album_card.dart';
import '../../design/components/buttons.dart';
import '../../design/components/context_menu.dart';
import '../../design/components/feedback.dart';
import '../../design/components/structure.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../shared/skeletons.dart';

/// 专辑页：按 `artist + album` 聚合的封面网格（`DESIGN.md` §5.2 / §6.2）。
///
/// 列数按窗口宽度算（[tyGridColumns]），瓦片高度按排版令牌算（[tyTileExtent]），
/// 页面不写 `childAspectRatio` 这类魔法值；点击进详情，悬停播放钮起播整张专辑。
class AlbumsPage extends ConsumerWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyMetrics metrics = context.metrics;
    final AsyncValue<List<AlbumSummary>> albums = ref.watch(albumsProvider);
    final int? count = albums.value?.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.pagePadding,
            TySpace.x20,
            metrics.pagePadding,
            TySpace.x12,
          ),
          child: TyPageHeader(
            title: '专辑',
            subtitle: count == null ? null : '共 $count 张',
          ),
        ),
        Expanded(
          child: TyAsyncView<List<AlbumSummary>>(
            value: albums,
            loading: (BuildContext context) => const GridSkeleton(),
            error: (BuildContext context, Object error, StackTrace? stack) =>
                TyErrorView(
                  title: '专辑列表读取失败',
                  detail: '$error',
                  onRetry: () => ref.invalidate(albumsProvider),
                ),
            isEmpty: (List<AlbumSummary> list) => list.isEmpty,
            empty: (BuildContext context) => TyEmptyState(
              icon: Icons.album_outlined,
              title: '还没有专辑',
              description: '添加来源并同步曲库后，这里会按专辑聚合展示',
              actionLabel: '添加来源',
              onAction: () => context.go('/sources'),
            ),
            data: (BuildContext context, List<AlbumSummary> list) =>
                _AlbumGrid(albums: list),
          ),
        ),
      ],
    );
  }
}

/// 网格本体：列数与瓦片高度都来自布局/排版令牌。
class _AlbumGrid extends ConsumerWidget {
  const _AlbumGrid({required this.albums});

  final List<AlbumSummary> albums;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          itemCount: albums.length,
          itemBuilder: (BuildContext context, int index) {
            final AlbumSummary album = albums[index];
            return TyAlbumCard(
              width: tile,
              title: album.album,
              subtitle: <String>[
                album.artist,
                if (album.year != null) '${album.year}年',
                '${album.trackCount} 首',
              ].join(' · '),
              coverPath: album.coverArtPath,
              coverSeed: '${album.artist} · ${album.album}',
              onTap: () => context.push(albumRoute(album.album, album.artist)),
              onPlay: () => _playAlbum(
                context,
                ref,
                AlbumKey(album: album.album, artist: album.artist),
                shuffle: false,
              ),
              onSecondaryTapDown: (TapDownDetails details) => _showAlbumMenu(
                context,
                ref,
                album,
                details.globalPosition,
              ),
              trailing: Builder(
                builder: (BuildContext buttonContext) => TyIconAction(
                  icon: Icons.more_horiz,
                  semanticLabel: '${album.album}：更多操作',
                  tooltip: '更多',
                  size: TyIconSize.compact,
                  onPressed: () => _showAlbumMenu(
                    context,
                    ref,
                    album,
                    _menuAnchor(buttonContext),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 专辑路由（`docs/UX_REDESIGN.md` §3.3）：专辑名在 path、艺术家在 query。
String albumRoute(String album, String artist) =>
    '/album/${Uri.encodeComponent(album)}'
    '?artist=${Uri.encodeQueryComponent(artist)}';

/// 从某个按钮的渲染盒算菜单锚点（⋯ 按钮场景）。
Offset _menuAnchor(BuildContext buttonContext) {
  final RenderObject? box = buttonContext.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    return box.localToGlobal(box.size.center(Offset.zero));
  }
  return Offset.zero;
}

/// 起播整张专辑；专辑没有可播放曲目时给一句即时说明，而不是静默无事发生。
Future<void> _playAlbum(
  BuildContext context,
  WidgetRef ref,
  AlbumKey key, {
  required bool shuffle,
}) async {
  final List<Track> tracks = await ref.read(albumTracksProvider(key).future);
  if (!context.mounted) {
    return;
  }
  if (tracks.isEmpty) {
    TySnack.show(context, '「${key.album}」还没有曲目');
    return;
  }
  await ref.read(playbackProvider.notifier).playTracks(tracks, shuffle: shuffle);
}

/// 专辑卡的上下文菜单（⋯ 与右键/长按共用同一份，`DESIGN.md` §6.4）。
Future<void> _showAlbumMenu(
  BuildContext context,
  WidgetRef ref,
  AlbumSummary album,
  Offset position,
) {
  final AlbumKey key = AlbumKey(album: album.album, artist: album.artist);
  return TyContextMenu.show(
    context,
    position: position,
    actions: <TyMenuAction>[
      TyMenuAction(
        label: '播放',
        icon: Icons.play_arrow_outlined,
        onSelected: () =>
            _playAlbum(context, ref, key, shuffle: false),
      ),
      TyMenuAction(
        label: '随机播放',
        icon: Icons.shuffle,
        onSelected: () => _playAlbum(context, ref, key, shuffle: true),
      ),
      TyMenuAction(
        label: '查看专辑',
        icon: Icons.album_outlined,
        onSelected: () => context.push(albumRoute(album.album, album.artist)),
      ),
    ],
  );
}
