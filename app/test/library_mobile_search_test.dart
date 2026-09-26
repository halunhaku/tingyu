import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/theme.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/features/library/library_page.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

/// 曲目行的"正在播放"高亮要读播放状态，而真 handler 会去起音频服务；
/// 这里给一个什么都不做的引擎，与 navigation_gesture_test 的做法一致。
final class _SilentEngine extends PlaybackEngineBase {
  @override
  String get name => 'silent';
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

/// 手机端此前没有任何搜索入口（搜索框只在桌面侧栏里）。这几条用例锁住：
/// 手机布局有输入框且输入会走防抖查询；桌面布局不出现它。
void main() {
  Track track(String id, String title) => Track(
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

  /// 手机/桌面布局由 `Theme.of(context).platform` 决定（不是 dart:io 的宿主系统），
  /// 所以这里直接换主题平台 —— 不需要动全局调试变量。
  Future<ProviderContainer> pumpLibrary(
    WidgetTester tester,
    TargetPlatform platform, {
    List<Track> tracks = const <Track>[],
  }) async {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
        visibleTracksProvider.overrideWithValue(
          AsyncValue<List<Track>>.data(tracks),
        ),
        searchResultsProvider.overrideWithValue(
          AsyncValue<SearchResults>.data((
            tracks: tracks,
            limit: 200,
            truncated: false,
          )),
        ),
        audioHandlerProvider.overrideWithValue(
          TingyuAudioHandler(_SilentEngine()),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTingyuTheme(
            Brightness.light,
          ).copyWith(platform: platform),
          home: const Scaffold(body: LibraryPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('手机布局：曲库页给出搜索框，输入写进搜索条件', (WidgetTester tester) async {
    final ProviderContainer container = await pumpLibrary(
      tester,
      TargetPlatform.android,
      tracks: <Track>[track('t1', '晴天')],
    );

    expect(find.widgetWithText(TextField, '搜索歌曲、艺术家或专辑'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '晴天');
    await tester.pump();

    expect(container.read(searchQueryProvider), '晴天');
    // 防抖：立刻查库会把每个按键都变成一次全库 LIKE。
    expect(container.read(debouncedSearchQueryProvider), isEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(debouncedSearchQueryProvider), '晴天');
  });

  testWidgets('手机布局：清空按钮同时清掉输入与搜索条件', (WidgetTester tester) async {
    final ProviderContainer container = await pumpLibrary(
      tester,
      TargetPlatform.android,
    );

    await tester.enterText(find.byType(TextField), '晴天');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('清除搜索'), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );
    expect(container.read(searchQueryProvider), isEmpty);
    expect(container.read(debouncedSearchQueryProvider), isEmpty);
  });

  testWidgets('桌面布局：曲库页不出现手机搜索框', (WidgetTester tester) async {
    await pumpLibrary(tester, TargetPlatform.macOS);

    expect(find.byType(TextField), findsNothing);
  });
}
