import 'package:drift/drift.dart';

/// 曲目表。
///
/// 字段与旧版 SwiftData `Track` 一一对应（`Sources/Models/Track.swift`），
/// 以便旧的 Swift 曲库可无损导入；差异只有两处：
/// 1. `duration` 用秒（Double）存储，与 Swift 端一致，避免播放层反复换算；
/// 2. 封面从 SwiftData 的 externalStorage `Data` 改为**磁盘文件路径**，
///    避免把图片二进制塞进 SQLite 拖慢查询与备份（见 `CoverStore`）。
@TableIndex(name: 'idx_tracks_source', columns: {#sourceId})
@TableIndex(name: 'idx_tracks_artist', columns: {#artist})
@TableIndex(name: 'idx_tracks_album', columns: {#album})
class Tracks extends Table {
  TextColumn get id => text()();

  TextColumn get sourceId => text()();

  TextColumn get title => text()();

  TextColumn get artist => text().withDefault(const Constant('未知艺术家'))();

  TextColumn get album => text().withDefault(const Constant('未知专辑'))();

  /// 时长（秒）。
  RealColumn get duration => real().withDefault(const Constant(0))();

  IntColumn get trackNumber => integer().nullable()();

  IntColumn get discNumber => integer().nullable()();

  IntColumn get year => integer().nullable()();

  TextColumn get genre => text().nullable()();

  IntColumn get bitrate => integer().nullable()();

  IntColumn get sampleRate => integer().nullable()();

  TextColumn get fileFormat => text().withDefault(const Constant('mp3'))();

  /// 本地绝对路径或远端 URL；同一来源内唯一。
  TextColumn get filePathOrUrl => text()();

  IntColumn get fileSize => integer().withDefault(const Constant(0))();

  TextColumn get etag => text().nullable()();

  DateTimeColumn get lastModified => dateTime().nullable()();

  /// 封面缓存文件路径（`CoverStore` 管理）。
  TextColumn get coverArtPath => text().nullable()();

  TextColumn get coverArtUrl => text().nullable()();

  TextColumn get lyrics => text().nullable()();

  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  DateTimeColumn get dateAdded => dateTime()();

  IntColumn get playCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get lastPlayedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  /// 扫描合并的匹配键：同一来源内 `filePathOrUrl` 唯一。
  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
        <Column<Object>>{sourceId, filePathOrUrl},
      ];
}

/// 音乐来源表；字段与旧版 `MusicSource` 一致。
///
/// 刻意不含任何凭据：WebDAV 密码与 Quark Cookie 属于密钥，走安全存储。
@TableIndex(name: 'idx_sources_kind', columns: {#kind})
class MusicSources extends Table {
  TextColumn get id => text()();

  TextColumn get name => text()();

  /// `local` / `webdav` / `quark`。
  TextColumn get kind => text()();

  TextColumn get localFolderPath => text().nullable()();

  /// 旧版 macOS 安全作用域书签（base64）；仅用于迁移留痕，新版本按目录路径访问。
  TextColumn get localBookmark => text().nullable()();

  TextColumn get webdavUrl => text().nullable()();

  TextColumn get webdavUsername => text().nullable()();

  TextColumn get webdavRootPath => text().nullable()();

  TextColumn get quarkFolderFid => text().nullable()();

  TextColumn get quarkAccountName => text().nullable()();

  TextColumn get syncStatus => text().withDefault(const Constant('未同步'))();

  DateTimeColumn get lastSyncedAt => dateTime().nullable()();

  IntColumn get trackCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 播放列表；曲目顺序由 [PlaylistItems] 承载（旧版是在 `Playlist.trackIds` 里存数组）。
class Playlists extends Table {
  TextColumn get id => text()();

  TextColumn get name => text()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 播放列表条目：显式保存顺序，允许同一曲目重复出现。
class PlaylistItems extends Table {
  TextColumn get playlistId => text().references(Playlists, #id, onDelete: KeyAction.cascade)();

  TextColumn get trackId => text().references(Tracks, #id, onDelete: KeyAction.cascade)();

  IntColumn get position => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{playlistId, position};
}
