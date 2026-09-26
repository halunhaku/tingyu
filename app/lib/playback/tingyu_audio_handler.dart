import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'playback_engine.dart';
import 'playback_item.dart';
import 'playback_snapshot.dart';

/// 播放引擎与系统媒体会话之间的唯一桥接点。
///
/// 职责边界：把 [PlaybackEngine] 的快照翻译成 `audio_service` 的
/// [playbackState] / [mediaItem] / [queue]，反向把系统指令（媒体键、锁屏、
/// SMTC、MPRIS、通知栏）转发给引擎。
/// 平台映射由 `audio_service` 及其平台实现完成：
/// macOS/iOS → MPNowPlayingInfoCenter + MPRemoteCommandCenter，
/// Android → MediaSession，Windows → SMTC（`audio_service_win`），
/// Linux → MPRIS2（`audio_service_mpris`）。
final class TingyuAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  TingyuAudioHandler(
    this._engine, {
    this.statePushInterval = const Duration(milliseconds: 500),
  }) {
    _subscription = _engine.snapshots.listen(_broadcast);
  }

  final PlaybackEngine _engine;

  /// 纯进度更新推送到系统媒体会话的最小间隔。
  final Duration statePushInterval;

  late final StreamSubscription<PlaybackSnapshot> _subscription;

  List<PlaybackItem> _items = const <PlaybackItem>[];

  /// 与 [_items] 平行的 [MediaItem] 缓存。
  ///
  /// 以前每次 `addToQueue` 都把整条队列重新翻译一遍再整条 publish：懒解析队列是
  /// 逐首追加的，于是 O(n²) 次分配 + 每次平台通道都要搬运整条列表。现在只在
  /// `setQueue` 重建、`addToQueue` 追加一个。
  List<MediaItem> _mediaItems = const <MediaItem>[];

  PlaybackSnapshot? _lastPushed;

  DateTime _lastPushAt = DateTime.fromMillisecondsSinceEpoch(0);

  String? _lastMediaItemId;

  int? _lastMediaItemIndex;

  Duration? _lastMediaItemDuration;

  /// 引擎名，便于设置页与诊断展示。
  String get engineName => _engine.name;

  /// 播放状态流：UI 与系统媒体会话消费同一个源，避免双引擎口径漂移。
  Stream<PlaybackSnapshot> get snapshots => _engine.snapshots;

  /// 最近一次播放状态。
  PlaybackSnapshot get currentSnapshot => _engine.current;

  /// 引擎当前队列条目（UI 兜底展示用）。
  PlaybackItem? get currentItem => _engine.currentItem;

  /// 引擎持有的队列（只读）。
  List<PlaybackItem> get items => _engine.items;

  /// 替换队列并定位到 [startIndex]（不自动播放）。
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {
    _items = List<PlaybackItem>.unmodifiable(items);
    _mediaItems = _items.map(_toMediaItem).toList(growable: false);
    // 新会话：即便下标与时长跟上一次会话完全相同，也要重新发布一次元数据 ——
    // 否则锁屏 / MPRIS / SMTC 会一直挂着上一轮的标题与封面。
    _lastMediaItemId = null;
    _lastMediaItemIndex = null;
    _lastMediaItemDuration = null;
    queue.add(_mediaItems);
    await _engine.setQueue(_items, startIndex: startIndex);
    _broadcast(_engine.current);
  }

  /// 追加已解析条目，不重建播放器队列，因此不会打断当前直链播放。
  Future<void> addToQueue(PlaybackItem item) async {
    await _engine.addToQueue(item);
    _items = List<PlaybackItem>.unmodifiable(<PlaybackItem>[..._items, item]);
    // 只翻译新增的这一个，然后把缓存整条推给系统（列表本身是引用复制，代价远小于
    // 每首歌都重新构造全部 MediaItem）。
    _mediaItems = <MediaItem>[..._mediaItems, _toMediaItem(item)];
    queue.add(_mediaItems);
    // 不清 `_lastMediaItem*`：去重键里已经带了曲目 id，追加不会让"当前这首"变样，
    // 清了反而会在每次预取追加时把同一份元数据再推一次给平台通道。
    _broadcast(_engine.current);
  }

  @override
  Future<void> play() => _engine.play();

  @override
  Future<void> pause() => _engine.pause();

  @override
  Future<void> seek(Duration position) => _engine.seek(position);

  @override
  Future<void> skipToNext() => _engine.skipToNext();

  @override
  Future<void> skipToPrevious() => _engine.skipToPrevious();

  @override
  Future<void> setSpeed(double speed) => _engine.setRate(speed);

  /// 音量不属于 `audio_service` 的 [AudioHandler] 契约，仅供 UI 直接调用。
  Future<void> setVolume(double volume) => _engine.setVolume(volume);

  /// 循环模式转发给引擎；单曲循环由引擎自己无缝循环，见 [PlaybackEngine.setRepeatMode]。
  ///
  /// 名字刻意不叫 `setRepeatMode`：`audio_service` 的 [AudioHandler] 已经占用了那个
  /// 名字（系统媒体会话下发的 [AudioServiceRepeatMode]），两者语义不同不能合并。
  Future<void> applyRepeatMode(PlaybackRepeatMode mode) =>
      _engine.setRepeatMode(mode);

  @override
  Future<void> stop() async {
    await _engine.pause();
    await _engine.seek(Duration.zero);
    await super.stop();
  }

  /// 释放订阅与引擎；`BaseAudioHandler` 未定义 `dispose`，故不标注 `@override`。
  Future<void> dispose() async {
    await _subscription.cancel();
    await _engine.dispose();
  }

  /// 把引擎快照翻译为系统媒体会话状态。
  ///
  /// 引擎的进度事件密度远高于系统侧需要的频率（约 60ms 一次），若全量透传，
  /// 会以同样的频率冲击平台通道 / SMTC / DBus。因此：播放语义变化
  /// （播放态、处理阶段、曲目、倍速）立即推送，纯进度更新按 [statePushInterval] 节流。
  void _broadcast(PlaybackSnapshot snapshot) {
    _syncMediaItem(snapshot);

    final PlaybackSnapshot? last = _lastPushed;
    final bool semanticsChanged =
        last == null ||
        last.playing != snapshot.playing ||
        last.processing != snapshot.processing ||
        last.index != snapshot.index ||
        last.rate != snapshot.rate;

    final DateTime now = DateTime.now();
    if (!semanticsChanged && now.difference(_lastPushAt) < statePushInterval) {
      return;
    }
    _lastPushed = snapshot;
    _lastPushAt = now;

    playbackState.add(
      PlaybackState(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          snapshot.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const <MediaAction>{MediaAction.seek},
        androidCompactActionIndices: const <int>[0, 1, 2],
        processingState: _processingStateOf(snapshot.processing),
        playing: snapshot.playing,
        updatePosition: snapshot.position,
        bufferedPosition: snapshot.buffered,
        speed: snapshot.rate,
        queueIndex: snapshot.index,
      ),
    );
  }

  /// 当前曲目的元数据只在「换了一首」或时长首次可知时更新，避免刷屏。
  ///
  /// 去重键必须带上 [PlaybackItem.id]：新会话的第一首常常还没有时长（0 / 未知），
  /// 只比 (下标, 时长) 会被判定成"没变"，锁屏 / MPRIS / SMTC 就一直挂着上一首歌的
  /// 标题、艺术家和封面。
  void _syncMediaItem(PlaybackSnapshot snapshot) {
    final int index = snapshot.index;
    if (index < 0 || index >= _items.length) {
      return;
    }
    final PlaybackItem item = _items[index];
    final Duration? duration = snapshot.duration == Duration.zero
        ? item.duration
        : snapshot.duration;
    if (_lastMediaItemId == item.id &&
        _lastMediaItemIndex == index &&
        _lastMediaItemDuration == duration) {
      return;
    }
    _lastMediaItemId = item.id;
    _lastMediaItemIndex = index;
    _lastMediaItemDuration = duration;
    mediaItem.add(_toMediaItem(item, duration: duration));
  }

  static MediaItem _toMediaItem(PlaybackItem item, {Duration? duration}) {
    final List<String> segments = item.uri.pathSegments;
    final String fallbackTitle = segments.isEmpty
        ? item.uri.toString()
        : segments.last;
    return MediaItem(
      id: item.id,
      title: item.title ?? fallbackTitle,
      artist: item.artist,
      album: item.album,
      artUri: item.artUri,
      duration: duration ?? item.duration,
      extras: <String, dynamic>{'uri': item.uri.toString()},
    );
  }

  static AudioProcessingState _processingStateOf(
    PlaybackProcessing processing,
  ) => switch (processing) {
    PlaybackProcessing.idle => AudioProcessingState.idle,
    PlaybackProcessing.loading => AudioProcessingState.loading,
    PlaybackProcessing.buffering => AudioProcessingState.buffering,
    PlaybackProcessing.ready => AudioProcessingState.ready,
    PlaybackProcessing.completed => AudioProcessingState.completed,
  };
}
