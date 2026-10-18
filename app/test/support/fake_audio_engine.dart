import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';

/// 可控假播放引擎：UI 测试里不接触任何真实音频后端。
///
/// 与各测试里散落的 `_SilentEngine` / `_DummyEngine` 不同，这里额外提供：
/// - 调用计数与最后一次参数（断言「UI 是否真的把操作下发给了引擎」）；
/// - `emitState(...)` 主动推进快照（播放中、缓冲、失败、倍速等状态可复现）；
/// - 可注入的失败（`failure`），用于验证播放失败态在 UI 上是否真的被渲染。
final class FakeAudioEngine extends PlaybackEngineBase {
  FakeAudioEngine({this.name = 'fake'});

  @override
  final String name;

  final List<PlaybackItem> _items = <PlaybackItem>[];
  int _index = 0;

  /// 调用计数：UI 不应重复下发同一操作（例如每次 rebuild 都 seek）。
  int playCalls = 0;
  int pauseCalls = 0;
  int skipNextCalls = 0;
  int skipPreviousCalls = 0;
  int setQueueCalls = 0;
  int addToQueueCalls = 0;

  /// 最后一次下发的参数。
  Duration? lastSeek;
  double? lastRate;
  double? lastVolume;
  PlaybackRepeatMode? lastRepeatMode;

  /// 注入失败：非空时对应方法抛出。
  Object? setQueueError;
  Object? playError;

  @override
  List<PlaybackItem> get items => List<PlaybackItem>.unmodifiable(_items);

  @override
  PlaybackItem? get currentItem =>
      _items.isEmpty ? null : _items[_index.clamp(0, _items.length - 1)];

  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {
    setQueueCalls++;
    final Object? error = setQueueError;
    if (error != null) {
      throw error;
    }
    _items
      ..clear()
      ..addAll(items);
    _index = _items.isEmpty ? 0 : startIndex.clamp(0, _items.length - 1);
    emitState(
      processing: _items.isEmpty
          ? PlaybackProcessing.idle
          : PlaybackProcessing.ready,
      index: _index,
    );
  }

  @override
  Future<void> addToQueue(PlaybackItem item) async {
    addToQueueCalls++;
    _items.add(item);
    emitState(index: _index);
  }

  @override
  Future<void> play() async {
    playCalls++;
    final Object? error = playError;
    if (error != null) {
      throw error;
    }
    emitState(playing: true, processing: PlaybackProcessing.ready);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    emitState(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    emitState(position: position);
  }

  @override
  Future<void> setRate(double rate) async {
    lastRate = rate;
    emitState(rate: rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
    emitState(volume: volume);
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {
    lastRepeatMode = mode;
    emitState(repeatMode: mode);
  }

  @override
  Future<void> skipToNext() async {
    skipNextCalls++;
    if (_items.isNotEmpty) {
      _index = (_index + 1).clamp(0, _items.length - 1);
    }
    emitState(index: _index, position: Duration.zero);
  }

  @override
  Future<void> skipToPrevious() async {
    skipPreviousCalls++;
    if (_items.isNotEmpty) {
      _index = (_index - 1).clamp(0, _items.length - 1);
    }
    emitState(index: _index, position: Duration.zero);
  }

  @override
  Future<void> dispose() async => closeSnapshotStream();

  /// 主动推进快照：未给出的字段沿用当前值，因此调用处只声明本次变化。
  void emitState({
    PlaybackProcessing? processing,
    bool? playing,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    int? index,
    double? rate,
    double? volume,
    PlayOrder? playOrder,
    PlaybackRepeatMode? repeatMode,
    PlaybackFailure? failure,
  }) {
    final PlaybackSnapshot now = current;
    emit(
      PlaybackSnapshot(
        processing: processing ?? now.processing,
        playing: playing ?? now.playing,
        position: position ?? now.position,
        duration: duration ?? now.duration,
        buffered: buffered ?? now.buffered,
        index: index ?? now.index,
        rate: rate ?? now.rate,
        volume: volume ?? now.volume,
        playOrder: playOrder ?? now.playOrder,
        repeatMode: repeatMode ?? now.repeatMode,
        failure: failure ?? now.failure,
      ),
    );
  }
}
