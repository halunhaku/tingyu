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
  TingyuDatabase([QueryExecutor? executor]) : super(executor ?? openLibraryConnection());

  @override
  int get schemaVersion => 1;

  /// 时间戳按文本存储：默认的 Unix 秒会丢掉毫秒，而旧库导出的 `dateAdded`
  /// / `lastPlayedAt` 带毫秒，往返导入导出会对不上。
  @override
  DriftDatabaseOptions get options => const DriftDatabaseOptions(storeDateTimeAsText: true);

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) => m.createAll(),
        beforeOpen: (OpeningDetails details) async {
          // 播放列表条目对曲目的引用需要外键约束才会级联清理。
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}

/// 默认连接：SQLite 文件放在应用支持目录，并把执行放到后台 isolate，
/// 避免上千条曲目的扫描写入阻塞 UI 线程。
QueryExecutor openLibraryConnection() => LazyDatabase(() async {
      final Directory dir = await getApplicationSupportDirectory();
      final File file = File(p.join(dir.path, 'library.sqlite'));
      return NativeDatabase.createInBackground(file);
    });
