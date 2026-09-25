
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/data/repositories/source_repository.dart';
import 'package:tingyu/data/repositories/track_repository.dart';
import 'package:tingyu/sources/ai/ai_client.dart';
import 'package:tingyu/sources/ai/ai_library_refactor_service.dart';

import 'support/test_support.dart';

class _FakeAIClient extends AIClient {
  _FakeAIClient(this.responder)
    : super(baseUrl: 'https://api.example.com', model: 'test-model');

  final Future<String> Function(List<ChatMessage> messages) responder;
  final List<List<ChatMessage>> calls = <List<ChatMessage>>[];

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    double temperature = 0.1,
  }) async {
    calls.add(messages);
    return responder(messages);
  }
}

void main() {
  test('空曲库时直接完成且不出网', () async {
    final TingyuDatabase db = openTestDatabase();
    addTearDown(db.close);

    final _FakeAIClient client = _FakeAIClient((_) async => '[]');
    final AILibraryRefactorService service = AILibraryRefactorService(
      tracks: TrackRepository(db),
      client: client,
    );

    final RefactorProgress progress = await service.refactorAll();
    expect(progress.isCompleted, isTrue);
    expect(progress.total, 0);
    expect(progress.updated, 0);
    expect(client.calls, isEmpty);
  });

  test('批量清洗已有曲目元数据并成功持久化入库', () async {
    final TingyuDatabase db = openTestDatabase();
    addTearDown(db.close);

    final SourceRepository sources = SourceRepository(db);
    await sources.upsert(
      const MusicSourcesCompanion(
        id: Value<String>('src-1'),
        name: Value<String>('本地目录'),
        kind: Value<String>('local'),
      ),
    );

    final TrackRepository tracks = TrackRepository(db);
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: const <ScannedTrack>[
        ScannedTrack(
          filePathOrUrl: '/music/01. 晴天 [HQ].mp3',
          title: '01. 晴天 [HQ]',
          artist: '未知艺术家',
          album: '未知专辑',
          duration: 240,
          fileFormat: 'mp3',
        ),
        ScannedTrack(
          filePathOrUrl: '/music/周杰伦 - 园游会.flac',
          title: '园游会',
          artist: '周杰伦',
          album: '未知专辑',
          duration: 250,
          fileFormat: 'flac',
        ),
      ],
    );

    final List<Track> originalList = await tracks.all();
    expect(originalList, hasLength(2));
    final String t1Id = originalList
        .firstWhere((t) => t.title.contains('晴天'))
        .id;
    final String t2Id = originalList
        .firstWhere((t) => t.title.contains('园游会'))
        .id;

    final _FakeAIClient client = _FakeAIClient((_) async {
      return '''
[
  {"id": "$t1Id", "title": "晴天", "artist": "周杰伦", "album": "叶惠美"},
  {"id": "$t2Id", "title": "园游会", "artist": "周杰伦", "album": "七里香"}
]
''';
    });

    final List<RefactorProgress> reportedProgress = <RefactorProgress>[];
    final AILibraryRefactorService service = AILibraryRefactorService(
      tracks: tracks,
      client: client,
      batchSize: 10,
    );

    final RefactorProgress finalProgress = await service.refactorAll(
      onProgress: (RefactorProgress p) => reportedProgress.add(p),
    );

    expect(finalProgress.isCompleted, isTrue);
    expect(finalProgress.updated, 2);
    expect(finalProgress.total, 2);
    expect(reportedProgress, isNotEmpty);

    final Track updated1 = (await tracks.byId(t1Id))!;
    expect(updated1.title, '晴天');
    expect(updated1.artist, '周杰伦');
    expect(updated1.album, '叶惠美');

    final Track updated2 = (await tracks.byId(t2Id))!;
    expect(updated2.title, '园游会');
    expect(updated2.artist, '周杰伦');
    expect(updated2.album, '七里香');
  });

  test('按 batchSize 分批次并在中途取消时提前终止', () async {
    final TingyuDatabase db = openTestDatabase();
    addTearDown(db.close);

    final SourceRepository sources = SourceRepository(db);
    await sources.upsert(
      const MusicSourcesCompanion(
        id: Value<String>('src-1'),
        name: Value<String>('本地'),
        kind: Value<String>('local'),
      ),
    );

    final TrackRepository tracks = TrackRepository(db);
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: const <ScannedTrack>[
        ScannedTrack(
          filePathOrUrl: '/1.mp3',
          title: 'Song 1',
          duration: 100,
          fileFormat: 'mp3',
        ),
        ScannedTrack(
          filePathOrUrl: '/2.mp3',
          title: 'Song 2',
          duration: 100,
          fileFormat: 'mp3',
        ),
        ScannedTrack(
          filePathOrUrl: '/3.mp3',
          title: 'Song 3',
          duration: 100,
          fileFormat: 'mp3',
        ),
      ],
    );

    final List<Track> all = await tracks.all();
    expect(all, hasLength(3));

    int callCount = 0;
    final _FakeAIClient client = _FakeAIClient((_) async {
      callCount++;
      return '[]';
    });

    final AILibraryRefactorService service = AILibraryRefactorService(
      tracks: tracks,
      client: client,
      batchSize: 1, // 每首一批
    );

    // 第一批后取消
    final RefactorProgress progress = await service.refactorAll(
      isCancelled: () => callCount >= 1,
    );

    expect(callCount, 1);
    expect(progress.processed, 1);
    expect(progress.total, 3);
  });
}
