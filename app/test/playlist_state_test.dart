import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/features/playlists/playlist_page.dart';
import 'package:tingyu/features/shell/app_shell.dart';
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
      builder: (_, GoRouterState state) =>
          Scaffold(body: PlaylistPage(playlistId: state.pathParameters['id'] ?? '')),
    ),
  ],
);

AsyncValue<List<Playlist>> _playlistsError() => AsyncValue<List<Playlist>>.error(
  StateError('db down'),
  StackTrace.empty,
);

void main() {
  testWidgets('歌单还在加载时显示进度，而不是「播放列表不存在」', (WidgetTester tester) async {
    final Completer<List<Playlist>> pending = Completer<List<Playlist>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistTracksProvider(
            'p1',
          ).overrideWith((Ref ref) async => const <Track>[]),
          playlistsProvider.overrideWith(
            (Ref ref) => Stream<List<Playlist>>.fromFuture(pending.future),
          ),
        ],
        child: MaterialApp.router(routerConfig: _pageRouter('p1')),
      ),
    );
    // 不 pumpAndSettle：加载指示器一直在转。
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('播放列表不存在'), findsNothing);
    expect(find.text('歌单读取失败'), findsNothing);

    pending.complete(<Playlist>[_playlist('p1', '夜间歌单')]);
    await tester.pumpAndSettle();
    expect(find.text('夜间歌单'), findsOneWidget);
  });

  testWidgets('读取失败显示错误与重试，不再伪装成不存在', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistTracksProvider(
            'p1',
          ).overrideWith((Ref ref) async => const <Track>[]),
          playlistsProvider.overrideWithValue(_playlistsError()),
        ],
        child: MaterialApp.router(routerConfig: _pageRouter('p1')),
      ),
    );
    await tester.pump();

    expect(find.text('歌单读取失败'), findsOneWidget);
    expect(find.text('播放列表不存在'), findsNothing);
    expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
  });

  testWidgets('列表里确实没有这个 id 才说「播放列表不存在」', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistTracksProvider(
            'p1',
          ).overrideWith((Ref ref) async => const <Track>[]),
          playlistsProvider.overrideWithValue(
            AsyncValue<List<Playlist>>.data(<Playlist>[_playlist('p2', '别的歌单')]),
          ),
        ],
        child: MaterialApp.router(routerConfig: _pageRouter('p1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('播放列表不存在'), findsOneWidget);
  });

  testWidgets('侧栏歌单读取失败给一行提示 + 重试，不再静默吞掉', (WidgetTester tester) async {
    final GoRouter router = GoRouter(
      initialLocation: '/x',
      routes: <RouteBase>[
        ShellRoute(
          builder: (BuildContext context, GoRouterState state, Widget child) =>
              AppShell(child: child),
          routes: <RouteBase>[
            GoRoute(path: '/x', builder: (_, _) => const SizedBox.shrink()),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistsProvider.overrideWithValue(_playlistsError()),
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
          ),
          audioHandlerProvider.overrideWithValue(
            TingyuAudioHandler(_DummyEngine()),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
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