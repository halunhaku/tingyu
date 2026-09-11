import 'package:drift/drift.dart';

import '../db/database.dart';
import '../models/library_summaries.dart';
import '../models/scanned_track.dart';

/// 曲目读写与扫描合并。
///
/// 合并语义与旧版 `Sources/Services/Library/LibrarySync.swift` 对齐：
/// 以 `(sourceId, filePathOrUrl)` 为匹配键；只覆盖"文件事实"，保留封面/歌词/收藏/
/// 播放计数等用户资产；扫描中消失的曲目连同其播放列表引用一并清理。
class TrackRepository {
  TrackRepository(this._db);

  final TingyuDatabase _db;

  /// 新扫描曲目的稳定 id：来源 + 路径。重复扫描幂等，且不必依赖随机 UUID。
  static String idFor({required String sourceId, required String filePathOrUrl}) =>
      '$sourceId::$filePathOrUrl';

  Stream<List<Track>> watchAll() => _ordered(_db.select(_db.tracks)).watch();

  Future<List<Track>> all() => _ordered(_db.select(_db.tracks)).get();

  Future<Track?> byId(String id) =>
      (_db.select(_db.tracks)..where(($TracksTable t) => t.id.equals(id))).getSingleOrNull();

  Future<List<Track>> bySource(String sourceId) =>
      _ordered(_db.select(_db.tracks)..where(($TracksTable t) => t.sourceId.equals(sourceId))).get();

  Stream<List<Track>> watchFavorites() =>
      _ordered(_db.select(_db.tracks)..where(($TracksTable t) => t.isFavorite.equals(true))).watch();

  /// 按标题/艺术家/专辑做子串匹配（大小写不敏感，ASCII 范围）。
  Future<List<Track>> search(String query, {int limit = 200}) {
    final String needle = '%${query.trim().toLowerCase()}%';
    final select = _db.select(_db.tracks)
      ..where(($TracksTable t) =>
          t.title.lower().like(needle) | t.artist.lower().like(needle) | t.album.lower().like(needle))
      ..limit(limit);
    return _ordered(select).get();
  }

  Future<void> setFavorite(String id, {required bool value}) {
    return (_db.update(_db.tracks)..where(($TracksTable t) => t.id.equals(id)))
        .write(TracksCompanion(isFavorite: Value<bool>(value)));
  }

  Future<void> recordPlay(String id, {DateTime? at}) async {
    final Track? track = await byId(id);
    if (track == null) {
      return;
    }
    await (_db.update(_db.tracks)..where(($TracksTable t) => t.id.equals(id))).write(
      TracksCompanion(
        playCount: Value<int>(track.playCount + 1),
        lastPlayedAt: Value<DateTime>((at ?? DateTime.now()).toUtc()),
      ),
    );
  }

  Future<void> updateLyrics(String id, String? lyrics) {
    return (_db.update(_db.tracks)..where(($TracksTable t) => t.id.equals(id)))
        .write(TracksCompanion(lyrics: Value<String?>(lyrics)));
  }

  Future<void> updateCoverArt(String id, {String? path, String? url}) {
    return (_db.update(_db.tracks)..where(($TracksTable t) => t.id.equals(id))).write(
      TracksCompanion(
        coverArtPath: Value<String?>(path),
        coverArtUrl: Value<String?>(url),
      ),
    );
  }

  /// 写回抓取到的元数据；`null` 表示该字段保持不变。
  Future<void> applyEnrichment({
    required String id,
    String? title,
    String? artist,
    String? album,
    String? lyrics,
    String? coverArtPath,
    String? coverArtUrl,
  }) {
    return (_db.update(_db.tracks)..where(($TracksTable t) => t.id.equals(id))).write(
      TracksCompanion(
        title: title == null ? const Value<String>.absent() : Value<String>(title),
        artist: artist == null ? const Value<String>.absent() : Value<String>(artist),
        album: album == null ? const Value<String>.absent() : Value<String>(album),
        lyrics: lyrics == null ? const Value<String?>.absent() : Value<String?>(lyrics),
        coverArtPath:
            coverArtPath == null ? const Value<String?>.absent() : Value<String?>(coverArtPath),
        coverArtUrl: coverArtUrl == null ? const Value<String?>.absent() : Value<String?>(coverArtUrl),
      ),
    );
  }

