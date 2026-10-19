import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/library_summaries.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/data/models/search_page_result.dart';
import 'package:tingyu/data/models/track_sort.dart';
import 'package:tingyu/data/repositories/playlist_repository.dart';
import 'package:tingyu/data/repositories/track_repository.dart';

import 'support/test_support.dart';

void main() {
  late TingyuDatabase db;
  late TrackRepository tracks;

  setUp(() {
    db = openTestDatabase();
    tracks = TrackRepository(db);
  });

  tearDown(() => db.close());

  ScannedTrack scan(
    String path, {
    String title = '歌曲',
    String artist = '歌手',
    String album = '专辑',
    double duration = 180,
    int size = 1000,
    String? coverArtPath,
    String? lyrics,
  }) {
    return ScannedTrack(
      filePathOrUrl: path,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      fileSize: size,
      fileFormat: 'flac',
      coverArtPath: coverArtPath,
      lyrics: lyrics,
    );
  }

  test('mergeScan 首次扫描写入曲目并保留文件事实', () async {
    final MergeResult result = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        scan('/music/a.flac'),
        scan('/music/b.flac', title: '另一首'),
      ],
    );

    expect(result.added, 2);
    expect(result.updated, 0);
    expect(result.removed, 0);

    final List<Track> stored = await tracks.bySource('src-1');
    expect(stored.length, 2);
    final Track first = stored.firstWhere(
      (Track t) => t.filePathOrUrl == '/music/a.flac',
    );
    expect(first.title, '歌曲');
    expect(first.fileSize, 1000);
    expect(first.fileFormat, 'flac');
    expect(
      first.id,
      TrackRepository.idFor(sourceId: 'src-1', filePathOrUrl: '/music/a.flac'),
    );
  });

  test('重复扫描只更新变化的文件事实，保留封面/歌词/收藏/播放统计', () async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/a.flac')],
    );
    final Track original = (await tracks.bySource('src-1')).single;

    await tracks.setFavorite(original.id, value: true);
    await tracks.updateLyrics(original.id, '歌词');
    await tracks.recordPlay(original.id);
    await tracks.updateCoverArt(original.id, path: 'cover.jpg');

    final MergeResult unchanged = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/a.flac')],
    );
    expect(unchanged.updated, 0, reason: '没有变化就不应写库');

    final MergeResult changed = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/a.flac', size: 2048, duration: 200)],
    );
    expect(changed.updated, 1);

    final Track merged = (await tracks.bySource('src-1')).single;
    expect(merged.fileSize, 2048);
    expect(merged.duration, 200);
    expect(merged.isFavorite, isTrue, reason: '用户资产不能被扫描覆盖');
    expect(merged.lyrics, '歌词');
    expect(merged.playCount, 1);
    expect(merged.coverArtPath, 'cover.jpg');
  });

  test('扫描中消失的曲目被删除，并从播放列表中摘除', () async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/a.flac'), scan('/music/b.flac')],
    );
    final String removedId = TrackRepository.idFor(
      sourceId: 'src-1',
      filePathOrUrl: '/music/b.flac',
    );

    final PlaylistRepository playlists = PlaylistRepository(db);
    await playlists.create(id: 'pl-1', name: '收藏夹');
    await playlists.addTrack('pl-1', removedId);
    await playlists.addTrack(
      'pl-1',
      TrackRepository.idFor(sourceId: 'src-1', filePathOrUrl: '/music/a.flac'),
    );

    final MergeResult result = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/a.flac')],
    );

    expect(result.removed, 1);
    expect((await tracks.bySource('src-1')).length, 1);
    final List<Track> playlistTracks = await playlists.tracksOf('pl-1');
    expect(playlistTracks.length, 1);
    expect(playlistTracks.single.filePathOrUrl, '/music/a.flac');
  });

  test('非权威扫描只增量合并，不删除未见曲目和播放列表引用', () async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        scan('/music/a.flac'),
        scan('/music/b.flac', title: '必须保留'),
      ],
    );
    final String preservedId = TrackRepository.idFor(
      sourceId: 'src-1',
      filePathOrUrl: '/music/b.flac',
    );
    await tracks.setFavorite(preservedId, value: true);
    final PlaylistRepository playlists = PlaylistRepository(db);
    await playlists.create(id: 'pl-1', name: '收藏夹');
    await playlists.addTrack('pl-1', preservedId);

    final MergeResult result = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        scan('/music/a.flac', size: 2048),
        scan('/music/c.flac', title: '新曲目'),
      ],
      removeMissing: false,
    );

    expect(result.added, 1);
    expect(result.updated, 1);
    expect(result.removed, 0);
    final List<Track> stored = await tracks.bySource('src-1');
    expect(stored.map((Track track) => track.filePathOrUrl).toSet(), <String>{
      '/music/a.flac',
      '/music/b.flac',
      '/music/c.flac',
    });
    expect(
      stored.singleWhere((Track track) => track.id == preservedId).isFavorite,
      isTrue,
    );
    expect(await playlists.tracksOf('pl-1'), hasLength(1));
  });

  test('占位元数据会被后到的真实值替换，但不会覆盖已有值', () async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        ScannedTrack(
          filePathOrUrl: '/music/c.flac',
          title: '',
          album: '夸克曲库',
          duration: 10,
        ),
      ],
    );

    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        scan('/music/c.flac', title: '真标题', artist: '真歌手', album: '真专辑'),
      ],
    );
    Track stored = (await tracks.bySource('src-1')).single;
    expect(stored.title, '真标题');
    expect(stored.artist, '真歌手');
    expect(stored.album, '真专辑');

    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        ScannedTrack(
          filePathOrUrl: '/music/c.flac',
          title: '  ',
          artist: ScannedTrack.unknownArtist,
          album: '夸克曲库',
          duration: 10,
        ),
      ],
    );
    stored = (await tracks.bySource('src-1')).single;
    expect(stored.title, '真标题', reason: '空标题不能覆盖已有标题');
    expect(stored.artist, '真歌手', reason: '占位艺术家不能覆盖已有艺术家');
    expect(stored.album, '真专辑', reason: '占位专辑名不能覆盖已有专辑');
  });

  test('search 命中标题/艺术家/专辑', () async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        scan('/music/1.flac', title: '晴天', artist: '周杰伦', album: '叶惠美'),
        scan('/music/2.flac', title: 'Hello', artist: 'Adele', album: '25'),
      ],
    );

    expect((await tracks.search('周杰伦')).single.title, '晴天');
    expect((await tracks.search('hello')).single.album, '25');
    expect(await tracks.search('不存在'), isEmpty);
  });

  test('响应式查询在首次空结果后仍推送新入库曲目', () async {
    final Future<List<List<Track>>> allEvents = tracks
        .watchAll()
        .take(2)
        .toList();
    final Future<List<List<Track>>> sourceEvents = tracks
        .watchBySource('src-1')
        .take(2)
        .toList();
    await pumpEventQueue();

    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/live.flac', title: '立即出现')],
    );

    final List<List<Track>> all = await allEvents;
    final List<List<Track>> source = await sourceEvents;
    expect(all.first, isEmpty);
    expect(all.last.single.title, '立即出现');
    expect(source.first, isEmpty);
    expect(source.last.single.title, '立即出现');
  });

  test('artists/albums 聚合：计数、年份取最大、占位名排最后', () async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        scan(
          '/music/1.flac',
          artist: '周杰伦',
          album: '叶惠美',
          duration: 1,
          coverArtPath: null,
        ),
        scan(
          '/music/2.flac',
          artist: '周杰伦',
          album: '叶惠美',
          duration: 1,
          coverArtPath: 'c1.jpg',
        ),
        ScannedTrack(
          filePathOrUrl: '/music/3.flac',
          title: 'x',
          artist: '周杰伦',
          album: '七里香',
          duration: 1,
        ),
        ScannedTrack(
          filePathOrUrl: '/music/4.flac',
          title: 'y',
          duration: 1,
          year: 2004,
        ),
        ScannedTrack(
          filePathOrUrl: '/music/5.flac',
          title: 'z',
          duration: 1,
          year: 2011,
        ),
      ],
    );

    final List<ArtistSummary> artists = await tracks.artists();
    expect(artists.map((ArtistSummary a) => a.name).toList(), <String>[
      '周杰伦',
      ScannedTrack.unknownArtist,
    ]);
    expect(artists.first.trackCount, 3);
    expect(artists.last.trackCount, 2);

    final List<AlbumSummary> albums = await tracks.albums();
    expect(albums.map((AlbumSummary a) => a.album).toList(), <String>[
      '七里香',
      '叶惠美',
      ScannedTrack.unknownAlbum,
    ]);
    final AlbumSummary album = albums.firstWhere(
      (AlbumSummary a) => a.album == '叶惠美',
    );
    expect(album.trackCount, 2);
    expect(album.coverArtPath, 'c1.jpg');
    final AlbumSummary unknown = albums.last;
    expect(unknown.year, 2011, reason: '未知专辑合并后年份取最大值');
    expect(unknown.trackCount, 2);
  });

  group('分页搜索', () {
    /// 直接写库并指定 `dateAdded`：drift 按秒存 DateTime，连续 mergeScan 拿到的
    /// 可能是同一秒的并列时间，既断言不了"最新的一条"，翻页顺序也不可控。
    Future<void> seedRecent(int count) async {
      for (int i = 0; i < count; i++) {
        await db
            .into(db.tracks)
            .insert(
              TracksCompanion.insert(
                id: 'recent-$i',
                sourceId: 'src-1',
                title: 'r$i',
                filePathOrUrl: '/music/recent-$i.flac',
                dateAdded: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
              ),
            );
      }
    }

    test('歌曲分页：45 条命中按 40/5 切页，两页 id 不相交', () async {
      await tracks.mergeScan(
        sourceId: 'src-1',
        scanned: <ScannedTrack>[
          for (int i = 0; i < 45; i++)
            scan('/music/hit-$i.flac', title: 'hit $i'),
        ],
      );

      final SearchPageResult<Track> first = await tracks.searchTracksPaged(
        'hit',
      );
      expect(first.total, 45, reason: 'total 是真实 COUNT，不是本页长度');
      expect(first.items, hasLength(40));

      final SearchPageResult<Track> second = await tracks.searchTracksPaged(
        'hit',
        offset: 40,
      );
      expect(second.total, 45);
      expect(second.items, hasLength(5));

      final Set<String> firstIds = first.items.map((Track t) => t.id).toSet();
      final Set<String> secondIds = second.items.map((Track t) => t.id).toSet();
      expect(firstIds.intersection(secondIds), isEmpty);
      expect(<String>{...firstIds, ...secondIds}, hasLength(45));
    });

    test('歌曲分页：中文子串命中，无命中与空查询都返回空结果', () async {
      await tracks.mergeScan(
        sourceId: 'src-1',
        scanned: <ScannedTrack>[
          scan('/music/1.flac', title: '晴天'),
          scan('/music/2.flac', title: '晴天娃娃'),
          scan('/music/3.flac', title: '阴天'),
        ],
      );

      final SearchPageResult<Track> chinese = await tracks.searchTracksPaged(
        '晴',
      );
      expect(chinese.total, 2);
      expect(chinese.items, hasLength(2));

      final SearchPageResult<Track> missing = await tracks.searchTracksPaged(
        '不存在',
      );
      expect(missing.total, 0);
      expect(missing.items, isEmpty);

      final SearchPageResult<Track> blank = await tracks.searchTracksPaged(
        '   ',
      );
      expect(blank.total, 0);
      expect(blank.items, isEmpty);
      expect((await tracks.searchTracksPaged('')).total, 0);
    });

    test('专辑分页：total 是「艺术家+专辑」组数，limit 1 翻页不重不漏', () async {
      await tracks.mergeScan(
        sourceId: 'src-1',
        scanned: <ScannedTrack>[
          scan('/music/a1.flac', artist: '甲', album: '同名专辑', title: '一'),
          scan('/music/a2.flac', artist: '甲', album: '同名专辑', title: '二'),
        ],
      );

      final SearchPageResult<AlbumSummary> oneGroup = await tracks
          .searchAlbumsPaged('同名');
      expect(oneGroup.total, 1, reason: '同艺术家同名专辑只算一组');
      expect(oneGroup.items, hasLength(1));
      expect(oneGroup.items.single.trackCount, 2);

      await tracks.mergeScan(
        sourceId: 'src-1',
        scanned: <ScannedTrack>[
          scan('/music/b1.flac', artist: '乙', album: '同名专辑', title: '三'),
        ],
        // 增量合并：这次扫描只带一首歌，权威模式会把上面两首当成"已消失"删掉。
        removeMissing: false,
      );

      final SearchPageResult<AlbumSummary> twoGroups = await tracks
          .searchAlbumsPaged('同名');
      expect(twoGroups.total, 2, reason: '同名专辑换个艺术家就是另一组');

      final SearchPageResult<AlbumSummary> page1 = await tracks
          .searchAlbumsPaged('同名', limit: 1);
      final SearchPageResult<AlbumSummary> page2 = await tracks
          .searchAlbumsPaged('同名', limit: 1, offset: 1);
      expect(page1.total, 2);
      expect(page1.items, hasLength(1));
      expect(page2.items, hasLength(1));
      expect(
        <String>{page1.items.single.artist, page2.items.single.artist},
        <String>{'甲', '乙'},
      );

      final SearchPageResult<AlbumSummary> byArtist = await tracks
          .searchAlbumsPaged('甲');
      expect(byArtist.total, 1, reason: '按艺术家名也能命中该组');
    });

    test('艺人分页：total 是艺人数，limit 1 翻两页是两个不同艺人', () async {
      await tracks.mergeScan(
        sourceId: 'src-1',
        scanned: <ScannedTrack>[
          scan('/music/a1.flac', artist: '歌手甲'),
          scan('/music/a2.flac', artist: '歌手甲', title: '另一首'),
          scan('/music/b1.flac', artist: '歌手乙'),
        ],
      );

      final SearchPageResult<ArtistSummary> all = await tracks
          .searchArtistsPaged('歌手');
      expect(all.total, 2, reason: '同一艺人的多首曲目只算一个人');
      expect(all.items.map((ArtistSummary a) => a.name).toSet(), <String>{
        '歌手甲',
        '歌手乙',
      });
      expect(
        all.items.firstWhere((ArtistSummary a) => a.name == '歌手甲').trackCount,
        2,
      );

      final SearchPageResult<ArtistSummary> page1 = await tracks
          .searchArtistsPaged('歌手', limit: 1);
      final SearchPageResult<ArtistSummary> page2 = await tracks
          .searchArtistsPaged('歌手', limit: 1, offset: 1);
      expect(page1.total, 2);
      expect(page1.items, hasLength(1));
      expect(page2.items, hasLength(1));
      expect(page1.items.single.name, isNot(page2.items.single.name));
      expect(
        <String>{page1.items.single.name, page2.items.single.name},
        <String>{'歌手甲', '歌手乙'},
      );
    });

    test('最近添加分页：dateAdded 倒序、真实计数、超出 100 条也不截断', () async {
      await seedRecent(45);

      final SearchPageResult<Track> first = await tracks.recentlyAddedPaged();
      expect(first.total, 45);
      expect(first.items, hasLength(40));
      expect(first.items.first.title, 'r44', reason: '最新入库的排第一');

      final SearchPageResult<Track> second = await tracks.recentlyAddedPaged(
        offset: 40,
      );
      expect(second.total, 45);
      expect(second.items, hasLength(5));
      expect(second.items.last.title, 'r0', reason: '最旧的落到最后一页');

      final Set<String> firstIds = first.items.map((Track t) => t.id).toSet();
      final Set<String> secondIds = second.items.map((Track t) => t.id).toSet();
      expect(firstIds.intersection(secondIds), isEmpty);
    });

    test('曲库列表分页：排序字段并列时按 id 兜底，翻两页不重不漏', () async {
      await tracks.mergeScan(
        sourceId: 'src-1',
        scanned: <ScannedTrack>[
          for (int i = 0; i < 45; i++)
            scan(
              '/music/same-$i.flac',
              title: '标题$i',
              artist: '同一艺术家',
              album: '同一专辑',
            ),
        ],
      );

      final SearchPageResult<Track> first = await tracks.listTracksPaged(
        sort: TrackSortField.artist,
      );
      expect(first.total, 45, reason: '空 query 不过滤，列全库');
      expect(first.items, hasLength(40));

      final SearchPageResult<Track> second = await tracks.listTracksPaged(
        sort: TrackSortField.artist,
        offset: 40,
      );
      expect(second.total, 45);
      expect(second.items, hasLength(5));

      final Set<String> firstIds = first.items.map((Track t) => t.id).toSet();
      final Set<String> secondIds = second.items.map((Track t) => t.id).toSet();
      expect(firstIds.intersection(secondIds), isEmpty);
      expect(<String>{...firstIds, ...secondIds}, hasLength(45));
    });

    test('曲库列表分页：favoritesOnly 只数收藏，sourceId 与 query 组合过滤', () async {
      await tracks.mergeScan(
        sourceId: 'src-1',
        scanned: <ScannedTrack>[
          for (int i = 0; i < 5; i++) scan('/music/f-$i.flac', title: '歌$i'),
        ],
      );
      await tracks.mergeScan(
        sourceId: 'src-2',
        scanned: <ScannedTrack>[scan('/other/x.flac', title: '别的歌')],
      );
      for (final (String source, String path) in <(String, String)>[
        ('src-1', '/music/f-0.flac'),
        ('src-1', '/music/f-2.flac'),
        ('src-2', '/other/x.flac'),
      ]) {
        await tracks.setFavorite(
          TrackRepository.idFor(sourceId: source, filePathOrUrl: path),
          value: true,
        );
      }

      expect((await tracks.listTracksPaged()).total, 6);

      final SearchPageResult<Track> favorites = await tracks.listTracksPaged(
        favoritesOnly: true,
      );
      expect(favorites.total, 3, reason: '收藏过滤后的 total 只数收藏');
      expect(favorites.items, hasLength(3));
      expect(favorites.items.every((Track t) => t.isFavorite), isTrue);

      final SearchPageResult<Track> scoped = await tracks.listTracksPaged(
        favoritesOnly: true,
        sourceId: 'src-1',
      );
      expect(scoped.total, 2);
      expect(scoped.items, hasLength(2));

      final SearchPageResult<Track> queried = await tracks.listTracksPaged(
        query: '别的',
      );
      expect(queried.total, 1, reason: '非空 query 按标题/艺术家/专辑子串过滤');

      final SearchPageResult<Track> blank = await tracks.listTracksPaged(
        query: '   ',
      );
      expect(blank.total, 6, reason: '空 query 不加文本过滤，列全库');
    });

    test('曲库列表分页：addedAt 倒序时第一页首条是最新入库的', () async {
      await seedRecent(45);

      final SearchPageResult<Track> first = await tracks.listTracksPaged(
        sort: TrackSortField.addedAt,
        ascending: false,
      );
      expect(first.total, 45);
      expect(first.items, hasLength(40));
      expect(first.items.first.title, 'r44');

      final SearchPageResult<Track> second = await tracks.listTracksPaged(
        sort: TrackSortField.addedAt,
        ascending: false,
        offset: 40,
      );
      expect(second.items, hasLength(5));
      expect(second.items.last.title, 'r0');
    });
  });
}
