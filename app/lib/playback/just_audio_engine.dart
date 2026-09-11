import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;

import 'playback_engine.dart';
import 'playback_item.dart';
import 'playback_snapshot.dart';

/// 移动（Android / iOS）播放引擎，基于 `just_audio`（ExoPlayer / AVPlayer）。
///
/// 选型理由：移动端必须依赖系统解码器与音频会话（音频焦点、后台保活、锁屏控制），
/// 由 `audio_service` 统一接管；libmpv 在 Android 上无法提供前台服务与系统媒体通知。
final class JustAudioEngine extends PlaybackEngineBase {
  JustAudioEngine() {
    _subscriptions = <StreamSubscription<void>>[
      _player.playbackEventStream.listen(
        (_) => _sync(),
        onError: (Object _, StackTrace _) => _sync(),
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

  @override
  String get name => _engineName;

  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {
    await _player.setAudioSources(
      items.map(_toAudioSource).toList(growable: false),
      initialIndex: startIndex,
    );
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

  void _sync() {
    emit(
      PlaybackSnapshot(
        processing: _processingOf(_player.processingState),
        playing: _player.playing,
        position: _player.position,
        duration: _player.duration ?? Duration.zero,
        buffered: _player.bufferedPosition,
        index: _player.currentIndex ?? 0,
        rate: _player.speed,
        volume: _player.volume,
      ),
    );
  }

  static PlaybackProcessing _processingOf(ja.ProcessingState state) => switch (state) {
        ja.ProcessingState.idle => PlaybackProcessing.idle,
        ja.ProcessingState.loading => PlaybackProcessing.loading,
        ja.ProcessingState.buffering => PlaybackProcessing.buffering,
        ja.ProcessingState.ready => PlaybackProcessing.ready,
        ja.ProcessingState.completed => PlaybackProcessing.completed,
      };
}
