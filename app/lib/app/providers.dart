import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/cover_store.dart';
import '../data/db/database.dart';
import '../data/enrichment_service.dart';
import '../data/models/library_query.dart';
import '../data/models/library_summaries.dart';
import '../data/models/search_page_result.dart';
import '../data/models/search_overview.dart';
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
import '../data/secure_store.dart';
import '../sources/ai/ai_client.dart';
import '../sources/ai/ai_config.dart';
import '../sources/ai/ai_library_refactor_service.dart';
import '../sources/ai/ai_settings_repository.dart';

// ---------------------------------------------------------------- 数据层

/// 曲线库数据库；随 ProviderScope 销毁。
final Provider<TingyuDatabase> databaseProvider = Provider<TingyuDatabase>((
  Ref ref,
) {
  final TingyuDatabase database = TingyuDatabase();
  ref.onDispose(database.close);
  return database;
});

final Provider<CoverStore> coverStoreProvider = Provider<CoverStore>(
  (Ref ref) => CoverStore(),
);

/// 封面缓存文件名 → 文件（不存在时为 null）。UI 用它渲染本地封面。
final coverFileProvider = FutureProvider.family<File?, String>((
  Ref ref,
  String name,
) async {
  return ref.watch(coverStoreProvider).resolve(name);
});

final Provider<TrackRepository> trackRepositoryProvider =
    Provider<TrackRepository>(
      (Ref ref) => TrackRepository(ref.watch(databaseProvider)),
    );

final Provider<PlaylistRepository> playlistRepositoryProvider =
    Provider<PlaylistRepository>(
      (Ref ref) => PlaylistRepository(ref.watch(databaseProvider)),
    );

final Provider<SourceRepository> sourceRepositoryProvider =
    Provider<SourceRepository>(
      (Ref ref) => SourceRepository(ref.watch(databaseProvider)),
    );

// ---------------------------------------------------------------- 曲库查询

final StreamProvider<List<Track>> allTracksProvider =
    StreamProvider<List<Track>>(
      (Ref ref) => ref.watch(trackRepositoryProvider).watchAll(),
    );

final StreamProvider<List<Track>> favoritesProvider =
    StreamProvider<List<Track>>(
      (Ref ref) => ref.watch(trackRepositoryProvider).watchFavorites(),
    );

final StreamProvider<List<AlbumSummary>> albumsProvider =
    StreamProvider<List<AlbumSummary>>(
      (Ref ref) => ref.watch(trackRepositoryProvider).watchAlbums(),
    );

final StreamProvider<List<ArtistSummary>> artistsProvider =
    StreamProvider<List<ArtistSummary>>(
      (Ref ref) => ref.watch(trackRepositoryProvider).watchArtists(),
    );

final StreamProvider<List<MusicSource>> sourcesProvider =
    StreamProvider<List<MusicSource>>(
      (Ref ref) => ref.watch(sourceRepositoryProvider).watchAll(),
    );

final StreamProvider<List<Playlist>> playlistsProvider =
    StreamProvider<List<Playlist>>(
      (Ref ref) => ref.watch(playlistRepositoryProvider).watchAll(),
    );

/// 歌单 id → 曲目数（一条 GROUP BY，代替"每个歌单各 JOIN 一次"）。
final StreamProvider<Map<String, int>> playlistTrackCountsProvider =
    StreamProvider<Map<String, int>>(
      (Ref ref) => ref.watch(playlistRepositoryProvider).watchTrackCounts(),
    );

/// 侧栏搜索框的输入（未防抖）；空串表示不搜索。
///
/// 输入框、清除按钮、页面标题都用它，所以敲键立刻有反应；
/// 真正查库的是 [debouncedSearchQueryProvider]。
class SearchQueryController extends Notifier<String> {
  @override
  String build() => '';

  /// 写入"即时文本"，并把防抖查询一起转发。
  ///
  /// 两个入口（桌面侧栏、移动端搜索框）都要同时更新这两份状态，少写一行就会变成
  /// "每敲一个键查一次全库"或"搜不到"；把转发收在这里，调用方只认一个 API。
  void set(String value) {
    state = value;
    ref.read(debouncedSearchQueryProvider.notifier).set(value);
  }

  void clear() {
    state = '';
    ref.read(debouncedSearchQueryProvider.notifier).clear();
  }
}

final NotifierProvider<SearchQueryController, String> searchQueryProvider =
    NotifierProvider<SearchQueryController, String>(SearchQueryController.new);