  /// 把一次扫描结果合并进库。
  Future<MergeResult> mergeScan({
    required String sourceId,
    required List<ScannedTrack> scanned,
  }) {
    return _db.transaction<MergeResult>(() async {
      final List<Track> existing =
          await (_db.select(_db.tracks)..where(($TracksTable t) => t.sourceId.equals(sourceId))).get();
      final Map<String, Track> byPath = <String, Track>{
        for (final Track track in existing) track.filePathOrUrl: track,
      };

      final Set<String> seen = <String>{};
      int added = 0;
      int updated = 0;

      for (final ScannedTrack incoming in scanned) {
        final String path = incoming.filePathOrUrl;
        if (path.isEmpty || !seen.add(path)) {
          continue;
        }
        final Track? old = byPath[path];
        if (old == null) {
          await _db.into(_db.tracks).insert(_insert(sourceId, incoming));
          added++;
          continue;
        }
        final Track merged = _withFileFacts(old, incoming);
        if (merged != old) {
          await (_db.update(_db.tracks)..where(($TracksTable t) => t.id.equals(old.id))).write(merged);
          updated++;
        }
      }

      final List<String> removedIds = existing
          .where((Track track) => !seen.contains(track.filePathOrUrl))
          .map((Track track) => track.id)
          .toList(growable: false);
      if (removedIds.isNotEmpty) {
        // 播放列表条目的清理由外键级联完成（见 schema 中的 references）。
        await (_db.delete(_db.tracks)..where(($TracksTable t) => t.id.isIn(removedIds))).go();
      }

      return MergeResult(added: added, updated: updated, removed: removedIds.length);
    });
  }

  /// 艺术家聚合；占位名（未知艺术家）排在最后。
  Future<List<ArtistSummary>> artists({String? sourceId}) async {
    final Expression<int> count = _db.tracks.id.count();
    final JoinedSelectStatement<HasResultSet, dynamic> query = _db.selectOnly(_db.tracks)
      ..addColumns(<Expression<Object>>[_db.tracks.artist, count])
      ..groupBy(<Expression<Object>>[_db.tracks.artist]);
    if (sourceId != null) {
      query.where(_db.tracks.sourceId.equals(sourceId));
    }
    final List<TypedResult> rows = await query.get();
    final List<ArtistSummary> summaries = rows
        .map((TypedResult row) => ArtistSummary(
              name: row.read(_db.tracks.artist)!,
              trackCount: row.read(count) ?? 0,
            ))
        .toList();
    summaries.sort((ArtistSummary a, ArtistSummary b) => _compareNames(
          a.name,
          b.name,
          isPlaceholder: (String name) => name == ScannedTrack.unknownArtist,
        ));
    return summaries;
  }

  /// 专辑聚合：按 `artist + album` 归并，年份取最大值，封面取任一非空缓存文件。
  ///
  /// 这里用 `customSelect`：drift 的 `max()` 只对非空表达式开放，而 `year` 与
  /// `cover_art_path` 都是可空列。SQL 里的列名与 `schema.dart` 的 snake_case 命名绑定，
  /// 由 `track_repository_test.dart` 的聚合用例兜底（改列名会直接测挂）。
  Future<List<AlbumSummary>> albums({String? sourceId}) async {
    final String whereClause = sourceId == null ? '' : 'WHERE source_id = ?';
    final List<Variable<Object>> variables =
        sourceId == null ? const <Variable<Object>>[] : <Variable<Object>>[Variable<String>(sourceId)];
    final List<QueryRow> rows = await _db.customSelect(
      'SELECT artist, album, COUNT(*) AS track_count, MAX(year) AS year, '
      'MAX(cover_art_path) AS cover_art_path '
      'FROM tracks $whereClause GROUP BY artist, album',
      variables: variables,
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.tracks},
    ).get();

