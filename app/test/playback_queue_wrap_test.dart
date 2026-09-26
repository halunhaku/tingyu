import 'dart:async';

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

  /// 引擎收到的指令，用来断言控制器的行为真的下达到了引擎。
  final List<String> commands = <String>[];

  final List<PlaybackRepeatMode> repeatModes = <PlaybackRepeatMode>[];

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
    commands.add('setQueue:$startIndex');
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
    commands.add('play');
    emit(_snapshot = _snapshot.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    emit(_snapshot = _snapshot.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async {
    commands.add('seek:${position.inMilliseconds}');
    emit(_snapshot = _snapshot.copyWith(position: position));
  }

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async =>
      repeatModes.add(mode);

  /// 走到队尾就停住（真实引擎此时进入 completed）。
  @override
  Future<void> skipToNext() async {
    commands.add('next');
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

  /// 模拟一次普通的进度事件（位置在推进）。
  ///
  /// 位置必须真的变化：快照是按值比较的，同值快照不会触发监听。
  void emitProgress() {
    emit(
      _snapshot = _snapshot.copyWith(
        playing: true,
        processing: PlaybackProcessing.ready,
        position: _snapshot.position + const Duration(milliseconds: 60),
      ),
    );
  }

  @override
  Future<void> dispose() async => closeSnapshotStream();
}

final class _GatedResolver extends TrackResolver {
  _GatedResolver(super.ref);

  /// 需要挂起的曲目 id → 放行闸门；用来制造"解析还在飞"的窗口。
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};

  void gate(String id) => _gates[id] = Completer<void>();

  void release(String id) => _gates.remove(id)?.complete();

  @override
  Future<PlaybackItem> resolve(Track track) async {
    await _gates[track.id]?.future;
    return PlaybackItem(
      id: track.id,
      uri: Uri.parse(track.filePathOrUrl),
      title: track.title,
      artist: track.artist,
      album: track.album,
    );
  }
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
        trackResolverProvider.overrideWith((Ref ref) => _GatedResolver(ref)),
      ],
    );
  }

  final _MockEngine engine;

  /// 解析器是在 provider 首次读取时创建的，这里按需取同一个实例。
  _GatedResolver get resolver =>
      container.read(trackResolverProvider) as _GatedResolver;

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

  test('顺序播放：队尾不回绕，停下并回到 0', () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);

    await h.controller.playTracks(<Track>[_track('t1'), _track('t2')]);
    h.controller.cycleRepeatMode(); // all -> one
    h.controller.cycleRepeatMode(); // one -> off
    expect(h.state.repeatMode, PlaybackRepeatMode.off);

    await h.controller.next();
    await h.controller.next();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(h.state.index, 1, reason: '顺序播放不该回绕');
    expect(h.state.playing, isFalse);
    expect(
      h.state.position,
      Duration.zero,
      reason: '停在 completed 上 play()/next() 都是空操作，必须拨回 0',
    );
    expect(h.engine.commands, contains('pause'));
    expect(h.engine.commands, contains('seek:0'));
  });

  test('顺序播放播完后按播放键能重新出声', () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);

    await h.controller.playTracks(<Track>[_track('t1'), _track('t2')]);
    h.controller.cycleRepeatMode(); // all -> one
    h.controller.cycleRepeatMode(); // one -> off
    await h.controller.next();
    await h.controller.next();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(h.state.processing, PlaybackProcessing.completed);
    expect(h.state.playing, isFalse);

    h.engine.commands.clear();
    await h.controller.togglePlayPause();

    expect(
      h.engine.commands,
      <String>['seek:0', 'play'],
      reason: '引擎停在 completed 上，play() 是空操作，必须先回 0',
    );
    expect(h.state.playing, isTrue);
  });

  test('单曲循环：播完把当前曲从头重播（引擎不支持循环时的兜底）', () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);

    await h.controller.playTracks(<Track>[_track('t1'), _track('t2')]);
    h.controller.cycleRepeatMode(); // all -> one
    expect(h.state.repeatMode, PlaybackRepeatMode.one);
    expect(
      h.engine.repeatModes,
      <PlaybackRepeatMode>[PlaybackRepeatMode.one],
      reason: '单曲循环必须下发给引擎：两个引擎默认都只在列表末尾报 completed',
    );

    await h.controller.seek(const Duration(seconds: 45));
    expect(h.state.position, const Duration(seconds: 45));

    h.engine.emitCompleted();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(h.state.index, 0);
    expect(h.state.position, Duration.zero, reason: '单曲循环应从 0 重播');
    expect(h.state.playing, isTrue);
  });

  test('切回不循环/列表循环时，引擎收到的循环模式跟着变', () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);

    await h.controller.playTracks(<Track>[_track('t1')]);
    h.controller.cycleRepeatMode(); // all -> one
    h.controller.cycleRepeatMode(); // one -> off
    h.controller.cycleRepeatMode(); // off -> all

    expect(h.engine.repeatModes, <PlaybackRepeatMode>[
      PlaybackRepeatMode.one,
      PlaybackRepeatMode.off,
      PlaybackRepeatMode.all,
    ], reason: '控制器把用户选的模式原样交给引擎，由引擎把 all 映射成 off（列表回绕在控制器）');
  });

  test('重建队列期间旧会话的进度事件不会把预取塞进旧队列', () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);

    await h.controller.playTracks(<Track>[_track('t1'), _track('t2')]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(h.controller.trackIds, <String>['t1', 't2']);

    // 新会话：点的那一首解析挂在闸门上，期间旧会话仍在推事件。
    h.resolver.gate('t3');
    final Future<void> restart = h.controller.playTracks(<Track>[
      _track('t3'),
      _track('t4'),
    ]);
    await Future<void>.delayed(Duration.zero);
    h.engine.emitProgress();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    h.resolver.release('t3');
    await restart;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      h.controller.trackIds,
      <String>['t3', 't4'],
      reason: '重建期间预取把 t4 提前吃掉的话，新会话就永远少一首',
    );
    expect(
      h.engine.items.map((PlaybackItem item) => item.id).toList(),
      <String>['t3', 't4'],
      reason: '旧引擎队列上的残留追加必须被新队列替换掉',
    );
  });

  test('跳转播放会等在飞的预取落地，引擎队列不会少一首', () async {
    final _Harness h = _Harness();
    addTearDown(h.dispose);

    h.resolver.gate('t3');
    await h.controller.playTracks(<Track>[
      _track('t1'),
      _track('t2'),
      _track('t3'),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(h.controller.trackIds, <String>['t1', 't2']);

    // t3 的解析还挂在闸门上，此时跳到已解析的第一首。
    final Future<void> jump = h.controller.playAt(0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    h.resolver.release('t3');
    await jump;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(h.controller.trackIds, <String>['t1', 't2', 't3']);
    expect(
      h.engine.items.length,
      h.controller.trackIds.length,
      reason: '引擎队列与控制器三份平行数组必须同长度（少一首就是下标错位）',
    );
    expect(h.engine.currentItem?.id, 't1');
  });
}
