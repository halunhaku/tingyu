import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/buttons.dart';
import '../../design/components/context_menu.dart';
import '../../design/components/feedback.dart';
import '../../design/components/playlist_card.dart';
import '../../design/components/structure.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../shared/add_to_playlist.dart';
import '../shared/skeletons.dart';

/// 歌单页：2×2 封面拼贴网格，首个瓦片是「新建歌单」（`DESIGN.md` §5.2 / §6.2）。
///
/// 重命名/删除走 `TyContextMenu`（⋯ 与右键/长按同一份菜单），删除需二次确认。
class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyMetrics metrics = context.metrics;
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);
    final int? count = playlists.value?.length;

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
            title: '歌单',
            subtitle: count == null ? null : '共 $count 个',
            actions: <Widget>[
              TyButton(
                label: '新建歌单',
                icon: Icons.add,
                variant: TyButtonVariant.secondary,
                dense: true,
                onPressed: () => createPlaylist(context, ref),
              ),
            ],
          ),
        ),
        Expanded(
          child: TyAsyncView<List<Playlist>>(
            value: playlists,
            loading: (BuildContext context) =>
                const GridSkeleton(shortSubtitle: true),
            error: (BuildContext context, Object error, StackTrace? stack) =>
                TyErrorView(
                  title: '歌单读取失败',
                  detail: '$error',
                  onRetry: () => ref.invalidate(playlistsProvider),
                ),
            isEmpty: (List<Playlist> list) => list.isEmpty,
            empty: (BuildContext context) => TyEmptyState(
              icon: Icons.queue_music_outlined,
              title: '还没有歌单',
              description: '在歌曲上选择「添加到播放列表…」，或点上面的「新建歌单」',
              actionLabel: '新建歌单',
              onAction: () => createPlaylist(context, ref),
            ),
            data: (BuildContext context, List<Playlist> list) =>
                _PlaylistGrid(playlists: list),
          ),
        ),
      ],
    );
  }
}

/// 网格本体：首个瓦片是「新建歌单」，其余是歌单卡。
class _PlaylistGrid extends ConsumerWidget {
  const _PlaylistGrid({required this.playlists});

  final List<Playlist> playlists;

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
          itemCount: playlists.length + 1,
          itemBuilder: (BuildContext context, int index) {
            if (index == 0) {
              return TyNewPlaylistCard(
                width: tile,
                onTap: () => createPlaylist(context, ref),
              );
            }
            return _PlaylistTile(playlist: playlists[index - 1], width: tile);
          },
        );
      },
    );
  }
}

/// 单张歌单卡：拼贴封面取前 4 首曲目的封面，副标题是真实曲目数。
class _PlaylistTile extends ConsumerWidget {
  const _PlaylistTile({required this.playlist, required this.width});

  final Playlist playlist;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Map<String, int>> counts = ref.watch(
      playlistTrackCountsProvider,
    );
    final List<Track> tracks =
        ref.watch(playlistTracksProvider(playlist.id)).value ??
        const <Track>[];
    final int? count = counts.value?[playlist.id];

    return TyPlaylistCard(
      width: width,
      title: playlist.name,
      subtitle: count == null ? null : '$count 首',
      coverPaths: <String>[
        for (final Track track in tracks)
          if (track.coverArtPath != null && track.coverArtPath!.isNotEmpty)
            track.coverArtPath!,
      ].take(4).toList(),
      onTap: () => context.push('/playlist/${playlist.id}'),
      onPlay: () => _play(context, ref, tracks),
      onSecondaryTapDown: (TapDownDetails details) =>
          _showMenu(context, ref, details.globalPosition),
      trailing: Builder(
        builder: (BuildContext buttonContext) => TyIconAction(
          icon: Icons.more_horiz,
          semanticLabel: '${playlist.name}：更多操作',
          tooltip: '更多',
          size: TyIconSize.compact,
          onPressed: () => _showMenu(context, ref, _menuAnchor(buttonContext)),
        ),
      ),
    );
  }

  /// 起播整张歌单：空歌单不静默——给一句即时说明，而不是清掉当前播放。
  void _play(BuildContext context, WidgetRef ref, List<Track> tracks) {
    if (tracks.isEmpty) {
      TySnack.show(context, '「${playlist.name}」还没有曲目');
      return;
    }
    ref.read(playbackProvider.notifier).playTracks(tracks);
  }

  /// 歌单卡的上下文菜单：播放 / 重命名 / 删除歌单（危险项单独分组）。
  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position,
  ) {
    return TyContextMenu.show(
      context,
      position: position,
      actions: <TyMenuAction>[
        TyMenuAction(
          label: '播放',
          icon: Icons.play_arrow_outlined,
          onSelected: () => _play(
            context,
            ref,
            ref.read(playlistTracksProvider(playlist.id)).value ??
                const <Track>[],
          ),
        ),
        TyMenuAction(
          label: '重命名',
          icon: Icons.edit_outlined,
          onSelected: () => renamePlaylist(context, ref, playlist),
        ),
        TyMenuAction(
          label: '删除歌单',
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () => deletePlaylist(context, ref, playlist),
        ),
      ],
    );
  }
}

/// ⋯ 按钮的菜单锚点（全局坐标）。
Offset _menuAnchor(BuildContext buttonContext) {
  final RenderObject? box = buttonContext.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    return box.localToGlobal(box.size.center(Offset.zero));
  }
  return Offset.zero;
}

/// 新建歌单；id 与「添加到播放列表…」里的就地新建保持同一套约定。
Future<void> createPlaylist(BuildContext context, WidgetRef ref) async {
  final String? name = await promptPlaylistName(
    context,
    title: '新建歌单',
    confirmLabel: '创建',
  );
  if (name == null || name.trim().isEmpty) {
    return;
  }
  await ref
      .read(playlistRepositoryProvider)
      .create(
        id: 'pl-${DateTime.now().microsecondsSinceEpoch}',
        name: name.trim(),
      );
}

/// 重命名歌单；空名字与取消都不改数据。
Future<void> renamePlaylist(
  BuildContext context,
  WidgetRef ref,
  Playlist playlist,
) async {
  final String? name = await promptPlaylistName(
    context,
    title: '重命名歌单',
    confirmLabel: '保存',
    initial: playlist.name,
  );
  if (name == null || name.trim().isEmpty) {
    return;
  }
  await ref.read(playlistRepositoryProvider).rename(playlist.id, name.trim());
}

/// 删除歌单：危险操作必须二次确认（`DESIGN.md` §2.4）。
Future<void> deletePlaylist(
  BuildContext context,
  WidgetRef ref,
  Playlist playlist,
) async {
  final bool confirmed = await tyConfirm(
    context,
    title: '删除歌单「${playlist.name}」？',
    message: '歌单里的曲目本身不会被删除。',
    confirmLabel: '删除',
    destructive: true,
  );
  if (!confirmed) {
    return;
  }
  await ref.read(playlistRepositoryProvider).delete(playlist.id);
}
