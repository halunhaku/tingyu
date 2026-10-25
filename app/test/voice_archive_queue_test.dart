import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/playback_controller.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/features/player/queue_panel.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';

import 'support/pump.dart';

class _QueuePlayback extends PlaybackController {
  _QueuePlayback({
    this.source = const <Track>[],
    this.ids = const <String>[],
    this.queueItems = const <PlaybackItem>[],
    this.currentIndex = 0,
  });

  final List<Track> source;
  final List<String> ids;
  final List<PlaybackItem> queueItems;
  int currentIndex;
  final List<int> playedAt = <int>[];

  @override
  PlaybackSnapshot build() => PlaybackSnapshot.initial.copyWith(
    index: currentIndex,
    processing: PlaybackProcessing.ready,
  );

  @override
  List<Track> get sourceQueue => source;

  @override
  List<String> get trackIds => ids;

  @override
  List<PlaybackItem> get items => queueItems;

  @override
  int get queueDisplayIndex => currentIndex;

  @override
  Future<void> playAt(int index) async => playedAt.add(index);

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> togglePlayPause() async {}

  @override
  Future<void> next() async {}

  @override
  Future<void> previous() async {}

  @override
  Future<void> setVolume(double volume) async {}
}

Track _track(int number, {String? title}) => Track(
  id: 'track-$number',
  sourceId: 'source',
  title: title ?? '曲目 $number',
  artist: '歌手 $number',
  album: '专辑',
  duration: 200,
  fileFormat: 'mp3',
  filePathOrUrl: '/music/$number.mp3',
  fileSize: 1000,
  isFavorite: false,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

Future<void> _pumpGrouped(
  WidgetTester tester,
  _QueuePlayback playback, {
  List<Track> library = const <Track>[],
  Size size = const Size(412, 915),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  bool preview = false,
}) async {
  await pumpTyApp(
    tester,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: QueuePanel(grouped: true, preview: preview)),
    ),
    size: size,
    brightness: brightness,
    overrides: <Override>[
      playbackProvider.overrideWith(() => playback),
      allTracksProvider.overrideWithValue(
        AsyncValue<List<Track>>.data(library),
      ),
    ],
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('分组队列不重复当前曲，下一首仍调用队列原始索引', (WidgetTester tester) async {
    final List<Track> tracks = <Track>[
      _track(0),
      _track(1),
      _track(2),
      _track(3),
    ];
    final _QueuePlayback playback = _QueuePlayback(
      source: tracks,
      currentIndex: 1,
    );
    await _pumpGrouped(tester, playback, library: tracks);

    expect(find.text('当前播放'), findsOneWidget);
    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('曲目 0'), findsNothing, reason: '已播条目不应混入接下来');
    expect(find.text('曲目 1'), findsOneWidget);
    expect(find.text('曲目 2'), findsOneWidget);

    await tester.tap(find.text('曲目 2'));
    await tester.pump();
    expect(playback.playedAt, <int>[2]);
  });

  testWidgets('预览模式只显示下一首并保留原始队列索引', (WidgetTester tester) async {
    final List<Track> tracks = <Track>[
      _track(0),
      _track(1),
      _track(2),
      _track(3),
    ];
    final _QueuePlayback playback = _QueuePlayback(
      source: tracks,
      currentIndex: 1,
    );
    await _pumpGrouped(tester, playback, library: tracks, preview: true);

    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('当前播放'), findsNothing);
    expect(find.text('曲目 1'), findsNothing);
    expect(find.text('曲目 2'), findsOneWidget);
    expect(find.text('曲目 3'), findsNothing);

    await tester.tap(find.text('曲目 2'));
    await tester.pump();
    expect(playback.playedAt, <int>[2]);
  });

  testWidgets('分组队列支持只有 trackIds 的队列', (WidgetTester tester) async {
    final List<Track> idTracks = <Track>[_track(0), _track(1), _track(2)];
    final _QueuePlayback idsPlayback = _QueuePlayback(
      ids: idTracks.map((Track track) => track.id).toList(),
      currentIndex: 0,
    );
    await _pumpGrouped(tester, idsPlayback, library: idTracks);
    expect(find.text('曲目 1'), findsOneWidget);
    await tester.tap(find.text('曲目 1'));
    await tester.pump();
    expect(idsPlayback.playedAt, <int>[1]);
  });

  testWidgets('分组队列支持只有引擎 items 的队列', (WidgetTester tester) async {
    final _QueuePlayback itemsPlayback = _QueuePlayback(
      queueItems: <PlaybackItem>[
        PlaybackItem.fromUri(Uri.parse('file:///first.mp3'), title: '外部当前'),
        PlaybackItem.fromUri(Uri.parse('file:///second.mp3'), title: '外部下一首'),
      ],
      currentIndex: 0,
    );
    await _pumpGrouped(tester, itemsPlayback);
    expect(find.text('外部当前'), findsOneWidget);
    expect(find.text('外部下一首'), findsOneWidget);
    await tester.tap(find.text('外部下一首'));
    await tester.pump();
    expect(itemsPlayback.playedAt, <int>[1]);
  });

  testWidgets('没有下一首时显示明确空态', (WidgetTester tester) async {
    await _pumpGrouped(
      tester,
      _QueuePlayback(source: <Track>[_track(0)], currentIndex: 0),
      library: <Track>[_track(0)],
    );
    expect(find.text('暂无下一首'), findsOneWidget);
  });

  testWidgets('当前索引越界时显示明确空态', (WidgetTester tester) async {
    await _pumpGrouped(
      tester,
      _QueuePlayback(source: <Track>[_track(0)], currentIndex: 3),
      library: <Track>[_track(0)],
    );
    expect(find.text('暂无当前播放'), findsOneWidget);
    expect(find.text('暂无下一首'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字长标题在分组队列中允许动态增高且不溢出', (WidgetTester tester) async {
    const String longTitle = '这是一首标题很长的歌曲，用来检查大字显示时标题换行后不会挤压右侧时长';
    final Track track = _track(0, title: longTitle);
    await _pumpGrouped(
      tester,
      _QueuePlayback(source: <Track>[track], currentIndex: 0),
      library: <Track>[track],
      size: const Size(360, 640),
      brightness: Brightness.dark,
      textScale: 2,
    );

    final Text title = tester.widget<Text>(find.text(longTitle));
    expect(title.maxLines, 2);
    expect(find.text('3:20'), findsOneWidget);
    expect(tester.getSize(find.byType(ListView).first).height, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
