import 'package:flutter/foundation.dart';

/// 播放处理阶段，与具体引擎解耦。
enum PlaybackProcessing { idle, loading, buffering, ready, completed }

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

  PlaybackSnapshot copyWith({
    PlaybackProcessing? processing,
    bool? playing,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    int? index,
    double? rate,
    double? volume,
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
    );
  }

  @override
  String toString() =>
      'PlaybackSnapshot(processing: $processing, playing: $playing, '
      'position: ${position.inMilliseconds}ms, duration: ${duration.inMilliseconds}ms, '
      'buffered: ${buffered.inMilliseconds}ms, index: $index, rate: $rate, volume: $volume)';
}
