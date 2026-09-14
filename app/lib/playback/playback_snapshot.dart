import 'package:flutter/foundation.dart';

/// 播放处理阶段，与具体引擎解耦。
enum PlaybackProcessing { idle, loading, buffering, ready, completed }

/// 一次播放失败：取直链失败之外的**引擎侧**错误都归到这里
/// （文件不存在、网络不可达、权限被撤销、解码失败、明文流量被拦等）。
///
/// 每次失败都构造新实例。引擎的进度事件会以很高的频率反复推送同一份快照，
/// UI 因此不能按"字段值变了"判断是否提示，而要按"是不是同一个失败对象"判断：
/// 同一个 [PlaybackFailure] 实例只提示一次，新实例就是新的一次失败。
@immutable
class PlaybackFailure {
  const PlaybackFailure({required this.message, this.title});

  /// 面向用户的失败原因，不含堆栈。
  final String message;

  /// 出问题的曲目标题；引擎不知道时为空。
  final String? title;
}

/// 播放引擎对外的唯一状态载体。
///
/// UI 层与系统媒体会话（[AudioHandler]）都只消费它，避免双引擎各自的状态口径漂移。
@immutable
class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.processing,
    required this.playing,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.index,
    required this.rate,
    required this.volume,
    this.failure,
  });

  static const PlaybackSnapshot initial = PlaybackSnapshot(
    processing: PlaybackProcessing.idle,
    playing: false,
    position: Duration.zero,
    duration: Duration.zero,
    buffered: Duration.zero,
    index: 0,
    rate: 1,
    volume: 1,
  );

  final PlaybackProcessing processing;

  final bool playing;

  final Duration position;

  final Duration duration;

  final Duration buffered;

  /// 队列内当前曲目下标。
  final int index;

  final double rate;

  final double volume;

  /// 最近一次未恢复的播放失败；播放重新正常（或换曲成功装载）后自动清空。
  final PlaybackFailure? failure;

  PlaybackSnapshot copyWith({
    PlaybackProcessing? processing,
    bool? playing,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    int? index,
    double? rate,
    double? volume,
    PlaybackFailure? failure,
    bool clearFailure = false,
  }) {
    return PlaybackSnapshot(
      processing: processing ?? this.processing,
      playing: playing ?? this.playing,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      buffered: buffered ?? this.buffered,
      index: index ?? this.index,
      rate: rate ?? this.rate,
      volume: volume ?? this.volume,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }

  @override
  String toString() =>
      'PlaybackSnapshot(processing: $processing, playing: $playing, '
      'position: ${position.inMilliseconds}ms, duration: ${duration.inMilliseconds}ms, '
      'buffered: ${buffered.inMilliseconds}ms, index: $index, rate: $rate, volume: $volume'
      '${failure == null ? '' : ', failure: ${failure!.message}'})';
}
