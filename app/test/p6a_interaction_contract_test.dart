import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/design/components/buttons.dart';
import 'package:tingyu/design/components/context_menu.dart';

import 'support/pump.dart';

const ValueKey<String> _focusIndicatorKey = ValueKey<String>(
  'ty-focus-indicator',
);

void main() {
  testWidgets('Tab 顺序稳定，Enter 与 Space 驱动同一业务操作', (WidgetTester tester) async {
    final List<String> activations = <String>[];
    await pumpTyApp(
      tester,
      home: Scaffold(
        body: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _button('收藏', () => activations.add('收藏')),
              const SizedBox(width: 8),
              _button('播放', () => activations.add('播放')),
              const SizedBox(width: 8),
              _button('更多', () => activations.add('更多')),
            ],
          ),
        ),
      ),
      size: TyTestSizes.phone,
    );

    for (final String label in <String>['收藏', '播放', '更多']) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusedLabels(tester), <String>[
        label,
      ], reason: 'Tab 顺序必须在第一次进入页面时保持视觉顺序');
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(activations, <String>['更多', '更多']);
  });

  testWidgets('按住 Enter 或 Space 的自动重复不会重复执行操作', (WidgetTester tester) async {
    int activations = 0;
    await pumpTyApp(
      tester,
      home: Scaffold(body: Center(child: _button('播放', () => activations++))),
      size: TyTestSizes.phone,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.space,
    ]) {
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyRepeatEvent(key);
      await tester.sendKeyRepeatEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.pump();
    }

    expect(activations, 2, reason: '每次完整的 Enter / Space 按键只能触发一次，自动重复属于同一次按键');
  });

  testWidgets('Esc 关闭浮层并把焦点与可见焦点环还给触发控件', (WidgetTester tester) async {
    await pumpTyApp(
      tester,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (BuildContext context) => _button(
              '打开菜单',
              () => TyContextMenu.show(
                context,
                position: const Offset(24, 24),
                actions: <TyMenuAction>[
                  TyMenuAction(label: '查看专辑', onSelected: () {}),
                  TyMenuAction(label: '添加至歌单', onSelected: () {}),
                ],
              ),
            ),
          ),
        ),
      ),
      size: TyTestSizes.phone,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('查看专辑'), findsOneWidget);
    expect(find.text('添加至歌单'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('查看专辑'), findsNothing);
    expect(_focusedLabels(tester), <String>['打开菜单']);
    expect(
      find.descendant(
        of: find.widgetWithText(TyButton, '打开菜单'),
        matching: find.byKey(_focusIndicatorKey),
      ),
      findsOneWidget,
    );

    // 焦点确实可用，而不只是画出了焦点环。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('查看专辑'), findsOneWidget);
  });

  testWidgets('按钮暴露可执行语义动作与禁用状态', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await pumpTyApp(
        tester,
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _button('播放', () {}),
                const SizedBox(width: 8),
                const TyButton(label: '暂不可用'),
              ],
            ),
          ),
        ),
        size: TyTestSizes.phone,
      );

      final Finder enabledFinder = _semanticButton('播放');
      final Finder disabledFinder = _semanticButton('暂不可用');
      final Semantics enabledWidget =
          enabledFinder.evaluate().single.widget as Semantics;
      final Semantics disabledWidget =
          disabledFinder.evaluate().single.widget as Semantics;
      final SemanticsNode enabled = tester.getSemantics(enabledFinder);
      final SemanticsNode disabled = tester.getSemantics(disabledFinder);
      expect(enabled.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(enabledWidget.properties.enabled, isTrue);
      expect(
        disabled.getSemanticsData().hasAction(SemanticsAction.tap),
        isFalse,
      );
      expect(disabledWidget.properties.enabled, isFalse);
    } finally {
      semantics.dispose();
    }
  });
}

TyButton _button(String label, VoidCallback onPressed) =>
    TyButton(label: label, onPressed: onPressed);

Finder _semanticButton(String label) => find.descendant(
  of: find.widgetWithText(TyButton, label),
  matching: find.byWidgetPredicate(
    (Widget widget) => widget is Semantics && widget.properties.label == label,
  ),
);

List<String> _focusedLabels(WidgetTester tester) {
  final List<String> labels = <String>[];
  for (final String label in <String>['收藏', '播放', '更多', '打开菜单']) {
    final Finder button = find.widgetWithText(TyButton, label);
    if (button.evaluate().isEmpty) {
      continue;
    }
    if (find
        .descendant(of: button, matching: find.byKey(_focusIndicatorKey))
        .evaluate()
        .isNotEmpty) {
      labels.add(label);
    }
  }
  return labels;
}
