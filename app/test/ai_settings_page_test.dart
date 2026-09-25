import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/router.dart';
import 'package:tingyu/data/models/library_summaries.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/secure_store.dart';
import 'package:tingyu/features/settings/ai_settings_page.dart';
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStoreProvider.overrideWithValue(fakeStore)],
        child: const MaterialApp(home: AISettingsPage()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('AI 智能识别'), findsOneWidget);
    expect(find.text('启用智能识别'), findsOneWidget);

    // 默认关闭，不展示下方的端点与批量清洗
    expect(find.text('预设服务商'), findsNothing);
    expect(find.text('清洗整库'), findsNothing);

    // 打开开关
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    // 展开配置
    expect(find.text('预设服务商'), findsOneWidget);
    expect(find.text('API 端点 (Base URL)'), findsOneWidget);
    expect(find.text('模型名称 (Model)'), findsOneWidget);
    expect(find.text('API 密钥 (API Key)'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('清洗整库'), findsOneWidget);
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
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.pumpAndSettle();

    // 验证设置页内存在 AI 识别入口
    final Finder aiTile = find.text('AI 识别与清洗');
    expect(aiTile, findsOneWidget);

    // 点击跳转
    await tester.tap(aiTile);
    await tester.pumpAndSettle();

    // 成功到达 AISettingsPage
    expect(find.byType(AISettingsPage), findsOneWidget);
  });
}
