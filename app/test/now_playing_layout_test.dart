import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/playback_controller.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/theme.dart';
import 'package:tingyu/features/player/now_playing_page.dart';
import 'package:tingyu/features/player/playback_controls.dart';
import 'package:tingyu/features/shared/current_track.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

/// 正在播放页的竖向排布：传送器贴页面下缘（QQ 音乐同样把控件压在底部），
/// 多出来的高度由封面与传送器之间的弹性间隔吸收。
///
/// 旧版是"整块居中"：真机实测控件行下方空了 127dp（控件行底 746dp / 屏高 873dp），
/// 而顶部只空 168dp —— 控件浮在中间，底部一大块死白。
final class _SilentEngine extends PlaybackEngineBase {
  @override
  String get name => 'silent';
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
}

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required Size size,
    double bottomPadding = 0,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioHandlerProvider.overrideWithValue(
            TingyuAudioHandler(_SilentEngine()),
          ),
          // 有"正在播放的那一条"才会渲染出封面舞台与传送器（否则是空态）。
          currentTrackRefProvider.overrideWithValue((
            trackId: null,
            item: PlaybackItem.fromUri(
              Uri.file('/tmp/tingyu-layout-test.mp3'),
              title: '测试曲目',
              artist: '测试歌手',
            ),
          )),
          currentTrackProvider.overrideWithValue(null),
          playbackProvider.overrideWith(() => _FakePlayback()),
        ],
        child: MaterialApp(
          theme: buildTingyuTheme(Brightness.light),
          // 真实路由会给这一页套 Material（MaterialPageRoute），测试里用 Scaffold 等价提供。
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(padding: EdgeInsets.only(bottom: bottomPadding)),
                child: const NowPlayingPage(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('竖屏：传送器贴在下缘（留出 24dp + 手势条），不在底部留大片空白', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, size: const Size(390, 844), bottomPadding: 20);

    final Rect controls = tester.getRect(find.byType(PlaybackControls));
    final double gapToBottom = 844 - controls.bottom;

    // 下缘留白 = 24（固定）+ 20（安全区）。允许 4dp 的取整误差。
    expect(
      gapToBottom,
      closeTo(44, 4),
      reason: '传送器应当贴在下缘，实测距屏幕底 ${gapToBottom.toStringAsFixed(1)}dp',
    );
    expect(controls.width, lessThanOrEqualTo(420), reason: '内容列宽上限 420dp');
  });

  testWidgets('矮屏（横屏）不溢出：弹性间隔收成 0，内容可滚动', (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(844, 390));

    expect(tester.takeException(), isNull);
    // 传送器仍在树里（滚动区域内），只是不需要靠弹性间隔撑开。
    expect(find.byType(PlaybackControls), findsOneWidget);
  });
}

/// 只提供按钮行需要的状态，避免真控制器去碰音频引擎。
final class _FakePlayback extends PlaybackController {
  @override
  PlaybackSnapshot build() => PlaybackSnapshot.initial;
}
