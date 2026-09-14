import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('go_router pathParameters 已解码中文与转义路径段', (
    WidgetTester tester,
  ) async {
    final GoRouter router = GoRouter(
      initialLocation: '/artists/${Uri.encodeComponent('周杰伦')}',
      routes: <RouteBase>[
        GoRoute(
          path: '/artists/:name',
          builder: (_, GoRouterState state) => Text(
            state.pathParameters['name'] ?? '',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('周杰伦'), findsOneWidget);
  });
}
