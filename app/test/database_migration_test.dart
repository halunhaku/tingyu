import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/repositories/source_repository.dart';
import 'package:tingyu/data/repositories/track_repository.dart';

void main() {
  test(
    '打开已有未设版本号、含 idx_tracks_source 与旧版 sources 表的 SQLite 时不崩溃且自动迁移',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'tingyu_db_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File dbFile = File(p.join(temp.path, 'legacy_crash.sqlite'));

      // 模拟出问题的用户实际数据库状态：
      final sqlite.Database raw = sqlite.sqlite3.open(dbFile.path);
      raw.execute('''
      CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '未知艺术家',
        album TEXT NOT NULL DEFAULT '未知专辑',
        duration REAL NOT NULL DEFAULT 0,
        file_format TEXT NOT NULL DEFAULT 'mp3',
        file_path_or_url TEXT NOT NULL DEFAULT '',
        file_size INTEGER NOT NULL DEFAULT 0,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        play_count INTEGER NOT NULL DEFAULT 0,
        date_added TEXT NOT NULL
      );
    ''');
      raw.execute('CREATE INDEX idx_tracks_source ON tracks(source_id);');
      raw.execute('''
      INSERT INTO tracks (id, source_id, title, date_added)
      VALUES ('t-1', 'src-quark-1', '一路向北', '2026-09-01T00:00:00.000Z');
    ''');
      raw.execute('''
      CREATE TABLE sources (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        local_folder_path TEXT,
        webdav_url TEXT,
        webdav_username TEXT,
        webdav_root_path TEXT,
        quark_folder_fid TEXT,
        quark_account_name TEXT,
        sync_status TEXT NOT NULL DEFAULT '未同步',
        last_synced_at TEXT,
        track_count INTEGER NOT NULL DEFAULT 0
      );
    ''');
      raw.execute('''
      INSERT INTO sources (id, name, kind, sync_status, track_count)
      VALUES ('src-quark-1', '我的夸克云盘', 'quark', '已同步', 178);
    ''');
      raw.close();
      final TingyuDatabase db = TingyuDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      final List<MusicSource> sources = await db.select(db.musicSources).get();
      expect(sources, hasLength(1));
      expect(sources.single.id, 'src-quark-1');
      expect(sources.single.name, '我的夸克云盘');
      expect(sources.single.kind, 'quark');

      final TrackRepository tracks = TrackRepository(db);
      final List<Track> allTracks = await tracks.all();
      expect(allTracks, hasLength(1));
      await tracks.updateCoverArt(allTracks.single.id, path: 'covers/test.jpg');
      final Track updated = (await tracks.byId(allTracks.single.id))!;
      expect(updated.coverArtPath, 'covers/test.jpg');
    },
  );

  test('删除迁移过来的来源后重开数据库，不会被 legacy 表重新插回来', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'tingyu_db_migrate_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final File dbFile = File(p.join(temp.path, 'legacy_resurrect.sqlite'));

    final sqlite.Database raw = sqlite.sqlite3.open(dbFile.path);
    raw.execute('''
      CREATE TABLE sources (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        local_folder_path TEXT,
        webdav_url TEXT,
        webdav_username TEXT,
        webdav_root_path TEXT,
        quark_folder_fid TEXT,
        quark_account_name TEXT,
        sync_status TEXT NOT NULL DEFAULT '未同步',
        last_synced_at TEXT,
        track_count INTEGER NOT NULL DEFAULT 0
      );
    ''');
    raw.execute('''
      INSERT INTO sources (id, name, kind, sync_status, track_count)
      VALUES ('src-legacy-1', '旧版来源', 'quark', '已同步', 178);
    ''');
    raw.close();

    // 第一次打开：迁移进 music_sources
    TingyuDatabase db = TingyuDatabase(NativeDatabase(dbFile));
    List<MusicSource> sources = await db.select(db.musicSources).get();
    expect(sources, hasLength(1));

    // 用户删掉这个来源
    await SourceRepository(db).delete('src-legacy-1');
    expect(await db.select(db.musicSources).get(), isEmpty);
    await db.close();

    // 重开：迁移代码不应再把已删除的来源从 legacy 表里复制回来
    db = TingyuDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);
    sources = await db.select(db.musicSources).get();
    expect(
      sources,
      isEmpty,
      reason: 'legacy sources 表必须在迁移完成后清理，否则删掉的来源每次启动都会复活',
    );
  });
}
