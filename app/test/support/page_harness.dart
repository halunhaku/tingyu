import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/playback_controller.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/secure_store.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/design/tokens/tokens.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'pump.dart';

/// 页面级视觉回归的公共脚手架。
///
/// 三条纪律，缺一条 golden 就会闪：
/// 1. **关掉动画**：`MediaQuery.disableAnimations` 为真时骨架微光、音柱、漂移全部静止；
/// 2. **不吃真实数据**：所有数据由 overrides 注入（内存里的假引擎 + 固定文本）；
/// 3. **固定尺寸**：每个用例只用一个尺寸，尺寸入 golden 文件名。
class PageHarness {
  const PageHarness({
    required this.size,
    required this.brightness,
    this.overrides = const <Override>[],
    this.formFactor,
    this.textScale = 1,
  });

  final Size size;
  final Brightness brightness;

  /// 页面自己需要的 provider 覆盖（数据、播放态…）。
  final List<Override> overrides;

  /// 缺省按宽度推导；需要「窄窗但桌面语汇」时显式给。
  final FormFactor? formFactor;

  /// 固定系统字号，供 200% 无障碍布局回归使用。
  final double textScale;
}

/// 什么都不做的播放引擎：页面里的播放控件需要一个 handler，但不该碰音频服务。
final class SilentEngine extends PlaybackEngineBase {
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

/// 固定曲目：标题长度覆盖「短 / 长 / 中英混排」，不依赖任何真实曲库。
Track goldenTrack(
  String id,
  String title, {
  String artist = '周杰伦',
  String album = '叶惠美',
  double duration = 269,
  bool favorite = false,
}) => Track(
  id: id,
  sourceId: 'src-golden',
  title: title,
  artist: artist,
  album: album,
  duration: duration,
  fileFormat: 'flac',
  filePathOrUrl: '/music/$id.flac',
  fileSize: 1000,
  isFavorite: favorite,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

/// 挂载一个页面（不含外壳），冻结动画，注入数据。
Future<void> pumpPage(
  WidgetTester tester,
  Widget page,
  PageHarness harness,
) async {
  await tester.binding.setSurfaceSize(harness.size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final FormFactor factor =
      harness.formFactor ?? FormFactor.ofWidth(harness.size.width);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        formFactorProvider.overrideWithValue(factor),
        audioHandlerProvider.overrideWithValue(
          TingyuAudioHandler(SilentEngine()),
        ),
        autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
        ...harness.overrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: TyTheme.build(
          brightness: harness.brightness,
          density: TyDensity.comfortable,
        ),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: harness.size,
            textScaler: TextScaler.linear(harness.textScale),
            // 冻结所有动效：骨架微光与音柱是永久动画，不关掉 golden 永远不稳定。
            disableAnimations: true,
          ),
          child: TyLayoutScope.forSize(
            harness.size,
            density: TyDensity.comfortable,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: page,
      ),
    ),
  );
  // 固定推几帧：让 FutureProvider / StreamProvider 的初值落定，但不追赶动画。
  await pumpFrames(tester, frames: 8, step: const Duration(milliseconds: 20));
}

/// 需要 `GoRouter` 的页面（详情页 / 搜索页 / 舞台）用这个挂载：
/// 路径就是页面自己会读的那个（例如 `/album/x`），页面读 `GoRouterState` 才不会炸。
Future<void> pumpRoutedPage(
  WidgetTester tester,
  Widget page,
  PageHarness harness, {
  required String location,
}) async {
  // location 可能带 query（）；路由 pattern 只能是路径部分。
  final String path = Uri.parse(location).path;
  final GoRouter router = GoRouter(
    initialLocation: location,
    routes: <RouteBase>[
      GoRoute(
        path: path,
        builder: (_, _) => Scaffold(body: page),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.binding.setSurfaceSize(harness.size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final FormFactor factor =
      harness.formFactor ?? FormFactor.ofWidth(harness.size.width);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        formFactorProvider.overrideWithValue(factor),
        audioHandlerProvider.overrideWithValue(
          TingyuAudioHandler(SilentEngine()),
        ),
        autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
        secureStoreProvider.overrideWithValue(FakeSecureStore()),
        ...harness.overrides,
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: TyTheme.build(
          brightness: harness.brightness,
          density: TyDensity.comfortable,
        ),
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: harness.size,
            textScaler: TextScaler.linear(harness.textScale),
            disableAnimations: true,
          ),
          child: TyLayoutScope.forSize(
            harness.size,
            density: TyDensity.comfortable,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester, frames: 8, step: const Duration(milliseconds: 20));
}

/// 内存里的凭证存储：设置页的 AI 区块会读它，真实现走平台通道。
class FakeSecureStore extends SecureStore {
  final Map<String, String> _memory = <String, String>{};

  @override
  Future<void> write(String account, String value) async {
    _memory[account] = value;
  }

  @override
  Future<String?> read(String account) async {
    final String? value = _memory[account]?.trim();
    return (value != null && value.isNotEmpty) ? value : null;
  }

  @override
  Future<void> delete(String account) async {
    _memory.remove(account);
  }
}

/// 只提供 UI 需要的读数的播放控制器（不碰音频引擎）。
class FakePlaybackController extends PlaybackController {
  FakePlaybackController(this.tracks, {this.item});

  List<Track> tracks;

  List<String>? _trackIds;

  final PlaybackItem? item;

  @override
  PlaybackSnapshot build() => PlaybackSnapshot.initial.copyWith(
    processing: PlaybackProcessing.ready,
    duration: const Duration(minutes: 4),
    position: const Duration(seconds: 62),
  );

  @override
  List<String> get trackIds =>
      _trackIds ??= tracks.map((Track track) => track.id).toList();

  @override
  List<Track> get sourceQueue => tracks;

  @override
  List<PlaybackItem> get items => const <PlaybackItem>[];

  @override
  PlaybackItem? get currentItem => item;

  @override
  int get queueDisplayIndex => state.index;

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
