import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;

import 'playback_engine.dart';
import 'playback_item.dart';
import 'playback_snapshot.dart';
import 'playback_error_formatter.dart';

/// 移动（Android / iOS）播放引擎，基于 `just_audio`（ExoPlayer / AVPlayer）。
///
/// 选型理由：移动端必须依赖系统解码器与音频会话（音频焦点、后台保活、锁屏控制），
/// 由 `audio_service` 统一接管；libmpv 在 Android 上无法提供前台服务与系统媒体通知。
final class JustAudioEngine extends PlaybackEngineBase {
  JustAudioEngine() {
    _subscriptions = <StreamSubscription<void>>[
      _player.playbackEventStream.listen(
        (_) => _sync(),
        onError: (Object error, StackTrace _) {
          // 换队列/换曲会打断上一次加载，这种"被打断"是正常噪声，不当作播放失败。
          if (error is ja.PlayerInterruptedException) {
            _sync();
            return;
          }
          _fail(error);
        },
      ),
      _player.positionStream.listen((_) => _sync()),
      _player.durationStream.listen((_) => _sync()),
      _player.bufferedPositionStream.listen((_) => _sync()),
      _player.currentIndexStream.listen((_) => _sync()),
      _player.volumeStream.listen((_) => _sync()),
      _player.speedStream.listen((_) => _sync()),
    ];
  }

  static const String _engineName = 'just_audio (ExoPlayer / AVPlayer)';

  final ja.AudioPlayer _player = ja.AudioPlayer();

  late final List<StreamSubscription<void>> _subscriptions;

  List<PlaybackItem> _items = const <PlaybackItem>[];

  /// 最近一次未恢复的失败；装载成功或播放进入 ready 后清空。
  PlaybackFailure? _failure;

  @override
  List<PlaybackItem> get items => _items;

  @override
  PlaybackItem? get currentItem {
    final int? index = _player.currentIndex;
    return (index != null && index >= 0 && index < _items.length)
        ? _items[index]
        : null;
  }

  @override
  String get name => _engineName;

  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {
    _items = List<PlaybackItem>.unmodifiable(items);
    _failure = null;
    try {
      await _player.setAudioSources(
        items.map(_toAudioSource).toList(growable: false),
        initialIndex: startIndex,
      );
    } on Object catch (error) {
      _fail(error);
      return;
    }
    _sync();
  }

  @override
  Future<void> addToQueue(PlaybackItem item) async {
    _items = List<PlaybackItem>.unmodifiable(<PlaybackItem>[..._items, item]);
    _failure = null;
    try {
      await _player.addAudioSource(_toAudioSource(item));
    } on Object catch (error) {
      _fail(error);
      return;
    }
    _sync();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setSpeed(rate);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await closeSnapshotStream();
  }

  static ja.AudioSource _toAudioSource(PlaybackItem item) => ja.AudioSource.uri(
    item.uri,
    headers: item.httpHeaders.isEmpty ? null : item.httpHeaders,
    tag: item,
  );

  /// 记录一次失败并立即播报。
  ///
  /// 失败以快照字段的形式向上传递，而不是抛出：加载路径分布在
  /// "起播 / 预取追加 / 自动切下一首"多处，逐处 try/catch 只会漏掉其中一侧。
  void _fail(Object error) {
    _failure = PlaybackFailure(
      message: PlaybackErrorFormatter.format(error),
      title: currentItem?.title,
    );
    _sync();
  }

  void _sync() {
    final ja.ProcessingState processingState = _player.processingState;
    if (processingState == ja.ProcessingState.ready) {
      _failure = null;
    }
    emit(
      PlaybackSnapshot(
        processing: _processingOf(processingState),
        playing: _player.playing,
        position: _player.position,
        duration: _player.duration ?? Duration.zero,
        buffered: _player.bufferedPosition,
        index: _player.currentIndex ?? 0,
        rate: _player.speed,
        volume: _player.volume,
        failure: _failure,
      ),
    );
  }

  static PlaybackProcessing _processingOf(ja.ProcessingState state) =>
      switch (state) {
        ja.ProcessingState.idle => PlaybackProcessing.idle,
        ja.ProcessingState.loading => PlaybackProcessing.loading,
        ja.ProcessingState.buffering => PlaybackProcessing.buffering,
        ja.ProcessingState.ready => PlaybackProcessing.ready,
        ja.ProcessingState.completed => PlaybackProcessing.completed,
      };
}
