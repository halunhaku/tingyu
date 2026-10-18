import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/playback_controller.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/design/components/player_stage.dart';
import 'package:tingyu/design/components/transport.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/features/player/now_playing_page.dart';
import 'package:tingyu/features/shared/current_track.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

/// 播放舞台的竖向排布（`DESIGN.md` §6.3）：
/// - 传输行压在内容列下缘，多出来的高度由封面与传输行之间的弹性间隔吸收，
///   不在底部留大片空白（旧版工具栏浮在中间，真机实测底部空了 127dp）；
/// - 矮屏（横屏）不许溢出：封面按窗口高度收缩，内容整体可滚动。
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

/// 只提供界面需要的状态，避免真控制器去碰音频引擎。
final class _FakePlayback extends PlaybackController {
  @override
  PlaybackSnapshot build() => PlaybackSnapshot.initial.copyWith(
    processing: PlaybackProcessing.ready,
    duration: const Duration(minutes: 4),
  );
}

void main() {
  _stageLayoutCoverage();
  _textStyleCoverage();
}

Future<void> pumpPage(
  WidgetTester tester, {
  required Size size,
  double bottomPadding = 0,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final FormFactor formFactor = FormFactor.ofWidth(size.width);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        formFactorProvider.overrideWithValue(formFactor),
        audioHandlerProvider.overrideWithValue(
          TingyuAudioHandler(_SilentEngine()),
        ),
        // 有「正在播放的那一条」才会渲染出封面舞台与传输行（否则是空态）。
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
      child: MaterialApp.router(
        theme: TyTheme.build(brightness: Brightness.light),
        // 舞台自己读 GoRouterState（?tab=）与安全区，所以测试也走真路由器。
        routerConfig: GoRouter(
          initialLocation: '/stage',
          routes: <RouteBase>[
            GoRoute(
              path: '/stage',
              // 与真实路由同构：舞台挂在根 Navigator 上，**没有** Scaffold /
              // Material 祖先（它得自己提供），所以这里也不套 Scaffold。
              builder: (_, _) => Builder(
                builder: (BuildContext context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: size,
                    padding: EdgeInsets.only(bottom: bottomPadding),
                  ),
                  child: TyLayoutScope.forSize(
                    size,
                    child: const NowPlayingPage(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 舞台的竖向排布与矮屏行为。
void _stageLayoutCoverage() {
  testWidgets('竖屏：传输行贴在下缘（留出 24dp + 手势条），不在底部留大片空白', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, size: const Size(390, 844), bottomPadding: 20);

    final Rect transport = tester.getRect(find.byType(TyTransportRow));
    final double gapToBottom = 844 - transport.bottom;

    // 传输行下面只剩次级行（♥/歌词/队列/音量）与固定留白（24 固定 + 20 安全区），
    // 所以 96 是宽松上限；关键是它不再浮在屏幕中间。
    expect(
      gapToBottom,
      lessThanOrEqualTo(120),
      reason: '传输行应当贴在下缘，实测距屏幕底 ${gapToBottom.toStringAsFixed(1)}dp',
    );
    expect(
      transport.width,
      lessThanOrEqualTo(TyPlayerStageSize.contentMaxWidth + 1),
      reason: '内容列宽上限 ${TyPlayerStageSize.contentMaxWidth}dp',
    );
  });

  testWidgets('矮屏（横屏）不溢出：封面收缩，内容可滚动', (WidgetTester tester) async {
    await pumpPage(tester, size: const Size(844, 390));

    expect(tester.takeException(), isNull);
    // 传输行仍在树里（滚动区域内），只是不需要靠弹性间隔撑开。
    expect(find.byType(TyTransportRow), findsOneWidget);
  });
}

/// 页面只要挂在根 Navigator（舞台 / 队列 / 歌词），就必须自己提供 `Material`：
/// 否则 `Text` 会落到 MaterialApp 的 fallback 样式上——那套样式带一条**黄色下划线**
/// （Flutter 用来提示「你的文本不在 Material 里」），真机截图里一眼就能看见。
void _textStyleCoverage() {
  testWidgets('舞台的文本落在真实 DefaultTextStyle 里（没有 fallback 黄线）', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, size: const Size(390, 844));

    final Iterable<Element> texts = find.byType(Text).evaluate();
    expect(texts, isNotEmpty);
    for (final Element element in texts) {
      final TextStyle style = DefaultTextStyle.of(element).style;
      expect(
        style.decoration,
        isNot(TextDecoration.underline),
        reason: '文本落到了 MaterialApp 的 fallback 样式上：${element.widget}',
      );
      expect(
        style.decorationColor,
        isNot(const Color(0xFFFFFF00)),
        reason: '文本落到了 MaterialApp 的 fallback 样式上：${element.widget}',
      );
      expect(
        style.fontFamily,
        isNot('monospace'),
        reason: '文本落到了 MaterialApp 的 fallback 样式上：${element.widget}',
      );
    }
  });
}
