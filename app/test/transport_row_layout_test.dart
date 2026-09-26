import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/theme.dart';
import 'package:tingyu/features/player/playback_controls.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

/// 正在播放页那排控件（随机 / 上一首 / 播放 / 下一首 / 循环）的排版约束。
///
/// 真机截图里量到的旧排法是"固定间隔 + 整体居中"：各键宽度不同（大播放键 vs 普通图标）
/// 会把中心距撑成 88.5 / 107 / 99.5 / 93.5，左右两个模式键明显贴得近，
/// 而且它们的图标（24）比上一首/下一首（30）小一圈，看起来像被缩小的次级控件。
/// 这几条断言把"等宽槽 + 尺寸接近"的结论固定下来。
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
  /// 手机宽度（与真机截图同一量级）。
  const double phoneWidth = 390;

  Future<void> pumpControls(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(phoneWidth, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioHandlerProvider.overrideWithValue(
            TingyuAudioHandler(_SilentEngine()),
          ),
        ],
        child: MaterialApp(
          theme: buildTingyuTheme(Brightness.light),
          home: const Scaffold(body: PlaybackControls()),
        ),
      ),
    );
    await tester.pump();
  }

  double centerX(WidgetTester tester, Finder finder) =>
      tester.getCenter(finder).dx;

  /// 图标的实际尺寸由 IconButton.iconSize 决定（里面的 Icon 自身 size 是 null）。
  /// byTooltip 找到的是 Tooltip，所以这里往上取一层 IconButton。
  double iconSizeOf(WidgetTester tester, Finder button) => tester
      .widget<IconButton>(
        find.ancestor(of: button, matching: find.byType(IconButton)),
      )
      .iconSize!;

  testWidgets('五个键等距分布，播放键居中，两侧留白对称', (WidgetTester tester) async {
    await pumpControls(tester);

    final Finder shuffle = find.byTooltip('随机播放：关');
    final Finder previous = find.byTooltip('上一首');
    final Finder play = find.byIcon(Icons.play_arrow_rounded);
    final Finder next = find.byTooltip('下一首');
    final Finder repeat = find.byTooltip('列表循环');

    final List<double> centers = <double>[
      centerX(tester, shuffle),
      centerX(tester, previous),
      centerX(tester, play),
      centerX(tester, next),
      centerX(tester, repeat),
    ];
    final List<double> gaps = <double>[
      for (int i = 1; i < centers.length; i++) centers[i] - centers[i - 1],
    ];

    expect(
      gaps.reduce(math.max) - gaps.reduce(math.min),
      lessThan(1.0),
      reason: '五个键的中心距必须一致，实测 $gaps',
    );
    expect(
      centers[2],
      closeTo(phoneWidth / 2, 0.5),
      reason: '播放键要落在页面中轴上',
    );
    expect(
      phoneWidth - centers.last,
      closeTo(centers.first, 0.5),
      reason: '左右两侧留白必须对称',
    );
  });

  testWidgets('两个模式键与传送键尺寸接近，且都有 48dp 触控目标', (WidgetTester tester) async {
    await pumpControls(tester);

    final Finder shuffle = find.byTooltip('随机播放：关');
    final Finder previous = find.byTooltip('上一首');
    final Finder next = find.byTooltip('下一首');
    final Finder repeat = find.byTooltip('列表循环');

    final double side = iconSizeOf(tester, shuffle);
    expect(iconSizeOf(tester, repeat), side, reason: '两个模式键要一样大');
    expect(iconSizeOf(tester, previous), iconSizeOf(tester, next));
    expect(
      iconSizeOf(tester, previous) - side,
      lessThanOrEqualTo(4),
      reason: '模式键不该比传送键小一圈（旧版是 24 vs 30）',
    );

    for (final Finder button in <Finder>[
      shuffle,
      previous,
      next,
      repeat,
      // 播放键是 FilledButton：图标本身 33.6dp，可点区域是外面那圈 60dp 的圆。
      find.byType(FilledButton),
    ]) {
      final Size size = tester.getSize(button);
      expect(size.width, greaterThanOrEqualTo(48.0));
      expect(size.height, greaterThanOrEqualTo(48.0));
    }
  });

  testWidgets('窄屏（320dp）下仍然等距且不溢出', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioHandlerProvider.overrideWithValue(
            TingyuAudioHandler(_SilentEngine()),
          ),
        ],
        child: MaterialApp(
          theme: buildTingyuTheme(Brightness.light),
          home: const Scaffold(body: PlaybackControls()),
        ),
      ),
    );
    await tester.pump();

    final List<double> centers = <double>[
      centerX(tester, find.byTooltip('随机播放：关')),
      centerX(tester, find.byTooltip('上一首')),
      centerX(tester, find.byIcon(Icons.play_arrow_rounded)),
      centerX(tester, find.byTooltip('下一首')),
      centerX(tester, find.byTooltip('列表循环')),
    ];
    final List<double> gaps = <double>[
      for (int i = 1; i < centers.length; i++) centers[i] - centers[i - 1],
    ];
    expect(gaps.reduce(math.max) - gaps.reduce(math.min), lessThan(1.0));
    expect(tester.takeException(), isNull);
  });
}
