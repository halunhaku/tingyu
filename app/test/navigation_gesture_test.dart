import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/router.dart';
import 'package:tingyu/app/theme.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/library_summaries.dart';
import 'package:tingyu/data/secure_store.dart';
import 'package:tingyu/features/albums/album_detail_page.dart';
import 'package:tingyu/features/albums/albums_page.dart';
import 'package:tingyu/features/library/library_page.dart';
import 'package:tingyu/features/settings/ai_settings_page.dart';
import 'package:tingyu/features/settings/settings_page.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

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

/// 曲库根页：覆盖掉所有会碰真实数据库 / 平台通道的 provider。
/// 只要有一个真实 drift 流留在树上，测试就会因「永不完成的 Future + 无限动画」
/// 卡死在 pumpAndSettle。`extra` 用于追加专辑聚合等场景化覆盖。
Widget _libraryApp(GoRouter router, {List<Track> tracks = const <Track>[]}) {
  return ProviderScope(
    overrides: [
      autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
      visibleTracksProvider.overrideWithValue(
        AsyncValue<List<Track>>.data(tracks),
      ),
      favoritesProvider.overrideWithValue(
        AsyncValue<List<Track>>.data(
          tracks.where((Track t) => t.isFavorite).toList(),
        ),
      ),
      recentlyAddedProvider.overrideWithValue(
        AsyncValue<List<Track>>.data(tracks),
      ),
      allTracksProvider.overrideWithValue(AsyncValue<List<Track>>.data(tracks)),
      sourcesProvider.overrideWithValue(
        const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
      ),
      playlistsProvider.overrideWithValue(
        const AsyncValue<List<Playlist>>.data(<Playlist>[]),
      ),
      artistsProvider.overrideWithValue(
        const AsyncValue<List<ArtistSummary>>.data(<ArtistSummary>[]),
      ),
      albumsProvider.overrideWithValue(
        const AsyncValue<List<AlbumSummary>>.data(<AlbumSummary>[]),
      ),
      secureStoreProvider.overrideWithValue(_FakeSecureStore()),
      audioHandlerProvider.overrideWithValue(
        TingyuAudioHandler(_DummyEngine()),
      ),
    ],
    child: MaterialApp.router(
      theme: buildTingyuTheme(Brightness.light),
      routerConfig: router,
    ),
  );
}

void main() {
  testWidgets('根 Tab 页面 canPop 为 false：系统返回手势直接回到桌面', (
    WidgetTester tester,
  ) async {
    final GoRouter router = createRouter(
      initialLocation: '/library',
      mobile: true,
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_libraryApp(router));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryPage), findsOneWidget);
    expect(router.canPop(), isFalse);

    // 四个底部 Tab 之间切换都走 go()，不往栈里压路由，
    // 因此任意 Tab 下系统返回都直接退出应用回到桌面。
    for (final String path in <String>[
      '/favorites',
      '/playlists',
      '/sources',
      '/library',
    ]) {
      router.go(path);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, path);
      expect(router.canPop(), isFalse, reason: '$path 不该能 pop');
    }
  });

  testWidgets('二级与三级页面 canPop 为 true，返回按钮逐级 pop 回上级', (
    WidgetTester tester,
  ) async {
    final GoRouter router = createRouter(
      initialLocation: '/library',
      mobile: true,
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_libraryApp(router));
    await tester.pumpAndSettle();

    // 一级：曲库（根），不能 pop
    expect(router.canPop(), isFalse);

    // 二级：设置页
    router.push('/settings');
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(router.canPop(), isTrue);

    // 三级：AI 识别页
    router.push('/settings/ai');
    await tester.pumpAndSettle();
    expect(find.byType(AISettingsPage), findsOneWidget);
    expect(router.canPop(), isTrue);

    // 返回按钮：三级 → 二级
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(AISettingsPage), findsNothing);
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(router.canPop(), isTrue);

    // 返回按钮：二级 → 根
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(router.canPop(), isFalse);
  });

  testWidgets('专辑列表 → 专辑详情逐级返回，且详情页自带返回按钮', (WidgetTester tester) async {
    final GoRouter router = createRouter(
      initialLocation: '/library',
      mobile: true,
    );
    addTearDown(router.dispose);

    final List<Track> sampleTracks = <Track>[
      _track('t1', '晴天', '叶惠美', '周杰伦'),
      _track('t2', '梯田', '叶惠美', '周杰伦'),
    ];
    const AlbumKey key = AlbumKey(artist: '周杰伦', album: '叶惠美');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
          visibleTracksProvider.overrideWithValue(
            AsyncValue<List<Track>>.data(sampleTracks),
          ),
          favoritesProvider.overrideWithValue(
            const AsyncValue<List<Track>>.data(<Track>[]),
          ),
          recentlyAddedProvider.overrideWithValue(
            AsyncValue<List<Track>>.data(sampleTracks),
          ),
          allTracksProvider.overrideWithValue(
            AsyncValue<List<Track>>.data(sampleTracks),
          ),
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
          ),
          playlistsProvider.overrideWithValue(
            const AsyncValue<List<Playlist>>.data(<Playlist>[]),
          ),
          artistsProvider.overrideWithValue(
            const AsyncValue<List<ArtistSummary>>.data(<ArtistSummary>[]),
          ),
          albumsProvider.overrideWithValue(
            const AsyncValue<List<AlbumSummary>>.data(<AlbumSummary>[
              AlbumSummary(
                album: '叶惠美',
                artist: '周杰伦',
                trackCount: 2,
                year: 2003,
              ),
            ]),
          ),
          albumTracksProvider(key)
              .overrideWithValue(AsyncValue<List<Track>>.data(sampleTracks)),
          secureStoreProvider.overrideWithValue(_FakeSecureStore()),
          audioHandlerProvider.overrideWithValue(
            TingyuAudioHandler(_DummyEngine()),
          ),
        ],
        child: MaterialApp.router(
          theme: buildTingyuTheme(Brightness.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 二级：专辑列表
    router.push('/albums');
    await tester.pumpAndSettle();
    expect(find.byType(AlbumsPage), findsOneWidget);
    expect(router.canPop(), isTrue);

    // 三级：专辑详情
    await tester.tap(find.text('叶惠美'));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumDetailPage), findsOneWidget);
    expect(router.canPop(), isTrue);

    // 详情页自带返回按钮：三级 → 二级
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumDetailPage), findsNothing);
    expect(find.byType(AlbumsPage), findsOneWidget);
    expect(router.canPop(), isTrue);

    // 二级 → 根
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(AlbumsPage), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(router.canPop(), isFalse);
  });
}
