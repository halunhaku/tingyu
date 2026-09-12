import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

/// 记录调用并允许测试手动推送快照的假引擎。
final class _FakeEngine extends PlaybackEngineBase {
  final List<List<PlaybackItem>> queues = <List<PlaybackItem>>[];
  final List<String> commands = <String>[];

  @override
  String get name => 'fake';

  List<PlaybackItem> _items = const <PlaybackItem>[];

  @override
  List<PlaybackItem> get items => _items;

  @override
  PlaybackItem? get currentItem => _items.isEmpty ? null : _items.first;

  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {
    queues.add(items);
    _items = List<PlaybackItem>.unmodifiable(items);
    commands.add('setQueue:$startIndex');
  }

  @override
  Future<void> play() async => commands.add('play');

  @override
  Future<void> pause() async => commands.add('pause');

  @override
  Future<void> seek(Duration position) async => commands.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setRate(double rate) async => commands.add('rate:$rate');

  @override
  Future<void> setVolume(double volume) async => commands.add('volume:$volume');

  @override
  Future<void> skipToNext() async => commands.add('next');

  @override
  Future<void> skipToPrevious() async => commands.add('previous');

  @override
  Future<void> dispose() async => closeSnapshotStream();

  /// 供测试推送快照（`emit` 为 protected）。
  void push(PlaybackSnapshot snapshot) => emit(snapshot);
}

PlaybackSnapshot _snapshot({
  bool playing = false,
  PlaybackProcessing processing = PlaybackProcessing.ready,
  int index = 0,
  Duration position = Duration.zero,
  Duration duration = const Duration(seconds: 5),
  Duration buffered = Duration.zero,
}) {
  return PlaybackSnapshot(
    processing: processing,
    playing: playing,
    position: position,
    duration: duration,
    buffered: buffered,
    index: index,
    rate: 1,
    volume: 1,
  );
}

List<PlaybackItem> _items() => <PlaybackItem>[
      PlaybackItem.fromUri(Uri.parse('file:///music/a.flac')),
      PlaybackItem.fromUri(Uri.parse('file:///music/b.flac')),
    ];

void main() {
  late _FakeEngine engine;
  late TingyuAudioHandler handler;

  /// 推送快照并等待流事件送达（快照流是异步交付的）。
  Future<void> push(PlaybackSnapshot snapshot) async {
    engine.push(snapshot);
    await pumpEventQueue();
  }

  setUp(() {
    engine = _FakeEngine();
    handler = TingyuAudioHandler(engine, statePushInterval: const Duration(days: 1));
  });

  tearDown(() => handler.dispose());

  test('setQueue 把队列与定位下标转发给引擎，并发布队列元数据', () async {
    final List<PlaybackItem> items = _items();
    await handler.setQueue(items, startIndex: 1);
    await pumpEventQueue();

    expect(engine.queues.single, items);
    expect(engine.commands, <String>['setQueue:1']);
    expect(
      handler.queue.value.map((MediaItem item) => item.id).toList(),
      items.map((PlaybackItem item) => item.id).toList(),
    );
    expect(handler.queue.value.first.title, 'a.flac');
  });

  test('系统媒体会话指令转发到引擎', () async {
    await handler.play();
    await handler.pause();
    await handler.skipToNext();
    await handler.skipToPrevious();
    await handler.seek(const Duration(seconds: 3));
    await handler.setSpeed(1.5);
    await handler.setVolume(0.5);

    expect(engine.commands, <String>[
      'play',
      'pause',
      'next',
      'previous',
      'seek:3000',
      'rate:1.5',
      'volume:0.5',
    ]);
  });

  test('媒体元数据只在曲目切换或时长首次可知时更新', () async {
    await handler.setQueue(_items());
    final List<MediaItem?> published = <MediaItem?>[];
    final sub = handler.mediaItem.listen(published.add);
    await pumpEventQueue();
    published.clear();

    await push(_snapshot(duration: Duration.zero));
    expect(handler.mediaItem.value?.duration, isNull, reason: '引擎尚未得知时长时不伪造');

    await push(_snapshot(duration: const Duration(seconds: 5)));
    expect(handler.mediaItem.value?.duration, const Duration(seconds: 5));
    final int afterDurationKnown = published.length;

    await push(_snapshot(duration: const Duration(seconds: 5), position: const Duration(seconds: 1)));
    expect(published.length, afterDurationKnown, reason: '相同时长与曲目不应重复发布媒体元数据');

    await push(_snapshot(index: 1, duration: const Duration(seconds: 5)));
    expect(handler.mediaItem.value?.title, 'b.flac');

    await sub.cancel();
  });

  test('纯进度更新被节流，播放语义变化立即推送', () async {
    await handler.setQueue(_items());
    final List<PlaybackState> states = <PlaybackState>[];
    final sub = handler.playbackState.listen(states.add);
    await pumpEventQueue();
    final int initial = states.length;

    await push(_snapshot(playing: true));
    expect(states.length, initial + 1, reason: '播放态变化应立即推送');

    await push(_snapshot(playing: true, position: const Duration(milliseconds: 60)));
    await push(_snapshot(playing: true, position: const Duration(milliseconds: 120)));
    expect(states.length, initial + 1, reason: '节流窗口内的纯进度更新应被抑制');

    await push(_snapshot(playing: false, position: const Duration(milliseconds: 180)));
    expect(states.length, initial + 2, reason: '暂停应立即推送');
    expect(states.last.playing, isFalse);
    expect(states.last.queueIndex, 0);

    await sub.cancel();
  });
}
