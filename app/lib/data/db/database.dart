import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'schema.dart';

part 'database.g.dart';

/// 曲线库数据库。
///
/// `schemaVersion` 为 1；后续版本在 [migration] 里追加 `onUpgrade` 步骤。
@DriftDatabase(tables: <Type>[Tracks, MusicSources, Playlists, PlaylistItems])
class TingyuDatabase extends _$TingyuDatabase {
  TingyuDatabase([QueryExecutor? executor])
    : super(executor ?? openLibraryConnection());

  @override
  int get schemaVersion => 1;

  /// 时间戳按文本存储：默认的 Unix 秒会丢掉毫秒，而旧库导出的 `dateAdded`
  /// / `lastPlayedAt` 带毫秒，往返导入导出会对不上。
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      final List<QueryRow> tableRows = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final Set<String> existingTables = tableRows
          .map((QueryRow r) => r.read<String>('name'))
          .toSet();

      final List<QueryRow> indexRows = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      ).get();
      final Set<String> existingIndexes = indexRows
          .map((QueryRow r) => r.read<String>('name'))
          .toSet();

      for (final DatabaseSchemaEntity entity in allSchemaEntities) {
        if (entity is TableInfo) {
          if (!existingTables.contains(entity.actualTableName)) {
            await m.createTable(entity);
          }
        } else if (entity is Index) {
          if (!existingIndexes.contains(entity.entityName)) {
            await m.createIndex(entity);
          }
        }
      }

      // 兼容与迁移：若存在旧版 sources 表，无缝迁移至 music_sources
      if (existingTables.contains('sources')) {
        await customStatement('''
              INSERT OR IGNORE INTO music_sources (
                id, name, kind, local_folder_path,
                webdav_url, webdav_username, webdav_root_path,
                quark_folder_fid, quark_account_name,
                sync_status, last_synced_at, track_count
              )
              SELECT
                id, name, kind, local_folder_path,
                webdav_url, webdav_username, webdav_root_path,
                quark_folder_fid, quark_account_name,
                sync_status, last_synced_at, track_count
              FROM sources
            ''');
      }
    },
    beforeOpen: (OpeningDetails details) async {
      // 播放列表条目对曲目的引用需要外键约束才会级联清理。
      await customStatement('PRAGMA foreign_keys = ON');
      // 检查并补全旧库可能缺失的列（自动对齐声明的字段定义）
      await _ensureColumns('tracks', tracks.$columns);
      await _ensureColumns('music_sources', musicSources.$columns);

      // 额外保底：若在非 onCreate 路径下依然有未迁移的 legacy sources，补充迁移
      final List<QueryRow> legacy = await customSelect(
        "SELECT count(*) AS c FROM sqlite_master WHERE type = 'table' AND name = 'sources'",
      ).get();
      if (legacy.isNotEmpty && (legacy.first.read<int?>('c') ?? 0) > 0) {
        await customStatement('''
              INSERT OR IGNORE INTO music_sources (
                id, name, kind, local_folder_path,
                webdav_url, webdav_username, webdav_root_path,
                quark_folder_fid, quark_account_name,
                sync_status, last_synced_at, track_count
              )
              SELECT
                id, name, kind, local_folder_path,
                webdav_url, webdav_username, webdav_root_path,
                quark_folder_fid, quark_account_name,
                sync_status, last_synced_at, track_count
              FROM sources
            ''');
      }
    },
  );

  Future<void> _ensureColumns(
    String tableName,
    List<GeneratedColumn<Object>> columns,
  ) async {
    final List<QueryRow> info = await customSelect(
      "PRAGMA table_info('$tableName')",
    ).get();
    final Set<String> existing = info
        .map((QueryRow r) => r.read<String>('name'))
        .toSet();
    if (existing.isEmpty) return;

    for (final GeneratedColumn<Object> col in columns) {
      if (!existing.contains(col.name)) {
        final String typeStr = switch (col.type) {
          DriftSqlType.string => 'TEXT',
          DriftSqlType.int => 'INTEGER',
          DriftSqlType.bool => 'INTEGER',
          DriftSqlType.dateTime => 'TEXT',
          DriftSqlType.double => 'REAL',
          DriftSqlType.blob => 'BLOB',
          _ => 'TEXT',
        };
        final String defaultClause = col.$nullable
            ? ''
            : switch (col.type) {
                DriftSqlType.string => " DEFAULT ''",
                DriftSqlType.int => ' DEFAULT 0',
                DriftSqlType.bool => ' DEFAULT 0',
                DriftSqlType.dateTime => " DEFAULT '1970-01-01T00:00:00.000Z'",
                DriftSqlType.double => ' DEFAULT 0.0',
                _ => '',
              };
        await customStatement(
          'ALTER TABLE $tableName ADD COLUMN ${col.name} $typeStr$defaultClause',
        );
      }
    }
  }
}

/// 默认连接：SQLite 文件放在应用支持目录，并把执行放到后台 isolate，
/// 避免上千条曲目的扫描写入阻塞 UI 线程。
QueryExecutor openLibraryConnection() => LazyDatabase(() async {
  final Directory dir = await getApplicationSupportDirectory();
  final File file = File(p.join(dir.path, 'library.sqlite'));
  return NativeDatabase.createInBackground(file);
});
