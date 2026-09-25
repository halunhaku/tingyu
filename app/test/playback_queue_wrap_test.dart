import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/playback_controller.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/track_resolver.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'support/test_support.dart';

final class _MockEngine extends PlaybackEngineBase {
  @override
  String get name => 'mock';

  PlaybackSnapshot _snapshot = PlaybackSnapshot.initial;
  List<PlaybackItem> _queue = <PlaybackItem>[];
  int _index = 0;

  @override
  List<PlaybackItem> get items => _queue;

  @override
  PlaybackItem? get currentItem =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;

  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {
    _queue = List<PlaybackItem>.of(items);
    _index = startIndex;
    emit(
      _snapshot = _snapshot.copyWith(
        index: startIndex,
        position: Duration.zero,
        processing: PlaybackProcessing.ready,
      ),
    );
  }

  @override
  Future<void> addToQueue(PlaybackItem item) async {
    _queue.add(item);
    emit(_snapshot);
  }

  @override
  Future<void> play() async {
    emit(_snapshot = _snapshot.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    emit(_snapshot = _snapshot.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async {
    emit(_snapshot = _snapshot.copyWith(position: position));
  }

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  /// 走到队尾就停住（真实引擎此时进入 completed）。
  @override
  Future<void> skipToNext() async {
    if (_index + 1 < _queue.length) {
      _index++;
      emit(_snapshot = _snapshot.copyWith(index: _index));
      return;
    }
    emit(
      _snapshot = _snapshot.copyWith(
        playing: false,
        processing: PlaybackProcessing.completed,
      ),
    );
  }

  @override
  Future<void> skipToPrevious() async {
    if (_index > 0) {
      _index--;
      emit(_snapshot = _snapshot.copyWith(index: _index));
    }
  }

  /// 模拟「当前这首播完了」。
  void emitCompleted() {
    emit(
      _snapshot = _snapshot.copyWith(
        playing: false,
        processing: PlaybackProcessing.completed,
      ),
    );
  }

  @override
  Future<void> dispose() async => closeSnapshotStream();
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

Track _track(String id) => Track(
  id: id,
  sourceId: 'src-1',
  title: id,
  artist: '歌手',
  album: '专辑',
  duration: 200,
  fileFormat: 'mp3',
  filePathOrUrl: 'https://example.com/$id.mp3',
  fileSize: 1000,
  isFavorite: false,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

class _Harness {
  _Harness() : engine = _MockEngine(), db = openTestDatabase() {
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        audioHandlerProvider.overrideWithValue(TingyuAudioHandler(engine)),
        trackResolverProvider.overrideWith((Ref ref) => _DirectResolver(ref)),
      ],
    );
  }

  final _MockEngine engine;
  final TingyuDatabase db;
  late final ProviderContainer container;

  PlaybackController get controller =>
      container.read(playbackProvider.notifier);

  PlaybackSnapshot get state => container.read(playbackProvider);

  void dispose() {
    container.dispose();
    db.close();
  }
}

void main() {
  test('列表循环：队尾按「下一首」回到第一首继续播放', () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);

    await h.controller.playTracks(<Track>[_track('t1'), _track('t2')]);
    await h.controller.next();
    expect(h.state.index, 1);

    // 队尾再点下一首：列表循环必须回绕，而不是停住
    await h.controller.next();

    expect(h.state.index, 0, reason: '队尾之后必须回到第一首');
    expect(h.controller.currentItem?.title, 't1');
    expect(h.state.playing, isTrue);
  });

  test('列表循环：最后一首播完自动从头继续', () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);

    await h.controller.playTracks(<Track>[_track('t1'), _track('t2')]);
    await h.controller.next();
    expect(h.state.index, 1);

    h.engine.emitCompleted();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(h.state.index, 0, reason: '列表循环下播完最后一首应自动回绕');
    expect(h.controller.currentItem?.title, 't1');
    expect(h.state.playing, isTrue);
  });

  test('顺序播放：队尾不回绕，停下', () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);

    await h.controller.playTracks(<Track>[_track('t1'), _track('t2')]);
    h.controller.cycleRepeatMode(); // all -> one
    h.controller.cycleRepeatMode(); // one -> off
    expect(h.state.repeatMode, PlaybackRepeatMode.off);

    await h.controller.next();
    await h.controller.next();

    expect(h.state.index, 1, reason: '顺序播放不该回绕');
    expect(h.state.playing, isFalse);
  });

  test('单曲循环：播完把当前曲从头重播', () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);

    await h.controller.playTracks(<Track>[_track('t1'), _track('t2')]);
    h.controller.cycleRepeatMode(); // all -> one
    expect(h.state.repeatMode, PlaybackRepeatMode.one);

    await h.controller.seek(const Duration(seconds: 45));
    expect(h.state.position, const Duration(seconds: 45));

    h.engine.emitCompleted();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(h.state.index, 0);
    expect(h.state.position, Duration.zero, reason: '单曲循环应从 0 重播');
    expect(h.state.playing, isTrue);
  });
}
