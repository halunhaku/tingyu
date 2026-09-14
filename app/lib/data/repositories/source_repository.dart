import 'package:drift/drift.dart';

import '../db/database.dart';

/// 音乐来源（本地目录 / WebDAV / Quark）的读写入口。
class SourceRepository {
  SourceRepository(this._db);

  final TingyuDatabase _db;

  Stream<List<MusicSource>> watchAll() {
    final query = _db.select(_db.musicSources)..orderBy(<OrderingTerm Function($MusicSourcesTable)>[_byName]);
    return query.watch();
  }

  Future<List<MusicSource>> all() {
    final query = _db.select(_db.musicSources)..orderBy(<OrderingTerm Function($MusicSourcesTable)>[_byName]);
    return query.get();
  }

  Future<MusicSource?> byId(String id) {
    return (_db.select(_db.musicSources)..where(($MusicSourcesTable t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<void> upsert(MusicSourcesCompanion source) => _db.into(_db.musicSources).insertOnConflictUpdate(source);

  Future<void> updateSyncStatus(
    String id, {
    required String status,
    DateTime? syncedAt,
    int? trackCount,
  }) {
    return (_db.update(_db.musicSources)..where(($MusicSourcesTable t) => t.id.equals(id))).write(
      MusicSourcesCompanion(
        syncStatus: Value<String>(status),
        lastSyncedAt: syncedAt == null ? const Value<DateTime?>.absent() : Value<DateTime?>(syncedAt),
        trackCount: trackCount == null ? const Value<int>.absent() : Value<int>(trackCount),
      ),
    );
  }

  Future<int> trackCount(String sourceId) async {
    final Expression<int> count = _db.tracks.id.count();
    final JoinedSelectStatement<HasResultSet, dynamic> query = _db.selectOnly(_db.tracks)
      ..addColumns(<Expression<Object>>[count])
      ..where(_db.tracks.sourceId.equals(sourceId));
    final TypedResult row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// 删除来源：连同其曲目一起清理（播放列表引用由外键级联摘除）。
  /// 旧的 Swift 版把这件事交给调用方，这里收敛到一次事务里，避免留下悬空引用。
  Future<int> delete(String id) {
    return _db.transaction<int>(() async {
      await (_db.delete(_db.tracks)..where(($TracksTable t) => t.sourceId.equals(id))).go();
      return (_db.delete(_db.musicSources)..where(($MusicSourcesTable t) => t.id.equals(id))).go();
    });
  }

  static OrderingTerm _byName($MusicSourcesTable t) => OrderingTerm.asc(t.name);
}
