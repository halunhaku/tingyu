import 'package:drift/drift.dart';

import '../db/database.dart';

/// 播放列表读写：顺序由 `playlist_items.position` 显式保存。
class PlaylistRepository {
  PlaylistRepository(this._db);

  final TingyuDatabase _db;

  Stream<List<Playlist>> watchAll() =>
      _named(_db.select(_db.playlists)).watch();

  Future<List<Playlist>> all() => _named(_db.select(_db.playlists)).get();

  Future<Playlist?> byId(String id) => (_db.select(
    _db.playlists,
  )..where(($PlaylistsTable t) => t.id.equals(id))).getSingleOrNull();

  Future<void> create({
    required String id,
    required String name,
    DateTime? createdAt,
  }) {
    return _db
        .into(_db.playlists)
        .insert(
          PlaylistsCompanion.insert(
            id: id,
            name: name,
            createdAt: (createdAt ?? DateTime.now()).toUtc(),
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  Future<void> rename(String id, String name) {
    return (_db.update(_db.playlists)
          ..where(($PlaylistsTable t) => t.id.equals(id)))
        .write(PlaylistsCompanion(name: Value<String>(name)));
  }

  /// 删除播放列表（条目经外键级联清理）。
  Future<int> delete(String id) => (_db.delete(
    _db.playlists,
  )..where(($PlaylistsTable t) => t.id.equals(id))).go();

  /// 按保存的顺序返回曲目。
  Future<List<Track>> tracksOf(String playlistId) async {
    final JoinedSelectStatement<HasResultSet, dynamic> query =
        _db.select(_db.playlistItems).join(<Join<HasResultSet, dynamic>>[
            innerJoin(
              _db.tracks,
              _db.tracks.id.equalsExp(_db.playlistItems.trackId),
            ),
          ])
          ..where(_db.playlistItems.playlistId.equals(playlistId))
          ..orderBy(<OrderingTerm>[
            OrderingTerm.asc(_db.playlistItems.position),
          ]);
    final List<TypedResult> rows = await query.get();
    return rows.map((TypedResult row) => row.readTable(_db.tracks)).toList();
  }

  /// 追加一首到播放列表末尾。
  ///
  /// 先压紧位置再取条数当新位置：曲目被扫描删除后 `playlist_items` 由外键级联
  /// 摘除但位置不重排，直接用条数会在空洞存在时撞 (playlist_id, position) 主键。
  Future<void> addTrack(String playlistId, String trackId) {
    return _db.transaction(() async {
      await _renumber(playlistId);
      final Expression<int> count = _db.playlistItems.position.count();
      final int nextPosition =
          await (_db.selectOnly(_db.playlistItems)
                ..addColumns(<Expression<Object>>[count])
                ..where(_db.playlistItems.playlistId.equals(playlistId)))
              .map((TypedResult row) => row.read(count) ?? 0)
              .getSingle();
      await _db
          .into(_db.playlistItems)
          .insert(
            PlaylistItemsCompanion.insert(
              playlistId: playlistId,
              trackId: trackId,
              position: nextPosition,
            ),
          );
    });
  }

  /// 删除第 [index] 行（按当前展示顺序，而不是 position 字面值）。
  ///
  /// 界面上传进来的是 ListView 的行号；压紧位置后行号与 position 等价，
  /// 否则空洞下会删掉另一首或什么都没删。
  Future<void> removeAt(String playlistId, int index) {
    if (index < 0) {
      return Future<void>.value();
    }
    return _db.transaction(() async {
      await _renumber(playlistId);
      final int removed =
          await (_db.delete(_db.playlistItems)..where(
                ($PlaylistItemsTable t) =>
                    t.playlistId.equals(playlistId) & t.position.equals(index),
              ))
              .go();
      if (removed > 0) {
        await _shiftDownAfter(playlistId, from: index + 1);
      }
    });
  }

  /// 重新排序：把 [from] 位置的条目移动到 [to]。
  Future<void> move(String playlistId, {required int from, required int to}) {
    if (from == to) {
      return Future<void>.value();
    }
    return _db.transaction(() async {
      final List<PlaylistItem> items =
          await (_db.select(_db.playlistItems)
                ..where(
                  ($PlaylistItemsTable t) => t.playlistId.equals(playlistId),
                )
                ..orderBy(<OrderingTerm Function($PlaylistItemsTable)>[
                  ($PlaylistItemsTable t) => OrderingTerm.asc(t.position),
                ]))
              .get();
      if (from < 0 || from >= items.length || to < 0 || to >= items.length) {
        return;
      }
      final List<PlaylistItem> reordered = List<PlaylistItem>.of(items);
      reordered.insert(to, reordered.removeAt(from));
      // 必须先清空再写：位置有空洞时 insertOnConflictUpdate 只覆写 0..n-1，
      // 旧的高位行会留下来，表现为列表里多出重复条目。
      await (_db.delete(_db.playlistItems)
            ..where(($PlaylistItemsTable t) => t.playlistId.equals(playlistId)))
          .go();
      await _replacePositions(
        playlistId,
        reordered
            .map((PlaylistItem item) => item.trackId)
            .toList(growable: false),
      );
    });
  }

  /// 把 `position` 压紧成 0..n-1（保持现有顺序）。
  ///
  /// 来源被删除或曲目被扫描删除时，`playlist_items` 由外键级联摘除，但剩下的行
  /// 位置不重排，于是出现空洞（0,2,3…）。空洞会让「第 index 行」与
  /// 「position == index」不再等价：追加会撞主键、按行号删除会删错曲目、
  /// 重排会留下旧的高位行。所有写操作前先压紧一次即可恢复该不变式。
  Future<void> _renumber(String playlistId) async {
    final List<PlaylistItem> items = await _orderedItems(playlistId);
    await (_db.delete(
      _db.playlistItems,
    )..where(($PlaylistItemsTable t) => t.playlistId.equals(playlistId))).go();
    await _replacePositions(
      playlistId,
      items.map((PlaylistItem item) => item.trackId).toList(growable: false),
    );
  }

  Future<List<PlaylistItem>> _orderedItems(String playlistId) {
    return (_db.select(_db.playlistItems)
          ..where(($PlaylistItemsTable t) => t.playlistId.equals(playlistId))
          ..orderBy(<OrderingTerm Function($PlaylistItemsTable)>[
            ($PlaylistItemsTable t) => OrderingTerm.asc(t.position),
          ]))
        .get();
  }

  /// 整体替换曲目顺序（导入旧版播放列表时使用）。
  Future<void> replaceTracks(String playlistId, List<String> trackIds) {
    return _db.transaction(() async {
      await (_db.delete(_db.playlistItems)
            ..where(($PlaylistItemsTable t) => t.playlistId.equals(playlistId)))
          .go();
      await _replacePositions(playlistId, trackIds);
    });
  }

  /// 把 [from] 之后的条目整体前移一位。按位置升序写入，不会与主键冲突。
  Future<void> _shiftDownAfter(String playlistId, {required int from}) async {
    final List<PlaylistItem> tail =
        await (_db.select(_db.playlistItems)
              ..where(
                ($PlaylistItemsTable t) =>
                    t.playlistId.equals(playlistId) &
                    t.position.isBiggerOrEqualValue(from),
              )
              ..orderBy(<OrderingTerm Function($PlaylistItemsTable)>[
                ($PlaylistItemsTable t) => OrderingTerm.asc(t.position),
              ]))
            .get();
    for (final PlaylistItem item in tail) {
      await (_db.update(_db.playlistItems)..where(
            ($PlaylistItemsTable t) =>
                t.playlistId.equals(playlistId) &
                t.position.equals(item.position),
          ))
          .write(
            PlaylistItemsCompanion(position: Value<int>(item.position - 1)),
          );
    }
  }

  Future<void> _replacePositions(
    String playlistId,
    List<String> trackIds,
  ) async {
    for (int index = 0; index < trackIds.length; index++) {
      await _db
          .into(_db.playlistItems)
          .insertOnConflictUpdate(
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
    return statement..orderBy(<OrderingTerm Function($PlaylistsTable)>[
      ($PlaylistsTable t) => OrderingTerm.asc(t.name),
    ]);
  }
}
