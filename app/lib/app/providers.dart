import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/cover_store.dart';
import '../data/db/database.dart';
import '../data/enrichment_service.dart';
import '../data/models/library_summaries.dart';
import '../data/repositories/playlist_repository.dart';
import '../data/repositories/source_repository.dart';
import '../data/repositories/track_repository.dart';
import '../playback/playback_snapshot.dart';
import '../playback/tingyu_audio_handler.dart';
import '../sources/scraper/artist_avatar_store.dart';
import '../sources/scraper/itunes_cover_provider.dart';
import '../sources/scraper/lrclib_provider.dart';
import '../sources/scraper/metadata_enricher.dart';
import '../sources/scraper/metadata_provider.dart';
import '../sources/scraper/netease_provider.dart';
import '../sources/scraper/qq_music_provider.dart';
import 'playback_controller.dart';
import 'track_resolver.dart';

// ---------------------------------------------------------------- 数据层

/// 曲线库数据库；随 ProviderScope 销毁。
final Provider<TingyuDatabase> databaseProvider = Provider<TingyuDatabase>((Ref ref) {
  final TingyuDatabase database = TingyuDatabase();
  ref.onDispose(database.close);
  return database;
});

final Provider<CoverStore> coverStoreProvider = Provider<CoverStore>((Ref ref) => CoverStore());

/// 封面缓存文件名 → 文件（不存在时为 null）。UI 用它渲染本地封面。
final coverFileProvider = FutureProvider.family<File?, String>((Ref ref, String name) async {
  return ref.watch(coverStoreProvider).resolve(name);
});

final Provider<TrackRepository> trackRepositoryProvider =
    Provider<TrackRepository>((Ref ref) => TrackRepository(ref.watch(databaseProvider)));

final Provider<PlaylistRepository> playlistRepositoryProvider =
    Provider<PlaylistRepository>((Ref ref) => PlaylistRepository(ref.watch(databaseProvider)));

final Provider<SourceRepository> sourceRepositoryProvider =
    Provider<SourceRepository>((Ref ref) => SourceRepository(ref.watch(databaseProvider)));

// ---------------------------------------------------------------- 曲库查询

final StreamProvider<List<Track>> allTracksProvider =
    StreamProvider<List<Track>>((Ref ref) => ref.watch(trackRepositoryProvider).watchAll());

final StreamProvider<List<Track>> favoritesProvider =
    StreamProvider<List<Track>>((Ref ref) => ref.watch(trackRepositoryProvider).watchFavorites());

final StreamProvider<List<AlbumSummary>> albumsProvider =
    StreamProvider<List<AlbumSummary>>((Ref ref) => ref.watch(trackRepositoryProvider).watchAlbums());

final StreamProvider<List<ArtistSummary>> artistsProvider =
    StreamProvider<List<ArtistSummary>>((Ref ref) => ref.watch(trackRepositoryProvider).watchArtists());

final StreamProvider<List<MusicSource>> sourcesProvider =
    StreamProvider<List<MusicSource>>((Ref ref) => ref.watch(sourceRepositoryProvider).watchAll());

final StreamProvider<List<Playlist>> playlistsProvider =
    StreamProvider<List<Playlist>>((Ref ref) => ref.watch(playlistRepositoryProvider).watchAll());

/// 侧栏搜索框的输入；空串表示不搜索。
class SearchQueryController extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;

  void clear() => state = '';
}

final NotifierProvider<SearchQueryController, String> searchQueryProvider =
    NotifierProvider<SearchQueryController, String>(SearchQueryController.new);

/// 当前列表（搜索命中或全库）。
final FutureProvider<List<Track>> visibleTracksProvider = FutureProvider<List<Track>>((Ref ref) async {
  final String query = ref.watch(searchQueryProvider).trim();
  final TrackRepository tracks = ref.watch(trackRepositoryProvider);
  if (query.isEmpty) {
    return tracks.all();
  }
  return tracks.search(query);
});

/// 「最近添加」：按 dateAdded 倒序取前 100。
final FutureProvider<List<Track>> recentlyAddedProvider = FutureProvider<List<Track>>((Ref ref) async {
  final List<Track> all = await ref.watch(trackRepositoryProvider).all();
  final List<Track> sorted = List<Track>.of(all)
    ..sort((Track a, Track b) => b.dateAdded.compareTo(a.dateAdded));
  return sorted.take(100).toList(growable: false);
});

/// 某个来源下的曲目。
final tracksOfSourceProvider =
    FutureProvider.family<List<Track>, String>((Ref ref, String sourceId) async {
  return ref.watch(trackRepositoryProvider).bySource(sourceId);
});

/// 某个播放列表的曲目（保持保存的顺序）。
final playlistTracksProvider =
    FutureProvider.family<List<Track>, String>((Ref ref, String playlistId) async {
  return ref.watch(playlistRepositoryProvider).tracksOf(playlistId);
});

