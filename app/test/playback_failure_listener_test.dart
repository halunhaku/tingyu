import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/features/shared/playback_failure_listener.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

/// 只用来把快照推进 UI 的假引擎（`emit` 为 protected）。
final class _FakeEngine extends PlaybackEngineBase {
  @override
  String get name => 'fake';

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

  void push(PlaybackSnapshot snapshot) => emit(snapshot);
}

PlaybackSnapshot _snapshot({PlaybackFailure? failure}) => PlaybackSnapshot(
  processing: PlaybackProcessing.ready,
  playing: false,
  position: Duration.zero,
  duration: const Duration(seconds: 5),
  buffered: Duration.zero,
  index: 0,
  rate: 1,
  volume: 1,
  failure: failure,
);

/// 把监听器挂在与 `main.dart` 相同的位置：`MaterialApp.builder`（ScaffoldMessenger 之下）。
Future<_FakeEngine> _pumpListener(WidgetTester tester) async {
  final _FakeEngine engine = _FakeEngine();
  // 不在这里 dispose：testWidgets 的 FakeAsync 区里 await 异步流的取消会卡住，
  // 引擎本身也只是测试内的广播控制器，进程结束即回收。
  final TingyuAudioHandler handler = TingyuAudioHandler(engine);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [audioHandlerProvider.overrideWithValue(handler)],
      child: MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            PlaybackFailureListener(child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    ),
  );
  return engine;
}

void main() {
  testWidgets('播放失败会弹提示，同一份快照反复推送不会重新弹', (WidgetTester tester) async {
    final _FakeEngine engine = await _pumpListener(tester);

    const PlaybackFailure failure = PlaybackFailure(
      message: 'Source error',
      title: '晴天',
    );
    engine.push(_snapshot(failure: failure));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('「晴天」Source error'), findsOneWidget);

    // 进度事件会以同一实例反复推送同一份快照；t=3s 再推一次，若被当成新失败
    // 会重置 SnackBar 的显示时长，那么到 t=5s 它仍然在屏上。
    await tester.pump(const Duration(seconds: 3));
    engine.push(_snapshot(failure: failure));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2)); // 越过 4s 自动关闭时刻
    await tester.pump(const Duration(milliseconds: 400)); // 关闭动画
    expect(find.text('「晴天」Source error'), findsNothing);
  });

  testWidgets('换一首歌再次失败会重新提示', (WidgetTester tester) async {
    final _FakeEngine engine = await _pumpListener(tester);

    engine.push(
      _snapshot(
        failure: const PlaybackFailure(message: 'Source error', title: '晴天'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('「晴天」Source error'), findsOneWidget);

    engine.push(
      _snapshot(
        failure: const PlaybackFailure(message: 'Source error', title: '稻香'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 旧的退场
    await tester.pump(const Duration(milliseconds: 300)); // 新的进场
    expect(find.text('「晴天」Source error'), findsNothing);
    expect(find.text('「稻香」Source error'), findsOneWidget);
  });
}
