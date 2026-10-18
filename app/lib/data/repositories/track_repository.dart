import 'package:drift/drift.dart';

import '../db/database.dart';
import '../models/library_summaries.dart';
import '../models/scanned_track.dart';
import '../models/search_page_result.dart';
import '../models/track_sort.dart';

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
    int offset = 0,
  }) {
    final String needle = _likePattern(query);
    final select = _db.select(_db.tracks)
      ..where(($TracksTable t) => _matchSearch(t, needle))
      ..limit(limit, offset: offset);
    return _ordered(select);
  }

  /// 标题/艺术家/专辑子串谓词；[search] 与分页查询共用，避免两处 LIKE 口径漂移。
  static Expression<bool> _matchSearch($TracksTable t, String needle) =>
      t.title.lower().like(needle) |
      t.artist.lower().like(needle) |
      t.album.lower().like(needle);

  /// LIKE 模式：大小写不敏感的子串匹配（与 [search] 的谓词完全一致）。
  static String _likePattern(String query) => '%${query.trim().toLowerCase()}%';

  /// 查询词是否为空；空查询不查库，直接返回空结果。
  static bool _isBlank(String query) => query.trim().isEmpty;

  /// 歌曲搜索分页：标题/艺术家/专辑子串匹配（大小写不敏感，谓词同 [search]）。
  ///
  /// "共 N 条"要的是过滤后的全量，而列表一次只显示一页：总数单独用一条
  /// `COUNT(*)` 问库，绝不把整表读进内存再切片。
  Future<SearchPageResult<Track>> searchTracksPaged(
    String query, {
    int offset = 0,
    int limit = 40,
  }) async {
    if (_isBlank(query)) {
      return const SearchPageResult<Track>(items: <Track>[], total: 0);
    }
    final String needle = _likePattern(query);
    final int total = await _countTracks(
      ($TracksTable t) => _matchSearch(t, needle),
    );
    if (total == 0) {
      return const SearchPageResult<Track>(items: <Track>[], total: 0);
    }
    final List<Track> items = await _searchQuery(
      query,
      limit: limit,
      offset: offset,
    ).get();
    return SearchPageResult<Track>(items: items, total: total);
  }

  /// 专辑搜索分页：按专辑名或艺术家名匹配；`total` 是命中的「艺术家+专辑」组数。
  Future<SearchPageResult<AlbumSummary>> searchAlbumsPaged(
    String query, {
    int offset = 0,
    int limit = 40,
  }) async {
    if (_isBlank(query)) {
      return const SearchPageResult<AlbumSummary>(
        items: <AlbumSummary>[],
        total: 0,
      );
    }
    final String needle = _likePattern(query);
    final int total = await _countAlbumGroups(needle);
    if (total == 0) {
      return const SearchPageResult<AlbumSummary>(
        items: <AlbumSummary>[],
        total: 0,
      );
    }
    final List<AlbumSummary> items = _mapAlbums(
      await _pagedAlbumsQuery(needle, offset: offset, limit: limit).get(),
    );
    return SearchPageResult<AlbumSummary>(items: items, total: total);
  }

  /// 艺人搜索分页；`total` 是命中的艺人数。
  Future<SearchPageResult<ArtistSummary>> searchArtistsPaged(
    String query, {
    int offset = 0,
    int limit = 40,
  }) async {
    if (_isBlank(query)) {
      return const SearchPageResult<ArtistSummary>(
        items: <ArtistSummary>[],
        total: 0,
      );
    }
    final String needle = _likePattern(query);
    final int total = await _countArtistMatches(needle);
    if (total == 0) {
      return const SearchPageResult<ArtistSummary>(
        items: <ArtistSummary>[],
        total: 0,
      );
    }
    final List<ArtistSummary> items = _mapArtists(
      await _artistsQuery(
        null,
        match: needle,
        offset: offset,
        limit: limit,
      ).get(),
    );
    return SearchPageResult<ArtistSummary>(items: items, total: total);
  }

  /// 最近添加分页（dateAdded 倒序，全量，不是旧 [watchRecentlyAdded] 的 100 条截断）。
  Future<SearchPageResult<Track>> recentlyAddedPaged({
    int offset = 0,
    int limit = 40,
  }) async {
    final SimpleSelectStatement<$TracksTable, Track> select =
        _db.select(_db.tracks)
          ..orderBy(<OrderingTerm Function($TracksTable)>[
            ($TracksTable t) => OrderingTerm.desc(t.dateAdded),
            // 同一秒入库的曲目在 dateAdded 上并列（drift 按秒存 DateTime），
            // 只靠它无法定序，补 id 兜底才能保证翻页不重不漏。
            ($TracksTable t) => OrderingTerm.asc(t.id),
          ])
          ..limit(limit, offset: offset);
    final List<Track> items = await select.get();
    final int total = await _countTracks(null);
    return SearchPageResult<Track>(items: items, total: total);
  }

  /// 曲库歌曲列表分页（曲库根页 / 收藏 / 最近添加共用）。
  ///
  /// 与 [searchTracksPaged] 的区别：空 [query] 表示**不加文本过滤**（列全库），
  /// 而不是返回空结果。`total` 是当前过滤条件下的真实总数（真实 COUNT，不是
  /// 本页长度）。
  Future<SearchPageResult<Track>> listTracksPaged({
    String query = '',
    bool favoritesOnly = false,
    String? sourceId,
    TrackSortField sort = TrackSortField.title,
    bool ascending = true,
    int offset = 0,
    int limit = 40,
  }) async {
    final Expression<bool> Function($TracksTable)? predicate = _listPredicate(
      needle: _isBlank(query) ? null : _likePattern(query),
      favoritesOnly: favoritesOnly,
      sourceId: sourceId,
    );
    final SimpleSelectStatement<$TracksTable, Track> select = _db.select(
      _db.tracks,
    );
    if (predicate != null) {
      select.where(predicate);
    }
    select
      ..orderBy(<OrderingTerm Function($TracksTable)>[
        ($TracksTable t) => _sortTerm(t, sort, ascending),
        // 排序字段常常并列（同名专辑下的多首、同一秒入库）：没有 id 兜底时
        // 并列行在两次查询里的先后不定，翻页会重/漏。
        ($TracksTable t) => OrderingTerm.asc(t.id),
      ])
      ..limit(limit, offset: offset);
    final List<Track> items = await select.get();
    final int total = await _countTracks(predicate);
    return SearchPageResult<Track>(items: items, total: total);
  }

  /// 曲库列表的过滤谓词；没有任何条件时返回 `null`，让 SQL 不带 WHERE。
  static Expression<bool> Function($TracksTable)? _listPredicate({
    required String? needle,
    required bool favoritesOnly,
    required String? sourceId,
  }) {
    if (needle == null && !favoritesOnly && sourceId == null) {
      return null;
    }
    return ($TracksTable t) {
      final List<Expression<bool>> conditions = <Expression<bool>>[
        if (needle != null) _matchSearch(t, needle),
        if (favoritesOnly) t.isFavorite.equals(true),
        if (sourceId != null) t.sourceId.equals(sourceId),
      ];
      return conditions.reduce(
        (Expression<bool> a, Expression<bool> b) => a & b,
      );
    };
  }

  /// 排序字段到列：`duration` 是秒（非空列），`addedAt` 是入库时间。
  static OrderingTerm _sortTerm(
    $TracksTable t,
    TrackSortField sort,
    bool ascending,
  ) {
    final Expression<Object> column = switch (sort) {
      TrackSortField.title => t.title,
      TrackSortField.artist => t.artist,
      TrackSortField.album => t.album,
      TrackSortField.duration => t.duration,
      TrackSortField.addedAt => t.dateAdded,
    };
    return ascending ? OrderingTerm.asc(column) : OrderingTerm.desc(column);
  }

  /// 曲目真实计数：与分页查询传同一份谓词，`null` 表示全表计数。
  Future<int> _countTracks(Expression<bool> Function($TracksTable)? predicate) {
    return predicate == null
        ? _db.tracks.count().getSingle()
        : _db.tracks.count(where: predicate).getSingle();
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

  /// 艺人聚合查询；[match] 是艺名子串谓词，[limit] 非空时按艺名排序并分页。
  ///
  /// 不给 [limit] 时既不排序也不分页，[artists]/[watchArtists] 的行为因此保持不变。
  JoinedSelectStatement<HasResultSet, dynamic> _artistsQuery(
    String? sourceId, {
    String? match,
    int offset = 0,
    int? limit,
  }) {
    final Expression<int> count = _db.tracks.id.count();
    final JoinedSelectStatement<HasResultSet, dynamic> query =
        _db.selectOnly(_db.tracks)
          ..addColumns(<Expression<Object>>[_db.tracks.artist, count])
          ..groupBy(<Expression<Object>>[_db.tracks.artist]);
    if (sourceId != null) {
      query.where(_db.tracks.sourceId.equals(sourceId));
    }
    if (match != null) {
      query.where(_db.tracks.artist.lower().like(match));
    }
    if (limit != null) {
      // 分组键即排序键（每组唯一），同一行在两次查询里的相对位置因此稳定；
      // 没有 ORDER BY 时 SQLite 的分组顺序不保证，翻页会重/漏。
      query
        ..orderBy(<OrderingTerm>[OrderingTerm.asc(_db.tracks.artist)])
        ..limit(limit, offset: offset);
    }
    return query;
  }

  /// 命中的艺人数：一条 `COUNT(DISTINCT artist)` 算完，不把分组结果读出来再数。
  Future<int> _countArtistMatches(String needle) async {
    final QueryRow row = await _db
        .customSelect(
          'SELECT COUNT(DISTINCT artist) AS c FROM tracks '
          'WHERE LOWER(artist) LIKE ?',
          variables: <Variable<Object>>[Variable<String>(needle)],
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.tracks},
        )
        .getSingle();
    return row.read<int>('c');
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

  /// 专辑聚合的投影列；全量与分页查询共用一份，改列名只需改这里。
  static const String _albumProjection =
      'artist, album, COUNT(*) AS track_count, MAX(year) AS year, '
      'MAX(cover_art_path) AS cover_art_path';

  Selectable<QueryRow> _albumsQuery(String? sourceId) {
    final String whereClause = sourceId == null ? '' : 'WHERE source_id = ?';
    final List<Variable<Object>> variables = sourceId == null
        ? const <Variable<Object>>[]
        : <Variable<Object>>[Variable<String>(sourceId)];
    return _db.customSelect(
      'SELECT $_albumProjection '
      'FROM tracks $whereClause GROUP BY artist, album',
      variables: variables,
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.tracks},
    );
  }

  /// 分页专辑聚合：列与 [_albumsQuery] 同源，按 LIKE 过滤并显式排序分页。
  ///
  /// `ORDER BY artist, album` 排的正是分组键（每组唯一），同一行在两次查询里的
  /// 相对位置一致，翻页才不重不漏。
  Selectable<QueryRow> _pagedAlbumsQuery(
    String needle, {
    required int offset,
    required int limit,
  }) {
    return _db.customSelect(
      'SELECT $_albumProjection FROM tracks '
      'WHERE LOWER(album) LIKE ? OR LOWER(artist) LIKE ? '
      'GROUP BY artist, album ORDER BY artist, album LIMIT ? OFFSET ?',
      variables: <Variable<Object>>[
        Variable<String>(needle),
        Variable<String>(needle),
        Variable<int>(limit),
        Variable<int>(offset),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.tracks},
    );
  }

  /// 命中的「艺术家+专辑」组数：先按组归并再去重计数，口径是组而不是曲目。
  Future<int> _countAlbumGroups(String needle) async {
    final QueryRow row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM ('
          'SELECT 1 FROM tracks WHERE LOWER(album) LIKE ? OR LOWER(artist) LIKE ? '
          'GROUP BY artist, album)',
          variables: <Variable<Object>>[
            Variable<String>(needle),
            Variable<String>(needle),
          ],
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.tracks},
        )
        .getSingle();
    return row.read<int>('c');
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
