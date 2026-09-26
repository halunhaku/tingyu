import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/playback/just_audio_engine.dart';

/// just_audio 的 `play()` 只在播放停止/暂停时才 complete（其文档明说）。移动端
/// `PlaybackController._restartEngineFrom` 要 `await handler.play()` 才继续补全元数据
/// 与预取，所以引擎必须改成"真正开始出声就返回"。
///
/// 这里在没有任何平台实现的测试环境里跑：`play()` 仍必须**立刻**返回，既不能挂住，
/// 也不能把平台错误抛给调用方（错误由快照上报）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('play() 起播后立刻返回，不等整首歌（也不抛平台错误）', () async {
    final JustAudioEngine engine = JustAudioEngine();
    await engine.play().timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('play() 没有立刻返回：await 它会把调用方挂住一整首歌'),
    );
    await engine.dispose();
  });

  test('重复调用 play() 也不会挂住', () async {
    final JustAudioEngine engine = JustAudioEngine();
    await engine.play().timeout(const Duration(seconds: 2));
    await engine.play().timeout(const Duration(seconds: 2));
    await engine.dispose();
  });
}