    final List<AlbumSummary> summaries = rows
        .map((QueryRow row) => AlbumSummary(
              artist: row.read<String>('artist'),
              album: row.read<String>('album'),
              trackCount: row.read<int>('track_count'),
              year: row.readNullable<int>('year'),
              coverArtPath: row.readNullable<String>('cover_art_path'),
            ))
        .toList();
    summaries.sort((AlbumSummary a, AlbumSummary b) => _compareNames(
          a.album,
          b.album,
          isPlaceholder: (String name) => ScannedTrack.placeholderAlbums.contains(name),
        ));
    return summaries;
  }

  TracksCompanion _insert(String sourceId, ScannedTrack incoming) => TracksCompanion.insert(
        id: idFor(sourceId: sourceId, filePathOrUrl: incoming.filePathOrUrl),
        sourceId: sourceId,
        title: incoming.title,
        artist: Value<String>(incoming.artist),
        album: Value<String>(incoming.album),
        duration: Value<double>(incoming.duration),
        trackNumber: Value<int?>(incoming.trackNumber),
        discNumber: Value<int?>(incoming.discNumber),
        year: Value<int?>(incoming.year),
        genre: Value<String?>(incoming.genre),
        bitrate: Value<int?>(incoming.bitrate),
        sampleRate: Value<int?>(incoming.sampleRate),
        fileFormat: Value<String>(incoming.fileFormat),
        filePathOrUrl: incoming.filePathOrUrl,
        fileSize: Value<int>(incoming.fileSize),
        etag: Value<String?>(incoming.etag),
        lastModified: Value<DateTime?>(incoming.lastModified),
        coverArtPath: Value<String?>(incoming.coverArtPath),
        coverArtUrl: Value<String?>(incoming.coverArtUrl),
        lyrics: Value<String?>(incoming.lyrics),
        dateAdded: DateTime.now().toUtc(),
      );

  /// 只把"文件事实"写回，用户资产（封面/歌词/收藏/播放统计）保持不动。
  static Track _withFileFacts(Track old, ScannedTrack incoming) {
    return old.copyWith(
      fileSize: incoming.fileSize,
      fileFormat: incoming.fileFormat,
      etag: Value<String?>(incoming.etag),
      lastModified: Value<DateTime?>(incoming.lastModified),
      duration: incoming.duration > 0 ? incoming.duration : old.duration,
      coverArtPath: old.coverArtPath == null && incoming.coverArtPath != null
          ? Value<String?>(incoming.coverArtPath)
          : const Value<String?>.absent(),
      coverArtUrl: old.coverArtUrl == null && incoming.coverArtUrl != null
          ? Value<String?>(incoming.coverArtUrl)
          : const Value<String?>.absent(),
      title: _isPlaceholderText(old.title) && !_isPlaceholderText(incoming.title) ? incoming.title : old.title,
      artist: _isPlaceholderArtist(old.artist) && !_isPlaceholderArtist(incoming.artist)
          ? incoming.artist
          : old.artist,
      album: ScannedTrack.placeholderAlbums.contains(old.album) &&
              !ScannedTrack.placeholderAlbums.contains(incoming.album)
          ? incoming.album
          : old.album,
    );
  }

  static bool _isPlaceholderText(String value) => value.trim().isEmpty;

  static bool _isPlaceholderArtist(String value) => value.isEmpty || value == ScannedTrack.unknownArtist;

  /// 占位名排最后，其余按码点序（与旧版 `localizedStandardCompare` 的本地化排序
  /// 略有差异：中文按 Unicode 码点而非拼音，M4 UI 阶段再按需引入排序键）。
  static int _compareNames(String a, String b, {required bool Function(String) isPlaceholder}) {
    final bool placeholderA = isPlaceholder(a);
    final bool placeholderB = isPlaceholder(b);
    if (placeholderA != placeholderB) {
      return placeholderA ? 1 : -1;
    }
    return a.compareTo(b);
  }

  static SimpleSelectStatement<$TracksTable, Track> _ordered(
    SimpleSelectStatement<$TracksTable, Track> statement,
  ) {
    return statement
      ..orderBy(<OrderingTerm Function($TracksTable)>[
        ($TracksTable t) => OrderingTerm.asc(t.artist),
        ($TracksTable t) => OrderingTerm.asc(t.album),
        ($TracksTable t) => OrderingTerm.asc(t.discNumber),
        ($TracksTable t) => OrderingTerm.asc(t.trackNumber),
        ($TracksTable t) => OrderingTerm.asc(t.title),
      ]);
  }
}
