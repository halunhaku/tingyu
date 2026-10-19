import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/design/components/buttons.dart';
import 'package:tingyu/design/components/navigation.dart';
import 'package:tingyu/design/components/track.dart';
import 'package:tingyu/design/layout/app_shell.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/features/player/mini_player.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'support/fake_audio_engine.dart';
import 'support/pump.dart';

void main() {
  const ValueKey<String> focusIndicatorKey = ValueKey<String>(
    'ty-focus-indicator',
  );

  testWidgets('键盘聚焦主按钮时显示统一焦点环', (WidgetTester tester) async {
    await pumpTyApp(
      tester,
      home: Scaffold(
        body: Center(
          child: TyButton(label: '播放全部', onPressed: () {}),
        ),
      ),
      size: const Size(390, 844),
    );

    final Size unfocusedSize = tester.getSize(find.byType(TyButton));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(TyButton),
        matching: find.byKey(focusIndicatorKey),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(find.byType(TyButton)), unfocusedSize);
  });

  testWidgets('键盘聚焦图标按钮时显示统一焦点环', (WidgetTester tester) async {
    await pumpTyApp(
      tester,
      home: Scaffold(
        body: Center(
          child: TyIconAction(
            icon: Icons.more_horiz,
            semanticLabel: '更多操作',
            onPressed: () {},
          ),
        ),
      ),
      size: const Size(390, 844),
    );

    final Size unfocusedSize = tester.getSize(find.byType(TyIconAction));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(TyIconAction),
        matching: find.byKey(focusIndicatorKey),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(find.byType(TyIconAction)), unfocusedSize);
  });

  testWidgets('compact 底部导航只消费一次系统底部安全区', (WidgetTester tester) async {
    const double bottomInset = 24;
    final GoRouter router = await pumpShellWithBottomInset(
      tester,
      bottomInset: bottomInset,
    );

    expect(
      tester.getRect(find.byType(TyBottomNav)).bottom,
      closeTo(844 - bottomInset, 0.5),
    );

    router.push('/source/s1');
    await tester.pumpAndSettle();

    expect(find.byType(TyBottomNav), findsNothing);
    expect(
      tester.getRect(find.byType(MiniPlayer)).bottom,
      closeTo(844 - bottomInset, 0.5),
    );
  });

  testWidgets('曲目行读屏不重复，收藏与更多操作保持独立节点', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await pumpTyApp(
        tester,
        home: Scaffold(
          body: TyTrackRow(
            track: Track(
              id: 't1',
              sourceId: 's1',
              title: '晴天',
              artist: '周杰伦',
              album: '叶惠美',
              duration: 200,
              fileFormat: 'mp3',
              filePathOrUrl: '/music/t1.mp3',
              fileSize: 1,
              isFavorite: false,
              dateAdded: DateTime.utc(2026, 9, 1),
              playCount: 0,
            ),
            isPlaying: true,
            playing: true,
            onTap: () {},
            onToggleFavorite: () {},
            onMore: () {},
            onSelectChanged: (_) {},
          ),
        ),
        size: const Size(390, 844),
      );
      await tester.pump();

      final List<SemanticsNode> nodes = _flattenSemantics(
        tester.getSemantics(find.byType(TyTrackRow)),
      );
      final String labels = nodes
          .map((SemanticsNode node) => node.label)
          .join('\n');
      expect(_occurrences(labels, '晴天'), 1);
      expect(_occurrences(labels, '正在播放'), 1);

      final SemanticsNode track = nodes.singleWhere(
        (SemanticsNode node) =>
            node.label.contains('晴天') && node.label.contains('周杰伦'),
      );
      final SemanticsNode favorite = nodes.singleWhere(
        (SemanticsNode node) => node.tooltip == '收藏',
      );
      final SemanticsNode more = nodes.singleWhere(
        (SemanticsNode node) => node.tooltip == '更多操作',
      );
      expect(track.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(
        favorite.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );
      expect(more.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(favorite.id, isNot(more.id));
    } finally {
      semantics.dispose();
    }
  });
}

List<SemanticsNode> _flattenSemantics(SemanticsNode root) {
  final List<SemanticsNode> nodes = <SemanticsNode>[root];
  root.visitChildren((SemanticsNode child) {
    nodes.addAll(_flattenSemantics(child));
    return true;
  });
  return nodes;
}

int _occurrences(String source, String value) =>
    value.allMatches(source).length;

Future<GoRouter> pumpShellWithBottomInset(
  WidgetTester tester, {
  required double bottomInset,
}) async {
  const Size size = Size(390, 844);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/library/songs',
    routes: <RouteBase>[
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            TyAppShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            path: '/library/songs',
            builder: (_, _) => const Text('LIBRARY'),
          ),
          GoRoute(path: '/source/:id', builder: (_, _) => const Text('SOURCE')),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        sourcesProvider.overrideWithValue(
          const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
        ),
        playlistsProvider.overrideWithValue(
          const AsyncValue<List<Playlist>>.data(<Playlist>[]),
        ),
        allTracksProvider.overrideWithValue(
          AsyncValue<List<Track>>.data(<Track>[
            Track(
              id: 't1',
              sourceId: 'src-1',
              title: '晴天',
              artist: '周杰伦',
              album: '叶惠美',
              duration: 200,
              fileFormat: 'mp3',
              filePathOrUrl: '/music/t1.mp3',
              fileSize: 1000,
              isFavorite: false,
              dateAdded: DateTime.utc(2026, 9, 1),
              playCount: 0,
            ),
          ]),
        ),
        audioHandlerProvider.overrideWithValue(
          TingyuAudioHandler(FakeAudioEngine()),
        ),
      ],
      child: MaterialApp.router(
        theme: TyTheme.build(brightness: Brightness.light),
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: size,
            padding: EdgeInsets.only(bottom: bottomInset),
          ),
          child: ProviderScope(
            overrides: <Override>[
              formFactorProvider.overrideWithValue(FormFactor.compact),
            ],
            child: TyLayoutScope.forSize(
              size,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return router;
}