/// 搜索防抖窗口：输入停顿这么久才真正查库。
///
/// 侧栏是「每敲一个字符 set 一次」，直接查库等于每个字符跑一次整库 LIKE；
/// 250ms 是 `docs/UX_REDESIGN.md` §5.5 的统一口径（全应用一个值），
/// 快速输入时只有最后一帧会落到数据库。
const Duration searchDebounce = Duration(milliseconds: 250);

/// 最近搜索词上限：内存 ≤ 10 条，**不落库**（`docs/UX_REDESIGN.md` §4.2）。
const int recentSearchLimit = 10;

/// 最近搜索词（进程内）：搜索页空查询时给「刚才找过什么」。
class RecentSearchesController extends Notifier<List<String>> {
  @override
  List<String> build() => const <String>[];

  /// 记一次搜索；重复词提前、超出上限截断。
  void remember(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return;
    }
    state = <String>[
      trimmed,
      for (final String item in state)
        if (item != trimmed) item,
    ].take(recentSearchLimit).toList(growable: false);
  }

  void clear() => state = const <String>[];
}

final NotifierProvider<RecentSearchesController, List<String>>
recentSearchesProvider =
    NotifierProvider<RecentSearchesController, List<String>>(
      RecentSearchesController.new,
    );

/// 防抖后的查询词；曲库查询只认它。
class DebouncedSearchQueryController extends Notifier<String> {
  Timer? _timer;

  @override
  String build() {
    // 定时器必须随 provider 一起释放，否则测试里会留下 pending timer。
    ref.onDispose(() => _timer?.cancel());
    return '';
  }

  void set(String value) {
    _timer?.cancel();
    if (value.trim().isEmpty) {
      // 清空/只剩空白时不必等防抖：空查询走全库列表，
      // 立即生效才不会先闪一下「搜不到」再回到全库。
      state = '';
      return;
    }
    _timer = Timer(searchDebounce, () => state = value);
  }

  void clear() {
    _timer?.cancel();
    state = '';
  }
}

final NotifierProvider<DebouncedSearchQueryController, String>
debouncedSearchQueryProvider =
    NotifierProvider<DebouncedSearchQueryController, String>(
      DebouncedSearchQueryController.new,
    );

/// 「最近添加」：按 dateAdded 倒序取前 100，并随入库实时刷新。
final StreamProvider<List<Track>> recentlyAddedProvider =
    StreamProvider<List<Track>>((Ref ref) {
      return ref.watch(trackRepositoryProvider).watchRecentlyAdded();
    });

/// 某个来源下的曲目。
final tracksOfSourceProvider = StreamProvider.family<List<Track>, String>((
  Ref ref,
  String sourceId,
) {
  return ref.watch(trackRepositoryProvider).watchBySource(sourceId);
});

/// 某个播放列表的曲目（保持保存的顺序）。
final playlistTracksProvider = FutureProvider.family<List<Track>, String>((
  Ref ref,
  String playlistId,
) async {
  return ref.watch(playlistRepositoryProvider).tracksOf(playlistId);
});

/// 某位艺术家的曲目（专辑 → 碟号 → 曲序），随曲库实时刷新。
final artistTracksProvider = StreamProvider.family<List<Track>, String>((
  Ref ref,
  String artist,
) {
  return ref.watch(trackRepositoryProvider).watchAll().map((List<Track> all) {
    final List<Track> mine = all
        .where((Track track) => track.artist == artist)
        .toList();
    sortForAlbum(mine);
    return mine;
  });
});

/// 某个专辑的曲目（按 `artist + album` 归并，与 [albumsProvider] 口径一致）。
final albumTracksProvider = StreamProvider.family<List<Track>, AlbumKey>((
  Ref ref,
  AlbumKey key,
) {
  return ref.watch(trackRepositoryProvider).watchAll().map((List<Track> all) {
    final List<Track> mine = all
        .where(
          (Track track) =>
              track.album == key.album && track.artist == key.artist,
        )
        .toList();
    sortForAlbum(mine);
    return mine;
  });
});

