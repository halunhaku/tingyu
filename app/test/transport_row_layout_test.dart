import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/design/components/interactive.dart';
import 'package:tingyu/design/components/transport.dart';

import 'support/pump.dart';

/// 传输行（随机 / 上一首 / 播放 / 下一首 / 循环）的排版约束。
///
/// 真机截图里量到的旧排法是「固定间隔 + 整体居中」：各键宽度不同（大播放键 vs
/// 普通图标）会把中心距撑成 88.5 / 107 / 99.5 / 93.5，左右两个模式键明显贴得近，
/// 而且它们的图标（24）比上一首/下一首（30）小一圈，看起来像被缩小的次级控件。
/// 这几条断言把「等宽槽 + 尺寸接近 + 48dp 命中」的结论固定下来。
void main() {
  /// 手机宽度（与真机截图同一量级）。
  const double phoneWidth = 390;

  Future<void> pumpControls(WidgetTester tester) async {
    await pumpTyApp(
      tester,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: phoneWidth,
            child: TyTransportRow(
              playing: false,
              onPlayPause: () {},
              onPrevious: () {},
              onNext: () {},
              onToggleShuffle: () {},
              onCycleRepeat: () {},
              hitSize: TyPlayerSize.transportHitTarget,
            ),
          ),
        ),
      ),
      size: const Size(phoneWidth, 844),
    );
  }

  double centerX(WidgetTester tester, Finder finder) =>
      tester.getCenter(finder).dx;

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
    expect(centers[2], closeTo(phoneWidth / 2, 0.5), reason: '播放键要落在页面中轴上');
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

    double iconSizeOf(Finder button) => tester
        .widget<Icon>(
          find.descendant(of: button, matching: find.byType(Icon)).first,
        )
        .size!;

    final double side = iconSizeOf(shuffle);
    expect(iconSizeOf(repeat), side, reason: '两个模式键要一样大');
    expect(iconSizeOf(previous), iconSizeOf(next));
    expect(
      iconSizeOf(previous) - side,
      lessThanOrEqualTo(12),
      reason: '模式键不该比传送键小一圈（旧版是 24 vs 30）',
    );

    for (final Finder button in <Finder>[shuffle, previous, next, repeat]) {
      final Size hit = tester.getSize(
        find.descendant(of: button, matching: find.byType(TyInteractive)).first,
      );
      expect(
        hit.shortestSide,
        greaterThanOrEqualTo(48),
        reason: '传输键命中区不得小于 48（DESIGN.md §8）',
      );
    }
  });
}
