import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../playback/playback_item.dart';
import '../playback/playback_snapshot.dart';
import '../playback/tingyu_audio_handler.dart';
import 'providers.dart';

/// 界面层唯一的播放入口：管理队列、转发指令、并把播放历史写回曲库。
///
/// 系统媒体会话（媒体键 / 锁屏 / SMTC / MPRIS）的指令由 [TingyuAudioHandler]
/// 直接落到引擎上，这里只负责"用户从界面发起的播放"与状态暴露。
class PlaybackController extends Notifier<PlaybackSnapshot> {
  TingyuAudioHandler? _handler;

  List<PlaybackItem> _queue = const <PlaybackItem>[];

  List<String> _trackIds = const <String>[];

  String? _lastRecordedId;

  /// 与队列一一对应的曲目 id（用于"正在播放"与播放列表联动）。
  List<String> get trackIds => _trackIds;

  List<PlaybackItem> get queue => _queue;

  /// 引擎当前条目：即使队列不是经本控制器设置（调试入口 / 系统恢复）也能拿到元数据。
  PlaybackItem? get currentItem => handler.currentItem;

  /// 引擎持有的队列；控制器自己设置的队列优先（含曲目 id 映射）。
  List<PlaybackItem> get items => _queue.isNotEmpty ? _queue : handler.items;

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
    final StreamSubscription<PlaybackSnapshot> subscription = handler.snapshots.listen((PlaybackSnapshot snapshot) {
      state = snapshot;
      _recordPlay(snapshot);
    });
    ref.onDispose(subscription.cancel);
    return handler.currentSnapshot;
  }

  /// 用一批曲目替换队列并开始播放。
  ///
  /// 单条曲目解析失败（例如远端凭据失效）只跳过该条，不影响整队列。
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) {
      return;
    }
    final resolver = ref.read(trackResolverProvider);
    final List<PlaybackItem> items = <PlaybackItem>[];
    final List<String> ids = <String>[];
    for (final Track track in tracks) {
      try {
        items.add(await resolver.resolve(track));
        ids.add(track.id);
      } on Object catch (error) {
        debugPrint('[playback] 跳过无法解析的曲目「${track.title}」: $error');
      }
    }
    if (items.isEmpty) {
      return;
    }
    _queue = List<PlaybackItem>.unmodifiable(items);
    _trackIds = List<String>.unmodifiable(ids);
    _lastRecordedId = null;
    await handler.setQueue(items, startIndex: startIndex);
    await handler.play();
  }

  /// 在当前队列的指定位置开始播放（点击列表某一行）。
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _queue.length) {
      return;
    }
    await handler.seek(Duration.zero);
    // 通过重建队列定位：引擎的 jump 语义在各平台上不一致，重建最稳。
    final List<PlaybackItem> items = List<PlaybackItem>.of(_queue);
    await handler.setQueue(items, startIndex: index);
    await handler.play();
  }

  Future<void> togglePlayPause() async {
    if (state.playing) {
      await handler.pause();
    } else {
      await handler.play();
    }
  }

  Future<void> pause() => handler.pause();

  Future<void> next() => handler.skipToNext();

  Future<void> previous() => handler.skipToPrevious();

  Future<void> seek(Duration position) => handler.seek(position);

  Future<void> setVolume(double volume) => handler.setVolume(volume);

  void _recordPlay(PlaybackSnapshot snapshot) {
    if (!snapshot.playing) {
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
