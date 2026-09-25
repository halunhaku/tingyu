import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../playback/playback_item.dart';
import '../playback/playback_snapshot.dart';
import '../playback/tingyu_audio_handler.dart';
import '../playback/playback_error_formatter.dart';
import 'providers.dart';
import 'track_resolver.dart';

/// 界面层唯一的播放入口：管理懒解析队列、转发指令、并把播放历史写回曲库。
class PlaybackController extends Notifier<PlaybackSnapshot> {
  static const int _prefetchCount = 2;

  TingyuAudioHandler? _handler;

  List<PlaybackItem> _queue = const <PlaybackItem>[];
  List<String> _trackIds = const <String>[];
  List<int> _resolvedSourceIndices = const <int>[];
  List<Track> _sourceQueue = const <Track>[];
  PlayOrder _playOrder = PlayOrder.sequential;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.all;
  List<Track> _originalSourceQueue = const <Track>[];
  int _nextSourceIndex = 0;
  int _queueGeneration = 0;
  Future<void>? _prefetchFuture;
  String? _lastRecordedId;

  /// 本次起播第一个要解析的曲目（用户点的那一首）。
  int _startSourceIndex = 0;

  /// 最近一次解析失败的原因（取直链、校验授权）。
  Object? _lastResolveError;

  /// 与已解析队列一一对应的曲目 id。
  List<String> get trackIds => _trackIds;

  List<PlaybackItem> get queue => _queue;

  PlaybackItem? get currentItem => handler.currentItem;

  List<PlaybackItem> get items => _queue.isNotEmpty ? _queue : handler.items;

  /// 当前播放会话的完整曲目列表（点击起播时排好序），供「接下来播放」展示。
  ///
  /// 引擎侧仍只预取当前曲目后两首直链；UI 用这份列表，避免队列看起来只有 3 首。
  List<Track> get sourceQueue => _sourceQueue;

  /// 「接下来播放」里正在播放那一行的下标（相对 [sourceQueue]）。
  int get queueDisplayIndex {
    final int engineIndex = state.index;
    if (engineIndex < 0 || engineIndex >= _resolvedSourceIndices.length) {
      return engineIndex;
    }
    return _resolvedSourceIndices[engineIndex];
  }

  TingyuAudioHandler get handler {
    final TingyuAudioHandler? cached = _handler;
    if (cached != null) {
      return cached;
    }
    final TingyuAudioHandler resolved = ref.read(audioHandlerProvider);
    _handler = resolved;
    return resolved;
  }

  @override
  PlaybackSnapshot build() {
    final TingyuAudioHandler handler = ref.watch(audioHandlerProvider);
    _handler = handler;
    final StreamSubscription<PlaybackSnapshot> subscription = handler.snapshots
        .listen((PlaybackSnapshot snapshot) {
          final PlaybackSnapshot enriched = snapshot.copyWith(
            playOrder: _playOrder,
            repeatMode: _repeatMode,
          );
          state = enriched;
          _recordPlay(enriched);
          if (snapshot.processing == PlaybackProcessing.completed &&
              _repeatMode == PlaybackRepeatMode.one) {
            unawaited(handler.seek(Duration.zero).then((_) => handler.play()));
          } else {
            unawaited(_ensureAhead());
          }
        });
    ref.onDispose(subscription.cancel);
    return handler.currentSnapshot.copyWith(
      playOrder: _playOrder,
      repeatMode: _repeatMode,
    );
  }

  /// 优先解析用户点击的歌曲并立即播放，只在后台预取后续两首直链。
  ///
  /// 旧实现会先串行解析整个列表；夸克曲库每首都要请求一次下载地址，导致点击后
  /// 长时间无响应。现在队列从点击项开始循环排列，并随播放推进按需追加。
  /// 优先解析用户点击的歌曲并立即播放，只在后台预取后续两首直链。
  ///
  /// 支持传入 [shuffle] 直接以随机顺序起播。
  Future<void> playTracks(
    List<Track> tracks, {
    int startIndex = 0,
    bool shuffle = false,
  }) async {
    if (tracks.isEmpty) {
      return;
    }
    _originalSourceQueue = List<Track>.unmodifiable(tracks);
    final int normalized = startIndex.clamp(0, tracks.length - 1);
    if (shuffle) {
      _playOrder = PlayOrder.shuffle;
      final Track start = tracks[normalized];
      final List<Track> rest =
          tracks.where((Track t) => t.id != start.id).toList()..shuffle();
      _sourceQueue = <Track>[start, ...rest];
    } else {
      _playOrder = PlayOrder.sequential;
      _sourceQueue = <Track>[
        ...tracks.skip(normalized),
        ...tracks.take(normalized),
      ];
    }
    state = state.copyWith(playOrder: _playOrder, repeatMode: _repeatMode);
    await _restartEngineFrom(0);
  }

