import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/cover_store.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/library_summaries.dart';
import 'package:tingyu/data/repositories/track_repository.dart';
import 'package:tingyu/sources/local/local_library_scanner.dart';
import 'package:tingyu/sources/local/local_source_adapter.dart';
import 'package:tingyu/sources/source_adapter.dart';

import 'support/test_support.dart';

/// 重复同步的保护条件：跳过解析产出的那批"稀疏结果"必须能与合并层配合好 ——
/// 它只有文件事实（标题取文件名、时长为 0、没有封面），绝不能把库里已经刮削好的
/// 标题、时长、封面冲掉；同时它也不会让本次扫描被误判成"来源不完整"。
void main() {
  late Directory root;
  late TingyuDatabase db;
  late TrackRepository tracks;

  setUp(() async {
    root = await createTempDirectory();
    db = openTestDatabase();
    tracks = TrackRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> write(String name, List<int> bytes) async {
    final File file = File('${root.path}/$name');
    await file.writeAsBytes(bytes);
  }

  LocalSourceAdapter adapter({required bool withKnownFacts}) => LocalSourceAdapter(
    sourceId: 'src-1',
    folderPath: root.path,
    scanner: LocalLibraryScanner(
      coverStore: CoverStore(rootDirectory: () async => root),
    ),
    knownFacts: withKnownFacts ? () => tracks.fileFacts('src-1') : null,
  );

  test('第二次同步近似空转，且不会冲掉已刮削的元数据', () async {
    await write(
      '歌手 - 歌名.mp3',
      buildTaggedMp3(title: '标签标题', artist: '标签歌手', album: '标签专辑'),
    );

    // 第一次：库里没有任何事实，完整解析。
    final SourceScanResult first = await adapter(withKnownFacts: true).scan();
    expect(first.tracks.single.title, '标签标题');
    final MergeResult firstMerge = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: first.tracks,
      removeMissing: first.isAuthoritative,
    );
    expect(firstMerge.added, 1);

    // 模拟刮削把元数据补全成"库里更好的那一份"。
    final Track stored = (await tracks.bySource('src-1')).single;
    await tracks.applyEnrichment(
      id: stored.id,
      title: '刮削后的标题',
      artist: '刮削后的歌手',
      lyrics: '刮削来的歌词',
    );

    // 第二次：文件没动过 → 扫描器只给文件事实。
    final SourceScanResult second = await adapter(withKnownFacts: true).scan();
    expect(second.tracks.single.title, '歌手 - 歌名');
    expect(second.tracks.single.duration, 0);
    expect(second.isAuthoritative, isTrue, reason: '跳过解析不等于扫描不完整');

    final MergeResult secondMerge = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: second.tracks,
      removeMissing: second.isAuthoritative,
    );
    expect(secondMerge.added, 0);
    expect(secondMerge.removed, 0);

    final Track afterRescan = (await tracks.bySource('src-1')).single;
    expect(afterRescan.title, '刮削后的标题');
    expect(afterRescan.artist, '刮削后的歌手');
    expect(afterRescan.lyrics, '刮削来的歌词');
    expect(afterRescan.duration, stored.duration, reason: '稀疏结果的 0 不能覆盖已有时长');
    expect(afterRescan.coverArtPath, stored.coverArtPath);
  });

  test('不给已知事实时每次都是完整解析（行为与改动前一致）', () async {
    await write(
      '歌手 - 歌名.mp3',
      buildTaggedMp3(title: '标签标题', artist: '标签歌手', album: '标签专辑'),
    );

    final SourceScanResult result = await adapter(
      withKnownFacts: false,
    ).scan();

    expect(result.tracks.single.title, '标签标题');
    expect(result.tracks.single.artist, '标签歌手');
  });
}
