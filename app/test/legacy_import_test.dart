import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/cover_store.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/legacy_import.dart';
import 'package:tingyu/data/repositories/playlist_repository.dart';
import 'package:tingyu/data/repositories/source_repository.dart';
import 'package:tingyu/data/repositories/track_repository.dart';

import 'support/test_support.dart';

void main() {
  late Directory root;
  late TingyuDatabase db;
  late LegacyLibraryImporter importer;

  setUp(() async {
    root = await createTempDirectory();
    db = openTestDatabase();
    importer = LegacyLibraryImporter(db, coverStore: CoverStore(rootDirectory: () async => root));
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  /// 一份最小但覆盖全部字段的导出（契约见 docs/crossplatform-migration.md §6）。
  String exportJson({
    List<Map<String, dynamic>>? tracks,
    List<Map<String, dynamic>>? playlists,
    int version = LegacyLibraryImporter.supportedVersion,
  }) {
    return jsonEncode(<String, dynamic>{
      'version': version,
      'exportedAt': '2026-09-11T11:53:50.026Z',
      'sources': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'SRC-1',
          'name': '夸克网盘 (音乐)',
          'kind': 'quark',
          'localFolderPath': null,
          'localBookmarkBase64': null,
          'webdavUrl': null,
          'webdavUsername': null,
          'webdavRootPath': null,
          'quarkFolderFid': 'fid-1',
          'quarkAccountName': '夸克用户',
          'syncStatus': '夸克凭据已失效',
          'lastSyncedAt': '2026-09-08T02:56:51.131Z',
          'trackCount': 2,
        },
      ],
      'tracks': tracks ??
          <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'TRACK-1',
              'sourceId': 'SRC-1',
              'title': '止战之殇',
              'artist': '未知艺术家',
              'album': '夸克曲库',
              'duration': 0,
              'trackNumber': 3,
              'discNumber': null,
              'year': null,
              'genre': null,
              'bitrate': null,
              'sampleRate': null,
              'fileFormat': 'flac',
              'filePathOrUrl': 'quark://fid-a',
              'fileSize': 54641611,
              'etag': null,
              'lastModified': null,
              'coverArtBase64': null,
              'coverArtUrl': null,
              'lyrics': '[00:01.00]歌词',
              'isFavorite': true,
              'dateAdded': '2026-09-08T02:56:48.323Z',
              'playCount': 7,
              'lastPlayedAt': '2026-09-09T10:00:00.500Z',
            },
            <String, dynamic>{
              'id': 'TRACK-2',
              'sourceId': 'SRC-1',
              'title': '七里香',
              'artist': '周杰伦',
              'album': '七里香',
              'duration': 299.5,
              'trackNumber': null,
              'discNumber': 1,
              'year': 2004,
              'genre': 'Pop',
              'bitrate': 320,
              'sampleRate': 44100,
              'fileFormat': 'mp3',
              'filePathOrUrl': 'quark://fid-b',
              'fileSize': 1024,
              'etag': 'etag-2',
              'lastModified': '2026-01-02T03:04:05.600Z',
              'coverArtBase64': base64Encode(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]),
              'coverArtUrl': 'https://example.com/cover.jpg',
              'lyrics': null,
              'isFavorite': false,
              'dateAdded': '2026-09-08T02:56:49.000Z',
              'playCount': 0,
              'lastPlayedAt': null,
            },
          ],
      'playlists': playlists ??
          <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'PL-1',
              'name': '通勤',
              'createdAt': '2026-09-01T00:00:00.000Z',
              'trackIds': <String>['TRACK-2', 'TRACK-1', 'TRACK-DELETED'],
            },
          ],
    });
  }

  test('导入来源/曲目/播放列表，保留旧主键与字段', () async {
    final LegacyImportReport report = await importer.importJson(exportJson());

    expect(report.sources, 1);
    expect(report.tracks, 2);
    expect(report.playlists, 1);
    expect(report.skippedTracks, 0);
    expect(report.covers, 1);

    final MusicSource source = (await SourceRepository(db).all()).single;
    expect(source.id, 'SRC-1');
    expect(source.kind, 'quark');
    expect(source.quarkFolderFid, 'fid-1');
    expect(source.lastSyncedAt, isNotNull);

    final TrackRepository tracks = TrackRepository(db);
    final Track first = (await tracks.byId('TRACK-1'))!;
    expect(first.title, '止战之殇');
    expect(first.duration, 0);
    expect(first.isFavorite, isTrue);
    expect(first.playCount, 7);
    expect(first.lyrics, '[00:01.00]歌词');
    expect(first.dateAdded.toUtc(), DateTime.utc(2026, 9, 8, 2, 56, 48, 323));
    expect(first.lastPlayedAt?.toUtc(), DateTime.utc(2026, 9, 9, 10, 0, 0, 500));

    final Track second = (await tracks.byId('TRACK-2'))!;
    expect(second.duration, 299.5, reason: 'JSON 里的整数值也要按 double 还原');
    expect(second.discNumber, 1);
    expect(second.year, 2004);
    expect(second.coverArtUrl, 'https://example.com/cover.jpg');
    expect(second.coverArtPath, isNotNull);
    final File cover = (await CoverStore(rootDirectory: () async => root).resolve(second.coverArtPath))!;
    expect(cover.existsSync(), isTrue);
    expect(cover.readAsBytesSync(), <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);

    final List<Track> playlistTracks = await PlaylistRepository(db).tracksOf('PL-1');
    expect(playlistTracks.map((Track t) => t.id).toList(), <String>['TRACK-2', 'TRACK-1'],
        reason: '顺序保留，且已失效的引用被丢弃');
  });

  test('重复导入幂等，不产生重复行', () async {
    await importer.importJson(exportJson());
    final LegacyImportReport second = await importer.importJson(exportJson());

    expect(second.tracks, 2);
    expect((await TrackRepository(db).all()).length, 2);
    expect((await PlaylistRepository(db).tracksOf('PL-1')).length, 2);
  });

  test('来源不在导出文件内的曲目被跳过并计数', () async {
    final String json = exportJson(
      tracks: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'ORPHAN',
          'sourceId': 'SRC-MISSING',
          'title': '孤儿',
          'filePathOrUrl': 'quark://x',
        },
      ],
      playlists: <Map<String, dynamic>>[],
    );

    final LegacyImportReport report = await importer.importJson(json);

    expect(report.skippedTracks, 1);
    expect(report.tracks, 0);
    expect(await TrackRepository(db).all(), isEmpty);
  });

  test('版本不匹配或根节点非法时拒绝导入', () async {
    expect(
      () => importer.importJson(exportJson(version: 99)),
      throwsA(isA<FormatException>()),
    );
    expect(() => importer.importJson('[]'), throwsA(isA<FormatException>()));
  });
}
