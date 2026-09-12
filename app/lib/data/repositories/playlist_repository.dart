import 'package:drift/drift.dart';

import '../db/database.dart';

/// 播放列表读写：顺序由 `playlist_items.position` 显式保存。
class PlaylistRepository {
  PlaylistRepository(this._db);

  final TingyuDatabase _db;

  Stream<List<Playlist>> watchAll() => _named(_db.select(_db.playlists)).watch();

  Future<List<Playlist>> all() => _named(_db.select(_db.playlists)).get();

  Future<Playlist?> byId(String id) =>
      (_db.select(_db.playlists)..where(($PlaylistsTable t) => t.id.equals(id))).getSingleOrNull();

  Future<void> create({required String id, required String name, DateTime? createdAt}) {
    return _db.into(_db.playlists).insert(
          PlaylistsCompanion.insert(
            id: id,
            name: name,
            createdAt: (createdAt ?? DateTime.now()).toUtc(),
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  Future<void> rename(String id, String name) {
    return (_db.update(_db.playlists)..where(($PlaylistsTable t) => t.id.equals(id)))
        .write(PlaylistsCompanion(name: Value<String>(name)));
  }

  /// 删除播放列表（条目经外键级联清理）。
  Future<int> delete(String id) =>
      (_db.delete(_db.playlists)..where(($PlaylistsTable t) => t.id.equals(id))).go();

  /// 按保存的顺序返回曲目。
  Future<List<Track>> tracksOf(String playlistId) async {
    final JoinedSelectStatement<HasResultSet, dynamic> query = _db.select(_db.playlistItems).join(<Join<HasResultSet, dynamic>>[
      innerJoin(_db.tracks, _db.tracks.id.equalsExp(_db.playlistItems.trackId)),
    ])
      ..where(_db.playlistItems.playlistId.equals(playlistId))
      ..orderBy(<OrderingTerm>[OrderingTerm.asc(_db.playlistItems.position)]);
    final List<TypedResult> rows = await query.get();
    return rows.map((TypedResult row) => row.readTable(_db.tracks)).toList();
  }

  /// 追加一首到播放列表末尾。
  ///
  /// 位置始终保持 0..n-1 连续（追加递增、删除前移、重排整体重写），
  /// 因此下一条的位置就是当前条数，无需 MAX 聚合。
  Future<void> addTrack(String playlistId, String trackId) {
    return _db.transaction(() async {
      final Expression<int> count = _db.playlistItems.position.count();
      final int nextPosition = await (_db.selectOnly(_db.playlistItems)
            ..addColumns(<Expression<Object>>[count])
            ..where(_db.playlistItems.playlistId.equals(playlistId)))
          .map((TypedResult row) => row.read(count) ?? 0)
          .getSingle();
      await _db.into(_db.playlistItems).insert(
            PlaylistItemsCompanion.insert(
              playlistId: playlistId,
              trackId: trackId,
              position: nextPosition,
            ),
          );
    });
  }

  /// 删除指定位置的一条；后续位置顺次前移，保持连续。
  Future<void> removeAt(String playlistId, int position) {
    return _db.transaction(() async {
      await (_db.delete(_db.playlistItems)
            ..where(($PlaylistItemsTable t) => t.playlistId.equals(playlistId) & t.position.equals(position)))
          .go();
      await _shiftDownAfter(playlistId, from: position + 1);
    });
  }

  /// 重新排序：把 [from] 位置的条目移动到 [to]。
  Future<void> move(String playlistId, {required int from, required int to}) {
    if (from == to) {
      return Future<void>.value();
    }
    return _db.transaction(() async {
      final List<PlaylistItem> items = await (_db.select(_db.playlistItems)
            ..where(($PlaylistItemsTable t) => t.playlistId.equals(playlistId))
            ..orderBy(<OrderingTerm Function($PlaylistItemsTable)>[
              ($PlaylistItemsTable t) => OrderingTerm.asc(t.position)
            ]))
          .get();
      if (from < 0 || from >= items.length || to < 0 || to >= items.length) {
        return;
      }
      final List<PlaylistItem> reordered = List<PlaylistItem>.of(items);
      reordered.insert(to, reordered.removeAt(from));
      await _replacePositions(playlistId, reordered.map((PlaylistItem item) => item.trackId).toList());
    });
  }

  /// 整体替换曲目顺序（导入旧版播放列表时使用）。
  Future<void> replaceTracks(String playlistId, List<String> trackIds) {
    return _db.transaction(() async {
      await (_db.delete(_db.playlistItems)..where(($PlaylistItemsTable t) => t.playlistId.equals(playlistId))).go();
      await _replacePositions(playlistId, trackIds);
    });
  }

  /// 把 [from] 之后的条目整体前移一位。按位置升序写入，不会与主键冲突。
  Future<void> _shiftDownAfter(String playlistId, {required int from}) async {
    final List<PlaylistItem> tail = await (_db.select(_db.playlistItems)
          ..where(($PlaylistItemsTable t) => t.playlistId.equals(playlistId) & t.position.isBiggerOrEqualValue(from))
          ..orderBy(<OrderingTerm Function($PlaylistItemsTable)>[
            ($PlaylistItemsTable t) => OrderingTerm.asc(t.position)
          ]))
        .get();
    for (final PlaylistItem item in tail) {
      await (_db.update(_db.playlistItems)
            ..where(($PlaylistItemsTable t) =>
                t.playlistId.equals(playlistId) & t.position.equals(item.position)))
          .write(PlaylistItemsCompanion(position: Value<int>(item.position - 1)));
    }
  }

  Future<void> _replacePositions(String playlistId, List<String> trackIds) async {
    for (int index = 0; index < trackIds.length; index++) {
      await _db.into(_db.playlistItems).insertOnConflictUpdate(
            PlaylistItemsCompanion.insert(
              playlistId: playlistId,
              trackId: trackIds[index],
              position: index,
            ),
          );
    }
  }

  static SimpleSelectStatement<$PlaylistsTable, Playlist> _named(
    SimpleSelectStatement<$PlaylistsTable, Playlist> statement,
  ) {
    return statement..orderBy(<OrderingTerm Function($PlaylistsTable)>[($PlaylistsTable t) => OrderingTerm.asc(t.name)]);
  }
}
