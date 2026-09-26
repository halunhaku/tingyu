import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tingyu/playback/media_kit_engine.dart';
import 'package:tingyu/playback/playback_snapshot.dart';

/// 桌面引擎的处理阶段判断：夸克 / WebDAV 直链没有 Content-Length，mpv 的
/// `state.duration` 会整首歌都是 0。以前"duration == 0 就是 loading"，于是播放键
/// 整首歌停在转圈图标上，用户以为没播。
///
/// 这里只测纯函数，不初始化 libmpv（没有原生库，构造 Player 会失败）。
void main() {
  Playlist queue() => Playlist(<Media>[Media('https://example.com/a.flac')]);

  test('未知时长（直链没有 Content-Length）按可播放处理，而不是加载中', () {
    expect(
      MediaKitEngine.processingOf(PlayerState(playlist: queue())),
      PlaybackProcessing.ready,
    );
  });

  test('队列为空是 idle，真在缓冲是 buffering，播完是 completed', () {
    expect(
      MediaKitEngine.processingOf(const PlayerState()),
      PlaybackProcessing.idle,
    );
    expect(
      MediaKitEngine.processingOf(
        PlayerState(playlist: queue(), buffering: true),
      ),
      PlaybackProcessing.buffering,
    );
    expect(
      MediaKitEngine.processingOf(
        PlayerState(playlist: queue(), completed: true),
      ),
      PlaybackProcessing.completed,
    );
  });

  test('时长已知时也只是 ready（此前它顺带覆盖了这条路径）', () {
    expect(
      MediaKitEngine.processingOf(
        PlayerState(playlist: queue(), duration: const Duration(seconds: 200)),
      ),
      PlaybackProcessing.ready,
    );
  });
}