  /// 在「接下来播放」的指定行开始播放。
  Future<void> playAt(int index) async {
    if (_sourceQueue.isNotEmpty) {
      if (index < 0 || index >= _sourceQueue.length) {
        return;
      }
      final int resolved = _resolvedSourceIndices.indexOf(index);
      if (resolved >= 0 && resolved < _queue.length) {
        await handler.seek(Duration.zero);
        final List<PlaybackItem> items = List<PlaybackItem>.of(_queue);
        await handler.setQueue(items, startIndex: resolved);
        await handler.play();
        unawaited(_ensureAhead());
        return;
      }
      await _restartEngineFrom(index);
      return;
    }
    if (index < 0 || index >= _queue.length) {
      return;
    }
    await handler.seek(Duration.zero);
    final List<PlaybackItem> items = List<PlaybackItem>.of(_queue);
    await handler.setQueue(items, startIndex: index);
    await handler.play();
    unawaited(_ensureAhead());
  }

  Future<void> togglePlayPause() async {
    if (state.playing) {
      await handler.pause();
    } else {
      await handler.play();
    }
  }

  Future<void> pause() => handler.pause();

  Future<void> next() async {
    await _ensureAhead(minimumAhead: 1);
    await handler.skipToNext();
  }

  Future<void> previous() => handler.skipToPrevious();

  Future<void> seek(Duration position) => handler.seek(position);

  /// 切换随机播放状态（顺序 ↔ 随机）。
  void toggleShuffle() {
    if (_playOrder == PlayOrder.sequential) {
      _playOrder = PlayOrder.shuffle;
      if (_sourceQueue.isNotEmpty) {
        if (_originalSourceQueue.isEmpty) {
          _originalSourceQueue = List<Track>.of(_sourceQueue);
        }
        final int currentIdx = queueDisplayIndex.clamp(
          0,
          _sourceQueue.length - 1,
        );
        final Track current = _sourceQueue[currentIdx];
        final List<Track> remainder =
            _sourceQueue.where((Track t) => t.id != current.id).toList()
              ..shuffle();
        _sourceQueue = <Track>[current, ...remainder];
        unawaited(_restartEngineFrom(0));
      }
    } else {
      _playOrder = PlayOrder.sequential;
      if (_originalSourceQueue.isNotEmpty) {
        final int currentIdx = queueDisplayIndex.clamp(
          0,
          _sourceQueue.length - 1,
        );
        final String currentId = _sourceQueue[currentIdx].id;
        final int originalIdx = _originalSourceQueue.indexWhere(
          (Track t) => t.id == currentId,
        );
        if (originalIdx != -1) {
          _sourceQueue = <Track>[
            ..._originalSourceQueue.skip(originalIdx),
            ..._originalSourceQueue.take(originalIdx),
          ];
        } else {
          _sourceQueue = List<Track>.of(_originalSourceQueue);
        }
        unawaited(_restartEngineFrom(0));
      }
    }
    state = state.copyWith(playOrder: _playOrder);
  }

  /// 切换循环模式（列表循环 → 单曲循环 → 不循环 → 列表循环）。
  void cycleRepeatMode() {
    _repeatMode = switch (_repeatMode) {
      PlaybackRepeatMode.all => PlaybackRepeatMode.one,
      PlaybackRepeatMode.one => PlaybackRepeatMode.off,
      PlaybackRepeatMode.off => PlaybackRepeatMode.all,
    };
    state = state.copyWith(repeatMode: _repeatMode);
  }

  Future<void> setVolume(double volume) => handler.setVolume(volume);

  Future<void> _restartEngineFrom(int sourceIndex) async {
    final int generation = ++_queueGeneration;
    _prefetchFuture = null;
    _nextSourceIndex = sourceIndex;
    _startSourceIndex = sourceIndex;
    _queue = const <PlaybackItem>[];
    _trackIds = const <String>[];
    _resolvedSourceIndices = const <int>[];
    _lastRecordedId = null;
    _lastResolveError = null;

    final _Resolved? first = await _resolveNext(generation);
    if (first == null || generation != _queueGeneration) {
      return;
    }
    _queue = List<PlaybackItem>.unmodifiable(<PlaybackItem>[first.item]);
    _trackIds = List<String>.unmodifiable(<String>[first.track.id]);
    _resolvedSourceIndices = List<int>.unmodifiable(<int>[first.sourceIndex]);
    await handler.setQueue(_queue);
    if (generation != _queueGeneration) {
      return;
    }
    await handler.play();
    unawaited(ref.read(enrichmentServiceProvider).enrichTrack(first.track));
    unawaited(_ensureAhead());
  }

