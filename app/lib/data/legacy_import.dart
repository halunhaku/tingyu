import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import 'cover_store.dart';
import 'db/database.dart';
import 'models/scanned_track.dart';

/// 旧版（Swift）曲库导入的结果。
class LegacyImportReport {
  const LegacyImportReport({
    required this.sources,
    required this.tracks,
    required this.playlists,
    required this.skippedTracks,
    required this.covers,
  });

  final int sources;

  final int tracks;

  final int playlists;

  /// 因缺少必需字段或其来源不在导出文件内而被跳过的曲目数。
  final int skippedTracks;

  final int covers;

  @override
  String toString() =>
      'LegacyImportReport(sources: $sources, tracks: $tracks, playlists: $playlists, '
      'skippedTracks: $skippedTracks, covers: $covers)';
}

/// 导入旧版 Swift 版导出的曲库 JSON。
///
/// 导出端见 `tools/legacy-export/ExportLegacyLibrary.swift`，契约见
/// `docs/crossplatform-migration.md` §6。导入保留旧版主键（曲目 id、播放列表 id），
/// 因此播放列表对曲目的引用在迁移后依然成立；重复导入是幂等的。
class LegacyLibraryImporter {
  LegacyLibraryImporter(this._db, {CoverStore? coverStore}) : _coverStore = coverStore ?? CoverStore();

  static const int supportedVersion = 1;

  final TingyuDatabase _db;

  final CoverStore _coverStore;

  Future<LegacyImportReport> importFile(File file) => importJson(file.readAsStringSync());

  Future<LegacyImportReport> importJson(String jsonText) async {
    final Object? decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('导出文件根节点不是 JSON 对象');
    }
    final Object? version = decoded['version'];
    if (version != supportedVersion) {
      throw FormatException('不支持的导出版本：$version（当前支持 $supportedVersion）');
    }

    final List<Map<String, dynamic>> sources = _objects(decoded['sources']);
    final List<Map<String, dynamic>> tracks = _objects(decoded['tracks']);
    final List<Map<String, dynamic>> playlists = _objects(decoded['playlists']);
    final Set<String> sourceIds = <String>{
      for (final Map<String, dynamic> source in sources)
        if (_text(source['id']) case final String id) id,
    };

