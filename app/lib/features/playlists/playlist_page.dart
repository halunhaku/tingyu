
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/buttons.dart';
import '../../design/components/context_menu.dart';
import '../../design/components/detail_hero.dart';
import '../../design/components/feedback.dart';
import '../../design/components/structure.dart';
import '../../design/components/track.dart';
import '../../design/format.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../shared/playback_track_row.dart';
import '../shared/skeletons.dart';
import '../shared/track_actions.dart';
import 'playlists_page.dart';

/// 播放列表详情：头图 + 曲目表；顺序播放、拖拽重排、移出曲目、重命名与删除。
///
/// 队列语义（`docs/UX_REDESIGN.md` §4.1）：点击第 i 首即从该首起播整张歌单；
/// 「移出歌单」是成员关系操作（与曲库无关），走曲目菜单的同一入口。
class PlaylistPage extends ConsumerWidget {
  const PlaylistPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyMetrics metrics = context.metrics;
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);

    // 首次打开时 playlistsProvider 还在建流（loading），此时 value 为 null。
    // 曾经的写法把 loading 也当成「不存在」，真实歌单每次打开都会闪一下
    // 「播放列表不存在」；只有真的拿到列表却查不到 id（被删了/深链写错）才算不存在。
    if (!playlists.hasValue) {
      if (playlists.hasError) {
        return TyErrorView(
          title: '歌单读取失败',
          detail: '${playlists.error}',
          onRetry: () => ref.invalidate(playlistsProvider),
        );
      }
      return const TrackRowsSkeleton(rows: 8);
    }
    final Playlist? playlist = playlists.requireValue
        .where((Playlist item) => item.id == playlistId)
        .firstOrNull;

    if (playlist == null) {
      return TyEmptyState(
        icon: Icons.queue_music_outlined,
        title: '播放列表不存在',
        description: '它可能已经被删除',
        actionLabel: '返回歌单',
        onAction: () => context.go('/library/playlists'),
      );
    }

    final AsyncValue<List<Track>> tracks = ref.watch(
      playlistTracksProvider(playlistId),
    );
    final List<Track> list = tracks.value ?? const <Track>[];
    final String? coverPath = list
        .map((Track track) => track.coverArtPath)
        .firstWhere(
          (String? path) => path != null && path.isNotEmpty,
          orElse: () => null,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.pagePadding,
            TySpace.x16,
            metrics.pagePadding,
            TySpace.x8,
          ),
          child: TyDetailHero(
            eyebrow: '歌单',
            title: playlist.name,
            coverPath: coverPath,
            coverSeed: playlist.name,
            meta: _meta(list),
            header: context.canPop()
                ? Row(
                    children: <Widget>[
                      TyIconAction(
                        icon: Icons.arrow_back,
                        semanticLabel: '返回',
                        tooltip: '返回',
                        onPressed: () => context.pop(),
                      ),
                    ],
                  )
                : null,
            actions: <Widget>[
              TyButton(
                label: '播放',
                icon: Icons.play_arrow,
                onPressed: list.isEmpty
                    ? null
                    : () => _play(context, ref, list, shuffle: false),
              ),
              TyButton(
                label: '随机',
                icon: Icons.shuffle,
                variant: TyButtonVariant.secondary,
                onPressed: list.isEmpty
                    ? null
                    : () => _play(context, ref, list, shuffle: true),
              ),
              TyIconAction(
                icon: Icons.more_horiz,
                semanticLabel: '歌单更多操作',
                tooltip: '更多',
                onPressed: () => _showMenu(context, ref, playlist, list),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: metrics.pagePadding),
          child: TySectionHeader(
            title: '曲目',
            count: tracks.hasValue ? list.length : null,
          ),
        ),
        Expanded(
          child: TyAsyncView<List<Track>>(
            value: tracks,
            loading: (BuildContext context) =>
                const TrackRowsSkeleton(rows: 8),
            error: (BuildContext context, Object error, StackTrace? stack) =>
                TyErrorView(
                  title: '读取失败',
                  detail: '$error',
                  onRetry: () =>
                      ref.invalidate(playlistTracksProvider(playlistId)),
                ),
            isEmpty: (List<Track> value) => value.isEmpty,
            empty: (BuildContext context) => const TyEmptyState(
              icon: Icons.queue_music_outlined,
              title: '播放列表是空的',
              description: '在曲库里右键歌曲 → 添加到播放列表',
            ),
            data: (BuildContext context, List<Track> value) =>
                _reorderableList(context, ref, value),
          ),
        ),
      ],
    );
  }

  /// 元数据行（`·` 分隔）：曲目数 · 总时长。
  String _meta(List<Track> tracks) {
    final double total = tracks.fold<double>(
      0,
      (double sum, Track track) => sum + track.duration,
    );
    return <String>[
      if (tracks.isNotEmpty) '${tracks.length} 首',
      if (total > 0) formatSeconds(total),
    ].join(' · ');
  }

  Future<void> _play(
    BuildContext context,
    WidgetRef ref,
    List<Track> tracks, {
    required bool shuffle,
  }) {
    return ref
        .read(playbackProvider.notifier)
        .playTracks(tracks, shuffle: shuffle);
  }

  /// 拖拽重排保留（`docs/UX_REDESIGN.md` §5.3）：行本身用 [TyTrackRow]，
  /// 重排、移出、右键菜单都走既有单曲级能力。
  Widget _reorderableList(
    BuildContext context,
    WidgetRef ref,
    List<Track> tracks,
  ) {
    final TyMetrics metrics = context.metrics;
    final bool table = context.formFactor != FormFactor.compact;

    Future<void> removeAt(int index) async {
      await ref.read(playlistRepositoryProvider).removeAt(playlistId, index);
      ref.invalidate(playlistTracksProvider(playlistId));
    }

    Future<void> showMenu(Track track, Offset position) => showTrackMenu(
      context,
      ref,
      track,
      position: position,
      onPlay: () => ref
          .read(playbackProvider.notifier)
          .playTracks(tracks, startIndex: tracks.indexOf(track)),
      removeLabel: '移出歌单',
      onRemove: () => removeAt(tracks.indexOf(track)),
    );

    return ReorderableListView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: metrics.pagePadding,
        vertical: TySpace.x8,
      ),
      itemCount: tracks.length,
      itemExtent: table ? metrics.tableRowHeight : metrics.rowHeight,
      onReorderItem: (int oldIndex, int newIndex) async {
        await ref
            .read(playlistRepositoryProvider)
            .move(playlistId, from: oldIndex, to: newIndex);
        ref.invalidate(playlistTracksProvider(playlistId));
      },
      itemBuilder: (BuildContext context, int index) {
        final Track track = tracks[index];
        return Builder(
          key: ValueKey<String>(track.id),
          builder: (BuildContext rowContext) => PlaybackTrackRow(
            track: track,
            index: index + 1,
            tableMode: table,
            onTap: () => ref
                .read(playbackProvider.notifier)
                .playTracks(tracks, startIndex: index),
            onToggleFavorite: () => toggleTrackFavorite(ref, track),
            onMore: () => showMenu(track, rowOrigin(rowContext)),
            onSecondaryTapDown: (TapDownDetails details) =>
                showMenu(track, details.globalPosition),
          ),
        );
      },
    );
  }

  /// 头图的「更多」：重命名 / 删除歌单（危险项，需二次确认）。
  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    List<Track> tracks,
  ) {
    final RenderObject? box = context.findRenderObject();
    return TyContextMenu.show(
      context,
      position: box is RenderBox && box.hasSize
          ? box.localToGlobal(box.size.center(Offset.zero))
          : Offset.zero,
      actions: <TyMenuAction>[
        TyMenuAction(
          label: '播放',
          icon: Icons.play_arrow_outlined,
          enabled: tracks.isNotEmpty,
          onSelected: () => _play(context, ref, tracks, shuffle: false),
        ),
        TyMenuAction(
          label: '随机播放',
          icon: Icons.shuffle,
          enabled: tracks.isNotEmpty,
          onSelected: () => _play(context, ref, tracks, shuffle: true),
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
          onSelected: () async {
            await deletePlaylist(context, ref, playlist);
            if (!context.mounted) {
              return;
            }
            // 从歌单列表 push 进来的就退回列表；深链/侧栏直达时落到列表页。
            context.canPop()
                ? context.pop()
                : context.go('/library/playlists');
          },
        ),
      ],
    );
  }
}

