import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/library_query.dart';
import 'package:tingyu/data/models/search_page_result.dart';
import 'package:tingyu/design/components/cover.dart';
import 'package:tingyu/design/components/player_stage.dart';
import 'package:tingyu/design/components/track.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/features/library/library_page.dart';
import 'package:tingyu/features/player/now_playing_page.dart';
import 'package:tingyu/features/shared/current_track.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'support/page_harness.dart';
import 'support/pump.dart';

/// Phase 7.5 的性能回归：不测"快不快"，只测**结构上不会退化**的那几条——
/// 虚拟化还在不在、进度 tick 会不会重建整页、漂移背景会不会带动内容重建。
/// 这些是性能退化的根因，真到了卡顿再查就晚了。
void main() {
  testWidgets('2000 首的曲库：只构建可见行，滚到底不抛异常', (WidgetTester tester) async {
    final List<Track> huge = <Track>[
      for (int i = 0; i < 2000; i++) goldenTrack('t$i', '曲目 $i'),
    ];
    final FakePlaybackController playback = FakePlaybackController(huge);
    await pumpRoutedPage(
      tester,
      const LibraryPage(),
      PageHarness(
        size: const Size(1280, 800),
        brightness: Brightness.light,
        overrides: <Override>[
          playbackProvider.overrideWith(() => playback),
          sourcesProvider.overrideWithValue(
            const AsyncValue<List<MusicSource>>.data(<MusicSource>[]),
          ),
          libraryTracksPageProvider(
            const LibraryPageRequest(
              query: LibraryQuery(),
              limit: libraryPageSize,
            ),
          ).overrideWith(
            (Ref ref) async =>
                SearchPageResult<Track>(items: huge, total: huge.length),
          ),
        ],
      ),
      location: '/library/songs',
    );

    final int builtRows = find.byType(TyTrackRow).evaluate().length;
    expect(builtRows, greaterThan(0));
    expect(
      builtRows,
      lessThan(60),
      reason: '2000 条的列表只能构建可见的几十行，实测 $builtRows 行',
    );

    await tester.drag(find.byType(TyTrackRow).first, const Offset(0, -4000));
    await pumpFrames(tester, frames: 6);
    expect(tester.takeException(), isNull);
    expect(
      find.byType(TyTrackRow).evaluate().length,
      lessThan(60),
      reason: '滚动过程中也只应保留可见行',
    );
  });

  testWidgets('声档静态背景：连续帧不重建内容与封面', (WidgetTester tester) async {
    final Track track = goldenTrack('t1', '晴天');
    // 不全局冻结动画，验证声档停止背景漂移后内容仍不逐帧重建。
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final GoRouter router = GoRouter(
      initialLocation: '/stage',
      routes: <RouteBase>[
        GoRoute(path: '/stage', builder: (_, _) => const NowPlayingPage()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          formFactorProvider.overrideWithValue(FormFactor.compact),
          audioHandlerProvider.overrideWithValue(
            TingyuAudioHandler(SilentEngine()),
          ),
          autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
          // 舞台的高手机预览订阅全曲目；使用内存流，避免打开 Drift 查询。
          allTracksProvider.overrideWith(
            (Ref ref) => Stream<List<Track>>.value(<Track>[track]),
          ),
          currentTrackRefProvider.overrideWithValue((
            trackId: track.id,
            item: null,
          )),
          trackByIdProvider(track.id)
              .overrideWithValue(AsyncValue<Track?>.data(track)),
          playbackProvider.overrideWith(
            () => FakePlaybackController(<Track>[track]),
          ),
        ],
        child: MaterialApp.router(
          theme: TyTheme.build(brightness: Brightness.dark),
          routerConfig: router,
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: const Size(390, 844)),
            child: TyLayoutScope.forSize(
              const Size(390, 844),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(
      tester,
      frames: 10,
      step: const Duration(milliseconds: 16),
    );

    final Map<Type, int> rebuilds = <Type, int>{};
    bool counting = true;
    debugOnRebuildDirtyWidget = (Element element, bool _) {
      if (counting) {
        final Type type = element.widget.runtimeType;
        rebuilds[type] = (rebuilds[type] ?? 0) + 1;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    // 推进 60 帧 ≈ 1 秒，保留封面与舞台内容的零重建约束。
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    counting = false;

    expect(rebuilds[TyCover] ?? 0, 0, reason: '漂移不该重建封面（重建一次就可能重解图片）');
    expect(rebuilds[TyPlayerStage] ?? 0, 0, reason: '漂移不该重建舞台内容，它只应重绘背景层');
  });
}
