
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/models/library_summaries.dart';
import '../../design/components/buttons.dart';
import '../../design/components/context_menu.dart';
import '../../design/components/detail_hero.dart';
import '../../design/components/feedback.dart';
import '../../design/components/structure.dart';
import '../../design/components/track.dart';
import '../../design/format.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../shared/add_to_playlist.dart';
import '../shared/playback_track_row.dart';
import '../shared/skeletons.dart';
import '../shared/track_actions.dart';

/// 专辑详情：`TyDetailHero`（封面 + 元数据 + 播放/随机/加入歌单/更多）+ 曲目表。
///
/// 曲目顺序由 [albumTracksProvider] 给定（碟号 → 曲序 → 标题），点击第 i 首
/// 从该首开始播放整张专辑。
class AlbumDetailPage extends ConsumerWidget {
  const AlbumDetailPage({super.key, required this.albumKey});

  final AlbumKey albumKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyMetrics metrics = context.metrics;
    final AsyncValue<List<Track>> tracks = ref.watch(
      albumTracksProvider(albumKey),
    );
    final List<Track> list = tracks.value ?? const <Track>[];
    // 列表页已经读过聚合结果，封面/年份先从这里取，避免曲目还在加载时头图空一拍。
    final AlbumSummary? summary = ref
        .watch(albumsProvider)
        .value
        ?.where(
          (AlbumSummary item) =>
              item.album == albumKey.album && item.artist == albumKey.artist,
        )
        .firstOrNull;
    final Track? cover = _firstWithCover(list);

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
            eyebrow: '专辑',
            title: albumKey.album,
            coverPath: summary?.coverArtPath ?? cover?.coverArtPath,
            coverUrl: cover?.coverArtUrl,
            coverSeed: '${albumKey.artist} · ${albumKey.album}',
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
                    : () => _play(ref, list, shuffle: false),
              ),
              TyButton(
                label: '随机',
                icon: Icons.shuffle,
                variant: TyButtonVariant.secondary,
                onPressed: list.isEmpty
                    ? null
                    : () => _play(ref, list, shuffle: true),
              ),
              TyButton(
                label: '加入歌单',
                icon: Icons.playlist_add,
                variant: TyButtonVariant.secondary,
                onPressed: list.isEmpty
                    ? null
                    : () => showAddToPlaylistDialog(context, ref, list),
              ),
              TyIconAction(
                icon: Icons.more_horiz,
                semanticLabel: '专辑更多操作',
                tooltip: '更多',
                onPressed: () => _showMenu(context, ref, list),
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
                  title: '专辑读取失败',
                  detail: '$error',
                  onRetry: () => ref.invalidate(albumTracksProvider(albumKey)),
                ),
            isEmpty: (List<Track> value) => value.isEmpty,
            empty: (BuildContext context) => TyEmptyState(
              icon: Icons.album_outlined,
              title: '没有可播放的曲目',
              description: '${albumKey.album} · ${albumKey.artist}',
              actionLabel: '返回专辑列表',
              onAction: () => context.canPop()
                  ? context.pop()
                  : context.go('/library/albums'),
            ),
            data: (BuildContext context, List<Track> value) =>
                _trackList(context, ref, value),
          ),
        ),
      ],
    );
  }

  /// 元数据行（`·` 分隔，`DESIGN.md` §6.1 的 `TyDetailHero`）：艺术家 · 年份 · 曲目数 · 总时长。
  String _meta(List<Track> tracks) {
    final int? year = _firstYear(tracks);
    final double total = tracks.fold<double>(
      0,
      (double sum, Track track) => sum + track.duration,
    );
    return <String>[
      albumKey.artist,
      if (year != null) '$year年',
      if (tracks.isNotEmpty) '${tracks.length} 首歌曲',
      if (total > 0) formatSeconds(total),
    ].join(' · ');
  }

  Future<void> _play(WidgetRef ref, List<Track> tracks, {required bool shuffle}) {
    return ref
        .read(playbackProvider.notifier)
        .playTracks(tracks, shuffle: shuffle);
  }

  Widget _trackList(BuildContext context, WidgetRef ref, List<Track> tracks) {
    final TyMetrics metrics = context.metrics;
    Future<void> showMenu(Track track, Offset position) => showTrackMenu(
          context,
          ref,
          track,
          position: position,
          onPlay: () => _play(ref, tracks, shuffle: false),
        );
    void play(int index) => ref
        .read(playbackProvider.notifier)
        .playTracks(tracks, startIndex: index);
    // 行自己订阅播放态：进度 tick 与换曲都不会重建整张列表
    // （`ui_rebuild_seek_test` 的口径）。
    Widget row(BuildContext context, int index, Track track) => PlaybackTrackRow(
          key: ValueKey<String>('album-${track.id}'),
          track: track,
          index: index + 1,
          tableMode: !context.formFactor.isCompact,
          // 专辑页里「专辑」列恒等于页面标题，纯噪声：只在这一页关掉它。
          showAlbum: false,
          onTap: () => play(index),
          onToggleFavorite: () => toggleTrackFavorite(ref, track),
          onMore: () => showMenu(track, rowOrigin(context)),
          onSecondaryTapDown: (TapDownDetails details) =>
              showMenu(track, details.globalPosition),
        );

    if (context.formFactor == FormFactor.compact) {
      return TyTrackList(
        tracks: tracks,
        playingTrackId: null,
        playing: false,
        rowBuilder: row,
        padding: EdgeInsets.symmetric(horizontal: metrics.pagePadding),
      );
    }
    return TyTrackTable(
      tracks: tracks,
      playingTrackId: null,
      playing: false,
      rowBuilder: row,
    );
  }

  /// 头图的「更多」：与右键菜单同一份语义（播放 / 随机 / 加入歌单 / 在艺人中查看）。
  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
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
          onSelected: () => _play(ref, tracks, shuffle: false),
        ),
        TyMenuAction(
          label: '随机播放',
          icon: Icons.shuffle,
          enabled: tracks.isNotEmpty,
          onSelected: () => _play(ref, tracks, shuffle: true),
        ),
        TyMenuAction(
          label: '添加到播放列表…',
          icon: Icons.playlist_add,
          enabled: tracks.isNotEmpty,
          onSelected: () => showAddToPlaylistDialog(context, ref, tracks),
        ),
        TyMenuAction(
          label: '在艺人中查看',
          icon: Icons.person_outline,
          enabled: albumKey.artist.isNotEmpty,
          onSelected: () => context.push(
            '/artist/${Uri.encodeComponent(albumKey.artist)}',
          ),
        ),
      ],
    );
  }
}

/// 取第一条带封面的曲目（本地缓存优先，其次远端 URL）。
Track? _firstWithCover(List<Track> tracks) {
  for (final Track track in tracks) {
    if (track.coverArtPath != null || track.coverArtUrl != null) {
      return track;
    }
  }
  return null;
}

/// 专辑年份取第一条有年份的曲目。
int? _firstYear(List<Track> tracks) {
  for (final Track track in tracks) {
    if (track.year != null) {
      return track.year;
    }
  }
  return null;
}
