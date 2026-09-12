import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';

import 'app/providers.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'data/db/database.dart';
import 'data/legacy_import.dart';
import 'data/models/library_summaries.dart';
import 'data/repositories/source_repository.dart';
import 'data/repositories/track_repository.dart';
import 'playback/engine_factory.dart';
import 'playback/playback_engine.dart';
import 'playback/playback_item.dart';
import 'playback/tingyu_audio_handler.dart';
import 'sources/local/local_library_scanner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    MediaKit.ensureInitialized();
  }
  // 桌面系统媒体会话：macOS 走 audio_service 自带实现，Windows 由 audio_service_win
  // 接管 SMTC，Linux 由 audio_service_mpris 接管 MPRIS2；两者均通过
  // dartPluginClass 自动注册，无需在此手动初始化。

  final PlaybackEngine engine = createPlaybackEngine();
  final TingyuAudioHandler handler = await AudioService.init<TingyuAudioHandler>(
    builder: () => TingyuAudioHandler(engine),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.halunhaku.tingyu.audio',
      androidNotificationChannelName: '听屿播放',
      androidNotificationOngoing: true,
    ),
  );

  await _runDataHarness();

  runApp(
    ProviderScope(
      overrides: [audioHandlerProvider.overrideWithValue(handler)],
      child: const TingyuApp(),
    ),
  );

  await _runVerifyHarness(handler);
}

/// 应用根：MaterialApp.router + macOS 原生菜单栏。
class TingyuApp extends StatefulWidget {
  const TingyuApp({super.key});

  @override
  State<TingyuApp> createState() => _TingyuAppState();
}

class _TingyuAppState extends State<TingyuApp> {
  late final GoRouter _router = createRouter(
    // 调试用：`TINGYU_DEBUG_ROUTE=/albums` 可直接打开某个页面（截图/排查用）。
    initialLocation: Platform.environment['TINGYU_DEBUG_ROUTE']?.trim().isNotEmpty ?? false
        ? Platform.environment['TINGYU_DEBUG_ROUTE']!.trim()
        : '/library',
  );

  @override
  Widget build(BuildContext context) {
    final Widget app = MaterialApp.router(
      title: '听屿',
      debugShowCheckedModeBanner: false,
      theme: buildTingyuTheme(Brightness.light),
      darkTheme: buildTingyuTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: _router,
    );
    if (!Platform.isMacOS) {
      return app;
    }
    final ProviderContainer container = ProviderScope.containerOf(context, listen: false);
    return PlatformMenuBar(
      menus: _menus(container, _router),
      child: app,
    );
  }

  /// macOS 菜单栏：播放控制与页面跳转（对齐旧版 `CommandMenu("播放控制")`）。
  List<PlatformMenuItem> _menus(ProviderContainer container, GoRouter router) {
    return <PlatformMenuItem>[
      PlatformMenu(
        label: '听屿',
        menus: <PlatformMenuItem>[
          PlatformMenuItem(
            label: '设置…',
            shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
            onSelected: () => router.go('/settings'),
          ),
          PlatformMenuItem(
            label: '来源管理',
            onSelected: () => router.go('/sources'),
          ),
          PlatformMenuItem(
            label: '退出听屿',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyQ, meta: true),
            onSelected: () => exit(0),
          ),
        ],
      ),
      PlatformMenu(
        label: '播放',
        menus: <PlatformMenuItem>[
          PlatformMenuItem(
            label: '播放 / 暂停',
            shortcut: const SingleActivator(LogicalKeyboardKey.space),
            onSelected: () => container.read(playbackProvider.notifier).togglePlayPause(),
          ),
          PlatformMenuItem(
            label: '下一首',
            shortcut: const SingleActivator(LogicalKeyboardKey.arrowRight, meta: true),
            onSelected: () => container.read(playbackProvider.notifier).next(),
          ),
          PlatformMenuItem(
            label: '上一首',
            shortcut: const SingleActivator(LogicalKeyboardKey.arrowLeft, meta: true),
            onSelected: () => container.read(playbackProvider.notifier).previous(),
          ),
        ],
      ),
      PlatformMenu(
        label: '前往',
        menus: <PlatformMenuItem>[
          PlatformMenuItem(
            label: '曲库',
            shortcut: const SingleActivator(LogicalKeyboardKey.digit1, meta: true),
            onSelected: () => router.go('/library'),
          ),
          PlatformMenuItem(
            label: '专辑',
            shortcut: const SingleActivator(LogicalKeyboardKey.digit2, meta: true),
            onSelected: () => router.go('/albums'),
          ),
          PlatformMenuItem(
            label: '艺术家',
            shortcut: const SingleActivator(LogicalKeyboardKey.digit3, meta: true),
            onSelected: () => router.go('/artists'),
          ),
          PlatformMenuItem(
            label: '收藏',
            shortcut: const SingleActivator(LogicalKeyboardKey.digit4, meta: true),
            onSelected: () => router.go('/favorites'),
          ),
          PlatformMenuItem(
            label: '正在播放',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true, shift: true),
            onSelected: () => router.go('/now-playing'),
          ),
        ],
      ),
    ];
  }
}

