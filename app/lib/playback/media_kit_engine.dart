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
      // libmpv 的失败（打不开文件、网络不可达、解码失败）从这里来，不会抛给调用方。
      _player.stream.error.listen((String message) => _fail(message)),
    ];
  }

  static const String _engineName = 'media_kit (libmpv)';

  final Player _player;

  late final List<StreamSubscription<void>> _subscriptions;

  List<PlaybackItem> _items = const <PlaybackItem>[];

  /// 最近一次未恢复的失败；装载成功或重新出声后清空。
  PlaybackFailure? _failure;

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
    _failure = null;
    try {
      await _player.open(
        Playlist(items.map(_toMedia).toList(growable: false), index: startIndex),
        play: false,
      );
    } on Object catch (error) {
      _fail(error.toString());
      return;
    }
    _sync();
  }

  @override
  Future<void> addToQueue(PlaybackItem item) async {
    _items = List<PlaybackItem>.unmodifiable(<PlaybackItem>[..._items, item]);
    _failure = null;
    try {
      await _player.add(_toMedia(item));
    } on Object catch (error) {
      _fail(error.toString());
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

  /// 记录一次失败并立即播报；失败以快照字段向上传递，不抛给调用方。
  void _fail(String message) {
    _failure = PlaybackFailure(message: message, title: currentItem?.title);
    _sync();
  }

  void _sync() {
    final PlayerState state = _player.state;
    // 有确定时长说明当前媒体确实装载成功，之前那次失败可以撤下来了。
    if (state.duration > Duration.zero) {
      _failure = null;
    }
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
        failure: _failure,
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
