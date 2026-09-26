import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/playback_controller.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/track_resolver.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'support/test_support.dart';

final class _MockEngine extends PlaybackEngineBase {
  @override
  String get name => 'mock';

  PlaybackSnapshot _snapshot = PlaybackSnapshot.initial;
  List<PlaybackItem> _queue = <PlaybackItem>[];
  int _index = 0;

  @override
  List<PlaybackItem> get items => _queue;

  @override
  PlaybackItem? get currentItem =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;

  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {
    _queue = List<PlaybackItem>.of(items);
    _index = startIndex;
    emit(
      _snapshot = _snapshot.copyWith(
        index: startIndex,
        position: Duration.zero,
      ),
    );
  }

  @override
  Future<void> addToQueue(PlaybackItem item) async {
    _queue.add(item);
    emit(_snapshot);
  }

  @override
  Future<void> play() async {
    emit(_snapshot = _snapshot.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    emit(_snapshot = _snapshot.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async {
    emit(_snapshot = _snapshot.copyWith(position: position));
  }

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> skipToNext() async {
    if (_index + 1 < _queue.length) {
      _index++;
      emit(_snapshot = _snapshot.copyWith(index: _index));
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_index > 0) {
      _index--;
      emit(_snapshot = _snapshot.copyWith(index: _index));
    }
  }

  @override
  Future<void> dispose() async => closeSnapshotStream();
}

final class _DirectResolver extends TrackResolver {
  _DirectResolver(super.ref);

  @override
  Future<PlaybackItem> resolve(Track track) async {
    return PlaybackItem(
      id: track.id,
      uri: Uri.parse(track.filePathOrUrl),
      title: track.title,
      artist: track.artist,
      album: track.album,
    );
  }
}

Track _track(String id, String title) => Track(
  id: id,
  sourceId: 'src-1',
  title: title,
  artist: '歌手',
  album: '专辑',
  duration: 200,
  fileFormat: 'mp3',
  filePathOrUrl: 'https://example.com/$id.mp3',
  fileSize: 1000,
  isFavorite: false,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

ProviderContainer _container() {
  final TingyuDatabase db = openTestDatabase();
  final _MockEngine engine = _MockEngine();
  final TingyuAudioHandler handler = TingyuAudioHandler(engine);
  final ProviderContainer container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      audioHandlerProvider.overrideWithValue(handler),
      trackResolverProvider.overrideWith((Ref ref) => _DirectResolver(ref)),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  return container;
}

void main() {
  group('PlaybackController 播放模式与循环控制', () {
    test('cycleRepeatMode 在列表循环、单曲循环与播完停止间轮转', () async {
      final ProviderContainer container = _container();
      final PlaybackController controller = container.read(
        playbackProvider.notifier,
      );

      expect(controller.state.repeatMode, PlaybackRepeatMode.all);

      controller.cycleRepeatMode();
      expect(controller.state.repeatMode, PlaybackRepeatMode.one);

      controller.cycleRepeatMode();
      expect(controller.state.repeatMode, PlaybackRepeatMode.off);

      controller.cycleRepeatMode();
      expect(controller.state.repeatMode, PlaybackRepeatMode.all);
    });

    test('toggleShuffle 切换随机并在关闭后恢复原始队列顺序', () async {
      final ProviderContainer container = _container();
      final PlaybackController controller = container.read(
        playbackProvider.notifier,
      );

      final List<Track> tracks = <Track>[
        _track('t1', '歌1'),
        _track('t2', '歌2'),
        _track('t3', '歌3'),
        _track('t4', '歌4'),
        _track('t5', '歌5'),
      ];

      await controller.playTracks(tracks, startIndex: 0);
      expect(controller.state.playOrder, PlayOrder.sequential);
      expect(controller.sourceQueue.map((Track t) => t.id).toList(), <String>[
        't1',
        't2',
        't3',
        't4',
        't5',
      ]);

      // 开启随机播放
      controller.toggleShuffle();
      expect(controller.state.playOrder, PlayOrder.shuffle);
      final List<String> shuffledIds = controller.sourceQueue
          .map((Track t) => t.id)
          .toList();

      // 首项保留正在播放的曲目 t1
      expect(shuffledIds.first, 't1');
      expect(shuffledIds, hasLength(5));
      expect(shuffledIds.toSet(), <String>{'t1', 't2', 't3', 't4', 't5'});

      // 关闭随机播放，恢复原顺序（从当前正在播放的曲目重新排列）
      controller.toggleShuffle();
      expect(controller.state.playOrder, PlayOrder.sequential);
      expect(controller.sourceQueue.map((Track t) => t.id).toList(), <String>[
        't1',
        't2',
        't3',
        't4',
        't5',
      ]);
    });

    test('歌单里有重复曲目时，关闭随机不会多出一行', () async {
      final ProviderContainer container = _container();
      final PlaybackController controller = container.read(
        playbackProvider.notifier,
      );

      // 同一首歌出现两次（歌单允许）：按 id 集合还原尾部时，两份都会被塞回尾部，
      // 队列凭空变长、播放顺序也跟着错。
      final List<Track> tracks = <Track>[
        _track('t1', '歌1'),
        _track('t2', '歌2'),
        _track('t2', '歌2'),
        _track('t3', '歌3'),
      ];

      await controller.playTracks(tracks, startIndex: 0);
      controller.toggleShuffle();
      controller.toggleShuffle();

      expect(controller.sourceQueue.map((Track t) => t.id).toList(), <String>[
        't1',
        't2',
        't2',
        't3',
      ]);
    });

    test('playTracks 支持直接以 shuffle 模式起播', () async {
      final ProviderContainer container = _container();
      final PlaybackController controller = container.read(
        playbackProvider.notifier,
      );

      final List<Track> tracks = <Track>[
        _track('t1', '歌1'),
        _track('t2', '歌2'),
        _track('t3', '歌3'),
        _track('t4', '歌4'),
      ];

      await controller.playTracks(tracks, shuffle: true);
      expect(controller.state.playOrder, PlayOrder.shuffle);
      expect(controller.sourceQueue, hasLength(4));
    });

    test('播放中切换 toggleShuffle 不会重启播放，且保留当前播放进度', () async {
      final ProviderContainer container = _container();
      final PlaybackController controller = container.read(
        playbackProvider.notifier,
      );

      final List<Track> tracks = <Track>[
        _track('t1', '歌1'),
        _track('t2', '歌2'),
        _track('t3', '歌3'),
      ];

      await controller.playTracks(tracks, startIndex: 0);
      await controller.seek(const Duration(seconds: 45));

      expect(controller.state.position, const Duration(seconds: 45));
      expect(controller.state.playing, isTrue);

      // 切换随机播放
      controller.toggleShuffle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // 验证：播放状态依然是 playing，且进度依然是 45 秒，绝不能被重置为 0
      expect(controller.state.position, const Duration(seconds: 45));
      expect(controller.state.playing, isTrue);
      expect(controller.state.playOrder, PlayOrder.shuffle);

      // 再次切换关闭随机
      controller.toggleShuffle();
      expect(controller.state.position, const Duration(seconds: 45));
      expect(controller.state.playing, isTrue);
      expect(controller.state.playOrder, PlayOrder.sequential);
    });
  });
}
