import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'features/player/player_page.dart';
import 'playback/engine_factory.dart';
import 'playback/playback_engine.dart';
import 'playback/playback_item.dart';
import 'playback/tingyu_audio_handler.dart';

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

  runApp(TingyuApp(handler: handler));

  await _runVerifyHarness(handler);
}

/// M1 技术验证脚手架：设置 `TINGYU_DEBUG_SOURCES`（逗号分隔的本地路径或 URL）
/// 后启动即载入队列并播放，并打印播放状态，便于脚本化验证"播放 + 系统媒体会话"。
///
/// 例：`TINGYU_DEBUG_SOURCES=/tmp/a.wav,/tmp/b.wav flutter run -d macos`
/// 该入口在前端（M4）落地后移除。
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
          ))
      .toList(growable: false);

  await handler.setQueue(items);
  await handler.play();
}

class TingyuApp extends StatelessWidget {
  const TingyuApp({super.key, required this.handler});

  final TingyuAudioHandler handler;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '听屿',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E6F6A)),
        useMaterial3: true,
      ),
      home: PlayerPage(handler: handler),
    );
  }
}
