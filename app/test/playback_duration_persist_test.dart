import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/track_resolver.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/data/repositories/track_repository.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'support/test_support.dart';

/// 夸克 / WebDAV 的目录接口不报时长，扫描入库写的是 0，界面整库显示 `--:--`。
/// 解码器给出的时长是唯一可信来源：控制器要在它第一次 > 0 时补进曲库，
/// 且**每首只补一次**（进度事件每 ~60ms 一份，逐个写会把库写热）。
final class _FakeEngine extends PlaybackEngineBase {
  @override
  String get name => 'fake';

  List<PlaybackItem> _items = const <PlaybackItem>[];

  int _index = 0;

  @override
  List<PlaybackItem> get items => _items;

  @override
  PlaybackItem? get currentItem =>
      _index >= 0 && _index < _items.length ? _items[_index] : null;

  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {
    _items = List<PlaybackItem>.unmodifiable(items);
    _index = startIndex;
  }

  @override
  Future<void> addToQueue(PlaybackItem item) async {
    _items = List<PlaybackItem>.unmodifiable(<PlaybackItem>[..._items, item]);
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> dispose() async => closeSnapshotStream();

  /// 推送一份"当前曲目时长已知"的快照（`emit` 为 protected）。
  void pushDuration(Duration duration, {int index = 0}) => emit(
    PlaybackSnapshot(
      processing: PlaybackProcessing.ready,
      playing: true,
      position: Duration.zero,
      duration: duration,
      buffered: Duration.zero,
      index: index,
      rate: 1,
      volume: 1,
    ),
  );
}

final class _DirectResolver extends TrackResolver {
  _DirectResolver(super.ref);

  @override
  Future<PlaybackItem> resolve(Track track) async => PlaybackItem(
    id: track.id,
    uri: Uri.parse(track.filePathOrUrl),
    title: track.title,
    artist: track.artist,
    album: track.album,
  );
}

/// 记录补写时长的调用；同时把真正的写库路径也走一遍。
final class _RecordingTrackRepository extends TrackRepository {
  _RecordingTrackRepository(super.db);

  final List<(String, Duration)> durations = <(String, Duration)>[];

  @override
  Future<void> updateDurationIfUnknown(String id, Duration duration) {
    durations.add((id, duration));
    return super.updateDurationIfUnknown(id, duration);
  }
}

const String _sourceId = 'quark-1';

/// 曲目的 id 与库里一致（`TrackRepository.idFor`）：控制器补写时长时用的就是它。
Track _track(String id) => Track(
  id: TrackRepository.idFor(sourceId: _sourceId, filePathOrUrl: 'quark://$id'),
  sourceId: _sourceId,
  title: id,
  artist: '周杰伦',
  album: 'Jay',
  duration: 0,
  fileFormat: 'mp3',
  filePathOrUrl: 'quark://$id',
  fileSize: 0,
  isFavorite: false,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

void main() {
  late TingyuDatabase db;
  late _RecordingTrackRepository repository;
  late _FakeEngine engine;
  late ProviderContainer container;

  setUp(() async {
    db = openTestDatabase();
    repository = _RecordingTrackRepository(db);
    engine = _FakeEngine();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        trackRepositoryProvider.overrideWithValue(repository),
        audioHandlerProvider.overrideWithValue(TingyuAudioHandler(engine)),
        trackResolverProvider.overrideWith((Ref ref) => _DirectResolver(ref)),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// 库里先有一条时长为 0 的曲目（与扫描夸克目录的结果一致）。
  Future<void> seedTrack(String id) async {
    await TrackRepository(db).mergeScan(
      sourceId: _sourceId,
      scanned: <ScannedTrack>[
        ScannedTrack(
          filePathOrUrl: 'quark://$id',
          title: id,
          artist: '周杰伦',
          album: 'Jay',
          duration: 0,
          fileSize: 0,
          fileFormat: 'mp3',
        ),
      ],
    );
  }

  test('引擎报出真实时长后，曲库里那份 0 被补上', () async {
    await seedTrack('t1');
    final String id = TrackRepository.idFor(
      sourceId: _sourceId,
      filePathOrUrl: 'quark://t1',
    );
    expect((await TrackRepository(db).byId(id))?.duration, 0);

    await container.read(playbackProvider.notifier).playTracks(<Track>[
      _track('t1'),
    ]);
    engine.pushDuration(const Duration(seconds: 201));
    await pumpEventQueue();

    expect(repository.durations, <(String, Duration)>[
      (id, const Duration(seconds: 201)),
    ]);
    expect((await TrackRepository(db).byId(id))?.duration, 201);
  });

  test('同一首的后续进度事件不再写库，换一首才再写一次', () async {
    await seedTrack('t1');
    await container.read(playbackProvider.notifier).playTracks(<Track>[
      _track('t1'),
      _track('t2'),
    ]);

    engine.pushDuration(const Duration(seconds: 201));
    await pumpEventQueue();
    engine.pushDuration(const Duration(seconds: 201));
    engine.pushDuration(const Duration(seconds: 201));
    await pumpEventQueue();

    expect(
      repository.durations,
      hasLength(1),
      reason: '每 ~60ms 一份快照，逐份写会把数据库写热',
    );

    // 切到第二首（预取会把 t2 追加进引擎队列）
    engine.pushDuration(const Duration(seconds: 188), index: 1);
    await pumpEventQueue();

    expect(repository.durations.map((record) => record.$2).toList(), <Duration>[
      const Duration(seconds: 201),
      const Duration(seconds: 188),
    ]);
  });

  test('时长还不知道时（0）不写库，等到真实时长那一次', () async {
    await seedTrack('t1');
    await container.read(playbackProvider.notifier).playTracks(<Track>[
      _track('t1'),
    ]);

    engine.pushDuration(Duration.zero);
    await pumpEventQueue();
    expect(repository.durations, isEmpty);

    engine.pushDuration(const Duration(seconds: 201));
    await pumpEventQueue();
    expect(repository.durations, hasLength(1));
  });
}
