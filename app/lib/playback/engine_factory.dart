import 'media_kit_engine.dart';
import 'playback_engine.dart';

/// 创建播放引擎。
///
/// 听屿现只保留 macOS 单端：`media_kit`（libmpv）是唯一引擎，
/// 统一解码、缓冲控制、任意 URL + 自定义请求头。
/// 界面只认 [PlaybackEngine] 接口，换实现不影响上层。
PlaybackEngine createPlaybackEngine() {
  return MediaKitEngine();
}
