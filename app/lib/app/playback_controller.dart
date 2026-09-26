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

  /// 引擎队列是否已经装好（`setQueue` 返回后为 true）。
  ///
  /// 重建期间旧会话仍在推进：不设这道闸，预取会把解析结果追加到**旧**引擎队列上、
  /// 或者把 `_nextSourceIndex` 在重建脚下往前推，结果是新会话悄悄少一首歌，或者
  /// `_queue` / `_trackIds` / `_resolvedSourceIndices` 与引擎队列错位。
  bool _queueArmed = false;

  /// 控制器侧记下的失败（取直链、授权校验）。
  ///
  /// 必须自己存一份：引擎快照里的 `failure` 属于引擎，`snapshot.copyWith` 的
  /// `failure ?? this.failure` 读的是引擎那份 null，会把这里的失败在下一次
  /// 引擎 tick（~60ms 后）直接擦掉。
  PlaybackFailure? _pendingFailure;

  /// 本次起播第一个要解析的曲目（用户点的那一首）。
  int _startSourceIndex = 0;

  /// 已经上报过时长的曲目 id，避免每个进度 tick 都写一次库。
  String? _durationRecordedId;

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
          // 引擎开始播放我们已排队的曲目后，控制器侧的解析失败就过期了（新会话已
          // 起播）。判定必须带上「引擎下标落在 _queue 内」：失败发生在重建期间，
          // 那一刻是空队列，而**旧**会话的引擎还在 playing=true 地 tick，只看
          // playing 会把刚报的失败立刻擦掉（等于没报）。
          if (snapshot.playing &&
              snapshot.failure == null &&
              snapshot.index >= 0 &&
              snapshot.index < _queue.length) {
            _pendingFailure = null;
          }
          final PlaybackSnapshot enriched = snapshot.copyWith(
            playOrder: _playOrder,
            repeatMode: _repeatMode,
            failure: snapshot.failure ?? _pendingFailure,
          );
          state = enriched;
          _recordPlay(enriched);
          _recordDuration(enriched);
          unawaited(_onSnapshot(enriched));
        });
    ref.onDispose(subscription.cancel);
    return handler.currentSnapshot.copyWith(
      playOrder: _playOrder,
      repeatMode: _repeatMode,
    );
  }

  /// 当前这一遍是否已经走完（预取指针越过队尾）。
  bool get _passFinished =>
      _sourceQueue.isNotEmpty && _nextSourceIndex >= _sourceQueue.length;

  /// 本轮 completed 是否已经处理过。
  ///
  /// 必须按「跃迁」而不是「当前值」触发：真实引擎（libmpv / ExoPlayer）在
  /// seek 回 0 之后仍可能继续上报自身处于 completed（mpv 的 eof-reached 要等
  /// 重新出声才清），如果每次收到 completed 都重播一次，就会变成 seek→play→
  /// completed→seek… 的死循环。
  bool _completionHandled = false;

  /// 一首播完时的收尾。
  ///
  /// - 单曲循环：回到 0 重播当前曲；
  /// - 列表循环：走完一遍就从头重建队列（顺带把 `_queue` / `_trackIds` /
  ///   `_resolvedSourceIndices` 三份平行数组截断，长会话下不会无限增长）；
  /// - 顺序播放：停在最后一首，不再预取。
  Future<void> _onSnapshot(PlaybackSnapshot snapshot) async {
    if (snapshot.processing != PlaybackProcessing.completed) {
      _completionHandled = false;
      await _ensureAhead();
      return;
    }
    if (_completionHandled) {
      return;
    }
    _completionHandled = true;
    switch (_repeatMode) {
      case PlaybackRepeatMode.one:
        await handler.seek(Duration.zero);
        await handler.play();
      case PlaybackRepeatMode.all:
        if (_passFinished) {
          await _replayResolvedQueue();
        } else {
          await _ensureAhead();
        }
      case PlaybackRepeatMode.off:
        // just_audio 在播完后 playing 仍为 true（要显式 pause/stop 才变），
        // 不暂停的话 UI 与系统媒体会话会一直显示"正在播放"。
        //
        // 另外必须回到 0：引擎停在 completed 上时 `play()` 是空操作（just_audio
        // 文档明说），`seekToNext()` 也没有下一首，暂停后就永远出不了声 —— 用户看到
        // "播放键点了没反应"。seek(0) 后 play() 至少能把最后一首重放出来。
        await handler.pause();
        await handler.seek(Duration.zero);
    }
  }

  /// 列表循环重开一轮：直接复用已经解析好的引擎队列，从第 0 首重放。
  ///
  /// 刻意不在队尾重新解析整条队列：夸克每首要取一次直链，既慢，又会与仍在跑的
  /// 后台预取抢 `_nextSourceIndex`（重建期间预取会把旧队列当成追加目标，解析结果
  /// 白跑、指针被提前推到队尾，新队列只剩一首）。此刻引擎队列本身就是一轮完整
  /// 快照，重放它既没有网络开销，也天然把三份平行数组限制在一轮长度内。
  Future<void> _replayResolvedQueue() async {
    if (_queue.isEmpty) {
      return;
    }
    ++_queueGeneration;
    _prefetchFuture = null;
    _queueArmed = false;
    // 本轮已全部解析完；这一遍重放期间不需要再预取。
    _nextSourceIndex = _sourceQueue.length;
    await handler.setQueue(List<PlaybackItem>.of(_queue), startIndex: 0);
    _queueArmed = true;
    await handler.play();
  }

  /// 优先解析用户点击的歌曲并立即播放，只在后台预取后续两首直链。
  ///
  /// 旧实现会先串行解析整个列表；夸克曲库每首都要请求一次下载地址，导致点击后
  /// 长时间无响应。现在队列从点击项开始循环排列，并随播放推进按需追加。
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
        await _swapEngineQueue(resolved);
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
    await _swapEngineQueue(index);
    await handler.play();
    unawaited(_ensureAhead());
  }

  /// 用控制器侧已解析的队列重装引擎，并定位到 [startIndex]。
  ///
  /// 这里刻意**不**提升 `_queueGeneration`（重装用的就是当前这份队列），因此必须
  /// 自己处理"预取还在飞"：先闸住预取、等在飞的那一次落地，再复制队列去 setQueue。
  /// 否则它会在 setQueue 期间把新条目追加到**旧**引擎队列上 —— 引擎队列替换后那一首
  /// 就没了，而 `_queue` / `_trackIds` / `_resolvedSourceIndices` 里还有，三份平行
  /// 数组从此与引擎错位。
  Future<void> _swapEngineQueue(int startIndex) async {
    _queueArmed = false;
    final Future<void>? pending = _prefetchFuture;
    if (pending != null) {
      await pending;
    }
    await handler.setQueue(List<PlaybackItem>.of(_queue), startIndex: startIndex);
    _queueArmed = true;
  }

  Future<void> togglePlayPause() async {
    if (state.playing) {
      await handler.pause();
      return;
    }
    if (state.processing == PlaybackProcessing.completed) {
      // 播完停下后再按播放键：引擎停在 completed 上，`play()` 是空操作
      // （just_audio 文档明说；libmpv 同理会 eof 停住）。必须先把位置拨回去，
      // 否则这个键永远是死的。整轮播完的场景直接重放已解析队列，比只重播最后一首
      // 更符合"再听一遍"的预期。
      if (_repeatMode == PlaybackRepeatMode.all && _queue.isNotEmpty) {
        await _replayResolvedQueue();
        return;
      }
      await handler.seek(Duration.zero);
    }
    await handler.play();
  }

  Future<void> pause() => handler.pause();

  Future<void> next() async {
    // 先把这一轮的预取跑完，再判断"是不是到了队尾"：解析还在飞的时候
    // `_nextSourceIndex` 已经被推过队尾而 `_queue` 还没追加，此刻判断会把"下一首
    // 正在路上"误判成"整轮已播完"，于是重放一个只剩当前首的队列。
    await _ensureAhead(minimumAhead: 1);
    // 队尾按「下一首」：列表循环重放已解析的队列回到第 1 首；其余模式交给引擎
    // （顺序播放会停在最后一首，单曲循环由播完事件处理）。
    if (_repeatMode == PlaybackRepeatMode.all &&
        _passFinished &&
        handler.currentSnapshot.index >= _queue.length - 1) {
      await _replayResolvedQueue();
      return;
    }
    await handler.skipToNext();
  }

  Future<void> previous() => handler.skipToPrevious();

  Future<void> seek(Duration position) => handler.seek(position);

  /// 切换随机播放状态（顺序 ↔ 随机）。
  ///
  /// 只重排「尚未入队」的那一部分：换掉整条队列必然要 `setQueue`，那会重新装载
  /// 当前音轨、把播放进度清零；而重建引擎队列时若只改控制器侧的
  /// `_queue`/`_trackIds`/`_resolvedSourceIndices`，又与引擎实际队列错位
  /// （高亮行、迷你条歌名、歌词、播放历史全部指到别的歌）。因此这里保持
  /// `[0.._nextSourceIndex)` 不动，只打乱其后的部分，预取照旧往队尾追加：
  /// 没有重复曲目、没有下标错位，也不会打断正在播放的这一首。
  void toggleShuffle() {
    if (_sourceQueue.isEmpty) {
      _playOrder = _playOrder == PlayOrder.sequential
          ? PlayOrder.shuffle
          : PlayOrder.sequential;
      state = state.copyWith(playOrder: _playOrder);
      return;
    }
    if (_playOrder == PlayOrder.sequential) {
      _playOrder = PlayOrder.shuffle;
      if (_originalSourceQueue.isEmpty) {
        _originalSourceQueue = List<Track>.of(_sourceQueue);
      }
      final int from = _nextSourceIndex.clamp(0, _sourceQueue.length);
      final List<Track> tail = _sourceQueue.sublist(from)..shuffle();
      _sourceQueue = <Track>[..._sourceQueue.sublist(0, from), ...tail];
    } else {
      _playOrder = PlayOrder.sequential;
      if (_originalSourceQueue.isEmpty) {
        state = state.copyWith(playOrder: _playOrder);
        return;
      }
      final int from = _nextSourceIndex.clamp(0, _sourceQueue.length);
      // 按**重数**还原，而不是按 id 集合筛原始队列：
      // 歌单里同一首歌出现两次时，id 集合会把两份都留在尾部，尾部凭空多出一首
      // （曲目行数变多、播放顺序也错）。这里逐个消耗"尾部里还欠几份"。
      final Map<String, int> remaining = <String, int>{};
      for (final Track track in _sourceQueue.sublist(from)) {
        remaining[track.id] = (remaining[track.id] ?? 0) + 1;
      }
      final List<Track> restored = <Track>[];
      for (final Track track in _originalSourceQueue) {
        final int count = remaining[track.id] ?? 0;
        if (count > 0) {
          restored.add(track);
          remaining[track.id] = count - 1;
        }
      }
      _sourceQueue = <Track>[..._sourceQueue.sublist(0, from), ...restored];
    }
    state = state.copyWith(playOrder: _playOrder);
    unawaited(_ensureAhead());
  }

  /// 切换循环模式（列表循环 → 单曲循环 → 不循环 → 列表循环）。
  void cycleRepeatMode() {
    _repeatMode = switch (_repeatMode) {
      PlaybackRepeatMode.all => PlaybackRepeatMode.one,
      PlaybackRepeatMode.one => PlaybackRepeatMode.off,
      PlaybackRepeatMode.off => PlaybackRepeatMode.all,
    };
    state = state.copyWith(repeatMode: _repeatMode);
    // 立即下发给引擎：单曲循环只有引擎自己循环才是无缝的（ExoPlayer/AVPlayer 与
    // libmpv 默认都只在列表末尾报 completed），等作曲末再 seek(0) 会有一声空档。
    unawaited(handler.applyRepeatMode(_repeatMode));
  }

  Future<void> setVolume(double volume) => handler.setVolume(volume);

  Future<void> _restartEngineFrom(int sourceIndex) async {
    final int generation = ++_queueGeneration;
    _prefetchFuture = null;
    _queueArmed = false;
    _nextSourceIndex = sourceIndex;
    _startSourceIndex = sourceIndex;
    _queue = const <PlaybackItem>[];
    _trackIds = const <String>[];
    _resolvedSourceIndices = const <int>[];
    _lastRecordedId = null;
    _lastResolveError = null;
    // 新会话开始，上一轮记下的解析失败不再适用。
    _pendingFailure = null;

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
    // 引擎队列已就位，预取才可以往它上面追加。
    _queueArmed = true;
    await handler.play();
    unawaited(ref.read(enrichmentServiceProvider).enrichTrack(first.track));
    unawaited(_ensureAhead());
  }

  Future<void> _ensureAhead({int minimumAhead = _prefetchCount}) {
    // 引擎队列还没装好（重建中）时不预取：此刻追加会落到旧队列上，白跑一次解析。
    if (!_queueArmed) {
      return Future<void>.value();
    }
    // 已经有预取在飞：必须把它**返回**给调用方（而不是当成"无事可做"直接返回）。
    // `_resolveNext` 是先把 `_nextSourceIndex` 推过队尾、再 await 解析的，所以
    // "指针越界"并不代表"这一轮已经解析完"——`next()` 要等它落地才能判断队尾。
    final Future<void>? active = _prefetchFuture;
    if (active != null) {
      return active;
    }
    if (_sourceQueue.isEmpty || _nextSourceIndex >= _sourceQueue.length) {
      return Future<void>.value();
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
        _queueArmed &&
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
    // 自己留一份：引擎随后的每份快照里 failure 都是 null，copyWith 会把这条抹掉。
    _pendingFailure = reported;
    state = state.copyWith(failure: reported);
  }

  /// 把引擎解出来的真实时长补进曲库。
  ///
  /// 夸克 / WebDAV 的目录接口不报时长，扫描入库时只能写 0，界面于是整库都是 `--:--`；
  /// 解码器给出的这一份是唯一可信来源。写库是 fire-and-forget（失败只影响"时长补全"
  /// 这一个便利，不该打断播放），且**每首只写一次**：进度 tick 每 ~60ms 一份快照，
  /// 逐个都写会把数据库写热。
  void _recordDuration(PlaybackSnapshot snapshot) {
    final int index = snapshot.index;
    if (index < 0 || index >= _trackIds.length) {
      return;
    }
    final String id = _trackIds[index];
    if (id == _durationRecordedId) {
      return;
    }
    // 时长还没探明（直链刚起播时是 0）就先不记，等它变成正数的那一份快照。
    if (snapshot.duration <= Duration.zero) {
      return;
    }
    _durationRecordedId = id;
    unawaited(
      ref
          .read(trackRepositoryProvider)
          .updateDurationIfUnknown(id, snapshot.duration),
    );
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
