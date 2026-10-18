import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/library_query.dart';
import 'package:tingyu/data/models/library_summaries.dart';
import 'package:tingyu/data/models/search_overview.dart';
import 'package:tingyu/data/models/search_page_result.dart';
import 'package:tingyu/design/components/track.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/features/library/library_page.dart';
import 'package:tingyu/features/search/search_page.dart';
import 'package:tingyu/features/shared/playback_track_row.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'support/pump.dart';

/// 曲目行的「正在播放」高亮要读播放状态，而真 handler 会去起音频服务；
/// 这里给一个什么都不做的引擎，与 navigation_gesture_test 的做法一致。
final class _SilentEngine extends PlaybackEngineBase {
  @override
  String get name => 'silent';
  @override
  List<PlaybackItem> get items => const <PlaybackItem>[];
  @override
  PlaybackItem? get currentItem => null;
  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {}
  @override
  Future<void> addToQueue(PlaybackItem item) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> skipToNext() async {}
  @override
  Future<void> skipToPrevious() async {}
  @override
  Future<void> dispose() async => closeSnapshotStream();
}

Track _track(String id, String title) => Track(
  id: id,
  sourceId: 'src-1',
  title: title,
  artist: '周杰伦',
  album: '叶惠美',
  duration: 200,
  fileFormat: 'mp3',
  filePathOrUrl: '/music/$id.mp3',
  fileSize: 1000,
  isFavorite: false,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

const SearchPageRequest _overviewKey = SearchPageRequest(
  text: '晴天',
  limit: libraryPageSize,
);

/// 搜索入口从「曲库页内嵌搜索框」搬到独立的 `/search`（`docs/UX_REDESIGN.md` §3.2）：
/// compact 由搜索 Tab 进入、页面自带输入框并自动聚焦；桌面只在侧栏有输入框，
/// 曲库页本身不再出现任何搜索框。这几条用例锁住这两件事与防抖节奏。
///
/// 查询本身（真实 COUNT / 分页）由仓库层测试覆盖；这里只喂结果，验证页面怎么用。
void main() {
  Future<GoRouter> pumpSearch(
    WidgetTester tester, {
    SearchOverview? overview,
    SearchPageResult<Track>? songs,
    Size size = const Size(412, 915),
  }) async {
    final GoRouter router = GoRouter(
      initialLocation: '/search',
      routes: <RouteBase>[
        GoRoute(
          path: '/search',
          builder: (_, _) => const Scaffold(body: SearchPage()),
        ),
        GoRoute(
          path: '/library/songs',
          builder: (_, _) => const Scaffold(body: LibraryPage()),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
          audioHandlerProvider.overrideWithValue(
            TingyuAudioHandler(_SilentEngine()),
          ),
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
          ),
          playlistTrackCountsProvider.overrideWithValue(
            const AsyncValue<Map<String, int>>.data(<String, int>{}),
          ),
          if (overview != null)
            searchOverviewProvider.overrideWith((Ref ref) async => overview),
          searchSongsPageProvider(_overviewKey).overrideWith(
            (Ref ref) async =>
                songs ??
                const SearchPageResult<Track>(items: <Track>[], total: 0),
          ),
        ],
        child: MaterialApp.router(
          theme: TyTheme.build(brightness: Brightness.light),
          routerConfig: router,
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: size),
            child: TyLayoutScope.forSize(
              size,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester, frames: 6);
    return router;
  }

  testWidgets('compact：搜索页给出输入框，输入进 URL 且查询走防抖', (WidgetTester tester) async {
    final GoRouter router = await pumpSearch(tester);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(SearchPage)),
    );
    expect(find.byType(TextField), findsOneWidget, reason: 'compact 首页自带输入框');

    await tester.enterText(find.byType(TextField), '晴天');
    await tester.pump();

    expect(container.read(searchQueryProvider), '晴天');
    expect(
      router.routeInformationProvider.value.uri.queryParameters['q'],
      '晴天',
    );
    // 防抖：立刻查库会把每个按键都变成一次全库 LIKE。
    expect(container.read(debouncedSearchQueryProvider), isEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(debouncedSearchQueryProvider), '晴天');
    await unmountApp(tester);
  });

  testWidgets('compact：命中的曲目真的出现在页面上', (WidgetTester tester) async {
    final Track hit = _track('t1', '晴天');
    final GoRouter router = await pumpSearch(
      tester,
      overview: SearchOverview(
        songs: SearchGroup<Track>(items: <Track>[hit], total: 1),
        albums: const SearchGroup<AlbumSummary>(
          items: <AlbumSummary>[],
          total: 0,
        ),
        artists: const SearchGroup<ArtistSummary>(
          items: <ArtistSummary>[],
          total: 0,
        ),
        playlists: const SearchGroup<Playlist>(items: <Playlist>[], total: 0),
      ),
    );
    expect(router.routeInformationProvider.value.uri.path, '/search');

    await tester.enterText(find.byType(TextField), '晴天');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(
      tester,
      () => find.byType(PlaybackTrackRow).evaluate().isNotEmpty,
    );
    expect(find.text('晴天'), findsWidgets);
    await unmountApp(tester);
  });

  testWidgets('compact：清空按钮同时清掉输入、查询条件与 URL 参数', (WidgetTester tester) async {
    final GoRouter router = await pumpSearch(tester);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(SearchPage)),
    );

    await tester.enterText(find.byType(TextField), '晴天');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, () => find.byTooltip('清除').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('清除'));
    await pumpFrames(tester, frames: 6);

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );
    expect(container.read(searchQueryProvider), isEmpty);
    expect(container.read(debouncedSearchQueryProvider), isEmpty);
    expect(
      router.routeInformationProvider.value.uri.queryParameters['q'],
      isNull,
    );
    await unmountApp(tester);
  });

  testWidgets('桌面：曲库页不出现搜索框（搜索入口在侧栏）', (WidgetTester tester) async {
    final List<Track> tracks = <Track>[_track('t1', '晴天')];
    final GoRouter router = GoRouter(
      initialLocation: '/library/songs',
      routes: <RouteBase>[
        GoRoute(
          path: '/library/songs',
          builder: (_, _) => const Scaffold(body: LibraryPage()),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
          audioHandlerProvider.overrideWithValue(
            TingyuAudioHandler(_SilentEngine()),
          ),
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
          ),
          libraryTracksPageProvider(
            const LibraryPageRequest(
              query: LibraryQuery(),
              limit: libraryPageSize,
            ),
          ).overrideWith(
            (Ref ref) async =>
                SearchPageResult<Track>(items: tracks, total: tracks.length),
          ),
        ],
        child: MaterialApp.router(
          theme: TyTheme.build(brightness: Brightness.light),
          routerConfig: router,
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: const Size(1440, 900)),
            child: TyLayoutScope.forSize(
              const Size(1440, 900),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await pumpUntil(
      tester,
      () => find.byType(TyTrackRow).evaluate().isNotEmpty,
    );

    expect(find.byType(LibraryPage), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await unmountApp(tester);
  });

  testWidgets('分组结果给真实总数，超过 5 条时给「查看全部」', (WidgetTester tester) async {
    final List<Track> hits = <Track>[
      for (int i = 0; i < 9; i++) _track('t$i', '晴天 $i'),
    ];
    final GoRouter router = await pumpSearch(
      tester,
      overview: SearchOverview(
        songs: SearchGroup<Track>(
          items: hits.take(searchGroupPreviewSize).toList(),
          total: hits.length,
        ),
        albums: const SearchGroup<AlbumSummary>(
          items: <AlbumSummary>[],
          total: 0,
        ),
        artists: const SearchGroup<ArtistSummary>(
          items: <ArtistSummary>[],
          total: 0,
        ),
        playlists: const SearchGroup<Playlist>(items: <Playlist>[], total: 0),
      ),
      songs: SearchPageResult<Track>(items: hits, total: hits.length),
    );

    await tester.enterText(find.byType(TextField), '晴天');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, () => find.text('查看全部').evaluate().isNotEmpty);

    // 真实 COUNT（9 条命中）而不是「本页长度」；组内只露 5 条，其余靠「查看全部」。
    expect(find.text('歌曲'), findsWidgets);
    expect(find.text('9'), findsOneWidget, reason: '组头显示真实命中总数');
    expect(
      find.byType(PlaybackTrackRow),
      findsNWidgets(searchGroupPreviewSize),
    );

    await tester.tap(find.text('查看全部'));
    await pumpFrames(tester, frames: 6);
    expect(
      router.routeInformationProvider.value.uri.queryParameters['scope'],
      'songs',
    );
    // 分范围视图列出全部命中（不再有 200 条硬上限）。
    await pumpUntil(
      tester,
      () => find.byType(PlaybackTrackRow).evaluate().length == hits.length,
    );
    await unmountApp(tester);
  });
}
