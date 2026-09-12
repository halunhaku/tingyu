import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'playback_engine.dart';
import 'playback_item.dart';
import 'playback_snapshot.dart';

/// 桌面（macOS / Windows / Linux）播放引擎，基于 `media_kit`（libmpv）。
///
/// 使用前必须已执行 `MediaKit.ensureInitialized()`。
/// 选型理由：桌面三平台解码能力一致（FFmpeg）、gapless、缓冲可控，且支持带鉴权头的 URL。
final class MediaKitEngine extends PlaybackEngineBase {
  MediaKitEngine() : _player = Player() {
    _subscriptions = <StreamSubscription<void>>[
      _player.stream.playing.listen((_) => _sync()),
      _player.stream.completed.listen((_) => _sync()),
      _player.stream.buffering.listen((_) => _sync()),
      _player.stream.position.listen((_) => _sync()),
      _player.stream.duration.listen((_) => _sync()),
      _player.stream.buffer.listen((_) => _sync()),
      _player.stream.playlist.listen((_) => _sync()),
      _player.stream.rate.listen((_) => _sync()),
      _player.stream.volume.listen((_) => _sync()),
    ];
  }

  static const String _engineName = 'media_kit (libmpv)';

  final Player _player;

  late final List<StreamSubscription<void>> _subscriptions;

  List<PlaybackItem> _items = const <PlaybackItem>[];

  @override
  List<PlaybackItem> get items => _items;

  @override
  PlaybackItem? get currentItem {
    final int index = _player.state.playlist.index;
    return (index >= 0 && index < _items.length) ? _items[index] : null;
  }

  @override
  String get name => _engineName;

  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {
    _items = List<PlaybackItem>.unmodifiable(items);
    await _player.open(
      Playlist(items.map(_toMedia).toList(growable: false), index: startIndex),
      play: false,
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
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> skipToNext() => _player.next();

  @override
  Future<void> skipToPrevious() => _player.previous();

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await closeSnapshotStream();
  }

  static Media _toMedia(PlaybackItem item) => Media(
        item.uri.toString(),
        httpHeaders: item.httpHeaders.isEmpty ? null : item.httpHeaders,
      );

  void _sync() {
    final PlayerState state = _player.state;
    emit(
      PlaybackSnapshot(
        processing: _processingOf(state),
        playing: state.playing,
        position: state.position,
        duration: state.duration,
        buffered: state.buffer,
        index: state.playlist.index,
        rate: state.rate,
        volume: state.volume,
      ),
    );
  }

  PlaybackProcessing _processingOf(PlayerState state) {
    if (state.playlist.medias.isEmpty) {
      return PlaybackProcessing.idle;
    }
    if (state.buffering) {
      return PlaybackProcessing.buffering;
    }
    if (state.completed) {
      return PlaybackProcessing.completed;
    }
    if (state.duration == Duration.zero) {
      return PlaybackProcessing.loading;
    }
    return PlaybackProcessing.ready;
  }
}
