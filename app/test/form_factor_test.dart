import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/design/components/chips.dart';
import 'package:tingyu/design/components/navigation.dart';
import 'package:tingyu/design/layout/app_shell.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/features/player/mini_player.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'support/fake_audio_engine.dart';
import 'support/pump.dart';

void main() {
  _railCoverage();
  _railAfterResize();
  test('断点：640 / 1024 是唯一的形态边界', () {
    expect(FormFactor.ofWidth(360), FormFactor.compact);
    expect(FormFactor.ofWidth(639), FormFactor.compact);
    expect(FormFactor.ofWidth(640), FormFactor.medium);
    expect(FormFactor.ofWidth(1023), FormFactor.medium);
    expect(FormFactor.ofWidth(1024), FormFactor.expanded);
  });

  test('窗口软下限是 360×480', () {
    expect(TyLayoutScope.minWindowSize, const Size(360, 480));
  });

  testWidgets('formFactorProvider 与 context.formFactor 恒等：三个参考尺寸', (
    WidgetTester tester,
  ) async {
    for (final Size size in <Size>[
      TyTestSizes.phone,
      TyTestSizes.tablet,
      TyTestSizes.desktop,
    ]) {
      await pumpTyApp(tester, home: const _FactorProbe(), size: size);
      expect(find.text('same'), findsOneWidget, reason: '$size 下两者应一致');
    }
  });

  group('TyAppShell 按宽度选择外壳', () {
    testWidgets('compact：底部 Tab + 迷你条区域，无侧栏/rail', (WidgetTester tester) async {
      await pumpShell(tester, const Size(412, 915));
      expect(find.byType(TyBottomNav), findsOneWidget);
      expect(find.byType(TySidebar), findsNothing);
      expect(find.byType(TyNavRail), findsNothing);
      expect(find.text('LIBRARY'), findsOneWidget);
    });

    testWidgets('medium：图标 rail，无底部 Tab', (WidgetTester tester) async {
      await pumpShell(tester, const Size(900, 800));
      expect(find.byType(TyNavRail), findsOneWidget);
      expect(find.byType(TySidebar), findsNothing);
      expect(find.byType(TyBottomNav), findsNothing);
    });

    testWidgets('expanded：展开侧栏，无底部 Tab', (WidgetTester tester) async {
      await pumpShell(tester, const Size(1440, 900));
      expect(find.byType(TySidebar), findsOneWidget);
      expect(find.byType(TyNavRail), findsNothing);
      expect(find.byType(TyBottomNav), findsNothing);
    });

    testWidgets('低于 360×480 显示窗口过小，360×480 即可用', (WidgetTester tester) async {
      await pumpShell(tester, const Size(320, 400));
      expect(find.text('窗口过小'), findsOneWidget);
      expect(find.byType(TyBottomNav), findsNothing);

      await pumpShell(tester, const Size(360, 480));
      expect(find.text('窗口过小'), findsNothing);
      expect(find.byType(TyBottomNav), findsOneWidget);
    });

    testWidgets('compact 底部 Tab 真的切换路由', (WidgetTester tester) async {
      final ShellHarness harness = await pumpShell(
        tester,
        const Size(412, 915),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(TyBottomNav),
          matching: find.text('收藏'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        harness.router.routeInformationProvider.value.uri.path,
        '/favorites',
      );
      expect(find.text('FAVORITES'), findsOneWidget);
    });

    testWidgets('compact 四段曲库用分段控件切换，且不出现侧栏', (WidgetTester tester) async {
      final ShellHarness harness = await pumpShell(
        tester,
        const Size(412, 915),
      );
      expect(find.byType(TySegmentedControl), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(TySegmentedControl),
          matching: find.text('专辑'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        harness.router.routeInformationProvider.value.uri.path,
        '/library/albums',
      );
      expect(find.text('ALBUMS'), findsOneWidget);
    });

    testWidgets('compact 详情页隐藏底 Tab，但迷你播放条还在', (WidgetTester tester) async {
      final ShellHarness harness = await pumpShell(
        tester,
        const Size(412, 915),
      );
      expect(find.byType(TyBottomNav), findsOneWidget);

      harness.router.push('/source/s1');
      await tester.pumpAndSettle();
      expect(find.text('SOURCE'), findsOneWidget);
      expect(find.byType(TyBottomNav), findsNothing);
      expect(find.byType(MiniPlayer), findsOneWidget);
    });

    testWidgets('窗口从 1440 缩到 412：当前路径与摆放状态都不丢', (WidgetTester tester) async {
      final ShellHarness harness = await pumpShell(
        tester,
        const Size(1440, 900),
      );
      harness.router.go('/favorites');
      await tester.pumpAndSettle();
      expect(find.byType(TySidebar), findsOneWidget);

      harness.size.value = const Size(412, 915);
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpAndSettle();

      expect(find.byType(TySidebar), findsNothing);
      expect(find.byType(TyBottomNav), findsOneWidget);
      expect(
        harness.router.routeInformationProvider.value.uri.path,
        '/favorites',
      );
      expect(find.text('FAVORITES'), findsOneWidget);
      // 底部 Tab 的选中项跟随当前路径，而不是回到第一个。
      final TyBottomNav nav = tester.widget<TyBottomNav>(
        find.byType(TyBottomNav),
      );
      expect(nav.selectedIndex, 2);
    });
  });
}

class _FactorProbe extends ConsumerWidget {
  const _FactorProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FormFactor fromContext = context.formFactor;
    final FormFactor fromProvider = ref.watch(formFactorProvider);
    return Text(fromContext == fromProvider ? 'same' : 'differ');
  }
}

class ShellHarness {
  ShellHarness({required this.router, required this.size});

  final GoRouter router;
  final ValueNotifier<Size> size;
}

/// 挂载真实外壳做布局断言：返回路由器与可改尺寸，供 resize 场景复用。
Future<ShellHarness> pumpShell(WidgetTester tester, Size initial) async {
  final ValueNotifier<Size> size = ValueNotifier<Size>(initial);
  addTearDown(size.dispose);
  await tester.binding.setSurfaceSize(initial);
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
          GoRoute(
            path: '/library/albums',
            builder: (_, _) => const Text('ALBUMS'),
          ),
          GoRoute(path: '/search', builder: (_, _) => const Text('SEARCH')),
          GoRoute(
            path: '/favorites',
            builder: (_, _) => const Text('FAVORITES'),
          ),
          GoRoute(path: '/settings', builder: (_, _) => const Text('SETTINGS')),
          GoRoute(path: '/source/:id', builder: (_, _) => const Text('SOURCE')),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  Widget build() => ProviderScope(
    overrides: <Override>[
      sourcesProvider.overrideWithValue(
        const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
      ),
      playlistsProvider.overrideWithValue(
        const AsyncValue<List<Playlist>>.data(<Playlist>[]),
      ),
      // 外壳要判「空库 ∧ 无来源 → 首次引导」，因此会读这两个流；
      // 不覆盖就会挂到真实 drift 上，测试里留下永不完成的订阅与定时器。
      allTracksProvider.overrideWithValue(
        AsyncValue<List<Track>>.data(<Track>[_track('t1', '晴天')]),
      ),
      audioHandlerProvider.overrideWithValue(
        TingyuAudioHandler(FakeAudioEngine()),
      ),
    ],
    child: MaterialApp.router(
      theme: TyTheme.build(brightness: Brightness.light),
      routerConfig: router,
      // 与真实根部同构：一次测量同时喂 MediaQuery、作用域与 provider 桥。
      builder: (BuildContext context, Widget? child) =>
          ValueListenableBuilder<Size>(
            valueListenable: size,
            builder: (BuildContext context, Size value, Widget? _) =>
                MediaQuery(
                  data: MediaQuery.of(context).copyWith(size: value),
                  child: ProviderScope(
                    overrides: <Override>[
                      formFactorProvider.overrideWithValue(
                        FormFactor.ofWidth(value.width),
                      ),
                    ],
                    child: TyLayoutScope.forSize(
                      value,
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                ),
          ),
    ),
  );

  await tester.pumpWidget(build());
  await tester.pump();
  return ShellHarness(router: router, size: size);
}

/// 最小曲目：外壳只需知道「库不是空的」，字段值不重要。
Track _track(String id, String title) => Track(
  id: id,
  sourceId: 'src-1',
  title: title,
  artist: '周杰伦',
  album: '叶惠美',
  duration: 200,
  fileFormat: 'mp3',
  filePathOrUrl: '/music/$id.mp3',
  fileSize: 1000,
  isFavorite: false,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

/// medium 的 rail 必须把六个目的地都画出来（曾经只在截图里看到四个——
/// 那是 ListView 的裁剪，不是数据缺失；这条用例把「六个都在」钉死）。
void _railCoverage() {
  testWidgets('medium rail 六个目的地齐全', (WidgetTester tester) async {
    await pumpShell(tester, const Size(800, 600));
    for (final String label in <String>[
      '歌曲',
      '专辑',
      '艺术家',
      '歌单',
      '收藏',
      '设置',
    ]) {
      expect(find.byTooltip(label), findsOneWidget, reason: 'rail 里没有「」');
    }
  });
}

/// 从 expanded 缩到 medium（真机截图里 rail 只画出了前四个目的地）：切换外壳之后
/// 六个目的地都必须落在 rail 的可见范围内。
void _railAfterResize() {
  testWidgets('1440 缩到 930：rail 六个目的地仍然都在可见范围内', (
    WidgetTester tester,
  ) async {
    final ShellHarness harness = await pumpShell(
      tester,
      const Size(1440, 900),
    );
    expect(find.byType(TySidebar), findsOneWidget);

    harness.size.value = const Size(930, 537);
    await tester.binding.setSurfaceSize(const Size(930, 537));
    await tester.pumpAndSettle();

    expect(find.byType(TyNavRail), findsOneWidget);
    final Rect rail = tester.getRect(find.byType(TyNavRail));
    for (final String label in <String>[
      '歌曲',
      '专辑',
      '艺术家',
      '歌单',
      '收藏',
    ]) {
      final Rect item = tester.getRect(find.byTooltip(label));
      expect(
        item.top >= rail.top && item.bottom <= rail.bottom,
        isTrue,
        reason: '「$label」画到了 rail 之外：item=$item rail=$rail',
      );
    }
  });
}
