import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/design/components/feedback.dart';
import 'package:tingyu/design/tokens/metrics.dart';

import 'support/pump.dart';

/// `TyAsyncView` 四态：loading / error / empty / data，错误重试与空态行动可点。
void main() {
  Widget host(Widget view) => Scaffold(body: view);

  testWidgets('loading 显示骨架，不显示数据', (WidgetTester tester) async {
    await pumpTyApp(
      tester,
      home: host(
        TyAsyncView<int>(
          value: const AsyncValue<int>.loading(),
          data: (BuildContext context, int value) => Text('data $value'),
        ),
      ),
    );

    expect(find.byType(TySkeleton), findsWidgets);
    expect(find.textContaining('data '), findsNothing);
  });

  testWidgets('error 走 TyErrorView 并允许重试', (WidgetTester tester) async {
    int retries = 0;
    await pumpTyApp(
      tester,
      home: host(
        TyAsyncView<int>(
          value: AsyncValue<int>.error(StateError('boom'), StackTrace.current),
          data: (BuildContext context, int value) => Text('data $value'),
          error: (BuildContext context, Object error, StackTrace? stack) =>
              TyErrorView(
                title: '加载失败',
                detail: '$error',
                onRetry: () => retries++,
              ),
        ),
      ),
    );

    expect(find.text('加载失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retries, 1);
  });

  testWidgets('空数据走空态；isEmptyError 时走错误态', (WidgetTester tester) async {
    await pumpTyApp(
      tester,
      home: host(
        TyAsyncView<List<String>>(
          value: const AsyncValue<List<String>>.data(<String>[]),
          isEmpty: (List<String> value) => value.isEmpty,
          data: (BuildContext context, List<String> value) =>
              Text('${value.length}'),
          empty: (BuildContext context) =>
              const TyEmptyState(title: '还没有歌曲'),
        ),
      ),
    );
    expect(find.text('还没有歌曲'), findsOneWidget);

    await pumpTyApp(
      tester,
      home: host(
        TyAsyncView<List<String>>(
          value: const AsyncValue<List<String>>.data(<String>[]),
          isEmpty: (List<String> value) => value.isEmpty,
          isEmptyError: true,
          data: (BuildContext context, List<String> value) =>
              Text('${value.length}'),
        ),
      ),
    );
    expect(find.text('没有可用的数据'), findsOneWidget);
  });

  testWidgets('data 态渲染真实内容', (WidgetTester tester) async {
    await pumpTyApp(
      tester,
      home: host(
        TyAsyncView<int>(
          value: const AsyncValue<int>.data(7),
          data: (BuildContext context, int value) => Text('data $value'),
        ),
      ),
    );
    expect(find.text('data 7'), findsOneWidget);
  });

  testWidgets('紧凑形态下骨架不溢出手机宽度', (WidgetTester tester) async {
    await pumpTyApp(
      tester,
      home: host(
        TyAsyncView<int>(
          value: const AsyncValue<int>.loading(),
          data: (BuildContext context, int value) => Text('data $value'),
        ),
      ),
      size: TyTestSizes.phoneSmall,
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(TySkeleton).first).width,
      lessThanOrEqualTo(TyTestSizes.phoneSmall.width - TySpace.x32),
    );
  });
}
