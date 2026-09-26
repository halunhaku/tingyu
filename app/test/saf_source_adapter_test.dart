import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/sources/local/saf_source_adapter.dart';
import 'package:tingyu/sources/source_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('tingyu/saf');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('子目录读取失败时保留已发现曲目并标记为非权威扫描', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'hasPermission':
          return true;
        case 'listChildren':
          final Map<Object?, Object?> arguments =
              call.arguments! as Map<Object?, Object?>;
          if (arguments['parentDocumentId'] == 'broken-dir') {
            throw PlatformException(code: 'read_failed');
          }
          return <Object?>[
            _entry(
              documentId: 'broken-dir',
              uri: 'content://tree/broken-dir',
              name: 'Broken',
              isDirectory: true,
            ),
            _entry(
              documentId: 'song-1',
              uri: 'content://tree/song-1',
              name: '歌手 - 歌曲.mp3',
            ),
          ];
      }
      throw PlatformException(code: 'unexpected_method', message: call.method);
    });

    final SourceScanResult result = await SafSourceAdapter(
      sourceId: 'src-1',
      treeUri: 'content://tree/root',
    ).scan();

    expect(result.tracks, hasLength(1));
    expect(result.skipped, 1);
    expect(result.truncated, isFalse);
    expect(result.isAuthoritative, isFalse);
  });

  test('达到 maxFiles 时标记截断，不能作为删除依据', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'hasPermission') {
        return true;
      }
      if (call.method == 'listChildren') {
        return <Object?>[
          _entry(
            documentId: 'song-1',
            uri: 'content://tree/song-1',
            name: '一.mp3',
          ),
          _entry(
            documentId: 'song-2',
            uri: 'content://tree/song-2',
            name: '二.mp3',
          ),
        ];
      }
      throw PlatformException(code: 'unexpected_method', message: call.method);
    });

    final SourceScanResult result = await SafSourceAdapter(
      sourceId: 'src-1',
      treeUri: 'content://tree/root',
      maxFiles: 1,
    ).scan();

    expect(result.tracks, hasLength(1));
    expect(result.truncated, isTrue);
    expect(result.isAuthoritative, isFalse);
  });

  test('目录层级超过 maxDepth 时标记截断，不能作为删除依据', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'hasPermission') {
        return true;
      }
      if (call.method == 'listChildren') {
        final Map<Object?, Object?> arguments =
            call.arguments! as Map<Object?, Object?>;
        // 根目录有歌 + 一层子目录，子目录里有更深一层（第二层会被层级上限挡住）。
        if (arguments['parentDocumentId'] == 'nested') {
          return <Object?>[
            _entry(
              documentId: 'deep-dir',
              uri: 'content://tree/deep-dir',
              name: 'Deep',
              isDirectory: true,
            ),
          ];
        }
        return <Object?>[
          _entry(
            documentId: 'song-1',
            uri: 'content://tree/song-1',
            name: '歌手 - 歌曲.mp3',
          ),
          _entry(
            documentId: 'nested',
            uri: 'content://tree/nested',
            name: 'Nested',
            isDirectory: true,
          ),
        ];
      }
      throw PlatformException(code: 'unexpected_method', message: call.method);
    });

    final SourceScanResult result = await SafSourceAdapter(
      sourceId: 'src-1',
      treeUri: 'content://tree/root',
      maxDepth: 1,
    ).scan();

    // 第二层目录整棵没扫：若还按权威快照处理，里面已入库的曲目会被判为已删除。
    expect(result.tracks, hasLength(1));
    expect(result.truncated, isTrue);
    expect(result.truncationReason, '目录层级超过 1 层');
    expect(result.isAuthoritative, isFalse);
  });

  test('取消扫描时结果不是权威快照', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'hasPermission') {
        return true;
      }
      throw PlatformException(code: 'unexpected_method', message: call.method);
    });

    final SourceScanResult result = await SafSourceAdapter(
      sourceId: 'src-1',
      treeUri: 'content://tree/root',
    ).scan(isCancelled: () => true);

    expect(result.cancelled, isTrue);
    expect(result.tracks, isEmpty);
    expect(result.isAuthoritative, isFalse);
  });
}

Map<String, Object?> _entry({
  required String documentId,
  required String uri,
  required String name,
  bool isDirectory = false,
}) => <String, Object?>{
  'documentId': documentId,
  'uri': uri,
  'name': name,
  'isDirectory': isDirectory,
  'size': 100,
  'lastModified': 0,
};
