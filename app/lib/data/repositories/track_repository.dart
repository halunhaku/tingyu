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
  static String idFor({
    required String sourceId,
    required String filePathOrUrl,
  }) => '$sourceId::$filePathOrUrl';

  Stream<List<Track>> watchAll() => _ordered(_db.select(_db.tracks)).watch();

  Future<List<Track>> all() => _ordered(_db.select(_db.tracks)).get();

  Future<Track?> byId(String id) => (_db.select(
    _db.tracks,
  )..where(($TracksTable t) => t.id.equals(id))).getSingleOrNull();

  Stream<Track?> watchById(String id) => (_db.select(
    _db.tracks,
  )..where(($TracksTable t) => t.id.equals(id))).watchSingleOrNull();

  Future<List<Track>> bySource(String sourceId) => _ordered(
    _db.select(_db.tracks)
      ..where(($TracksTable t) => t.sourceId.equals(sourceId)),
  ).get();

  Stream<List<Track>> watchBySource(String sourceId) => _ordered(
    _db.select(_db.tracks)
      ..where(($TracksTable t) => t.sourceId.equals(sourceId)),
  ).watch();

  Stream<List<Track>> watchFavorites() => _ordered(
    _db.select(_db.tracks)
      ..where(($TracksTable t) => t.isFavorite.equals(true)),
  ).watch();

  /// 按标题/艺术家/专辑做子串匹配（大小写不敏感，ASCII 范围）。
  Future<List<Track>> search(String query, {int limit = 200}) =>
      _searchQuery(query, limit: limit).get();

  Stream<List<Track>> watchSearch(String query, {int limit = 200}) =>
      _searchQuery(query, limit: limit).watch();

  Stream<List<Track>> watchRecentlyAdded({int limit = 100}) {
    final select = _db.select(_db.tracks)
      ..orderBy(<OrderingTerm Function($TracksTable)>[
        ($TracksTable t) => OrderingTerm.desc(t.dateAdded),
      ])
      ..limit(limit);
    return select.watch();
  }

  SimpleSelectStatement<$TracksTable, Track> _searchQuery(
    String query, {
    required int limit,
  }) {
    final String needle = '%${query.trim().toLowerCase()}%';
    final select = _db.select(_db.tracks)
      ..where(
        ($TracksTable t) =>
            t.title.lower().like(needle) |
            t.artist.lower().like(needle) |
            t.album.lower().like(needle),
      )
      ..limit(limit);
    return _ordered(select);
  }

  Future<void> setFavorite(String id, {required bool value}) {
    return (_db.update(_db.tracks)..where(($TracksTable t) => t.id.equals(id)))
        .write(TracksCompanion(isFavorite: Value<bool>(value)));
  }

  /// 记一次播放。
  ///
  /// 计数用 SQL 自增，不再"读出来加一再写回去"：后者在两次播放几乎同时上报时
  /// 会丢计数，也让每次播放多一次跨 isolate 的往返。
  Future<void> recordPlay(String id, {DateTime? at}) {
    return _db.customUpdate(
      'UPDATE tracks SET play_count = play_count + 1, last_played_at = ? '
      'WHERE id = ?',
      variables: <Variable<Object>>[
        Variable<String>((at ?? DateTime.now()).toUtc().toIso8601String()),
        Variable<String>(id),
      ],
      updates: <ResultSetImplementation>{_db.tracks},
    );
  }

  /// 只在库里还没有时长时写入。
  ///
  /// 夸克 / WebDAV 的目录接口不给时长（旧版同样写 0），界面因此一直显示 `--:--`。
  /// 播放器开始播放后从解码器拿到的时长是唯一可信来源，顺手补上：下次打开曲库、
  /// 队列和锁屏都能显示真实时长，而不是让用户看着一排 `--:--`。
  Future<void> updateDurationIfUnknown(String id, Duration duration) {
    final double seconds = duration.inMilliseconds / 1000;
    if (seconds <= 0) {
      return Future<void>.value();
    }
    return (_db.update(_db.tracks)
          ..where(
            ($TracksTable t) => t.id.equals(id) & t.duration.equals(0),
          ))
        .write(TracksCompanion(duration: Value<double>(seconds)));
  }

  /// 某个来源里每个文件已记录的事实（大小 + 修改时间）。
  ///
  /// 本地目录重复扫描时用它判断"这个文件没动过"，从而跳过标签解析与封面落盘。
  Future<KnownFileFacts> fileFacts(String sourceId) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT file_path_or_url AS path, file_size AS size, '
          'last_modified AS modified FROM tracks WHERE source_id = ?',
          variables: <Variable<Object>>[Variable<String>(sourceId)],
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.tracks},
        )
        .get();
    return <String, ({int size, DateTime? modified})>{
      for (final QueryRow row in rows)
        row.read<String>('path'): (
          size: row.read<int>('size'),
          modified: row.read<DateTime?>('modified'),
        ),
    };
  }

  /// 当前仍被引用的封面文件名（封面缓存清理用）。
  Future<Set<String>> coverNamesInUse() async {
    final Set<String> names = <String>{};
    for (final QueryRow row in await _db
        .customSelect(
          'SELECT DISTINCT cover_art_path AS name FROM tracks '
          'WHERE cover_art_path IS NOT NULL AND cover_art_path != \'\'',
        )
        .get()) {
      final String? name = row.read<String?>('name');
      if (name != null && name.isNotEmpty) {
        names.add(name);
      }
    }
    return names;
  }

  Future<void> updateLyrics(String id, String? lyrics) {
    return (_db.update(_db.tracks)..where(($TracksTable t) => t.id.equals(id)))
        .write(TracksCompanion(lyrics: Value<String?>(lyrics)));
  }

  Future<void> updateCoverArt(String id, {String? path, String? url}) {
    return (_db.update(
      _db.tracks,
    )..where(($TracksTable t) => t.id.equals(id))).write(
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
    return (_db.update(
      _db.tracks,
    )..where(($TracksTable t) => t.id.equals(id))).write(
      TracksCompanion(
        title: title == null
            ? const Value<String>.absent()
            : Value<String>(title),
        artist: artist == null
            ? const Value<String>.absent()
            : Value<String>(artist),
        album: album == null
            ? const Value<String>.absent()
            : Value<String>(album),
        lyrics: lyrics == null
            ? const Value<String?>.absent()
            : Value<String?>(lyrics),
        coverArtPath: coverArtPath == null
            ? const Value<String?>.absent()
            : Value<String?>(coverArtPath),
        coverArtUrl: coverArtUrl == null
            ? const Value<String?>.absent()
            : Value<String?>(coverArtUrl),
      ),
    );
  }

  /// 把一次扫描结果合并进库。
  ///
  /// [removeMissing] 只能用于完整、权威的来源快照。取消、截断或跳过条目的
  /// 扫描必须传 false，否则短暂的权限/网络故障会误删曲目及其播放列表引用。
  ///
  /// 写入走 batch：drift 的每条独立语句都是一次跨 isolate 往返，逐条 await 时
  /// 一次五千首的扫描要跑五千个来回；batch 把整轮合并压成一趟。
  Future<MergeResult> mergeScan({
    required String sourceId,
    required List<ScannedTrack> scanned,
    bool removeMissing = true,
  }) {
    return _db.transaction<MergeResult>(() async {
      final List<Track> existing = await (_db.select(
        _db.tracks,
      )..where(($TracksTable t) => t.sourceId.equals(sourceId))).get();
      final Map<String, Track> byPath = <String, Track>{
        for (final Track track in existing) track.filePathOrUrl: track,
      };

      final Set<String> seen = <String>{};
      final List<TracksCompanion> inserts = <TracksCompanion>[];
      final List<Track> updates = <Track>[];

      for (final ScannedTrack incoming in scanned) {
        final String path = incoming.filePathOrUrl;
        if (path.isEmpty || !seen.add(path)) {
          continue;
        }
        final Track? old = byPath[path];
        if (old == null) {
          inserts.add(_insert(sourceId, incoming));
          continue;
        }
        final Track merged = _withFileFacts(old, incoming);
        if (merged != old) {
          updates.add(merged);
        }
      }

      final List<String> removedIds = removeMissing
          ? existing
                .where((Track track) => !seen.contains(track.filePathOrUrl))
                .map((Track track) => track.id)
                .toList(growable: false)
          : const <String>[];

      await _db.batch((Batch batch) {
        batch.insertAll(_db.tracks, inserts);
        for (final Track track in updates) {
          batch.update(
            _db.tracks,
            track,
            where: ($TracksTable t) => t.id.equals(track.id),
          );
        }
        if (removedIds.isNotEmpty) {
          // 播放列表条目的清理由外键级联完成（见 schema 中的 references）。
          batch.deleteWhere(
            _db.tracks,
            ($TracksTable t) => t.id.isIn(removedIds),
          );
        }
      });

      return MergeResult(
        added: inserts.length,
        updated: updates.length,
        removed: removedIds.length,
      );
    });
  }

  /// 艺术家聚合；占位名（未知艺术家）排在最后。
  Future<List<ArtistSummary>> artists({String? sourceId}) =>
      _artistsQuery(sourceId).get().then(_mapArtists);

  /// 同上，但随曲库变化自动重算（UI 用）。
  Stream<List<ArtistSummary>> watchArtists({String? sourceId}) =>
      _artistsQuery(sourceId).watch().map(_mapArtists);

  JoinedSelectStatement<HasResultSet, dynamic> _artistsQuery(String? sourceId) {
    final Expression<int> count = _db.tracks.id.count();
    final JoinedSelectStatement<HasResultSet, dynamic> query =
        _db.selectOnly(_db.tracks)
          ..addColumns(<Expression<Object>>[_db.tracks.artist, count])
          ..groupBy(<Expression<Object>>[_db.tracks.artist]);
    if (sourceId != null) {
      query.where(_db.tracks.sourceId.equals(sourceId));
    }
    return query;
  }

  List<ArtistSummary> _mapArtists(List<TypedResult> rows) {
    final Expression<int> count = _db.tracks.id.count();
    final List<ArtistSummary> summaries = rows
        .map(
          (TypedResult row) => ArtistSummary(
            name: row.read(_db.tracks.artist)!,
            trackCount: row.read(count) ?? 0,
          ),
        )
        .toList();
    summaries.sort(
      (ArtistSummary a, ArtistSummary b) => _compareNames(
        a.name,
        b.name,
        isPlaceholder: (String name) => name == ScannedTrack.unknownArtist,
      ),
    );
    return summaries;
  }

  /// 专辑聚合：按 `artist + album` 归并，年份取最大值，封面取任一非空缓存文件。
  ///
  /// 这里用 `customSelect`：drift 的 `max()` 只对非空表达式开放，而 `year` 与
  /// `cover_art_path` 都是可空列。SQL 里的列名与 `schema.dart` 的 snake_case 命名绑定，
  /// 由 `track_repository_test.dart` 的聚合用例兜底（改列名会直接测挂）。
  Future<List<AlbumSummary>> albums({String? sourceId}) =>
      _albumsQuery(sourceId).get().then(_mapAlbums);

  /// 同上，但随曲库变化自动重算（UI 用）。
  Stream<List<AlbumSummary>> watchAlbums({String? sourceId}) =>
      _albumsQuery(sourceId).watch().map(_mapAlbums);

  Selectable<QueryRow> _albumsQuery(String? sourceId) {
    final String whereClause = sourceId == null ? '' : 'WHERE source_id = ?';
    final List<Variable<Object>> variables = sourceId == null
        ? const <Variable<Object>>[]
        : <Variable<Object>>[Variable<String>(sourceId)];
    return _db.customSelect(
      'SELECT artist, album, COUNT(*) AS track_count, MAX(year) AS year, '
      'MAX(cover_art_path) AS cover_art_path '
      'FROM tracks $whereClause GROUP BY artist, album',
      variables: variables,
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.tracks},
    );
  }

  List<AlbumSummary> _mapAlbums(List<QueryRow> rows) {
    final List<AlbumSummary> summaries = rows
        .map(
          (QueryRow row) => AlbumSummary(
            artist: row.read<String>('artist'),
            album: row.read<String>('album'),
            trackCount: row.read<int>('track_count'),
            year: row.readNullable<int>('year'),
            coverArtPath: row.readNullable<String>('cover_art_path'),
          ),
        )
        .toList();
    summaries.sort(
      (AlbumSummary a, AlbumSummary b) => _compareNames(
        a.album,
        b.album,
        isPlaceholder: (String name) =>
            ScannedTrack.placeholderAlbums.contains(name),
      ),
    );
    return summaries;
  }

  TracksCompanion _insert(String sourceId, ScannedTrack incoming) =>
      TracksCompanion.insert(
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
      title:
          _isPlaceholderText(old.title) && !_isPlaceholderText(incoming.title)
          ? incoming.title
          : old.title,
      artist:
          _isPlaceholderArtist(old.artist) &&
              !_isPlaceholderArtist(incoming.artist)
          ? incoming.artist
          : old.artist,
      album:
          ScannedTrack.placeholderAlbums.contains(old.album) &&
              !ScannedTrack.placeholderAlbums.contains(incoming.album)
          ? incoming.album
          : old.album,
    );
  }

  static bool _isPlaceholderText(String value) => value.trim().isEmpty;

  static bool _isPlaceholderArtist(String value) =>
      value.isEmpty || value == ScannedTrack.unknownArtist;

  /// 占位名排最后，其余按码点序（与旧版 `localizedStandardCompare` 的本地化排序
  /// 略有差异：中文按 Unicode 码点而非拼音，M4 UI 阶段再按需引入排序键）。
  static int _compareNames(
    String a,
    String b, {
    required bool Function(String) isPlaceholder,
  }) {
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
    return statement..orderBy(<OrderingTerm Function($TracksTable)>[
      ($TracksTable t) => OrderingTerm.asc(t.artist),
      ($TracksTable t) => OrderingTerm.asc(t.album),
      ($TracksTable t) => OrderingTerm.asc(t.discNumber),
      ($TracksTable t) => OrderingTerm.asc(t.trackNumber),
      ($TracksTable t) => OrderingTerm.asc(t.title),
    ]);
  }
}