/// M2 数据层验证脚手架：设置 `TINGYU_DEBUG_SCAN_DIR`（扫描目录）与/或
/// `TINGYU_DEBUG_LEGACY_JSON`（旧版导出 JSON）后，在真实应用进程里跑一次
/// 「扫描 → 合并入库 → 旧库导入」，并打印结果。
///
/// 与测试的区别：这里走的是真实的 `path_provider` 目录、真实的 SQLite 文件与真实文件系统。
/// 该入口在前端完全落地后移除。
Future<void> _runDataHarness() async {
  final String scanDir = Platform.environment['TINGYU_DEBUG_SCAN_DIR'] ?? '';
  final String legacyJson = Platform.environment['TINGYU_DEBUG_LEGACY_JSON'] ?? '';
  if (scanDir.isEmpty && legacyJson.isEmpty) {
    return;
  }

  final TingyuDatabase db = TingyuDatabase();
  try {
    if (legacyJson.isNotEmpty) {
      final LegacyImportReport report = await LegacyLibraryImporter(db).importFile(File(legacyJson));
      debugPrint('[data] import $report');
    }

    if (scanDir.isNotEmpty) {
      const String sourceId = 'debug-local';
      final SourceRepository sources = SourceRepository(db);
      await sources.upsert(
        MusicSourcesCompanion.insert(
          id: sourceId,
          name: '调试目录',
          kind: 'local',
          localFolderPath: Value<String?>(scanDir),
        ),
      );
      final Stopwatch stopwatch = Stopwatch()..start();
      final LocalScanResult scan = await LocalLibraryScanner().scan(Directory(scanDir));
      final MergeResult merge = await TrackRepository(db).mergeScan(sourceId: sourceId, scanned: scan.tracks);
      stopwatch.stop();
      debugPrint('[data] scan files=${scan.tracks.length} unreadable=${scan.unreadableFiles} '
          'elapsed=${stopwatch.elapsedMilliseconds}ms merge=+${merge.added}/~${merge.updated}/-${merge.removed}');
      await sources.updateSyncStatus(
        sourceId,
        status: '已同步',
        syncedAt: DateTime.now().toUtc(),
        trackCount: scan.tracks.length,
      );
    }

    final TrackRepository tracks = TrackRepository(db);
    debugPrint('[data] library tracks=${(await tracks.all()).length} '
        'sources=${(await SourceRepository(db).all()).length} '
        'albums=${(await tracks.albums()).length} artists=${(await tracks.artists()).length}');
  } finally {
    await db.close();
  }
}

/// M1 技术验证脚手架：设置 `TINGYU_DEBUG_SOURCES`（逗号分隔的本地路径或 URL）
/// 后启动即载入队列并播放，并打印播放状态，便于脚本化验证"播放 + 系统媒体会话"。
///
/// 例：`TINGYU_DEBUG_SOURCES=/tmp/a.wav,/tmp/b.wav flutter run -d macos`
/// 远端来源可配合 `TINGYU_DEBUG_HEADERS="Authorization: Basic xxx"`。
Future<void> _runVerifyHarness(TingyuAudioHandler handler) async {
  final String raw = Platform.environment['TINGYU_DEBUG_SOURCES'] ?? '';
  final List<String> sources = raw
      .split(',')
      .map((String source) => source.trim())
      .where((String source) => source.isNotEmpty)
      .toList(growable: false);
  if (sources.isEmpty) {
    return;
  }

  handler.snapshots.listen(
    (snapshot) => debugPrint(
      '[snapshot] engine=${handler.engineName} processing=${snapshot.processing.name} '
      'playing=${snapshot.playing} position=${snapshot.position.inMilliseconds}ms '
      'duration=${snapshot.duration.inMilliseconds}ms index=${snapshot.index}',
    ),
  );

  final List<PlaybackItem> items = sources
      .map((String source) => PlaybackItem.fromUri(
            source.contains('://') ? Uri.parse(source) : Uri.file(source),
            httpHeaders: _debugHeaders(),
          ))
      .toList(growable: false);

  await handler.setQueue(items);
  await handler.play();
}

/// `TINGYU_DEBUG_HEADERS="Name: value;Name2: value2"` —— 用于验证带鉴权头的
/// 远端来源（WebDAV / Quark 直链）能否真的被播放引擎取到。
Map<String, String> _debugHeaders() {
  final String raw = Platform.environment['TINGYU_DEBUG_HEADERS'] ?? '';
  final Map<String, String> headers = <String, String>{};
  for (final String pair in raw.split(';')) {
    final int colon = pair.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    headers[pair.substring(0, colon).trim()] = pair.substring(colon + 1).trim();
  }
  return headers;
}
