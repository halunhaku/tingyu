import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/design/components/buttons.dart';
import 'package:tingyu/features/sources/source_sync.dart';
import 'package:tingyu/features/sources/sources_page.dart';

import '../tool/source_archive_fixtures.dart';
import 'support/page_harness.dart';

void main() {
  testWidgets('来源管理桌面摘要、卡片与状态层级可渲染', (WidgetTester tester) async {
    await _pumpSources(
      tester,
      size: const Size(1440, 900),
      brightness: Brightness.light,
      state: SourcePreviewState.normal,
    );

    expect(find.text('来源管理'), findsOneWidget);
    expect(find.text('3 个来源 · 228 首音乐'), findsOneWidget);
    expect(find.text('潮汐唱片'), findsOneWidget);
    expect(find.text('海岸线备份'), findsOneWidget);
    expect(find.text('远航云盘'), findsOneWidget);
    expect(
      find.byKey(const Key('source-card-preview-source-local')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('同步中使用真实计数与确定进度，不需要点击即可读状态', (WidgetTester tester) async {
    await _pumpSources(
      tester,
      size: const Size(1440, 900),
      brightness: Brightness.dark,
      state: SourcePreviewState.syncing,
    );

    expect(find.text('同步中'), findsWidgets);
    expect(find.text('已扫描 184 / 320'), findsOneWidget);
    expect(find.textContaining('海岸线备份 · 第 184 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('夸克会话失效时把主操作切到重新登录', (WidgetTester tester) async {
    await _pumpSources(
      tester,
      size: const Size(390, 844),
      brightness: Brightness.light,
      state: SourcePreviewState.relogin,
    );

    final Finder relogin = find.widgetWithText(TyButton, '重新登录');
    expect(relogin, findsOneWidget);
    expect(find.text('夸克会话已过期，需要重新登录后继续同步。'), findsOneWidget);
    expect(find.text('需恢复'), findsOneWidget);
    await tester.ensureVisible(relogin);
    await tester.pumpAndSettle();
    expect(tester.getRect(relogin).bottom, lessThanOrEqualTo(844));
    expect(tester.takeException(), isNull);
  });

  testWidgets('空来源提供三种明确入口，页面仍可滚动', (WidgetTester tester) async {
    await _pumpSources(
      tester,
      size: const Size(390, 844),
      brightness: Brightness.light,
      state: SourcePreviewState.empty,
    );

    expect(find.text('还没有音乐来源'), findsOneWidget);
    expect(find.text('本地目录'), findsWidgets);
    expect(find.text('WebDAV'), findsWidgets);
    expect(find.text('夸克网盘'), findsWidgets);
    expect(find.byKey(const Key('sources-add-local')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机 200% 字号不溢出并保留添加入口', (WidgetTester tester) async {
    await _pumpSources(
      tester,
      size: const Size(390, 844),
      brightness: Brightness.dark,
      state: SourcePreviewState.normal,
      textScale: 2,
    );

    expect(find.byTooltip('添加来源'), findsOneWidget);
    expect(find.text('潮汐唱片'), findsOneWidget);
    final Finder card = find.byKey(
      const Key('source-card-preview-source-local'),
    );
    final Finder status = find.descendant(of: card, matching: find.text('已连接'));
    expect(
      tester.getTopLeft(status).dy,
      greaterThan(tester.getTopLeft(find.text('潮汐唱片')).dy),
      reason: '放大文字时状态徽标应另起一行，不能挤断来源名称',
    );
    final Finder primaryAction = find.widgetWithText(TyButton, '同步').first;
    await tester.ensureVisible(primaryAction);
    await tester.pumpAndSettle();
    expect(tester.getRect(primaryAction).bottom, lessThanOrEqualTo(844));
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加按钮仍打开原来的来源类型选择', (WidgetTester tester) async {
    await _pumpSources(
      tester,
      size: const Size(1440, 900),
      brightness: Brightness.light,
      state: SourcePreviewState.normal,
    );

    await tester.tap(find.widgetWithText(TyButton, '添加来源'));
    await tester.pumpAndSettle();

    expect(find.text('添加来源'), findsWidgets);
    expect(find.text('本地目录'), findsOneWidget);
    expect(find.text('WebDAV'), findsOneWidget);
    expect(find.text('夸克网盘'), findsOneWidget);
  });

  testWidgets('来源更多菜单保留配置、诊断与删除入口', (WidgetTester tester) async {
    await _pumpSources(
      tester,
      size: const Size(1440, 900),
      brightness: Brightness.light,
      state: SourcePreviewState.normal,
    );

    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();

    expect(find.text('补全元数据'), findsWidgets);
    expect(find.text('复制诊断信息'), findsWidgets);
    expect(find.text('删除来源'), findsWidgets);
  });

  testWidgets('读取失败不向用户暴露 Bad state 前缀', (WidgetTester tester) async {
    await _pumpSources(
      tester,
      size: const Size(390, 844),
      brightness: Brightness.dark,
      state: SourcePreviewState.error,
      readError: true,
    );

    expect(find.text('读取来源失败'), findsOneWidget);
    expect(find.text('固定预览：模拟来源读取失败。'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
  });
}

Future<void> _pumpSources(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
  required SourcePreviewState state,
  double textScale = 1,
  bool readError = false,
}) {
  final List<MusicSource> sources = sourcePreviewFixtures(state);
  final Map<String, SourceSyncState> sync = sourcePreviewSyncStates(state);
  return pumpRoutedPage(
    tester,
    const SourcesPage(),
    PageHarness(
      size: size,
      brightness: brightness,
      textScale: textScale,
      overrides: <Override>[
        sourcesProvider.overrideWith(
          (Ref ref) => readError
              ? Stream<List<MusicSource>>.error(StateError('固定预览：模拟来源读取失败'))
              : Stream<List<MusicSource>>.value(sources),
        ),
        sourceSyncProvider.overrideWith(
          () => SourceSyncPreviewController(sync),
        ),
      ],
    ),
    location: '/sources',
  );
}
