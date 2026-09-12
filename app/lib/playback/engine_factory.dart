import 'dart:io' show Platform;

import 'just_audio_engine.dart';
import 'media_kit_engine.dart';
import 'playback_engine.dart';

/// 按平台创建播放引擎。
///
/// 桌面 → `media_kit`（libmpv，统一解码与缓冲控制）；
/// 移动 → `just_audio`（系统解码器 + 音频会话，配合 `audio_service` 实现后台播放与锁屏控制）。
PlaybackEngine createPlaybackEngine() {
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    return MediaKitEngine();
  }
  return JustAudioEngine();
}
