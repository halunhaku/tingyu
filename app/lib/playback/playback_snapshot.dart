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

/// 播放顺序：顺序播放或随机打乱。
enum PlayOrder {
  /// 顺序播放（按原始列表顺序）
  sequential,

  /// 随机播放（打乱队列顺序）
  shuffle,
}

/// 循环模式：不循环、列表循环、单曲循环。
enum PlaybackRepeatMode {
  /// 不循环：播完列表末尾后停止
  off,

  /// 列表循环：播完列表末尾后循环回第一首
  all,

  /// 单曲循环：单曲结束后重新播放该曲
  one,
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
    this.playOrder = PlayOrder.sequential,
    this.repeatMode = PlaybackRepeatMode.all,
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
    playOrder: PlayOrder.sequential,
    repeatMode: PlaybackRepeatMode.all,
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

  /// 播放顺序（顺序 / 随机）。
  final PlayOrder playOrder;

  /// 循环模式（不循环 / 列表循环 / 单曲循环）。
  final PlaybackRepeatMode repeatMode;

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
    PlayOrder? playOrder,
    PlaybackRepeatMode? repeatMode,
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
      playOrder: playOrder ?? this.playOrder,
      repeatMode: repeatMode ?? this.repeatMode,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }

  @override
  String toString() =>
      'PlaybackSnapshot(processing: $processing, playing: $playing, '
      'position: ${position.inMilliseconds}ms, duration: ${duration.inMilliseconds}ms, '
      'buffered: ${buffered.inMilliseconds}ms, index: $index, rate: $rate, volume: $volume'
      '${failure == null ? '' : ', failure: ${failure!.message}'})';

  /// 按值比较，**包括** [failure]。
  ///
  /// 引擎的进度事件每 ~60ms（media_kit）/ ~200ms（just_audio）推一份新快照，
  /// 若只按实例比较，Riverpod 会把每一次推进都当成"状态变了"，所有 watcher
  /// （迷你条、进度条、歌词……）跟着每次 tick 重建。这里做值比较后，只有真正
  /// 变化的快照才会让 `updateShouldNotify` 成立。
  ///
  /// [failure] 只比字段而不复用 [PlaybackFailure] 的相等性：那个类的文档约定
  /// "新实例就是新的一次失败"，UI 靠 `identical` 去重提示，不能改成值相等。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackSnapshot &&
          other.processing == processing &&
          other.playing == playing &&
          other.position == position &&
          other.duration == duration &&
          other.buffered == buffered &&
          other.index == index &&
          other.rate == rate &&
          other.volume == volume &&
          other.playOrder == playOrder &&
          other.repeatMode == repeatMode &&
          other.failure?.message == failure?.message &&
          other.failure?.title == failure?.title;

  @override
  int get hashCode => Object.hash(
    processing,
    playing,
    position,
    duration,
    buffered,
    index,
    rate,
    volume,
    playOrder,
    repeatMode,
    failure?.message,
    failure?.title,
  );
}
