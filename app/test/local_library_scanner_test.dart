import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tingyu/data/cover_store.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/sources/local/local_library_scanner.dart';

import 'support/test_support.dart';

void main() {
  late Directory root;
  late LocalLibraryScanner scanner;

  setUp(() async {
    root = await createTempDirectory();
    scanner = LocalLibraryScanner(
      coverStore: CoverStore(rootDirectory: () async => root),
    );
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> write(String relativePath, List<int> bytes) async {
    final File file = File(p.join(root.path, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  test('只收受支持的扩展名，跳过隐藏项与非音频文件', () async {
    await write('a.wav', buildSilentWav(seconds: 1));
    await write(
      'nested/b.mp3',
      buildTaggedMp3(title: 'T', artist: 'A', album: 'AL'),
    );
    await write('c.txt', <int>[1, 2, 3]);
    await write('.hidden/d.wav', buildSilentWav());
    await write('.e.wav', buildSilentWav());

    final LocalScanResult result = await scanner.scan(root);

    expect(
      result.tracks
          .map((ScannedTrack t) => p.relative(t.filePathOrUrl, from: root.path))
          .toList(),
      <String>['a.wav', p.join('nested', 'b.mp3')],
    );
    expect(result.unreadableFiles, 0);
    expect(result.cancelled, isFalse);
    expect(result.truncated, isFalse);
    expect(result.unreadableDirectories, 0);
    expect(result.isAuthoritative, isTrue);
  });

  test('读取时长与文件事实，无标签时回落为文件名', () async {
    await write('无标签的曲子.wav', buildSilentWav(seconds: 2));

    final ScannedTrack track = (await scanner.scan(root)).tracks.single;

    expect(track.title, '无标签的曲子');
    expect(track.artist, ScannedTrack.unknownArtist);
    expect(track.album, ScannedTrack.unknownAlbum);
    expect(track.duration, closeTo(2, 0.1));
    expect(track.fileFormat, 'wav');
    expect(track.fileSize, greaterThan(0));
    expect(track.lastModified, isNotNull);
  });

  test('ID3 标签映射到标题/艺术家/专辑', () async {
    await write(
      'tagged.mp3',
      buildTaggedMp3(title: '止战之殇', artist: '周杰伦', album: '七里香'),
    );

    final ScannedTrack track = (await scanner.scan(root)).tracks.single;

    expect(track.title, '止战之殇');
    expect(track.artist, '周杰伦');
    expect(track.album, '七里香');
    expect(track.fileFormat, 'mp3');
  });

  test('内嵌封面写入封面缓存目录并回传文件名', () async {
    await write('cover.wav', buildSilentWav());

    // 手工构造一个最小 PNG（仅用于验证落盘与命名，不参与解码）。
    final Directory covers = await CoverStore(rootDirectory: () async => root)
        .coversDirectory();
    final Uint8List png = Uint8List.fromList(<int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0,
      0,
      0,
      0,
    ]);
    final String name = await CoverStore(rootDirectory: () async => root)
        .save(png);

    expect(name, endsWith('.png'));
    expect(File(p.join(covers.path, name)).existsSync(), isTrue);
  });

  test('同一张封面重复保存共用同一个文件（一张专辑只落一份盘）', () async {
    final CoverStore store = CoverStore(rootDirectory: () async => root);
    final Directory covers = await store.coversDirectory();
    final Uint8List png = Uint8List.fromList(<int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      1,
      2,
      3,
    ]);

    final String first = await store.save(png);
    final String second = await store.save(
      Uint8List.fromList(<int>[...png]),
    );
    expect(second, first);
    expect(covers.listSync().whereType<File>(), hasLength(1));

    // 换了封面：新内容落到新文件，旧图交由 pruneUnreferenced 回收。
    final Uint8List other = Uint8List.fromList(<int>[...png, 9]);
    final String changed = await store.save(other);
    expect(changed, isNot(first));
    expect(covers.listSync().whereType<File>(), hasLength(2));

    final int removed = await store.pruneUnreferenced(<String>{changed});
    expect(removed, 1);
    expect(covers.listSync().whereType<File>(), hasLength(1));
  });

  test('maxFiles 截断并给出进度回调', () async {
    for (int index = 0; index < 5; index++) {
      await write('track_$index.wav', buildSilentWav());
    }
    final LocalLibraryScanner limited = LocalLibraryScanner(
      coverStore: CoverStore(rootDirectory: () async => root),
      maxFiles: 3,
    );
    final List<int> progress = <int>[];
    final LocalScanResult result = await limited.scan(
      root,
      onProgress: (int done, int total, String path) => progress.add(done),
    );

    expect(result.tracks.length, 3);
    expect(progress, <int>[3]);
    expect(result.truncated, isTrue);
    expect(result.isAuthoritative, isFalse);
  });

  test('取消扫描时立即返回已扫描部分', () async {
    for (int index = 0; index < 3; index++) {
      await write('t$index.wav', buildSilentWav());
    }
    final LocalScanResult result = await scanner.scan(
      root,
      isCancelled: () => true,
    );

    expect(result.cancelled, isTrue);
    expect(result.tracks, isEmpty);
    expect(result.isAuthoritative, isFalse);
  });

  test('目录不存在时返回空结果而不是抛异常', () async {
    final LocalScanResult result = await scanner.scan(
      Directory(p.join(root.path, 'nope')),
    );

    expect(result.tracks, isEmpty);
    expect(result.cancelled, isFalse);
    expect(result.unreadableDirectories, 1);
    expect(result.isAuthoritative, isFalse);
  });

  test('无法识别内容的文件被保留为文件名曲目，不会让整次扫描失败', () async {
    // 裸 ADTS 头 + 垃圾数据：扩展名在 supportedExtensions 内，
    // 但 audio_metadata_reader 没有任何解析器认领它。
    await write('good.wav', buildSilentWav(seconds: 1));
    await write('weird.mp3', <int>[
      0xFF,
      0xF1,
      ...List<int>.filled(2048, 0x00),
    ]);

    final LocalScanResult result = await scanner.scan(root);

    expect(result.tracks, hasLength(2), reason: '一个无法识别的文件不应让整次扫描抛出、丢掉其它曲目');
    final ScannedTrack weird = result.tracks.firstWhere(
      (ScannedTrack t) => p.basename(t.filePathOrUrl) == 'weird.mp3',
    );
    expect(weird.title, 'weird', reason: '无标签时回落到文件名');
    expect(weird.artist, ScannedTrack.unknownArtist);
    expect(result.unreadableFiles, 0);
  });
}
