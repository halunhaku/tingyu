import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/playback_controller.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/features/library/library_page.dart';
import 'package:tingyu/features/player/mini_player.dart';
import 'package:tingyu/features/player/player_bar.dart';
import 'package:tingyu/features/player/queue_panel.dart';
import 'package:tingyu/features/player/seek_bar.dart';
import 'package:tingyu/features/shared/cover_art.dart';
import 'package:tingyu/features/shared/track_row.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';

/// 播放 UI 的两条硬约束：
/// 1. 进度 tick（每秒 5-16 次）只重建真正显示进度的控件，列表行/封面/标题一律不动；
/// 2. 进度条只在松手时 seek 一次，拖动中途不能给引擎发 seek。
///
/// 这里用 [_FakePlayback] 直接推快照，绕开引擎与曲库，只留 UI 的重建口径。

/// 可手动推快照的播放控制器：只实现 UI 读到的那些读数。
class _FakePlayback extends PlaybackController {
  _FakePlayback(this._tracks, {this.item});

  List<Track> _tracks;

  List<String>? _trackIds;

  /// 与控制器同一口径：队列一换，id 列表也换一个新对象。
  List<Track> get tracks => _tracks;

  set tracks(List<Track> value) {
    _tracks = value;
    _trackIds = null;
  }

  final PlaybackItem? item;

  final List<Duration> seeks = <Duration>[];

  @override
  PlaybackSnapshot build() => PlaybackSnapshot.initial;

  void emit(PlaybackSnapshot snapshot) => state = snapshot;

  @override
  List<String> get trackIds =>
      _trackIds ??= _tracks.map((Track track) => track.id).toList();

  @override
  List<Track> get sourceQueue => _tracks;

  @override
  List<PlaybackItem> get items => const <PlaybackItem>[];

  @override
  PlaybackItem? get currentItem => item;

  @override
  int get queueDisplayIndex => state.index;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> togglePlayPause() async {}

  @override
  Future<void> next() async {}

  @override
  Future<void> previous() async {}

  @override
  Future<void> setVolume(double volume) async {}
}

