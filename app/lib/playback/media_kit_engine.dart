import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'playback_engine.dart';
import 'playback_item.dart';
import 'playback_snapshot.dart';
import 'playback_error_formatter.dart';

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

  /// 上一次同步时的播放位置，用于判断「音频确实在推进」。
  Duration _lastPosition = Duration.zero;

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
    _lastPosition = Duration.zero;
    try {
      await _player.open(
        Playlist(
          items.map(_toMedia).toList(growable: false),
          index: startIndex,
        ),
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
    _lastPosition = Duration.zero;
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

  /// libmpv 的单曲循环（`PlaylistMode.single`）由 mpv 自己循环，转场无缝；列表循环
  /// 与不循环都用 `none`，列表回绕交给控制器在 completed 时重建队列。
  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) => _player.setPlaylistMode(
    mode == PlaybackRepeatMode.one ? PlaylistMode.single : PlaylistMode.none,
  );

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
    _failure = PlaybackFailure(
      message: PlaybackErrorFormatter.format(message),
      title: currentItem?.title,
    );
    _sync();
  }

  void _sync() {
    final PlayerState state = _player.state;
    // 撤下失败提示的唯一依据是「确实重新出声了」：正在播放且播放位置在前进。
    //
    // 不能用「duration > 0」判断 —— mpv 装载失败时 state.duration 还停留在上一首，
    // 于是 _fail() 里紧接着的这次 _sync() 会立刻把刚记下的失败抹掉：直链过期、
    // 中途断网、解码失败在桌面端全部静默，用户只看到"点了没反应/自动跳下一首"。
    // 也不能只看 playing：装载失败后它仍可能报 true。
    final bool progressing = state.playing && state.position > _lastPosition;
    _lastPosition = state.position;
    if (_failure != null && progressing) {
      _failure = null;
    }
    emit(
      PlaybackSnapshot(
        processing: processingOf(state),
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

  /// 纯函数，只吃 libmpv 推来的 [PlayerState]；`@visibleForTesting` 是为了在
  /// 没有原生库的单元测试里守住"未知时长不等于还在加载"。
  @visibleForTesting
  static PlaybackProcessing processingOf(PlayerState state) {
    if (state.playlist.medias.isEmpty) {
      return PlaybackProcessing.idle;
    }
    if (state.buffering) {
      return PlaybackProcessing.buffering;
    }
    if (state.completed) {
      return PlaybackProcessing.completed;
    }
    // duration 未知 ≠ 还在加载：夸克 / WebDAV 这类直链没有 Content-Length，
    // mpv 的 state.duration 会整首都是 0；按 loading 处理会让播放键整首歌都停在
    // 转圈图标上（用户以为没播）。队列里有条目、又不在缓冲/播完，就是可播放的。
    return PlaybackProcessing.ready;
  }
}
