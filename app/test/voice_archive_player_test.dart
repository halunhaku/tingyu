import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/design/components/player_stage.dart';
import 'package:tingyu/design/components/transport.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/design/tokens/voice_archive.dart';
import 'package:tingyu/features/player/now_playing_page.dart';
import 'package:tingyu/features/player/queue_panel.dart';
import 'package:tingyu/features/shared/current_track.dart';
import 'package:tingyu/playback/playback_snapshot.dart';

import 'support/page_harness.dart';

class _Player extends FakePlaybackController {
  _Player(super.tracks, {this.failure, this.unknown = false});
  final PlaybackFailure? failure;
  final bool unknown;
  int? retriedIndex;
  @override
  PlaybackSnapshot build() => super.build().copyWith(
    playing: true,
    position: const Duration(seconds: 84),
    duration: unknown ? Duration.zero : const Duration(seconds: 252),
    failure: failure,
  );
  @override
  Future<void> playAt(int index) async {
    retriedIndex = index;
  }
}

void main() {
  final List<Track> tracks = <Track>[
    goldenTrack('c1', '海风经过', artist: '林间回声', album: '潮汐手记', duration: 252),
    goldenTrack('c2', '直到海岸线的最后一束光都熄灭', duration: 308),
  ];
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    String location = '/stage',
    double scale = 1,
    _Player? controller,
  }) async {
    final _Player playback = controller ?? _Player(tracks);
    await pumpRoutedPage(
      tester,
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: const NowPlayingPage(),
        ),
      ),
      PageHarness(
        size: size,
        brightness: brightness,
        overrides: <Override>[
          playbackProvider.overrideWith(() => playback),
          currentTrackRefProvider.overrideWithValue((
            trackId: tracks.first.id,
            item: null,
          )),
          trackByIdProvider(tracks.first.id)
              .overrideWithValue(AsyncValue<Track?>.data(tracks.first)),
          allTracksProvider.overrideWithValue(
            AsyncValue<List<Track>>.data(tracks),
          ),
        ],
      ),
      location: location,
    );
  }

  testWidgets('声档主题只在舞台作用域，默认队列和原有快照保持一致', (tester) async {
    await mount(tester);
    final BuildContext stageContext = tester.element(
      find.byType(TyPlayerStage),
    );
    expect(stageContext.ty.colors.accent, VoiceArchiveColors.light.accent);
    expect(
      tester.widget<TyTransportRow>(find.byType(TyTransportRow)).playing,
      isTrue,
    );
    expect(find.text('接下来'), findsOneWidget);
    expect(tester.widget<QueuePanel>(find.byType(QueuePanel)).preview, isTrue);
    expect(find.text('当前播放'), findsNothing);
    expect(
      TyTheme.build(brightness: Brightness.light).colorScheme.primary,
      isNot(VoiceArchiveColors.light.accent),
    );
  });

  testWidgets('显式歌词参数优先，点击唯一队列分段可切回', (tester) async {
    await mount(tester, location: '/stage?tab=lyrics');
    expect(find.byType(QueuePanel), findsNothing);
    await tester.tap(find.text('队列'));
    await tester.pump();
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短窗口保留队列入口并打开同主题的完整面板', (tester) async {
    await mount(tester, size: const Size(360, 640));
    expect(find.byType(QueuePanel), findsNothing);
    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.text('当前播放'), findsOneWidget);
    expect(
      tester.element(find.byType(QueuePanel)).ty.colors.accent,
      VoiceArchiveColors.light.accent,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('失败快照不画正常暂停态，重试调用原队列索引', (tester) async {
    final _Player playback = _Player(
      tracks,
      failure: const PlaybackFailure(message: '测试音频无法读取'),
    );
    await mount(tester, controller: playback);
    expect(find.textContaining('测试音频无法读取'), findsOneWidget);
    expect(
      tester.widget<TyTransportRow>(find.byType(TyTransportRow)).playing,
      isFalse,
    );
    await tester.tap(find.text('重试此曲'));
    expect(playback.retriedIndex, 0);
  });

  testWidgets('未知总时长禁用seek并明确显示未知', (tester) async {
    await mount(tester, controller: _Player(tracks, unknown: true));
    expect(tester.widget<TySeekBar>(find.byType(TySeekBar)).enabled, isFalse);
    expect(find.text('--:--'), findsWidgets);
  });

  for (final Size size in <Size>[
    const Size(360, 640),
    const Size(390, 844),
    const Size(844, 390),
    const Size(800, 900),
    const Size(1024, 768),
    const Size(1440, 900),
  ]) {
    for (final Brightness mode in Brightness.values) {
      testWidgets('页面大字不溢出 $size $mode', (tester) async {
        await mount(tester, size: size, brightness: mode, scale: 2);
        expect(tester.takeException(), isNull);
        expect(find.byType(TyTransportRow), findsOneWidget);
        final Rect transport = tester.getRect(find.byType(TyTransportRow));
        expect(transport.bottom, lessThanOrEqualTo(size.height));
        expect(transport.left, greaterThanOrEqualTo(0));
        expect(transport.right, lessThanOrEqualTo(size.width));
      });
    }
  }
}