Track _track(int n) => Track(
  id: 't$n',
  sourceId: 'src',
  title: '曲目 $n',
  artist: '歌手',
  album: '专辑',
  duration: 200,
  fileFormat: 'mp3',
  filePathOrUrl: '/music/t$n.mp3',
  fileSize: 1000,
  isFavorite: false,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

PlaybackSnapshot _playing(int seconds) => PlaybackSnapshot.initial.copyWith(
  playing: true,
  position: Duration(seconds: seconds),
  duration: const Duration(seconds: 200),
  index: 0,
);

/// 重建计数：借 Flutter 的脏控件回调，只统计测试关心的那几种组件。
class _RebuildCounter {
  final Map<Type, int> counts = <Type, int>{};

  bool _on = false;

  void start() {
    counts.clear();
    _on = true;
  }

  void stop() => _on = false;

  /// 某个类型重建了几次（按运行时类型精确匹配）。
  int of(Type type) => counts[type] ?? 0;

  /// 私有类型只能按名字片段匹配。
  int named(String typeNameFragment) => counts.entries
      .where(
        (MapEntry<Type, int> entry) =>
            entry.key.toString().contains(typeNameFragment),
      )
      .fold(0, (int sum, MapEntry<Type, int> entry) => sum + entry.value);
}

/// 固定查询词：截断提示只在真的有搜索词时才出现。
class _FixedQuery extends SearchQueryController {
  @override
  String build() => '周杰伦';
}

void main() {
  final _RebuildCounter counter = _RebuildCounter();

  setUp(() {
    debugOnRebuildDirtyWidget = (Element element, bool _) {
      if (counter._on) {
        final Type type = element.widget.runtimeType;
        counter.counts[type] = (counter.counts[type] ?? 0) + 1;
      }
    };
  });

  tearDown(() => debugOnRebuildDirtyWidget = null);
  tearDown(counter.stop);

  testWidgets('曲库列表：推进进度不重建任何一行，换曲只重建高亮翻转的行', (
    WidgetTester tester,
  ) async {
    final List<Track> tracks = <Track>[for (int i = 0; i < 12; i++) _track(i)];
    final _FakePlayback fake = _FakePlayback(tracks);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackProvider.overrideWith(() => fake),
          autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
          visibleTracksProvider.overrideWithValue(
            AsyncValue<List<Track>>.data(tracks),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: LibraryPage())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TrackRow), findsWidgets);

    fake.emit(_playing(1));
    await tester.pump();

    counter.start();
    for (int seconds = 2; seconds <= 12; seconds++) {
      fake.emit(_playing(seconds));
      await tester.pump();
    }
    counter.stop();
    expect(counter.of(TrackRow), 0, reason: '进度 tick 不该重建曲目行');
    expect(counter.of(CoverArt), 0, reason: '进度 tick 不该重建封面');

    // 换队列但下标不变（新旧队列都从第 0 首起播）：高亮必须自己跟过去。
    fake.tracks = <Track>[tracks[5], ...tracks];
    counter.start();
    fake.emit(_playing(0));
    await tester.pump();
    counter.stop();
    expect(counter.of(TrackRow), 2, reason: '只有高亮翻转的两行该重建');
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (Widget widget) => widget is TrackRow && widget.track.id == 't5',
        ),
        matching: find.byIcon(Icons.graphic_eq),
      ),
      findsOneWidget,
      reason: '新队列的当前曲目要拿到高亮',
    );
  });

  testWidgets('迷你条：推进进度不重建封面与标题', (WidgetTester tester) async {
    final Track track = _track(0);
    final _FakePlayback fake = _FakePlayback(
      <Track>[track],
      item: PlaybackItem.fromUri(Uri.parse('file:///music/t0.mp3')),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackProvider.overrideWith(() => fake),
          trackByIdProvider(track.id).overrideWithValue(
            AsyncValue<Track?>.data(track),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: Align(child: MiniPlayer())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('曲目 0'), findsOneWidget);

    fake.emit(_playing(1));
    await tester.pump();

    counter.start();
    for (int seconds = 2; seconds <= 10; seconds++) {
      fake.emit(_playing(seconds));
      await tester.pump();
    }
    counter.stop();
    expect(counter.of(MiniPlayer), 0);
    expect(counter.of(CoverArt), 0);
  });

  testWidgets('队列面板：一次取全库元数据，推进进度不重建行，换队列立即跟上', (
    WidgetTester tester,
  ) async {
    final List<Track> tracks = <Track>[for (int i = 0; i < 8; i++) _track(i)];
    final _FakePlayback fake = _FakePlayback(tracks);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackProvider.overrideWith(() => fake),
          allTracksProvider.overrideWithValue(
            AsyncValue<List<Track>>.data(tracks),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: QueuePanel())),
      ),
    );
    await tester.pumpAndSettle();
    // 没有覆盖 trackByIdProvider：面板若还逐行订阅它，这里只会看到「加载中…」。
    expect(find.text('曲目 7'), findsOneWidget);

    fake.emit(_playing(1));
    await tester.pump();

    counter.start();
    for (int seconds = 2; seconds <= 8; seconds++) {
      fake.emit(_playing(seconds));
      await tester.pump();
    }
    counter.stop();
    expect(counter.named('_QueueRow'), 0, reason: '进度 tick 不该重建队列行');

    fake.tracks = <Track>[tracks[3]];
    fake.emit(_playing(1));
    await tester.pump();
    expect(find.text('1 首'), findsOneWidget);
    expect(find.text('曲目 7'), findsNothing);
  });

  testWidgets('播放条：推进进度只重建进度条，拖动只在松手时 seek 一次', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final Track track = _track(0);
    final _FakePlayback fake = _FakePlayback(
      <Track>[track],
      item: PlaybackItem.fromUri(Uri.parse('file:///music/t0.mp3')),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackProvider.overrideWith(() => fake),
          trackByIdProvider(track.id).overrideWithValue(
            AsyncValue<Track?>.data(track),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: Align(child: PlayerBar())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('曲目 0'), findsOneWidget);

    fake.emit(_playing(20));
    await tester.pump();

    counter.start();
    for (int seconds = 21; seconds <= 29; seconds++) {
      fake.emit(_playing(seconds));
      await tester.pump();
    }
    counter.stop();
    expect(counter.of(PlayerBar), 0);
    expect(counter.of(CoverArt), 0, reason: '进度 tick 不该重建封面');
    expect(counter.of(SeekBar), 9, reason: '只有进度条该跟着 tick 重建');

    // 拖动 6 帧：中途一次 seek 都不能发，松手只发一次。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(Slider).first),
    );
    for (int frame = 0; frame < 6; frame++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    expect(fake.seeks, isEmpty, reason: '拖动过程中不该 seek');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(fake.seeks, hasLength(1));
  });

  testWidgets('曲库页：搜索命中被截断时给出上限提示', (WidgetTester tester) async {
    final List<Track> tracks = <Track>[for (int i = 0; i < 3; i++) _track(i)];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchQueryProvider.overrideWith(_FixedQuery.new),
          playbackProvider.overrideWith(() => _FakePlayback(const <Track>[])),
          autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
          visibleTracksProvider.overrideWithValue(
            AsyncValue<List<Track>>.data(tracks),
          ),
          searchResultsProvider.overrideWithValue(
            AsyncValue<SearchResults>.data(
              (tracks: tracks, limit: searchResultLimit, truncated: true),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: LibraryPage())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('搜索“周杰伦”'), findsOneWidget);
    expect(find.text('命中超过 $searchResultLimit 首，仅显示前 $searchResultLimit 首'), findsOneWidget);
  });

  testWidgets('封面按显示尺寸解码，不按原图分辨率', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coverFileProvider('cover.jpg').overrideWith(
            (Ref ref) async => File('/tmp/tingyu-cover-test.jpg'),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: CoverArt(coverArtPath: 'cover.jpg', size: 44),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Image image = tester.widget<Image>(find.byType(Image));
    // 44 逻辑像素 × dpr 2 = 88 物理像素，而不是原图分辨率。
    expect((image.image as ResizeImage).width, 88);
    expect(File('/tmp/tingyu-cover-test.jpg').existsSync(), isFalse);
  });
}
