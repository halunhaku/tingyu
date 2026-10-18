@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:tingyu/app/preferences.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/library_query.dart';
import 'package:tingyu/data/models/library_summaries.dart';
import 'package:tingyu/data/models/search_overview.dart';
import 'package:tingyu/data/models/search_page_result.dart';
import 'package:tingyu/data/settings_store.dart';
import 'package:tingyu/features/albums/album_detail_page.dart';
import 'package:tingyu/features/albums/albums_page.dart';
import 'package:tingyu/features/library/library_page.dart';
import 'package:tingyu/features/shared/current_track.dart';
import 'package:tingyu/features/player/lyrics_panel.dart';
import 'package:tingyu/features/player/now_playing_page.dart';
import 'package:tingyu/features/player/queue_panel.dart';
import 'package:tingyu/features/search/search_page.dart';
import 'package:tingyu/features/settings/settings_page.dart';
import 'package:tingyu/features/sources/source_page.dart';
import 'package:tingyu/features/sources/sources_page.dart';

import '../support/page_harness.dart';

/// 核心页面的视觉回归（`DESIGN.md` §9 的 golden 约定）。
///
/// 只在本机（Windows 参考渲染）生成与校验：
/// `flutter test --run-skipped -t golden --update-goldens` 生成，
/// `flutter test --run-skipped -t golden` 校验。CI 用 `--exclude-tags golden` 排除。
///
/// 覆盖的是「版式会不会被后续改动弄坏」：留白、列宽、卡片尺寸、密度、深浅色。
/// 不做像素级文案断言——文案由普通 widget 测试负责。
void main() {
  const Size wide = Size(1280, 800);
  const Size phone = Size(390, 844);

  final List<Track> songs = <Track>[
    goldenTrack('t1', '晴天'),
    goldenTrack('t2', '以父之名', duration: 342),
    goldenTrack(
      't3',
      'This Is A Very Long English Track Title That Should Ellipsize',
      artist: 'A Very Long Artist Name Ensemble',
      duration: 401,
    ),
    goldenTrack('t4', '梯田', favorite: true),
    goldenTrack('t5', '东风破', duration: 315),
    goldenTrack('t6', '双刀', duration: 351),
  ];

  List<Override> libraryOverrides() => <Override>[
    sourcesProvider.overrideWithValue(
      const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
    ),
    libraryTracksPageProvider(
      const LibraryPageRequest(query: LibraryQuery(), limit: libraryPageSize),
    ).overrideWith(
      (Ref ref) async =>
          SearchPageResult<Track>(items: songs, total: songs.length),
    ),
  ];

  testWidgets('golden: 曲库·歌曲（expanded / dark）', (WidgetTester tester) async {
    await pumpRoutedPage(
      tester,
      const LibraryPage(),
      PageHarness(
        size: wide,
        brightness: Brightness.dark,
        overrides: libraryOverrides(),
      ),
      location: '/library/songs',
    );
    await expectLater(
      find.byType(LibraryPage),
      matchesGoldenFile('goldens/library-songs-expanded-dark.png'),
    );
  });

  testWidgets('golden: 曲库·歌曲（compact / light）', (WidgetTester tester) async {
    await pumpRoutedPage(
      tester,
      const LibraryPage(),
      PageHarness(
        size: phone,
        brightness: Brightness.light,
        overrides: libraryOverrides(),
      ),
      location: '/library/songs',
    );
    await expectLater(
      find.byType(LibraryPage),
      matchesGoldenFile('goldens/library-songs-compact-light.png'),
    );
  });

  testWidgets('golden: 专辑网格（expanded / light）', (WidgetTester tester) async {
    await pumpRoutedPage(
      tester,
      const AlbumsPage(),
      PageHarness(
        size: wide,
        brightness: Brightness.light,
        overrides: <Override>[
          albumsProvider.overrideWithValue(
            AsyncValue<List<AlbumSummary>>.data(<AlbumSummary>[
              const AlbumSummary(album: '叶惠美', artist: '周杰伦', trackCount: 11, year: 2003),
              const AlbumSummary(album: 'HQ', artist: '守月', trackCount: 1),
              const AlbumSummary(album: '太阳之子', artist: '周杰伦', trackCount: 12),
              const AlbumSummary(album: '我们拥有同一扇门吗', artist: '希先森', trackCount: 4),
            ]),
          ),
        ],
      ),
      location: '/library/albums',
    );
    await expectLater(
      find.byType(AlbumsPage),
      matchesGoldenFile('goldens/albums-expanded-light.png'),
    );
  });

  testWidgets('golden: 专辑详情（expanded / light）', (WidgetTester tester) async {
    const AlbumKey key = AlbumKey(artist: '周杰伦', album: '叶惠美');
    await pumpRoutedPage(
      tester,
      const AlbumDetailPage(albumKey: key),
      PageHarness(
        size: wide,
        brightness: Brightness.light,
        overrides: <Override>[
          albumsProvider.overrideWithValue(
            const AsyncValue<List<AlbumSummary>>.data(<AlbumSummary>[]),
          ),
          albumTracksProvider(
            key,
          ).overrideWithValue(AsyncValue<List<Track>>.data(songs.take(6).toList())),
        ],
      ),
      location: '/album/x',
    );
    await expectLater(
      find.byType(AlbumDetailPage),
      matchesGoldenFile('goldens/album-detail-expanded-light.png'),
    );
  });

  testWidgets('golden: 搜索·空查询（expanded / light）', (WidgetTester tester) async {
    await pumpRoutedPage(
      tester,
      const SearchPage(),
      PageHarness(size: wide, brightness: Brightness.light),
      location: '/search',
    );
    await expectLater(
      find.byType(SearchPage),
      matchesGoldenFile('goldens/search-idle-expanded-light.png'),
    );
  });

  testWidgets('golden: 搜索·有结果（expanded / dark）', (WidgetTester tester) async {
    await pumpRoutedPage(
      tester,
      const SearchPage(),
      PageHarness(
        size: wide,
        brightness: Brightness.dark,
        overrides: <Override>[
          searchQueryProvider.overrideWith(_FixedQuery.new),
          debouncedSearchQueryProvider.overrideWith(_FixedDebouncedQuery.new),
          playlistTrackCountsProvider.overrideWithValue(
            const AsyncValue<Map<String, int>>.data(<String, int>{}),
          ),
          searchOverviewProvider.overrideWith((Ref ref) async {
            return SearchOverview(
              songs: SearchGroup<Track>(
                items: songs.take(searchGroupPreviewSize).toList(),
                total: songs.length + 30,
              ),
              albums: const SearchGroup<AlbumSummary>(
                items: <AlbumSummary>[
                  AlbumSummary(album: '叶惠美', artist: '周杰伦', trackCount: 11),
                ],
                total: 1,
              ),
              artists: const SearchGroup<ArtistSummary>(
                items: <ArtistSummary>[ArtistSummary(name: '周杰伦', trackCount: 101)],
                total: 1,
              ),
              playlists: const SearchGroup<Playlist>(
                items: <Playlist>[],
                total: 0,
              ),
            );
          }),
        ],
      ),
      location: '/search?q=%E5%91%A8%E6%9D%B0%E4%BC%A6',
    );
    await expectLater(
      find.byType(SearchPage),
      matchesGoldenFile('goldens/search-results-expanded-dark.png'),
    );
  });

  testWidgets('golden: 播放队列（pane / light）', (WidgetTester tester) async {
    final FakePlaybackController playback = FakePlaybackController(songs);
    await pumpPage(
      tester,
      const Scaffold(body: QueuePanel()),
      PageHarness(
        size: const Size(380, 640),
        brightness: Brightness.light,
        overrides: <Override>[
          playbackProvider.overrideWith(() => playback),
          allTracksProvider.overrideWithValue(AsyncValue<List<Track>>.data(songs)),
        ],
      ),
    );
    await expectLater(
      find.byType(QueuePanel),
      matchesGoldenFile('goldens/queue-pane-light.png'),
    );
  });

  testWidgets('golden: 歌词空态（pane / dark）', (WidgetTester tester) async {
    await pumpPage(
      tester,
      const Scaffold(body: LyricsPanel()),
      PageHarness(
        size: const Size(380, 640),
        brightness: Brightness.dark,
        overrides: <Override>[
          currentTrackRefProvider.overrideWithValue((
            trackId: null,
            item: null,
          )),
        ],
      ),
    );
    await expectLater(
      find.byType(LyricsPanel),
      matchesGoldenFile('goldens/lyrics-empty-pane-dark.png'),
    );
  });

  testWidgets('golden: 播放舞台（compact / dark）', (WidgetTester tester) async {
    final Track track = goldenTrack('t1', '晴天');
    await pumpRoutedPage(
      tester,
      const NowPlayingPage(),
      PageHarness(
        size: phone,
        brightness: Brightness.dark,
        overrides: <Override>[
          currentTrackRefProvider.overrideWithValue((
            trackId: track.id,
            item: null,
          )),
          trackByIdProvider(
            track.id,
          ).overrideWithValue(AsyncValue<Track?>.data(track)),
          playbackProvider.overrideWith(
            () => FakePlaybackController(<Track>[track]),
          ),
        ],
      ),
      location: '/stage',
    );
    await expectLater(
      find.byType(NowPlayingPage),
      matchesGoldenFile('goldens/stage-compact-dark.png'),
    );
  });

  testWidgets('golden: 设置（expanded / light）', (WidgetTester tester) async {
    await pumpRoutedPage(
      tester,
      const SettingsPage(),
      PageHarness(
        size: wide,
        brightness: Brightness.light,
        overrides: <Override>[
          settingsStoreProvider.overrideWithValue(
            SettingsStore(supportDirectory: () async => Directory('/nonexistent-tingyu-golden')),
          ),
          allTracksProvider.overrideWithValue(
            AsyncValue<List<Track>>.data(songs),
          ),
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
          ),
          playlistsProvider.overrideWithValue(
            const AsyncValue<List<Playlist>>.data(<Playlist>[]),
          ),
          albumsProvider.overrideWithValue(
            const AsyncValue<List<AlbumSummary>>.data(<AlbumSummary>[]),
          ),
          artistsProvider.overrideWithValue(
            const AsyncValue<List<ArtistSummary>>.data(<ArtistSummary>[]),
          ),
        ],
      ),
      location: '/settings',
    );
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/settings-expanded-light.png'),
    );
  });

  testWidgets('golden: 来源管理（expanded / light）', (WidgetTester tester) async {
    await pumpRoutedPage(
      tester,
      const SourcesPage(),
      PageHarness(
        size: wide,
        brightness: Brightness.light,
        overrides: <Override>[
          sourcesProvider.overrideWithValue(
            AsyncValue<List<MusicSource>>.data(<MusicSource>[
              MusicSource(
                id: 'src-golden',
                kind: 'quark',
                name: '夸克网盘',
                trackCount: 191,
                syncStatus: '已同步（新增 191 / 更新 0 / 移除 0）',
                lastSyncedAt: DateTime.utc(2026, 10, 6),
              ),
            ]),
          ),
        ],
      ),
      location: '/sources',
    );
    await expectLater(
      find.byType(SourcesPage),
      matchesGoldenFile('goldens/sources-expanded-light.png'),
    );
  });

  testWidgets('golden: 来源详情（expanded / light）', (WidgetTester tester) async {
    final MusicSource source = MusicSource(
      id: 'src-golden',
      kind: 'quark',
      name: '夸克网盘',
      trackCount: songs.length,
      syncStatus: '已同步（新增 6 / 更新 0 / 移除 0）',
      lastSyncedAt: DateTime.utc(2026, 10, 6),
    );
    await pumpRoutedPage(
      tester,
      const SourcePage(sourceId: 'src-golden'),
      PageHarness(
        size: wide,
        brightness: Brightness.light,
        overrides: <Override>[
          sourceByIdProvider(
            'src-golden',
          ).overrideWithValue(AsyncValue<MusicSource?>.data(source)),
          tracksOfSourceProvider(
            'src-golden',
          ).overrideWithValue(AsyncValue<List<Track>>.data(songs)),
          allTracksProvider.overrideWithValue(
            AsyncValue<List<Track>>.data(songs),
          ),
        ],
      ),
      location: '/source/src-golden',
    );
    await expectLater(
      find.byType(SourcePage),
      matchesGoldenFile('goldens/source-detail-expanded-light.png'),
    );
  });
}

/// 固定查询词：搜索页的两个结果组需要"正在搜索"的状态。
class _FixedQuery extends SearchQueryController {
  @override
  String build() => '周杰伦';
}

class _FixedDebouncedQuery extends DebouncedSearchQueryController {
  @override
  String build() => '周杰伦';
}
