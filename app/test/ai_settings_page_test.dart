import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/router.dart';

import 'package:tingyu/data/models/library_summaries.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/secure_store.dart';
import 'package:tingyu/features/settings/ai_settings_page.dart';
import 'package:tingyu/features/settings/settings_page.dart';

import 'support/pump.dart';

import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

class _FakeSecureStore extends SecureStore {
  _FakeSecureStore([Map<String, String>? initial])
    : _memory = initial != null
          ? Map<String, String>.from(initial)
          : <String, String>{};

  final Map<String, String> _memory;

  @override
  Future<void> write(String account, String value) async {
    _memory[account] = value;
  }

  @override
  Future<String?> read(String account) async {
    final String? val = _memory[account]?.trim();
    if (val != null && val.isNotEmpty) {
      return val;
    }
    return null;
  }

  @override
  Future<void> delete(String account) async {
    _memory.remove(account);
  }
}

final class _DummyEngine extends PlaybackEngineBase {
  @override
  String get name => 'dummy';
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
  testWidgets('AISettingsPage 渲染与切换开关展示详细配置', (WidgetTester tester) async {
    final _FakeSecureStore fakeStore = _FakeSecureStore();
    // 页面用 `context.canPop()` 决定是否显示返回键，所以要有一个真路由器。
    final GoRouter router = GoRouter(
      initialLocation: '/ai',
      routes: <RouteBase>[
        GoRoute(path: '/ai', builder: (_, _) => const AISettingsPage()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStoreProvider.overrideWithValue(fakeStore)],
        child: MaterialApp.router(
          theme: TyTheme.build(brightness: Brightness.light),
          routerConfig: router,
          builder: (BuildContext context, Widget? child) =>
              TyLayoutScope.forSize(
                const Size(1440, 900),
                child: child ?? const SizedBox.shrink(),
              ),
        ),
      ),
    );

    // 骨架是永久动画，用有界推进代替 pumpAndSettle。
    await pumpUntil(tester, () => find.text('启用智能识别').evaluate().isNotEmpty);

    expect(find.text('AI 智能识别'), findsOneWidget);
    expect(find.text('启用智能识别'), findsOneWidget);

    // 默认关闭，不展示端点与批量清洗。
    expect(find.text('预设服务商'), findsNothing);
    expect(find.text('清洗整库'), findsNothing);

    // 打开开关（设计系统的 SwitchRow 内部仍是 Material Switch）。
    await tester.tap(find.byType(Switch));
    await pumpFrames(tester, frames: 10);

    // 展开配置
    expect(find.text('预设服务商'), findsOneWidget);
    expect(find.text('API 端点 (Base URL)'), findsOneWidget);
    expect(find.text('模型名称 (Model)'), findsOneWidget);
    expect(find.text('API 密钥 (API Key)'), findsOneWidget);

    // 列表是懒挂载的：下面两段要滚进视口才会出现在元素树里。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await pumpFrames(tester, frames: 8);
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('清洗整库'), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('从 SettingsPage 点击 AI 识别条目导航至 AISettingsPage', (
    WidgetTester tester,
  ) async {
    final _FakeSecureStore fakeStore = _FakeSecureStore();
    final GoRouter router = createRouter(initialLocation: '/settings');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allTracksProvider.overrideWithValue(
            const AsyncValue<List<Track>>.data(<Track>[]),
          ),
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
          ),
          playlistsProvider.overrideWithValue(
            const AsyncValue<List<Playlist>>.data(<Playlist>[]),
          ),
          albumsProvider.overrideWithValue(
            const AsyncValue<List<AlbumSummary>>.data(<AlbumSummary>[]),
          ),
          artistsProvider.overrideWithValue(
            const AsyncValue<List<ArtistSummary>>.data(<ArtistSummary>[]),
          ),
          secureStoreProvider.overrideWithValue(fakeStore),
          audioHandlerProvider.overrideWithValue(
            TingyuAudioHandler(_DummyEngine()),
          ),
        ],
        child: MaterialApp.router(
          theme: TyTheme.build(brightness: Brightness.light),
          routerConfig: router,
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: const Size(1440, 900)),
            child: TyLayoutScope.forSize(
              const Size(1440, 900),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );

    await pumpUntil(
      tester,
      () => find.byType(SettingsPage).evaluate().isNotEmpty,
    );

    // 设置页很长，AI 入口在下方：滚进视口才会被挂载。
    // 注意要指定**设置页自己的**滚动视图（侧栏也是一个 Scrollable）。
    await tester.scrollUntilVisible(
      find.text('AI 识别与清洗'),
      300,
      scrollable: find.descendant(
        of: find.byType(SettingsPage),
        matching: find.byType(Scrollable),
      ),
    );
    await pumpFrames(tester, frames: 6);

    // 验证设置页内存在 AI 识别入口
    final Finder aiTile = find.text('AI 识别与清洗');
    expect(aiTile, findsOneWidget);

    // 点击跳转
    await tester.tap(aiTile);
    await pumpUntil(
      tester,
      () => find.byType(AISettingsPage).evaluate().isNotEmpty,
    );

    // 成功到达 AISettingsPage
    expect(find.byType(AISettingsPage), findsOneWidget);
    await unmountApp(tester);
  });
}
