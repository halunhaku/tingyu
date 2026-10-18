
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/album_card.dart';
import '../../design/components/buttons.dart';
import '../../design/components/detail_hero.dart';
import '../../design/components/feedback.dart';
import '../../design/components/structure.dart';
import '../../design/components/track.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../albums/albums_page.dart' show albumRoute;
import '../shared/playback_track_row.dart';
import '../shared/skeletons.dart';
import '../shared/track_actions.dart';
import 'artists_page.dart' show artistAvatarProvider;

/// 艺术家详情：头像 + 名字 + 统计，下方是「专辑」横向封面轨与「全部曲目」。
///
/// 曲目顺序沿用 [artistTracksProvider]；专辑之间按专辑名排序，组内沿用
/// [sortForAlbum]（碟号 → 曲序 → 标题）。
///
/// 专辑区做成一行横向轨道而不是多行网格：曲目区由 `TyTrackTable`/`TyTrackList`
/// 承载，它们自己拥有滚动视口，多行网格会把整页剩下的高度吃掉。
class ArtistDetailPage extends ConsumerStatefulWidget {
  const ArtistDetailPage({super.key, required this.artist});

  final String artist;

  @override
  ConsumerState<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends ConsumerState<ArtistDetailPage> {
  /// 「全部曲目」默认展示的条数（`docs/UX_REDESIGN.md` §5.3）。
  static const int _previewCount = 10;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final TyMetrics metrics = context.metrics;
    final AsyncValue<List<Track>> tracks = ref.watch(
      artistTracksProvider(widget.artist),
    );
    final List<Track> list = tracks.value ?? const <Track>[];
    final Map<String, List<Track>> groups = _groupByAlbum(list);
    final List<Track> shown = _expanded
        ? list
        : list.take(_previewCount).toList();

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
            eyebrow: '艺术家',
            title: widget.artist,
            coverBytes: ref.watch(artistAvatarProvider(widget.artist)).value,
            coverSeed: widget.artist,
            coverShape: TyDetailHeroShape.circle,
            meta: tracks.hasValue
                ? '${list.length} 首歌曲 · ${groups.length} 张专辑'
                : null,
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
                label: '播放全部',
                icon: Icons.play_arrow,
                onPressed: list.isEmpty
                    ? null
                    : () => ref
                          .read(playbackProvider.notifier)
                          .playTracks(list),
              ),
              TyButton(
                label: '随机',
                icon: Icons.shuffle,
                variant: TyButtonVariant.secondary,
                onPressed: list.isEmpty
                    ? null
                    : () => ref
                          .read(playbackProvider.notifier)
                          .playTracks(list, shuffle: true),
              ),
            ],
          ),
        ),
        if (groups.isNotEmpty) ...<Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: metrics.pagePadding),
            child: TySectionHeader(title: '专辑', count: groups.length),
          ),
          _AlbumRail(groups: groups),
        ],
        Padding(
          padding: EdgeInsets.symmetric(horizontal: metrics.pagePadding),
          child: TySectionHeader(
            title: '全部曲目',
            count: tracks.hasValue ? list.length : null,
            actionLabel: list.length > _previewCount
                ? (_expanded ? '收起' : '全部展开')
                : null,
            onAction: list.length > _previewCount
                ? () => setState(() => _expanded = !_expanded)
                : null,
          ),
        ),
        Expanded(
          child: TyAsyncView<List<Track>>(
            value: tracks,
            loading: (BuildContext context) =>
                const TrackRowsSkeleton(rows: 8),
            error: (BuildContext context, Object error, StackTrace? stack) =>
                TyErrorView(
                  title: '艺术家读取失败',
                  detail: '$error',
                  onRetry: () =>
                      ref.invalidate(artistTracksProvider(widget.artist)),
                ),
            isEmpty: (List<Track> value) => value.isEmpty,
            empty: (BuildContext context) => TyEmptyState(
              icon: Icons.person_outline,
              title: '没有这位艺术家的曲目',
              description: widget.artist,
              actionLabel: '返回艺术家列表',
              onAction: () => context.canPop()
                  ? context.pop()
                  : context.go('/library/artists'),
            ),
            data: (BuildContext context, List<Track> value) =>
                _trackList(context, shown),
          ),
        ),
      ],
    );
  }

  /// 曲目区：桌面表格 / compact 列表，接线与曲库页一致。
  Widget _trackList(BuildContext context, List<Track> tracks) {
    final TyMetrics metrics = context.metrics;

    Future<void> play(int index) => ref
        .read(playbackProvider.notifier)
        .playTracks(tracks, startIndex: index);

    Future<void> showMenu(Track track, Offset position) => showTrackMenu(
      context,
      ref,
      track,
      position: position,
      onPlay: () => play(tracks.indexOf(track)),
    );

    // 行自己订阅播放态：进度 tick 一行都不重建（`ui_rebuild_seek_test` 的口径）。
    Widget row(BuildContext context, int index, Track track) => PlaybackTrackRow(
      key: ValueKey<String>('artist-${track.id}'),
      track: track,
      index: index + 1,
      tableMode: !context.formFactor.isCompact,
      showAlbum:
          !context.formFactor.isCompact &&
          context.formFactor == FormFactor.expanded,
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
}

/// 专辑横向轨：单行、按专辑名排序，点击进专辑详情，悬停播放钮起播这张专辑。
class _AlbumRail extends ConsumerWidget {
  const _AlbumRail({required this.groups});

  final Map<String, List<Track>> groups;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyMetrics metrics = context.metrics;
    final List<MapEntry<String, List<Track>>> entries = groups.entries.toList();
    return SizedBox(
      height: tyTileExtent(context, metrics.gridMinTile),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: metrics.pagePadding),
        itemCount: entries.length,
        separatorBuilder: (_, _) => SizedBox(width: metrics.gridGap),
        itemBuilder: (BuildContext context, int index) {
          final String album = entries[index].key;
          final List<Track> albumTracks = entries[index].value;
          return TyAlbumCard(
            width: metrics.gridMinTile,
            title: album,
            subtitle: '${albumTracks.length} 首',
            coverPath: _firstCoverPath(albumTracks),
            coverUrl: _firstCoverUrl(albumTracks),
            coverSeed: '$album · ${albumTracks.first.artist}',
            onTap: () => context.push(
              albumRoute(album, albumTracks.first.artist),
            ),
            onPlay: () =>
                ref.read(playbackProvider.notifier).playTracks(albumTracks),
          );
        },
      ),
    );
  }
}

/// 按专辑名分组；`List.sort` 不保证稳定，所以组内重新用 [sortForAlbum] 定序。
Map<String, List<Track>> _groupByAlbum(List<Track> tracks) {
  final List<Track> ordered = List<Track>.of(tracks)
    ..sort((Track a, Track b) => a.album.compareTo(b.album));

  final Map<String, List<Track>> groups = <String, List<Track>>{};
  for (final Track track in ordered) {
    (groups[track.album] ??= <Track>[]).add(track);
  }
  for (final List<Track> group in groups.values) {
    sortForAlbum(group);
  }
  return groups;
}

String? _firstCoverPath(List<Track> tracks) => tracks
    .map((Track track) => track.coverArtPath)
    .firstWhere(
      (String? path) => path != null && path.isNotEmpty,
      orElse: () => null,
    );

String? _firstCoverUrl(List<Track> tracks) => tracks
    .map((Track track) => track.coverArtUrl)
    .firstWhere(
      (String? url) => url != null && url.isNotEmpty,
      orElse: () => null,
    );
