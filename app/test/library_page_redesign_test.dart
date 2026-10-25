import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/library_query.dart';
import 'package:tingyu/data/models/search_page_result.dart';
import 'package:tingyu/design/components/buttons.dart';
import 'package:tingyu/design/components/chips.dart';
import 'package:tingyu/design/components/cover.dart';
import 'package:tingyu/design/components/track.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/features/library/library_page.dart';
import 'package:tingyu/features/library/library_table_columns.dart';
import 'package:tingyu/features/library/library_view_state.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'support/page_harness.dart';
import 'support/pump.dart';

void main() {
  const List<MusicSource> sources = <MusicSource>[
    MusicSource(
      id: 'src-local',
      kind: 'local',
      name: '本地文件',
      trackCount: 2,
      syncStatus: '已完成',
    ),
    MusicSource(
      id: 'src-webdav',
      kind: 'webdav',
      name: 'WebDAV',
      trackCount: 1,
      syncStatus: '已完成',
    ),
  ];

  final List<Track> tracks = <Track>[
    goldenTrack(
      't1',
      '海风经过',
    ).copyWith(sourceId: 'src-local', artist: '林间回声', album: '潮汐手记'),
    goldenTrack(
      't2',
      '直到海岸线的最后一束光都熄灭，仍然想把这句标题完整读完',
    ).copyWith(sourceId: 'src-webdav', artist: '林间回声', album: '潮汐手记'),
    goldenTrack(
      't3',
      '无封面的练习',
      duration: 171,
    ).copyWith(sourceId: 'src-local', artist: '听屿试录', album: '练习录音'),
  ];

  List<Override> overridesFor(_RecordingPlayback playback) => <Override>[
    sourcesProvider.overrideWithValue(
      const AsyncValue<List<MusicSource>>.data(sources),
    ),
    playbackProvider.overrideWith(() => playback),
    libraryTracksPageProvider(
      const LibraryPageRequest(query: LibraryQuery(), limit: libraryPageSize),
    ).overrideWith(
      (Ref ref) async =>
          SearchPageResult<Track>(items: tracks, total: tracks.length),
    ),
  ];

  test('桌面列策略严格遵循 P2 的 864 / 708 / 560 / 460 边界', () {
    expect(LibraryTableColumns.forContentWidth(864), LibraryTableColumns.full);
    expect(
      LibraryTableColumns.forContentWidth(863),
      LibraryTableColumns.withoutAlbum,
    );
    expect(
      LibraryTableColumns.forContentWidth(708),
      LibraryTableColumns.withoutAlbum,
    );
    expect(
      LibraryTableColumns.forContentWidth(707),
      LibraryTableColumns.withoutArtist,
    );
    expect(
      LibraryTableColumns.forContentWidth(560),
      LibraryTableColumns.withoutArtist,
    );
    expect(
      LibraryTableColumns.forContentWidth(559),
      LibraryTableColumns.withoutSource,
    );
    expect(
      LibraryTableColumns.forContentWidth(460),
      LibraryTableColumns.withoutSource,
    );
    expect(
      LibraryTableColumns.forContentWidth(459),
      LibraryTableColumns.single,
    );
  });

  testWidgets('桌面曲库显示来源，播放全部与单曲点击都走原播放控制器', (WidgetTester tester) async {
    final _RecordingPlayback playback = _RecordingPlayback(tracks);
    await pumpPage(
      tester,
      const Scaffold(body: LibraryPage()),
      PageHarness(
        size: const Size(1280, 800),
        brightness: Brightness.light,
        overrides: overridesFor(playback),
      ),
    );

    expect(find.text('曲库'), findsOneWidget);
    expect(find.text('来源'), findsOneWidget);
    expect(find.text('本地文件'), findsNWidgets(2));
    expect(find.byType(TyTrackTable), findsOneWidget);

    await tester.tap(find.text('播放全部'));
    await tester.pump();
    expect(playback.lastTracks, tracks);
    expect(playback.lastStartIndex, 0);

    playback.lastTracks = null;
    playback.lastStartIndex = null;
    await tester.tap(find.byKey(const ValueKey<String>('library-t1')));
    await tester.pump();
    expect(playback.lastTracks, tracks);
    expect(playback.lastStartIndex, 0);
  });

  testWidgets('播放全部会补齐筛选后的所有分页', (WidgetTester tester) async {
    final _RecordingPlayback playback = _RecordingPlayback(tracks);
    final Completer<SearchPageResult<Track>> remaining =
        Completer<SearchPageResult<Track>>();
    bool requestedRemainingPage = false;

    await pumpPage(
      tester,
      const Scaffold(body: LibraryPage()),
      PageHarness(
        size: const Size(1280, 800),
        brightness: Brightness.light,
        overrides: <Override>[
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(sources),
          ),
          playbackProvider.overrideWith(() => playback),
          libraryTracksPageProvider(
            const LibraryPageRequest(
              query: LibraryQuery(),
              limit: libraryPageSize,
            ),
          ).overrideWith(
            (Ref ref) async => SearchPageResult<Track>(
              items: tracks.take(1).toList(),
              total: tracks.length,
            ),
          ),
          libraryTracksPageProvider(
            const LibraryPageRequest(
              query: LibraryQuery(),
              offset: libraryPageSize,
              limit: libraryPageSize,
            ),
          ).overrideWith((Ref ref) {
            requestedRemainingPage = true;
            return remaining.future;
          }),
        ],
      ),
    );

    await tester.tap(find.text('播放全部'));
    await tester.pump();
    await tester.pump();

    expect(requestedRemainingPage, isTrue);
    expect(find.text('正在准备…'), findsOneWidget);
    expect(playback.lastTracks, isNull);

    remaining.complete(
      SearchPageResult<Track>(
        items: tracks.skip(1).toList(),
        total: tracks.length,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(playback.lastTracks, tracks);
    expect(playback.lastStartIndex, 0);
    expect(find.text('播放全部'), findsOneWidget);
  });

  testWidgets('手机曲库使用双行标题，200% 字号收起筛选并保持可操作', (WidgetTester tester) async {
    final _RecordingPlayback playback = _RecordingPlayback(tracks);
    await pumpPage(
      tester,
      const Scaffold(body: LibraryPage()),
      PageHarness(
        size: const Size(390, 844),
        brightness: Brightness.light,
        textScale: 2,
        overrides: overridesFor(playback),
      ),
    );

    expect(find.byType(TyTrackList), findsOneWidget);
    // P2：默认正文不重复铺开专辑与来源；放大字号时收进组合筛选菜单。
    expect(find.text('林间回声'), findsWidgets);
    expect(find.textContaining('潮汐手记'), findsNothing);
    expect(find.textContaining('本地文件'), findsNothing);
    expect(find.text('筛选与排序'), findsOneWidget);
    final Text title = tester.widget<Text>(
      find.textContaining('直到海岸线的最后一束光').first,
    );
    expect(title.maxLines, 2);
    final TyCover cover = tester.widget<TyCover>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('library-t1')),
            matching: find.byType(TyCover),
          )
          .first,
    );
    expect(cover.size, 56);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('library-t2'))).height,
      greaterThanOrEqualTo(120),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('筛选与排序'));
    await tester.pumpAndSettle();
    expect(find.text('按标题排序'), findsOneWidget);
    expect(find.text('升序'), findsOneWidget);
    expect(find.text('来源：本地文件'), findsOneWidget);
  });

  testWidgets('手机来源筛选结果只在副标题补充来源上下文', (WidgetTester tester) async {
    final _RecordingPlayback playback = _RecordingPlayback(tracks);
    await pumpPage(
      tester,
      const Scaffold(
        body: LibraryPage(view: LibraryViewState(sourceId: 'src-local')),
      ),
      PageHarness(
        size: const Size(390, 844),
        brightness: Brightness.light,
        overrides: <Override>[
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(sources),
          ),
          playbackProvider.overrideWith(() => playback),
          libraryTracksPageProvider(
            const LibraryPageRequest(
              query: LibraryQuery(sourceId: 'src-local'),
              limit: libraryPageSize,
            ),
          ).overrideWith(
            (Ref ref) async => SearchPageResult<Track>(
              items: <Track>[tracks[0], tracks[2]],
              total: 2,
            ),
          ),
        ],
      ),
    );

    expect(find.text('林间回声 · 本地文件'), findsOneWidget);
    expect(find.textContaining('潮汐手记'), findsNothing);
  });

  testWidgets('桌面列按内容宽度先收专辑，保留艺术家与来源', (WidgetTester tester) async {
    final _RecordingPlayback playback = _RecordingPlayback(tracks);

    await pumpPage(
      tester,
      const Scaffold(body: LibraryPage()),
      PageHarness(
        size: const Size(800, 800),
        brightness: Brightness.light,
        overrides: overridesFor(playback),
      ),
    );
    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsNothing);
    expect(find.text('来源'), findsOneWidget);

    await pumpPage(
      tester,
      const Scaffold(body: LibraryPage()),
      PageHarness(
        size: const Size(650, 800),
        brightness: Brightness.light,
        overrides: overridesFor(playback),
      ),
    );
    expect(find.text('艺术家'), findsNothing);
    expect(find.text('专辑'), findsNothing);
    expect(find.text('来源'), findsOneWidget);
    // 艺术家进入副标题，不会把来源列一起收掉。
    expect(find.text('本地文件'), findsNWidgets(2));
  });

  testWidgets('639/640 切换列表与表格，1024 内容宽度恢复完整来源列', (WidgetTester tester) async {
    final _RecordingPlayback playback = _RecordingPlayback(tracks);
    await pumpPage(
      tester,
      const Scaffold(body: LibraryPage()),
      PageHarness(
        size: const Size(639, 800),
        brightness: Brightness.dark,
        overrides: overridesFor(playback),
      ),
    );
    expect(find.byType(TyTrackList), findsOneWidget);
    expect(find.byType(TyTrackTable), findsNothing);

    await pumpPage(
      tester,
      const Scaffold(body: LibraryPage()),
      PageHarness(
        size: const Size(640, 800),
        brightness: Brightness.dark,
        overrides: overridesFor(playback),
      ),
    );
    expect(find.byType(TyTrackTable), findsOneWidget);
    expect(find.byType(TyTrackList), findsNothing);

    await pumpPage(
      tester,
      const Scaffold(body: LibraryPage()),
      PageHarness(
        size: const Size(1024, 800),
        brightness: Brightness.light,
        overrides: overridesFor(playback),
      ),
    );
    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('来源'), findsOneWidget);
  });

  testWidgets('手机分段导航与内联搜索仍使用原路由', (WidgetTester tester) async {
    final _RecordingPlayback playback = _RecordingPlayback(tracks);
    final GoRouter router = GoRouter(
      initialLocation: '/library/songs',
      routes: <RouteBase>[
        GoRoute(
          path: '/library/songs',
          builder: (BuildContext context, GoRouterState state) => Scaffold(
            body: LibraryPage(
              routePath: '/library/songs',
              view: LibraryViewState.fromQuery(state.uri.queryParameters),
            ),
          ),
        ),
        GoRoute(
          path: '/library/albums',
          builder: (_, _) => const Scaffold(body: Text('ALBUMS')),
        ),
        GoRoute(
          path: '/search',
          builder: (_, _) => const Scaffold(body: Text('SEARCH')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await _pumpInteractiveLibrary(
      tester,
      router: router,
      overrides: overridesFor(playback),
    );

    await tester.tap(
      find.descendant(
        of: find.byType(TySegmentedControl),
        matching: find.text('专辑'),
      ),
    );
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/library/albums');
    expect(find.text('ALBUMS'), findsOneWidget);

    router.go('/library/songs');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '海风');
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/search');
    expect(
      router.routeInformationProvider.value.uri.queryParameters['q'],
      '海风',
    );
  });

  testWidgets('空库与读取失败使用真实状态，不伪造曲目', (WidgetTester tester) async {
    final _RecordingPlayback playback = _RecordingPlayback(const <Track>[]);
    await pumpPage(
      tester,
      const Scaffold(body: LibraryPage()),
      PageHarness(
        size: const Size(1024, 800),
        brightness: Brightness.light,
        overrides: <Override>[
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(sources),
          ),
          playbackProvider.overrideWith(() => playback),
          libraryTracksPageProvider(
            const LibraryPageRequest(
              query: LibraryQuery(),
              limit: libraryPageSize,
            ),
          ).overrideWith(
            (Ref ref) async =>
                const SearchPageResult<Track>(items: <Track>[], total: 0),
          ),
        ],
      ),
    );
    expect(find.text('曲库是空的'), findsOneWidget);
    expect(
      tester.widget<TyIconAction>(find.byType(TyIconAction)).onPressed,
      isNull,
    );

    await unmountApp(tester);
    await pumpPage(
      tester,
      const Scaffold(body: LibraryPage()),
      PageHarness(
        size: const Size(1024, 800),
        brightness: Brightness.dark,
        overrides: <Override>[
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(sources),
          ),
          playbackProvider.overrideWith(() => playback),
          libraryTracksPageProvider(
            const LibraryPageRequest(
              query: LibraryQuery(),
              limit: libraryPageSize,
            ),
          ).overrideWith(
            (Ref ref) async => throw StateError('fixture failure'),
          ),
        ],
      ),
    );
    expect(find.text('曲库读取失败'), findsOneWidget);
    expect(find.text('无法读取曲库'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
  });
}

Future<void> _pumpInteractiveLibrary(
  WidgetTester tester, {
  required GoRouter router,
  required List<Override> overrides,
}) async {
  const Size size = Size(390, 844);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        formFactorProvider.overrideWithValue(FormFactor.compact),
        audioHandlerProvider.overrideWithValue(
          TingyuAudioHandler(SilentEngine()),
        ),
        autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
        ...overrides,
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: TyTheme.build(brightness: Brightness.light),
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: size,
            textScaler: TextScaler.noScaling,
            disableAnimations: true,
          ),
          child: TyLayoutScope.forSize(
            size,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester, frames: 8, step: const Duration(milliseconds: 20));
}

class _RecordingPlayback extends FakePlaybackController {
  _RecordingPlayback(super.tracks);

  List<Track>? lastTracks;
  int? lastStartIndex;

  @override
  Future<void> playTracks(
    List<Track> tracks, {
    int startIndex = 0,
    bool shuffle = false,
  }) async {
    lastTracks = tracks;
    lastStartIndex = startIndex;
  }
}
