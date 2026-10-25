import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/router.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/library_query.dart';
import 'package:tingyu/data/models/library_summaries.dart';
import 'package:tingyu/data/models/search_page_result.dart';
import 'package:tingyu/data/secure_store.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/features/albums/album_detail_page.dart';
import 'package:tingyu/features/albums/albums_page.dart';
import 'package:tingyu/features/library/library_page.dart';
import 'package:tingyu/features/settings/ai_settings_page.dart';
import 'package:tingyu/features/settings/settings_page.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'support/pump.dart';

/// 设置页会读 `aiSettingsProvider`，后者经 `secureStoreProvider` 落到真实
/// flutter_secure_storage 平台通道；测试里不替换它，Future 永远不完成。
class _FakeSecureStore extends SecureStore {
  final Map<String, String> _memory = <String, String>{};

  @override
  Future<void> write(String account, String value) async {
    _memory[account] = value;
  }

  @override
  Future<String?> read(String account) async {
    final String? value = _memory[account]?.trim();
    return (value != null && value.isNotEmpty) ? value : null;
  }

  @override
  Future<void> delete(String account) async {
    _memory.remove(account);
  }
}

final class _DummyEngine extends PlaybackEngineBase {
  @override
  String get name => 'dummy';
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

Track _track(String id, String title, String album, String artist) => Track(
  id: id,
  sourceId: 'src-1',
  title: title,
  artist: artist,
  album: album,
  duration: 200,
  fileFormat: 'mp3',
  filePathOrUrl: '/music/$id.mp3',
  fileSize: 1000,
  isFavorite: false,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

final List<Track> _sampleTracks = <Track>[
  _track('t1', '晴天', '叶惠美', '周杰伦'),
  _track('t2', '梯田', '叶惠美', '周杰伦'),
];

const AlbumKey _key = AlbumKey(artist: '周杰伦', album: '叶惠美');

const Size _phone = Size(412, 915);

/// 覆盖掉所有会碰真实数据库 / 平台通道的 provider。
///
/// 页面测试**不接真实 drift**：内存库会为流查询留下定时器，测试收尾时会被判成
/// 「树拆掉后仍有 pending timer」；同理，页面需要的分页查询也要显式给出。
List<Override> _overrides({List<Track> tracks = const <Track>[]}) => <Override>[
  autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
  allTracksProvider.overrideWithValue(AsyncValue<List<Track>>.data(tracks)),
  sourcesProvider.overrideWithValue(
    const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
  ),
  playlistsProvider.overrideWithValue(
    const AsyncValue<List<Playlist>>.data(<Playlist>[]),
  ),
  playlistTrackCountsProvider.overrideWithValue(
    const AsyncValue<Map<String, int>>.data(<String, int>{}),
  ),
  artistsProvider.overrideWithValue(
    const AsyncValue<List<ArtistSummary>>.data(<ArtistSummary>[]),
  ),
  albumsProvider.overrideWithValue(
    const AsyncValue<List<AlbumSummary>>.data(<AlbumSummary>[
      AlbumSummary(album: '叶惠美', artist: '周杰伦', trackCount: 2, year: 2003),
    ]),
  ),
  libraryTracksPageProvider(
    const LibraryPageRequest(query: LibraryQuery(), limit: libraryPageSize),
  ).overrideWith(
    (Ref ref) async =>
        SearchPageResult<Track>(items: tracks, total: tracks.length),
  ),
  albumTracksProvider(_key)
      .overrideWithValue(AsyncValue<List<Track>>.data(tracks)),
  secureStoreProvider.overrideWithValue(_FakeSecureStore()),
  audioHandlerProvider.overrideWithValue(TingyuAudioHandler(_DummyEngine())),
];

/// 挂载真实应用外壳（与 `main.dart` 同构的最小版）。
Future<void> pumpApp(
  WidgetTester tester,
  GoRouter router, {
  List<Track> tracks = const <Track>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(tracks: tracks),
      child: MaterialApp.router(
        theme: TyTheme.build(brightness: Brightness.light),
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: _phone),
          child: TyLayoutScope.forSize(
            _phone,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  Future<GoRouter> pumpRoot(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(_phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final GoRouter router = createRouter(initialLocation: '/library/songs');
    addTearDown(router.dispose);
    await pumpApp(tester, router, tracks: _sampleTracks);
    await pumpUntil(
      tester,
      () => find.byType(LibraryPage).evaluate().isNotEmpty,
    );
    return router;
  }

  testWidgets('根 Tab 页面 canPop 为 false：系统返回手势直接回到桌面', (
    WidgetTester tester,
  ) async {
    final GoRouter router = await pumpRoot(tester);

    expect(find.byType(LibraryPage), findsOneWidget);
    expect(router.canPop(), isFalse);

    // 根级目的地之间切换都走 go()，不往栈里压路由，
    // 因此任意 Tab 下系统返回都直接退出应用回到桌面。
    for (final String path in <String>[
      '/favorites',
      '/library/playlists',
      '/sources',
      '/settings',
      '/search',
      '/library/songs',
    ]) {
      router.go(path);
      await pumpFrames(tester, frames: 6);
      expect(router.routeInformationProvider.value.uri.path, path);
      expect(router.canPop(), isFalse, reason: '$path 不该能 pop');
    }
    await unmountApp(tester);
  });

  testWidgets('二级与三级页面 canPop 为 true，返回按钮逐级 pop 回上级', (
    WidgetTester tester,
  ) async {
    final GoRouter router = await pumpRoot(tester);

    // 一级：曲库（根），不能 pop
    expect(router.canPop(), isFalse);

    // 二级：设置页
    router.push('/settings');
    await pumpUntil(
      tester,
      () => find.byType(SettingsPage).evaluate().isNotEmpty,
    );
    expect(router.canPop(), isTrue);

    // 三级：AI 识别页
    router.push('/ai');
    await pumpUntil(
      tester,
      () => find.byType(AISettingsPage).evaluate().isNotEmpty,
    );
    expect(router.canPop(), isTrue);

    // 返回按钮：三级 → 二级
    await tester.tap(find.byTooltip('返回'));
    await pumpFrames(tester, frames: 10);
    expect(find.byType(AISettingsPage), findsNothing);
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(router.canPop(), isTrue);

    // 二级 → 根：设置是根级目的地（compact 下底部 Tab 仍在），因此退栈而不是找返回键。
    router.pop();
    await pumpFrames(tester, frames: 10);
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(router.canPop(), isFalse);
    await unmountApp(tester);
  });

  testWidgets('专辑列表 → 专辑详情逐级返回，且详情页自带返回按钮', (WidgetTester tester) async {
    final GoRouter router = await pumpRoot(tester);

    // 二级：专辑列表
    router.push('/library/albums');
    await pumpUntil(
      tester,
      () => find.byType(AlbumsPage).evaluate().isNotEmpty,
    );
    expect(router.canPop(), isTrue);

    // 三级：专辑详情
    await tester.tap(find.text('叶惠美'));
    await pumpUntil(
      tester,
      () => find.byType(AlbumDetailPage).evaluate().isNotEmpty,
    );
    expect(router.canPop(), isTrue);

    // 详情页自带返回按钮：三级 → 二级
    expect(find.byTooltip('返回'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await pumpFrames(tester, frames: 10);
    expect(find.byType(AlbumDetailPage), findsNothing);
    expect(find.byType(AlbumsPage), findsOneWidget);
    expect(router.canPop(), isTrue);

    // 二级 → 根
    router.pop();
    await pumpFrames(tester, frames: 10);
    expect(find.byType(AlbumsPage), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(router.canPop(), isFalse);
    await unmountApp(tester);
  });
}
