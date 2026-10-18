import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/features/playlists/playlist_page.dart';
import 'package:tingyu/features/shared/skeletons.dart';
import 'package:tingyu/design/components/buttons.dart';
import 'package:tingyu/design/layout/app_shell.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

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

Playlist _playlist(String id, String name) =>
    Playlist(id: id, name: name, createdAt: DateTime.utc(2026, 9, 1));

/// 歌单页头部要读 `context.canPop()`，所以必须有 GoRouter 祖先；
/// 从根路由直达（不可 pop）模拟桌面侧栏/深链打开歌单的情形。
GoRouter _pageRouter(String playlistId) => GoRouter(
  initialLocation: '/p/$playlistId',
  routes: <RouteBase>[
    GoRoute(
      path: '/p/:id',
      builder: (_, GoRouterState state) => Scaffold(
        body: PlaylistPage(playlistId: state.pathParameters['id'] ?? ''),
      ),
    ),
  ],
);

AsyncValue<List<Playlist>> _playlistsError() =>
    AsyncValue<List<Playlist>>.error(StateError('db down'), StackTrace.empty);

void main() {
  testWidgets('歌单还在加载时显示进度，而不是「播放列表不存在」', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(_pageSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final Completer<List<Playlist>> pending = Completer<List<Playlist>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistTracksProvider('p1')
              .overrideWith((Ref ref) async => const <Track>[]),
          playlistsProvider.overrideWith(
            (Ref ref) => Stream<List<Playlist>>.fromFuture(pending.future),
          ),
        ],
        child: _pageApp(_pageRouter('p1')),
      ),
    );
    // 不 pumpAndSettle：骨架的微光一直在动。
    await tester.pump();

    expect(find.byType(TrackRowsSkeleton), findsOneWidget);
    expect(find.text('播放列表不存在'), findsNothing);
    expect(find.text('歌单读取失败'), findsNothing);

    pending.complete(<Playlist>[_playlist('p1', '夜间歌单')]);
    await tester.pumpAndSettle();
    expect(find.text('夜间歌单'), findsOneWidget);
  });

  testWidgets('读取失败显示错误与重试，不再伪装成不存在', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(_pageSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistTracksProvider('p1')
              .overrideWith((Ref ref) async => const <Track>[]),
          playlistsProvider.overrideWithValue(_playlistsError()),
        ],
        child: _pageApp(_pageRouter('p1')),
      ),
    );
    await tester.pump();

    expect(find.text('歌单读取失败'), findsOneWidget);
    expect(find.text('播放列表不存在'), findsNothing);
    expect(find.widgetWithText(TyButton, '重试'), findsOneWidget);
  });

  testWidgets('列表里确实没有这个 id 才说「播放列表不存在」', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(_pageSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistTracksProvider('p1')
              .overrideWith((Ref ref) async => const <Track>[]),
          playlistsProvider.overrideWithValue(
            AsyncValue<List<Playlist>>.data(<Playlist>[
              _playlist('p2', '别的歌单'),
            ]),
          ),
        ],
        child: _pageApp(_pageRouter('p1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('播放列表不存在'), findsOneWidget);
  });

  testWidgets('侧栏歌单读取失败给一行提示 + 重试，不再静默吞掉', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final GoRouter router = GoRouter(
      initialLocation: '/x',
      routes: <RouteBase>[
        ShellRoute(
          builder: (BuildContext context, GoRouterState state, Widget child) =>
              TyLayoutScope.forSize(
                const Size(1440, 900),
                child: TyAppShell(child: child),
              ),
          routes: <RouteBase>[
            GoRoute(path: '/x', builder: (_, _) => const SizedBox.shrink()),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 外壳要判「空库 ∧ 无来源 → 首次引导」；不挡住就会挂到真实 drift 流上，
          // 测试收尾时会留下 pending timer。
          allTracksProvider.overrideWithValue(
            AsyncValue<List<Track>>.data(<Track>[
              Track(
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
            ]),
          ),
          playlistsProvider.overrideWithValue(_playlistsError()),
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
          ),
          audioHandlerProvider.overrideWithValue(
            TingyuAudioHandler(_DummyEngine()),
          ),
        ],
        child: MaterialApp.router(
          theme: TyTheme.build(brightness: Brightness.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('播放列表读取失败'), findsOneWidget);
    expect(find.byTooltip('重试'), findsOneWidget);

    await tester.tap(find.byTooltip('重试'));
    await tester.pump();
    expect(find.text('播放列表读取失败'), findsOneWidget);
  });
}

/// 页面级外壳：注入尺寸与本工程的主题（`TyLayoutScope` 是页面读令牌的唯一入口）。
Widget _pageApp(GoRouter router) => MaterialApp.router(
  theme: TyTheme.build(brightness: Brightness.light),
  routerConfig: router,
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(size: _pageSize),
    child: TyLayoutScope.forSize(
      _pageSize,
      child: child ?? const SizedBox.shrink(),
    ),
  ),
);

const Size _pageSize = Size(412, 915);
