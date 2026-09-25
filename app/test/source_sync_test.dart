import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/library_summaries.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/data/repositories/playlist_repository.dart';
import 'package:tingyu/data/repositories/source_repository.dart';
import 'package:tingyu/data/repositories/track_repository.dart';
import 'package:tingyu/features/sources/source_sync.dart';

import 'support/test_support.dart';

void main() {
  test('本地来源暂时不可访问时保留曲目、收藏和播放列表引用', () async {
    final TingyuDatabase database = openTestDatabase();
    addTearDown(database.close);
    final ProviderContainer container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    final Directory parent = await createTempDirectory();
    addTearDown(() => parent.delete(recursive: true));
    final PathProviderPlatform originalPathProvider =
        PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(parent.path);
    addTearDown(() => PathProviderPlatform.instance = originalPathProvider);
    final String unavailablePath = p.join(
      parent.path,
      'temporarily-unavailable',
    );

    final SourceRepository sources = SourceRepository(database);
    await sources.upsert(
      MusicSourcesCompanion.insert(
        id: 'src-1',
        name: '暂时离线的目录',
        kind: 'local',
        localFolderPath: Value<String?>(unavailablePath),
        trackCount: const Value<int>(1),
      ),
    );

    final TrackRepository tracks = TrackRepository(database);
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        const ScannedTrack(
          filePathOrUrl: '/music/keep.flac',
          title: '必须保留',
          artist: '歌手',
          album: '专辑',
          lyrics: '歌词',
          coverArtPath: 'cover.jpg',
          duration: 180,
          fileFormat: 'flac',
        ),
      ],
    );
    final Track original = (await tracks.bySource('src-1')).single;
    await tracks.setFavorite(original.id, value: true);

    final PlaylistRepository playlists = PlaylistRepository(database);
    await playlists.create(id: 'playlist-1', name: '不能损坏的歌单');
    await playlists.addTrack('playlist-1', original.id);

    final MusicSource source = (await sources.byId('src-1'))!;
    final MergeResult? result = await container
        .read(sourceSyncProvider.notifier)
        .sync(source);

    expect(result?.removed, 0);
    final List<Track> stored = await tracks.bySource('src-1');
    expect(stored, hasLength(1));
    expect(stored.single.isFavorite, isTrue);
    expect(await playlists.tracksOf('playlist-1'), hasLength(1));
    expect((await sources.byId('src-1'))?.trackCount, 1);
  });
}

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.applicationSupportPath);

  final String applicationSupportPath;

  @override
  Future<String?> getApplicationSupportPath() async => applicationSupportPath;
}