  Future<void> _ensureAhead({int minimumAhead = _prefetchCount}) {
    if (_sourceQueue.isEmpty || _nextSourceIndex >= _sourceQueue.length) {
      return Future<void>.value();
    }
    final Future<void>? active = _prefetchFuture;
    if (active != null) {
      return active;
    }
    final int generation = _queueGeneration;
    final Future<void> future = _prefetch(generation, minimumAhead);
    _prefetchFuture = future;
    return future.whenComplete(() {
      if (identical(_prefetchFuture, future)) {
        _prefetchFuture = null;
      }
    });
  }

  Future<void> _prefetch(int generation, int minimumAhead) async {
    while (generation == _queueGeneration &&
        _nextSourceIndex < _sourceQueue.length &&
        _queue.length - handler.currentSnapshot.index - 1 < minimumAhead) {
      final _Resolved? resolved = await _resolveNext(generation);
      if (resolved == null || generation != _queueGeneration) {
        return;
      }
      await handler.addToQueue(resolved.item);
      if (generation != _queueGeneration) {
        return;
      }
      _queue = List<PlaybackItem>.unmodifiable(<PlaybackItem>[
        ..._queue,
        resolved.item,
      ]);
      _trackIds = List<String>.unmodifiable(<String>[
        ..._trackIds,
        resolved.track.id,
      ]);
      _resolvedSourceIndices = List<int>.unmodifiable(<int>[
        ..._resolvedSourceIndices,
        resolved.sourceIndex,
      ]);
    }
  }

  Future<_Resolved?> _resolveNext(int generation) async {
    if (_sourceQueue.isEmpty) {
      return null;
    }
    final TrackResolver resolver = ref.read(trackResolverProvider);
    int attempts = 0;
    while (generation == _queueGeneration && attempts < _sourceQueue.length) {
      if (_nextSourceIndex >= _sourceQueue.length) {
        if (_repeatMode == PlaybackRepeatMode.all) {
          _nextSourceIndex = 0;
        } else {
          return null;
        }
      }
      attempts++;
      final int sourceIndex = _nextSourceIndex;
      final Track track = _sourceQueue[_nextSourceIndex++];
      try {
        final PlaybackItem item = await resolver.resolve(track);
        if (generation != _queueGeneration) {
          return null;
        }
        return _Resolved(track: track, item: item, sourceIndex: sourceIndex);
      } on Object catch (error) {
        _lastResolveError = error;
        if (sourceIndex == _startSourceIndex) {
          // 点的就是这一首：立刻给提示。否则用户只看到"点了没反应"，
          // 而后面几十首挨个尝试要跑很久。仅上报一次，不重复刷屏。
          _reportResolveFailure(sourceIndex);
          _startSourceIndex = -1;
        }
        debugPrint('[playback] 跳过无法解析的曲目「${track.title}」: $error');
      }
    }
    return null;
  }

  /// 用户点的那一首解析不出来（取直链、校验授权失败）时，把原因写进快照。
  ///
  /// 引擎侧的失败由引擎自己上报；解析发生在引擎之前，没有引擎事件可依赖，
  /// 这里补上同一个字段，界面不必为"取直链失败"再开一条提示路径。
  /// 队列里**后续**曲目解析失败不提示（那只是"跳过"，歌曲照放），只进日志。
  void _reportResolveFailure(int sourceIndex) {
    final String title = sourceIndex >= 0 && sourceIndex < _sourceQueue.length
        ? _sourceQueue[sourceIndex].title
        : '';
    final Object? error = _lastResolveError;
    debugPrint('[playback] 无法播放「$title」: ${error ?? '未知原因'}');
    final String reason = PlaybackErrorFormatter.format(error);
    final PlaybackFailure reported = PlaybackFailure(
      message: error == null ? '无法加载曲目' : '无法播放：$reason',
      title: title.isEmpty ? null : title,
    );
    state = state.copyWith(failure: reported);
  }

  void _recordPlay(PlaybackSnapshot snapshot) {
    if (snapshot.playing == false) {
      return;
    }
    final int index = snapshot.index;
    if (index < 0 || index >= _trackIds.length) {
      return;
    }
    final String id = _trackIds[index];
    if (id == _lastRecordedId) {
      return;
    }
    _lastRecordedId = id;
    unawaited(ref.read(trackRepositoryProvider).recordPlay(id));
  }
}

class _Resolved {
  const _Resolved({
    required this.track,
    required this.item,
    required this.sourceIndex,
  });

  final Track track;
  final PlaybackItem item;
  final int sourceIndex;
}
