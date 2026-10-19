import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/design/components/cover.dart';
import 'package:tingyu/design/components/player_stage.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';

void main() {
  testWidgets('高手机展示有界预览槽，矮手机保留独立入口', (WidgetTester tester) async {
    await _pumpStage(tester, const Size(390, 844));
    expect(find.byKey(const ValueKey<String>('compact-pane')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('compact-pane'))).height,
      TyPlayerStageSize.compactPaneHeight,
    );

    await _pumpStage(tester, const Size(390, 640));
    expect(find.byKey(const ValueKey<String>('compact-pane')), findsNothing);
    expect(find.bySemanticsLabel('打开播放队列'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded 只在有右栏时布局380宽面板和48间距', (WidgetTester tester) async {
    // A taller window leaves enough vertical budget to reach the preferred size.
    await _pumpStage(tester, const Size(1440, 960));
    final Rect cover = tester.getRect(find.byType(TyCover));
    final Rect pane = tester.getRect(
      find.byKey(const ValueKey<String>('right-pane')),
    );
    expect(cover.width, TyPlayerStageSize.desktopCoverPreferred);
    expect(pane.width, TyPlayerStageSize.rightPaneWidth);
    expect(
      pane.left - cover.right,
      greaterThanOrEqualTo(TyPlayerStageSize.paneGap),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded 中高窗按可用高度收敛封面预算', (WidgetTester tester) async {
    await _pumpStage(tester, const Size(1440, 900));
    final double coverHeight = tester.getSize(find.byType(TyCover)).height;
    final double availableStageHeight = 900 - TyPlayerStageSize.topBarHeight;
    final double expectedCoverHeight =
        availableStageHeight * TyPlayerStageSize.coverHeightRatio;

    expect(coverHeight, expectedCoverHeight);
    expect(coverHeight, lessThan(TyPlayerStageSize.desktopCoverPreferred));
    expect(tester.takeException(), isNull);
  });

  testWidgets('长标题完整语义，横屏大字时主控仍可到达且无溢出', (WidgetTester tester) async {
    const String title = '这是一段需要完整保留语义的中英文长标题 Long Track Name';
    await _pumpStage(
      tester,
      const Size(844, 390),
      textScaler: const TextScaler.linear(2),
      title: title,
    );
    expect(find.bySemanticsLabel('播放控制'), findsOneWidget);
    final Rect scrollViewport = tester.getRect(
      find.byType(SingleChildScrollView),
    );
    Rect transport = tester.getRect(
      find.byKey(const ValueKey<String>('transport')),
    );
    expect(transport.top, greaterThanOrEqualTo(0));
    expect(transport.bottom, lessThanOrEqualTo(390));
    expect(tester.getSemantics(find.text(title)).label, title);

    await tester.ensureVisible(find.text(title));
    await tester.pumpAndSettle();

    final Rect titleRect = tester.getRect(find.text(title));
    expect(titleRect.top, greaterThanOrEqualTo(scrollViewport.top));
    expect(titleRect.bottom, lessThanOrEqualTo(scrollViewport.bottom));
    transport = tester.getRect(find.byKey(const ValueKey<String>('transport')));
    expect(transport.top, greaterThanOrEqualTo(0));
    expect(transport.bottom, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpStage(
  WidgetTester tester,
  Size size, {
  TextScaler textScaler = TextScaler.noScaling,
  String title = '测试曲目',
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: TyTheme.build(brightness: Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: textScaler),
          child: TyLayoutScope.forSize(
            size,
            child: TyPlayerStage(
              background: const SizedBox.expand(),
              title: title,
              artist: '测试歌手',
              album: '测试专辑',
              progress: Semantics(label: '播放控制', child: SizedBox(height: 44)),
              transport: const SizedBox(
                key: ValueKey<String>('transport'),
                height: 48,
              ),
              actions: <Widget>[
                Semantics(
                  label: '打开播放队列',
                  child: SizedBox(width: 44, height: 44),
                ),
              ],
              compactPane: const ColoredBox(
                key: ValueKey<String>('compact-pane'),
                color: Color(0x00000000),
                child: Center(child: Text('tab + 预览')),
              ),
              rightPane: const ColoredBox(
                key: ValueKey<String>('right-pane'),
                color: Color(0x00000000),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
