import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/data/models/search_page_result.dart';
import 'package:tingyu/data/repositories/playlist_repository.dart';
import 'package:tingyu/data/repositories/source_repository.dart';
import 'package:tingyu/data/repositories/track_repository.dart';

import 'support/test_support.dart';

void main() {
  late TingyuDatabase db;
  late TrackRepository tracks;
  late PlaylistRepository playlists;
  late SourceRepository sources;

  setUp(() {
    db = openTestDatabase();
    tracks = TrackRepository(db);
    playlists = PlaylistRepository(db);
    sources = SourceRepository(db);
  });

  tearDown(() => db.close());

  Future<void> seedTracks(List<String> paths) async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: paths
          .map((String path) => ScannedTrack(filePathOrUrl: path, title: path, duration: 1))
          .toList(growable: false),
    );
  }

  String idOf(String path) => TrackRepository.idFor(sourceId: 'src-1', filePathOrUrl: path);

  test('追加曲目保持插入顺序，删除后位置顺次前移', () async {
    await seedTracks(<String>['/m/a.flac', '/m/b.flac', '/m/c.flac']);
    await playlists.create(id: 'pl-1', name: '测试');
    await playlists.addTrack('pl-1', idOf('/m/a.flac'));
    await playlists.addTrack('pl-1', idOf('/m/b.flac'));
    await playlists.addTrack('pl-1', idOf('/m/c.flac'));

    expect(
      (await playlists.tracksOf('pl-1')).map((Track t) => t.filePathOrUrl).toList(),
      <String>['/m/a.flac', '/m/b.flac', '/m/c.flac'],
    );

    await playlists.removeAt('pl-1', 0);
    expect(
      (await playlists.tracksOf('pl-1')).map((Track t) => t.filePathOrUrl).toList(),
      <String>['/m/b.flac', '/m/c.flac'],
    );

    // 删除后新增应追加到末尾（位置连续，不会出现空洞）。
    await playlists.addTrack('pl-1', idOf('/m/a.flac'));
    expect(
      (await playlists.tracksOf('pl-1')).map((Track t) => t.filePathOrUrl).toList(),
      <String>['/m/b.flac', '/m/c.flac', '/m/a.flac'],
    );
  });

  test('move 重排曲目顺序', () async {
    await seedTracks(<String>['/m/a.flac', '/m/b.flac', '/m/c.flac']);
    await playlists.create(id: 'pl-1', name: '测试');
    for (final String path in <String>['/m/a.flac', '/m/b.flac', '/m/c.flac']) {
      await playlists.addTrack('pl-1', idOf(path));
    }

    await playlists.move('pl-1', from: 2, to: 0);
    expect(
      (await playlists.tracksOf('pl-1')).map((Track t) => t.filePathOrUrl).toList(),
      <String>['/m/c.flac', '/m/a.flac', '/m/b.flac'],
    );

    await playlists.move('pl-1', from: 0, to: 0);
    expect(
      (await playlists.tracksOf('pl-1')).map((Track t) => t.filePathOrUrl).toList(),
      <String>['/m/c.flac', '/m/a.flac', '/m/b.flac'],
    );
  });

  test('删除播放列表级联清理条目，删除曲目也会摘掉条目', () async {
    await seedTracks(<String>['/m/a.flac', '/m/b.flac']);
    await playlists.create(id: 'pl-1', name: '测试');
    await playlists.addTrack('pl-1', idOf('/m/a.flac'));
    await playlists.addTrack('pl-1', idOf('/m/b.flac'));

    await playlists.delete('pl-1');
    expect(await playlists.tracksOf('pl-1'), isEmpty);
    final List<PlaylistItem> leftovers = await db.select(db.playlistItems).get();
    expect(leftovers, isEmpty);
  });

  test('删除来源连带删除其曲目与播放列表条目', () async {
    await sources.upsert(
      MusicSourcesCompanion.insert(id: 'src-1', name: '本地', kind: 'local'),
    );
    await seedTracks(<String>['/m/a.flac']);
    await playlists.create(id: 'pl-1', name: '测试');
    await playlists.addTrack('pl-1', idOf('/m/a.flac'));

    expect(await sources.trackCount('src-1'), 1);
    await sources.delete('src-1');

    expect(await sources.all(), isEmpty);
    expect(await tracks.all(), isEmpty);
    expect(await db.select(db.playlistItems).get(), isEmpty);
  });

  test('watchAll 按名称排序并能收到新增', () async {
    await playlists.create(id: 'p2', name: 'B 列表');
    await playlists.create(id: 'p1', name: 'A 列表');

    final List<Playlist> first = await playlists.all();
    expect(first.map((Playlist p) => p.name).toList(), <String>['A 列表', 'B 列表']);

    final List<List<Playlist>> emissions = <List<Playlist>>[];
    final sub = playlists.watchAll().listen(emissions.add);
    await Future<void>.delayed(Duration.zero);
    await playlists.create(id: 'p3', name: '0 列表');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    expect(emissions.last.first.name, '0 列表');
  });

  test('曲目数按歌单聚合，且随增删实时推送', () async {
    await seedTracks(<String>['/m/a.flac', '/m/b.flac', '/m/c.flac']);
    await playlists.create(id: 'pl-1', name: '一');
    await playlists.create(id: 'pl-2', name: '二');
    await playlists.addTrack('pl-1', idOf('/m/a.flac'));
    await playlists.addTrack('pl-1', idOf('/m/b.flac'));
    await playlists.addTrack('pl-2', idOf('/m/c.flac'));

    expect(await playlists.trackCounts(), <String, int>{'pl-1': 2, 'pl-2': 1});

    final List<Map<String, int>> emissions = <Map<String, int>>[];
    final StreamSubscription<Map<String, int>> sub = playlists
        .watchTrackCounts()
        .listen(emissions.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);

    await playlists.addTrack('pl-2', idOf('/m/a.flac'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(emissions.last['pl-2'], 2);
    // 空歌单不出现在聚合里，UI 用 `?? 0` 兜底。
    expect(emissions.last.containsKey('pl-3'), isFalse);
  });

  test('按歌单名搜索分页：total 是真实命中数，limit 1 翻两页取到两个', () async {
    await playlists.create(id: 'pl-1', name: '我的歌单');
    await playlists.create(id: 'pl-2', name: '歌单二号');
    await playlists.create(id: 'pl-3', name: '别的名字');

    final SearchPageResult<Playlist> first = await playlists.searchByNamePaged(
      '歌',
      limit: 1,
    );
    expect(first.total, 2, reason: 'total 是命中总数，不是本页长度');
    expect(first.items, hasLength(1));

    final SearchPageResult<Playlist> second = await playlists.searchByNamePaged(
      '歌',
      limit: 1,
      offset: 1,
    );
    expect(second.total, 2);
    expect(second.items, hasLength(1));
    expect(
      <String>{first.items.single.id, second.items.single.id},
      <String>{'pl-1', 'pl-2'},
    );
  });

  test('按歌单名搜索：未命中与空查询都返回空结果', () async {
    await playlists.create(id: 'pl-1', name: '我的歌单');

    final SearchPageResult<Playlist> missing =
        await playlists.searchByNamePaged('不存在');
    expect(missing.total, 0);
    expect(missing.items, isEmpty);

    final SearchPageResult<Playlist> blank = await playlists.searchByNamePaged(
      '   ',
    );
    expect(blank.total, 0);
    expect(blank.items, isEmpty);
    expect((await playlists.searchByNamePaged('')).total, 0);
  });
}