/// 专辑/曲目列表统一排序：碟号 → 曲序 → 标题（与旧版 `LibraryGrouping.sortForAlbum` 一致）。
void sortForAlbum(List<Track> tracks) {
  tracks.sort((Track a, Track b) {
    final int byDisc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
    if (byDisc != 0) {
      return byDisc;
    }
    final int byTrack = (a.trackNumber ?? 1 << 30).compareTo(
      b.trackNumber ?? 1 << 30,
    );
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
final trackByIdProvider = StreamProvider.family<Track?, String>((
  Ref ref,
  String id,
) {
  return ref.watch(trackRepositoryProvider).watchById(id);
});

/// 按来源 id 取一条来源记录（播放解析、来源页都用它）。
///
/// 用流而不是一次性的 Future：同步可能在来源列表那边发起，正开着的来源详情页
/// 必须立刻显示新统计，而不是把旧的「3 首 · 新增 1 / 移除 0」一直挂到杀进程重进。
final sourceByIdProvider = StreamProvider.family<MusicSource?, String>((
  Ref ref,
  String id,
) {
  return ref.watch(sourceRepositoryProvider).watchById(id);
});

// ---------------------------------------------------------------- 抓取与播放

final Provider<MetadataEnricher> metadataEnricherProvider =
    Provider<MetadataEnricher>((Ref ref) {
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

/// 「自动补全整个会话只跑一次」的进程内标记。
///
/// provider 本身是 keepAlive 的，曲库页刷新时还会 invalidate；没有这个标记的话，
/// 每次重挂载/刷新都会重新遍历整库、对每首缺元数据的歌串行打一遍网络。
class _SessionOnceGuard {
  bool _used = false;

  /// 第一次返回 true，之后恒为 false。
  bool take() {
    if (_used) {
      return false;
    }
    _used = true;
    return true;
  }
}

/// 用 provider 持有标记，测试里可以 override 掉以恢复「每次都会跑」的行为。
final Provider<_SessionOnceGuard> _autoEnrichmentGuardProvider =
    Provider<_SessionOnceGuard>((Ref ref) => _SessionOnceGuard());

/// 首次打开曲库时自动遍历缺失元数据的歌曲，与原生 macOS 的 onAppear 行为一致。
///
/// 一次最多补 [autoEnrichmentLimit] 首：缺时长的曲目（夸克 / WebDAV 整库都没有时长）
/// 会让待办从几十条涨到几百条，串行跑完既久又是对上游的一轮密集请求。
/// 剩下的留给下次会话或用户在来源页手动「补全」。
final FutureProvider<void> autoLibraryEnrichmentProvider = FutureProvider<void>(
  (Ref ref) async {
    if (!ref.watch(_autoEnrichmentGuardProvider).take()) {
      // 本会话已经跑过一次：重挂载/刷新直接复用，不再重打网络。
      return;
    }
    final List<Track> pending = (await ref.watch(trackRepositoryProvider).all())
        .where(trackNeedsEnrichment)
        .toList();
    if (pending.isEmpty) {
      // 没有缺失元数据的歌：连 service 都不用建（它持有各家网络客户端）。
      return;
    }
    // 封面 → 歌词 → 时长：前者是列表里最显眼的缺失，后者只影响一个数字。
    pending.sort(
      (Track a, Track b) =>
          _enrichmentPriority(a).compareTo(_enrichmentPriority(b)),
    );
    final List<Track> batch = pending
        .take(autoEnrichmentLimit)
        .toList(growable: false);
    final LibraryEnrichmentService service = ref.watch(
      enrichmentServiceProvider,
    );
    bool cancelled = false;
    ref.onDispose(() => cancelled = true);
    for (final Track track in batch) {
      if (cancelled) {
        // provider 已释放（页面离开 / 容器销毁）：剩下的曲目不再发请求。
        return;
      }
      try {
        await service.enrichTrack(track);
      } on Object {
        // 单曲失败不阻断后续歌曲；抓取本身是尽力而为。
      }
    }
  },
);

/// 自动补全的每会话上限。
const int autoEnrichmentLimit = 60;

/// 越小越先补：先补列表里看得见的（封面），再补歌词，最后补时长。
int _enrichmentPriority(Track track) {
  if (track.coverArtPath == null && track.coverArtUrl == null) {
    return 0;
  }
  if (track.lyrics == null || track.lyrics!.isEmpty) {
    return 1;
  }
  return 2;
}

final Provider<ArtistAvatarStore> artistAvatarStoreProvider =
    Provider<ArtistAvatarStore>(
      (Ref ref) => ArtistAvatarStore(lookup: NetEaseProvider()),
    );

/// 曲目 → 可播放条目（含远端来源的鉴权头）。
final Provider<TrackResolver> trackResolverProvider = Provider<TrackResolver>(
  (Ref ref) => TrackResolver(ref),
);

/// 播放控制器；持有 system audio handler。
final NotifierProvider<PlaybackController, PlaybackSnapshot> playbackProvider =
    NotifierProvider<PlaybackController, PlaybackSnapshot>(
      PlaybackController.new,
    );

/// 由 `main.dart` 在 `ProviderScope.overrides` 中注入的音频处理器。
final Provider<TingyuAudioHandler> audioHandlerProvider =
    Provider<TingyuAudioHandler>(
      (Ref ref) => throw UnimplementedError(
        'audioHandlerProvider 必须在 ProviderScope.overrides 中注入',
      ),
    );

final Provider<SecureStore> secureStoreProvider = Provider<SecureStore>(
  (Ref ref) => SecureStore(),
);

final Provider<AISettingsRepository> aiSettingsRepositoryProvider =
    Provider<AISettingsRepository>(
      (Ref ref) => AISettingsRepository(store: ref.watch(secureStoreProvider)),
    );

class AISettingsNotifier extends AsyncNotifier<AISettings> {
  @override
  Future<AISettings> build() {
    return ref.watch(aiSettingsRepositoryProvider).load();
  }

  Future<void> save(AISettings settings) async {
    state = AsyncValue<AISettings>.data(settings);
    await ref.read(aiSettingsRepositoryProvider).save(settings);
  }
}

final AsyncNotifierProvider<AISettingsNotifier, AISettings> aiSettingsProvider =
    AsyncNotifierProvider<AISettingsNotifier, AISettings>(
      AISettingsNotifier.new,
    );

final Provider<AILibraryRefactorService> aiLibraryRefactorServiceProvider =
    Provider<AILibraryRefactorService>((Ref ref) {
      final AISettings settings =
          ref.watch(aiSettingsProvider).value ?? const AISettings();
      return AILibraryRefactorService(
        tracks: ref.watch(trackRepositoryProvider),
        client: AIClient(
          baseUrl: settings.baseUrl,
          model: settings.model,
          apiKey: settings.apiKey,
        ),
        enrichmentService: ref.watch(enrichmentServiceProvider),
      );
    });

/// 静音曲目时用的占位专辑值（与旧版一致）。
const Set<String> placeholderAlbumNames = <String>{'未知专辑', '夸克曲库', 'WebDAV 曲库'};

/// 判断专辑名是否仍是占位值。
bool isPlaceholderAlbum(String album) => placeholderAlbumNames.contains(album);

bool trackNeedsEnrichment(Track track) =>
    track.coverArtPath == null ||
    (track.lyrics == null || track.lyrics!.isEmpty) ||
    track.artist == '未知艺术家' ||
    isPlaceholderAlbum(track.album) ||
    // 时长为 0：夸克 / WebDAV 的目录接口不报时长，搜索来源的候选里带 ——
    // 不补的话整库都显示 `--:--`（播放时也能补，但那只覆盖听过的歌）。
    track.duration <= 0;

// ------------------------------------------------------ 分页曲库与搜索（B4）

/// 曲库列表页大小：约两屏，滚动到底再取下一页。
const int libraryPageSize = 40;

/// 搜索「全部」视图里每组先露出的条数（精确总数另外给）。
const int searchGroupPreviewSize = 5;

/// 曲库内容指纹：分页查询是 `Future`（不是 Stream），靠它感知「库变了」。
///
/// 长度 / 收藏数 / 最新入库时间任一变化都说明列表要重取。做成一个 int 是为了
/// 让分页 provider 只要 `watch` 一下就自动刷新，不必在每个写库点手动 invalidate。
final Provider<int> libraryFingerprintProvider = Provider<int>((Ref ref) {
  final List<Track> tracks =
      ref.watch(allTracksProvider).value ?? const <Track>[];
  int favorites = 0;
  DateTime? latest;
  for (final Track track in tracks) {
    if (track.isFavorite) {
      favorites++;
    }
    if (latest == null || track.dateAdded.isAfter(latest)) {
      latest = track.dateAdded;
    }
  }
  return Object.hash(tracks.length, favorites, latest);
});

/// 曲库单页取数：键含完整查询条件与偏移，值相等即复用。
final libraryTracksPageProvider =
    FutureProvider.family<SearchPageResult<Track>, LibraryPageRequest>((
      Ref ref,
      LibraryPageRequest request,
    ) {
      // 指纹变化 → 本页自动重取。
      ref.watch(libraryFingerprintProvider);
      return ref
          .watch(trackRepositoryProvider)
          .listTracksPaged(
            query: request.query.text,
            favoritesOnly: request.query.favoritesOnly,
            sourceId: request.query.sourceId,
            sort: request.query.sort,
            ascending: request.query.ascending,
            offset: request.offset,
            limit: request.limit,
          );
    });

/// 搜索页四组分页（「查看全部」后按 40 条一页继续取）。
final searchSongsPageProvider =
    FutureProvider.family<SearchPageResult<Track>, SearchPageRequest>((
      Ref ref,
      SearchPageRequest request,
    ) {
      ref.watch(libraryFingerprintProvider);
      return ref
          .watch(trackRepositoryProvider)
          .searchTracksPaged(
            request.text,
            offset: request.offset,
            limit: request.limit,
          );
    });

final searchAlbumsPageProvider =
    FutureProvider.family<SearchPageResult<AlbumSummary>, SearchPageRequest>((
      Ref ref,
      SearchPageRequest request,
    ) {
      ref.watch(libraryFingerprintProvider);
      return ref
          .watch(trackRepositoryProvider)
          .searchAlbumsPaged(
            request.text,
            offset: request.offset,
            limit: request.limit,
          );
    });

final searchArtistsPageProvider =
    FutureProvider.family<SearchPageResult<ArtistSummary>, SearchPageRequest>((
      Ref ref,
      SearchPageRequest request,
    ) {
      ref.watch(libraryFingerprintProvider);
      return ref
          .watch(trackRepositoryProvider)
          .searchArtistsPaged(
            request.text,
            offset: request.offset,
            limit: request.limit,
          );
    });

final searchPlaylistsPageProvider =
    FutureProvider.family<SearchPageResult<Playlist>, SearchPageRequest>((
      Ref ref,
      SearchPageRequest request,
    ) {
      ref.watch(libraryFingerprintProvider);
      return ref
          .watch(playlistRepositoryProvider)
          .searchByNamePaged(
            request.text,
            offset: request.offset,
            limit: request.limit,
          );
    });

/// 搜索「全部」视图：四组并行取前 [searchGroupPreviewSize] 条 + 精确总数。
///
/// 四路并行（record `.wait`）而不是串行 await：搜索延迟是这页唯一的性能指标。
final searchOverviewProvider = FutureProvider<SearchOverview>((Ref ref) async {
  final String query = ref.watch(debouncedSearchQueryProvider).trim();
  if (query.isEmpty) {
    return SearchOverview.empty;
  }
  ref.watch(libraryFingerprintProvider);
  final TrackRepository tracks = ref.watch(trackRepositoryProvider);
  final PlaylistRepository playlists = ref.watch(playlistRepositoryProvider);
  final (
    SearchPageResult<Track> songs,
    SearchPageResult<AlbumSummary> albums,
    SearchPageResult<ArtistSummary> artists,
    SearchPageResult<Playlist> playlistHits,
  ) = await (
    tracks.searchTracksPaged(query, limit: searchGroupPreviewSize),
    tracks.searchAlbumsPaged(query, limit: searchGroupPreviewSize),
    tracks.searchArtistsPaged(query, limit: searchGroupPreviewSize),
    playlists.searchByNamePaged(query, limit: searchGroupPreviewSize),
  ).wait;
  return SearchOverview(
    songs: SearchGroup<Track>(items: songs.items, total: songs.total),
    albums: SearchGroup<AlbumSummary>(items: albums.items, total: albums.total),
    artists: SearchGroup<ArtistSummary>(
      items: artists.items,
      total: artists.total,
    ),
    playlists: SearchGroup<Playlist>(
      items: playlistHits.items,
      total: playlistHits.total,
    ),
  );
});

/// 命令面板空查询时的「最近添加」提示。
final FutureProvider<List<Track>> paletteRecentProvider =
    FutureProvider<List<Track>>((Ref ref) async {
      ref.watch(libraryFingerprintProvider);
      final SearchPageResult<Track> page = await ref
          .watch(trackRepositoryProvider)
          .recentlyAddedPaged(limit: searchGroupPreviewSize);
      return page.items;
    });

/// 应用数据目录（数据库、封面缓存、偏好文件都在这儿）。
///
/// 做成 provider 而不是在页面里现调 `getApplicationSupportDirectory()`：
/// 配置页每次重建都会重问一次系统目录，而且测试没法替换（平台通道在
/// widget 测试里没有实现，直接抛 MissingPluginException）。
final FutureProvider<Directory> dataDirectoryProvider =
    FutureProvider<Directory>((Ref ref) => getApplicationSupportDirectory());
