import 'dart:async';

import 'package:flutter/foundation.dart';

import 'playback_item.dart';
import 'playback_snapshot.dart';

/// 播放引擎抽象：桌面（libmpv）与移动（ExoPlayer / AVPlayer）各有一套实现。
///
/// 上层（UI、[AudioHandler]）只允许依赖本接口，禁止直接引用具体引擎的 API。
abstract interface class PlaybackEngine {
  /// 引擎名，用于诊断与设置页展示。
  String get name;

  /// 状态流；订阅即收到当前值。
  Stream<PlaybackSnapshot> get snapshots;

  /// 最近一次状态。
  PlaybackSnapshot get current;

  /// 替换整个队列并从 [startIndex] 定位（不自动播放）。
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0});

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<void> setRate(double rate);

  Future<void> setVolume(double volume);

  Future<void> skipToNext();

  Future<void> skipToPrevious();

  Future<void> dispose();
}

/// 快照合并的公共实现：具体引擎只在自身事件回调里调用 [emit]。
abstract base class PlaybackEngineBase implements PlaybackEngine {
  final StreamController<PlaybackSnapshot> _controller =
      StreamController<PlaybackSnapshot>.broadcast();

  PlaybackSnapshot _snapshot = PlaybackSnapshot.initial;

  @override
  Stream<PlaybackSnapshot> get snapshots async* {
    yield _snapshot;
    yield* _controller.stream;
  }

  @override
  PlaybackSnapshot get current => _snapshot;

  @protected
  void emit(PlaybackSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_controller.isClosed) {
      _controller.add(snapshot);
    }
  }

  @protected
  Future<void> closeSnapshotStream() => _controller.close();
}