    return _db.transaction<LegacyImportReport>(() async {
      int importedSources = 0;
      int importedTracks = 0;
      int skipped = 0;
      int covers = 0;

      for (final Map<String, dynamic> source in sources) {
        final String? id = _text(source['id']);
        if (id == null) {
          continue;
        }
        await _db.into(_db.musicSources).insertOnConflictUpdate(
              MusicSourcesCompanion.insert(
                id: id,
                name: _text(source['name']) ?? '未命名来源',
                kind: _text(source['kind']) ?? 'local',
                localFolderPath: Value<String?>(_text(source['localFolderPath'])),
                localBookmark: Value<String?>(_text(source['localBookmarkBase64'])),
                webdavUrl: Value<String?>(_text(source['webdavUrl'])),
                webdavUsername: Value<String?>(_text(source['webdavUsername'])),
                webdavRootPath: Value<String?>(_text(source['webdavRootPath'])),
                quarkFolderFid: Value<String?>(_text(source['quarkFolderFid'])),
                quarkAccountName: Value<String?>(_text(source['quarkAccountName'])),
                syncStatus: Value<String>(_text(source['syncStatus']) ?? '未同步'),
                lastSyncedAt: Value<DateTime?>(_dateTime(source['lastSyncedAt'])),
                trackCount: Value<int>(_int(source['trackCount']) ?? 0),
              ),
            );
        importedSources++;
      }

      for (final Map<String, dynamic> track in tracks) {
        final String? id = _text(track['id']);
        final String? sourceId = _text(track['sourceId']);
        final String? path = _text(track['filePathOrUrl']);
        if (id == null || sourceId == null || path == null || !sourceIds.contains(sourceId)) {
          skipped++;
          continue;
        }

        final String? coverArtPath = await _importCover(id, _text(track['coverArtBase64']));
        if (coverArtPath != null) {
          covers++;
        }

        await _db.into(_db.tracks).insertOnConflictUpdate(
              TracksCompanion.insert(
                id: id,
                sourceId: sourceId,
                title: _text(track['title']) ?? path,
                artist: Value<String>(_text(track['artist']) ?? ScannedTrack.unknownArtist),
                album: Value<String>(_text(track['album']) ?? ScannedTrack.unknownAlbum),
                duration: Value<double>(_double(track['duration']) ?? 0),
                trackNumber: Value<int?>(_int(track['trackNumber'])),
                discNumber: Value<int?>(_int(track['discNumber'])),
                year: Value<int?>(_int(track['year'])),
                genre: Value<String?>(_text(track['genre'])),
                bitrate: Value<int?>(_int(track['bitrate'])),
                sampleRate: Value<int?>(_int(track['sampleRate'])),
                fileFormat: Value<String>(_text(track['fileFormat']) ?? 'mp3'),
                filePathOrUrl: path,
                fileSize: Value<int>(_int(track['fileSize']) ?? 0),
                etag: Value<String?>(_text(track['etag'])),
                lastModified: Value<DateTime?>(_dateTime(track['lastModified'])),
                coverArtPath: Value<String?>(coverArtPath),
                coverArtUrl: Value<String?>(_text(track['coverArtUrl'])),
                lyrics: Value<String?>(_text(track['lyrics'])),
                isFavorite: Value<bool>(track['isFavorite'] == true),
                dateAdded: _dateTime(track['dateAdded']) ?? DateTime.now().toUtc(),
                playCount: Value<int>(_int(track['playCount']) ?? 0),
                lastPlayedAt: Value<DateTime?>(_dateTime(track['lastPlayedAt'])),
              ),
            );
        importedTracks++;
      }

      int importedPlaylists = 0;
      for (final Map<String, dynamic> playlist in playlists) {
        final String? id = _text(playlist['id']);
        if (id == null) {
          continue;
        }
        await _db.into(_db.playlists).insertOnConflictUpdate(
              PlaylistsCompanion.insert(
                id: id,
                name: _text(playlist['name']) ?? '未命名播放列表',
                createdAt: _dateTime(playlist['createdAt']) ?? DateTime.now().toUtc(),
              ),
            );
        await (_db.delete(_db.playlistItems)..where(($PlaylistItemsTable t) => t.playlistId.equals(id))).go();

        int position = 0;
        for (final Object? rawTrackId in (playlist['trackIds'] as List<dynamic>? ?? const <dynamic>[])) {
          final String? trackId = _text(rawTrackId);
          if (trackId == null) {
            continue;
          }
          final Track? existing = await (_db.select(_db.tracks)..where(($TracksTable t) => t.id.equals(trackId)))
              .getSingleOrNull();
          if (existing == null) {
            continue; // 旧库里已失效的引用：直接丢弃，不制造悬空条目。
          }
          await _db.into(_db.playlistItems).insert(
                PlaylistItemsCompanion.insert(
                  playlistId: id,
                  trackId: trackId,
                  position: position++,
                ),
              );
        }
        importedPlaylists++;
      }

      return LegacyImportReport(
        sources: importedSources,
        tracks: importedTracks,
        playlists: importedPlaylists,
        skippedTracks: skipped,
        covers: covers,
      );
    });
  }

  Future<String?> _importCover(String trackId, String? base64) async {
    if (base64 == null || base64.isEmpty) {
      return null;
    }
    final Uint8List bytes = base64Decode(base64);
    return _coverStore.save(trackId, bytes);
  }

  static List<Map<String, dynamic>> _objects(Object? value) {
    if (value is! List<dynamic>) {
      return const <Map<String, dynamic>>[];
    }
    return value.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  static String? _text(Object? value) {
    if (value is String) {
      final String trimmed = value.trim();
      return trimmed.isEmpty ? null : value;
    }
    return null;
  }

  /// 时长等数值字段在 JSON 里可能被写成整数（JSON 只有一种数字类型）。
  static double? _double(Object? value) => value is num ? value.toDouble() : null;

  static int? _int(Object? value) {
    if (value is int) {
      return value;
    }
    return value is num ? value.toInt() : null;
  }

  static DateTime? _dateTime(Object? value) {
    if (value is! String) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  }
}
