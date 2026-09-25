import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/data/repositories/playlist_repository.dart';
import 'package:tingyu/data/repositories/source_repository.dart';
import 'package:tingyu/data/repositories/track_repository.dart';

import 'support/test_support.dart';

ScannedTrack _scanned(String path, String title) => ScannedTrack(
  filePathOrUrl: path,
  title: title,
  artist: '歌手',
  album: '专辑',
  duration: 200,
  fileFormat: 'mp3',
);

Future<TingyuDatabase> _dbWithSource() async {
  final TingyuDatabase db = openTestDatabase();
  await SourceRepository(db).upsert(
    const MusicSourcesCompanion(
      id: Value<String>('src-1'),
      name: Value<String>('本地'),
      kind: Value<String>('local'),
    ),
  );
  return db;
}

void main() {
  test('曲目被扫描删除后重建：播放列表仍能继续追加曲目（position 无空洞）', () async {
    final TingyuDatabase db = await _dbWithSource();
    addTearDown(db.close);

    final TrackRepository tracks = TrackRepository(db);
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        _scanned('/a.mp3', 'A'),
        _scanned('/b.mp3', 'B'),
        _scanned('/c.mp3', 'C'),
      ],
    );
    final List<Track> all = await tracks.all();
    final Map<String, String> idByTitle = <String, String>{
      for (final Track t in all) t.title: t.id,
    };

    final PlaylistRepository playlists = PlaylistRepository(db);
    await playlists.create(id: 'pl-1', name: '歌单');
    await playlists.addTrack('pl-1', idByTitle['A']!);
    await playlists.addTrack('pl-1', idByTitle['B']!);
    await playlists.addTrack('pl-1', idByTitle['C']!);
    expect(await playlists.tracksOf('pl-1'), hasLength(3));

    // 模拟「来源里删掉 B 之后重新同步」：B 的 tracks 行消失，
    // playlist_items 由外键级联摘除，但剩下的 position 不重排。
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[_scanned('/a.mp3', 'A'), _scanned('/c.mp3', 'C')],
      removeMissing: true,
    );

    final List<Track> afterRemoval = await playlists.tracksOf('pl-1');
    expect(afterRemoval.map((Track t) => t.title), <String>['A', 'C']);

    // B 重新回到来源里（扫描回来的是新主键行）
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        _scanned('/a.mp3', 'A'),
        _scanned('/b.mp3', 'B'),
        _scanned('/c.mp3', 'C'),
      ],
      removeMissing: true,
    );
    final String newB = (await tracks.all())
        .firstWhere((Track t) => t.title == 'B')
        .id;

    // 用户再加一首：不能因为 position 空洞而主键冲突
    await expectLater(
      playlists.addTrack('pl-1', newB),
      completes,
      reason: 'position 有空洞时用 count 当新位置会撞 (playlist_id, position) 主键',
    );
    expect(await playlists.tracksOf('pl-1'), hasLength(3));
  });

  test('曲目被扫描删除后重建：删除某一行不会误删其它曲目', () async {
    final TingyuDatabase db = await _dbWithSource();
    addTearDown(db.close);

    final TrackRepository tracks = TrackRepository(db);
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        _scanned('/a.mp3', 'A'),
        _scanned('/b.mp3', 'B'),
        _scanned('/c.mp3', 'C'),
      ],
    );
    final Map<String, String> idByTitle = <String, String>{
      for (final Track t in await tracks.all()) t.title: t.id,
    };

    final PlaylistRepository playlists = PlaylistRepository(db);
    await playlists.create(id: 'pl-1', name: '歌单');
    for (final String title in <String>['A', 'B', 'C']) {
      await playlists.addTrack('pl-1', idByTitle[title]!);
    }

    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[_scanned('/a.mp3', 'A'), _scanned('/c.mp3', 'C')],
      removeMissing: true,
    );

    // 界面按「第 index 行」删除；空洞下必须删的仍是这一行的曲目
    final List<Track> rows = await playlists.tracksOf('pl-1');
    expect(rows.map((Track t) => t.title), <String>['A', 'C']);
    await playlists.removeAt('pl-1', 1); // 第 2 行 = C

    final List<Track> left = await playlists.tracksOf('pl-1');
    expect(left.map((Track t) => t.title), <String>[
      'A',
    ], reason: '删除第 2 行应删掉 C（position=2），而不是错删 A（position=0）');
  });

  test('重新排序后不会出现重复条目', () async {
    final TingyuDatabase db = await _dbWithSource();
    addTearDown(db.close);

    final TrackRepository tracks = TrackRepository(db);
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        _scanned('/a.mp3', 'A'),
        _scanned('/b.mp3', 'B'),
        _scanned('/c.mp3', 'C'),
      ],
    );
    final Map<String, String> idByTitle = <String, String>{
      for (final Track t in await tracks.all()) t.title: t.id,
    };

    final PlaylistRepository playlists = PlaylistRepository(db);
    await playlists.create(id: 'pl-1', name: '歌单');
    for (final String title in <String>['A', 'B', 'C']) {
      await playlists.addTrack('pl-1', idByTitle[title]!);
    }

    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[_scanned('/a.mp3', 'A'), _scanned('/c.mp3', 'C')],
      removeMissing: true,
    );

    await playlists.move('pl-1', from: 1, to: 0); // C 上移到首位

    final List<Track> rows = await playlists.tracksOf('pl-1');
    expect(rows.map((Track t) => t.title), <String>[
      'C',
      'A',
    ], reason: '重排只覆写 0..n-1 会留下旧的高位行，表现为重复/顺序错乱');
  });
}