/// 某位艺术家的曲目（专辑 → 碟号 → 曲序）。
final artistTracksProvider =
    FutureProvider.family<List<Track>, String>((Ref ref, String artist) async {
  final List<Track> all = await ref.watch(trackRepositoryProvider).all();
  final List<Track> mine = all.where((Track track) => track.artist == artist).toList();
  sortForAlbum(mine);
  return mine;
});

/// 某个专辑的曲目（按 `artist + album` 归并，与 [albumsProvider] 口径一致）。
final albumTracksProvider =
    FutureProvider.family<List<Track>, AlbumKey>((Ref ref, AlbumKey key) async {
  final List<Track> all = await ref.watch(trackRepositoryProvider).all();
  final List<Track> mine = all
      .where((Track track) => track.album == key.album && track.artist == key.artist)
      .toList();
  sortForAlbum(mine);
  return mine;
});

/// 专辑/曲目列表统一排序：碟号 → 曲序 → 标题（与旧版 `LibraryGrouping.sortForAlbum` 一致）。
void sortForAlbum(List<Track> tracks) {
  tracks.sort((Track a, Track b) {
    final int byDisc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
    if (byDisc != 0) {
      return byDisc;
    }
    final int byTrack = (a.trackNumber ?? 1 << 30).compareTo(b.trackNumber ?? 1 << 30);
    if (byTrack != 0) {
      return byTrack;
    }
    return a.title.compareTo(b.title);
  });
}

/// 专辑查询键：与聚合查询的 `GROUP BY artist, album` 保持一致。
class AlbumKey {
  const AlbumKey({required this.artist, required this.album});

  final String artist;

  final String album;

  @override
  bool operator ==(Object other) =>
      other is AlbumKey && other.artist == artist && other.album == album;

  @override
  int get hashCode => Object.hash(artist, album);
}

/// 按 id 取曲目（播放条/正在播放页展示当前曲目用）。
final trackByIdProvider =
    FutureProvider.family<Track?, String>((Ref ref, String id) async {
  return ref.watch(trackRepositoryProvider).byId(id);
});

/// 按来源 id 取一条来源记录（播放解析、来源页都用它）。
final sourceByIdProvider =
    FutureProvider.family<MusicSource?, String>((Ref ref, String id) async {
  return ref.watch(sourceRepositoryProvider).byId(id);
});

// ---------------------------------------------------------------- 抓取与播放

final Provider<MetadataEnricher> metadataEnricherProvider = Provider<MetadataEnricher>((Ref ref) {
  return MetadataEnricher(
    searcher: QQMusicProvider(),
    lyricsProvider: LrclibProvider(),
    fallbackSearcher: NetEaseProvider(),
    fallbackLyricsProvider: NetEaseProvider(),
    coverLookup: ITunesCoverProvider(),
    downloader: ImageDownloader(),
  );
});

final Provider<LibraryEnrichmentService> enrichmentServiceProvider =
    Provider<LibraryEnrichmentService>((Ref ref) {
  return LibraryEnrichmentService(
    tracks: ref.watch(trackRepositoryProvider),
    covers: ref.watch(coverStoreProvider),
    enricher: ref.watch(metadataEnricherProvider),
  );
});

final Provider<ArtistAvatarStore> artistAvatarStoreProvider = Provider<ArtistAvatarStore>(
  (Ref ref) => ArtistAvatarStore(lookup: NetEaseProvider()),
);

/// 曲目 → 可播放条目（含远端来源的鉴权头）。
final Provider<TrackResolver> trackResolverProvider =
    Provider<TrackResolver>((Ref ref) => TrackResolver(ref));

/// 播放控制器；持有 system audio handler。
final NotifierProvider<PlaybackController, PlaybackSnapshot> playbackProvider =
    NotifierProvider<PlaybackController, PlaybackSnapshot>(PlaybackController.new);

/// 由 `main.dart` 在 `ProviderScope.overrides` 中注入的音频处理器。
final Provider<TingyuAudioHandler> audioHandlerProvider = Provider<TingyuAudioHandler>(
  (Ref ref) => throw UnimplementedError('audioHandlerProvider 必须在 ProviderScope.overrides 中注入'),
);

/// 静音曲目时用的占位专辑值（与旧版一致）。
const Set<String> placeholderAlbumNames = <String>{'未知专辑', '夸克曲库', 'WebDAV 曲库'};

/// 判断专辑名是否仍是占位值。
bool isPlaceholderAlbum(String album) => placeholderAlbumNames.contains(album);

/// 便捷：把可能为 null 的值包成 drift 的更新值。
Value<T> valueOrAbsent<T>(T? value) => value == null ? Value<T>.absent() : Value<T>(value);
