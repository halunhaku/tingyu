import 'package:flutter/foundation.dart';

import '../db/database.dart';
import 'library_summaries.dart';

/// 搜索分组结果：`items` 是当前露出的条目，`total` 是该组的真实命中总数。
@immutable
class SearchGroup<T> {
  const SearchGroup({required this.items, required this.total});

  final List<T> items;
  final int total;

  bool get isEmpty => total == 0;
  bool get hasMore => total > items.length;
}

/// 搜索页「全部」视图的一次快照：四组各取前几条 + 精确总数。
///
/// 分四组而不是一个大列表：命中 300 首歌时，用户通常先想确认「有没有这张专辑」，
/// 精确 COUNT 让他不必翻页就知道该不该点进某一组。
@immutable
class SearchOverview {
  const SearchOverview({
    required this.songs,
    required this.albums,
    required this.artists,
    required this.playlists,
  });

  static const SearchOverview empty = SearchOverview(
    songs: SearchGroup<Track>(items: <Track>[], total: 0),
    albums: SearchGroup<AlbumSummary>(items: <AlbumSummary>[], total: 0),
    artists: SearchGroup<ArtistSummary>(items: <ArtistSummary>[], total: 0),
    playlists: SearchGroup<Playlist>(items: <Playlist>[], total: 0),
  );

  final SearchGroup<Track> songs;
  final SearchGroup<AlbumSummary> albums;
  final SearchGroup<ArtistSummary> artists;
  final SearchGroup<Playlist> playlists;

  bool get isEmpty =>
      songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty;
}
