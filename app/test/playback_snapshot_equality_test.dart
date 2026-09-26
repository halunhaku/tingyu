import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

/// 引擎的进度事件每 ~60ms（media_kit）/ ~200ms（just_audio）推一份快照。快照若只按
/// 实例比较，Riverpod 会把每一次推进都当成"状态变了"，迷你条、进度条、歌词等所有
/// watcher 跟着重建。这个文件守住"值没变就不通知"。
final class _TickingEngine extends PlaybackEngineBase {
  @override
  String get name => 'ticking';

  @override
  List<PlaybackItem> get items => const <PlaybackItem>[];

  @override
  PlaybackItem? get currentItem => null;

  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {}

  @override
  Future<void> addToQueue(PlaybackItem item) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> dispose() async => closeSnapshotStream();

  /// 推送一份快照（`emit` 为 protected）。
  void push(PlaybackSnapshot snapshot) => emit(snapshot);
}

PlaybackSnapshot _tick({Duration position = Duration.zero}) => PlaybackSnapshot(
  processing: PlaybackProcessing.ready,
  playing: true,
  position: position,
  duration: const Duration(seconds: 200),
  buffered: position,
  index: 0,
  rate: 1,
  volume: 1,
);

void main() {
  group('PlaybackSnapshot 值比较', () {
    test('字段相同的两份快照相等，hashCode 一致', () {
      expect(_tick(), _tick());
      expect(_tick().hashCode, _tick().hashCode);

      expect(_tick() == _tick(position: const Duration(seconds: 1)), isFalse);
      expect(
        _tick() ==
            PlaybackSnapshot(
              processing: PlaybackProcessing.buffering,
              playing: true,
              position: Duration.zero,
              duration: const Duration(seconds: 200),
              buffered: Duration.zero,
              index: 0,
              rate: 1,
              volume: 1,
            ),
        isFalse,
      );
    });

    test('失败只比字段，PlaybackFailure 本身仍是"新实例 = 新的一次失败"', () {
      PlaybackSnapshot withFailure(PlaybackFailure failure) =>
          PlaybackSnapshot(
            processing: PlaybackProcessing.ready,
            playing: false,
            position: Duration.zero,
            duration: const Duration(seconds: 200),
            buffered: Duration.zero,
            index: 0,
            rate: 1,
            volume: 1,
            failure: failure,
          );

      final PlaybackFailure first = PlaybackFailure(
        message: '无法播放：网络连接失败',
        title: '晴天',
      );
      final PlaybackFailure second = PlaybackFailure(
        message: '无法播放：网络连接失败',
        title: '晴天',
      );

      // UI（PlaybackFailureListener）靠 identical 判断"是不是新的一次失败"，
      // 所以这个类不能改成值相等。
      expect(identical(first, second), isFalse);
      expect(withFailure(first), withFailure(second));

      expect(
        withFailure(first) ==
            withFailure(
              PlaybackFailure(message: '无法播放：网络连接失败', title: '稻香'),
            ),
        isFalse,
        reason: '换了曲目必须算新状态，提示才会重新弹',
      );
    });
  });

  test('引擎重复推送同一份值的快照不会让 Riverpod 再次通知 watcher', () async {
    final _TickingEngine engine = _TickingEngine();
    final ProviderContainer container = ProviderContainer(
      overrides: [audioHandlerProvider.overrideWithValue(TingyuAudioHandler(engine))],
    );
    addTearDown(container.dispose);

    int notifications = 0;
    container.listen<PlaybackSnapshot>(playbackProvider, (
      PlaybackSnapshot? previous,
      PlaybackSnapshot next,
    ) {
      notifications++;
    }, fireImmediately: true);
    expect(notifications, 1);

    engine.push(_tick());
    await pumpEventQueue();
    expect(notifications, 2, reason: '状态确实变了要通知');

    engine.push(_tick());
    await pumpEventQueue();
    expect(
      notifications,
      2,
      reason: '值没变的进度 tick 不该重建所有 watcher',
    );

    engine.push(_tick(position: const Duration(milliseconds: 60)));
    await pumpEventQueue();
    expect(notifications, 3, reason: '位置真的推进了仍要通知');
  });
}
