import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tingyu/data/cover_store.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/sources/local/folder_permission.dart';
import 'package:tingyu/sources/local/local_bookmark_source_adapter.dart';
import 'package:tingyu/sources/local/local_library_scanner.dart';
import 'package:tingyu/sources/source_adapter.dart';

import 'support/test_support.dart';

/// iOS 书签来源：授权是一个安全作用域书签，库里的路径存成**相对授权目录**的形式。
/// 绝对路径会随容器 UUID 变化，重装后必须仍然匹配到同一条曲目（否则收藏与歌单全丢）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('tingyu/saf');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory root;
  late Directory? resolved;
  late List<MethodCall> calls;

  setUp(() async {
    root = await createTempDirectory();
    resolved = root;
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return call.method == 'resolveBookmark' ? resolved?.path : null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  Future<void> write(String relativePath, List<int> bytes) async {
    final File file = File(p.join(root.path, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  // 封面缓存写到本次测试的临时目录，不碰真实的 path_provider 目录。
  LocalBookmarkSourceAdapter adapter() => LocalBookmarkSourceAdapter(
    sourceId: 'src-1',
    bookmark: 'BOOKMARK',
    scanner: LocalLibraryScanner(coverStore: CoverStore(rootDirectory: () async => root)),
  );

  test('扫描把授权目录下的文件写成相对路径，并保留标签事实', () async {
    await write(
      p.join('叶惠美', '晴天.mp3'),
      buildTaggedMp3(title: '晴天', artist: '周杰伦', album: '叶惠美'),
    );

    final SourceScanResult result = await adapter().scan();

    expect(result.tracks, hasLength(1));
    final ScannedTrack track = result.tracks.single;
    expect(track.filePathOrUrl, p.join('叶惠美', '晴天.mp3'));
    expect(track.title, '晴天');
    expect(track.artist, '周杰伦');
    expect(track.album, '叶惠美');
  });

  test('授权目录换了位置，同一批曲目的匹配键不变', () async {
    final Directory moved = await createTempDirectory();
    addTearDown(() => moved.delete(recursive: true));
    for (final Directory dir in <Directory>[root, moved]) {
      final File file = File(p.join(dir.path, 'Music', 'a.mp3'));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(buildTaggedMp3(title: 'a', artist: 'x', album: 'y'));
    }

    final LocalBookmarkSourceAdapter source = adapter();
    final List<String> before =
        (await source.scan()).tracks.map((ScannedTrack t) => t.filePathOrUrl).toList();

    // 模拟"应用更新后容器路径变了"：书签解析到新的目录。
    resolved = moved;
    final List<String> after =
        (await source.scan()).tracks.map((ScannedTrack t) => t.filePathOrUrl).toList();

    expect(after, before);
    expect(before.single, p.join('Music', 'a.mp3'));
  });

  test('open 用当前解析出的目录还原绝对路径', () async {
    final PlaybackItem item = await adapter().open(p.join('叶惠美', '晴天.mp3'));

    expect(item.uri, Uri.file(p.join(root.path, '叶惠美', '晴天.mp3')));
  });

  test('书签失效时抛授权提示，而不是静默返回空结果', () async {
    resolved = null;

    await expectLater(adapter().scan(), throwsA(isA<FolderPermissionLostException>()));
    await expectLater(
      adapter().open(p.join('叶惠美', '晴天.mp3')),
      throwsA(isA<FolderPermissionLostException>()),
    );
  });

  test('iOS 用 resolveBookmark 拿目录，不碰 Android 的 SAF 方法', () async {
    await adapter().scan();

    expect(calls.map((MethodCall call) => call.method), <String>['resolveBookmark']);
    expect(calls.single.arguments, <String, Object?>{'bookmark': 'BOOKMARK'});
  });
}
