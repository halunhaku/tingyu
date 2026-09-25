import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/sources/ai/ai_client.dart';
import 'package:tingyu/sources/ai/ai_metadata_parser.dart';
import 'package:tingyu/sources/scraper/smart_title_parser.dart';

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
  group('AIMetadataParser 元数据解析器', () {
    test('空输入直接返回空 Map，且不出网', () async {
      final _FakeAIClient client = _FakeAIClient((_) async => '[]');
      final Map<String, ParsedSongInfo> result =
          await AIMetadataParser.parseBatch(
            client: client,
            items: const <AIInputItem>[],
          );

      expect(result, isEmpty);
      expect(client.calls, isEmpty);
    });

    test('标准 JSON 数组响应解析为 ParsedSongInfo 映射', () async {
      final _FakeAIClient client = _FakeAIClient((
        List<ChatMessage> messages,
      ) async {
        expect(messages, hasLength(2));
        expect(messages[0].role, 'system');
        expect(messages[0].content, contains('音乐元数据专家'));
        expect(messages[1].role, 'user');
        expect(messages[1].content, contains('01. 晴天 [HQ].mp3'));

        return '''
[
  {"id": "t1", "title": "晴天", "artist": "周杰伦", "album": "叶惠美"},
  {"id": "t2", "title": "富士山下", "artist": "陈奕迅", "album": "What's Going On...?"}
]
''';
      });

      final Map<String, ParsedSongInfo> result =
          await AIMetadataParser.parseBatch(
            client: client,
            items: const <AIInputItem>[
              AIInputItem(id: 't1', filename: '01. 晴天 [HQ].mp3'),
              AIInputItem(id: 't2', filename: '陈奕迅 - 富士山下.flac'),
            ],
          );

      expect(result, hasLength(2));
      expect(result['t1']?.title, '晴天');
      expect(result['t1']?.artist, '周杰伦');
      expect(result['t1']?.album, '叶惠美');

      expect(result['t2']?.title, '富士山下');
      expect(result['t2']?.artist, '陈奕迅');
      expect(result['t2']?.album, "What's Going On...?");
    });

    test('剥离 Markdown ```json 代码块外壳与首尾噪音', () async {
      final _FakeAIClient client = _FakeAIClient(
        (_) async => '''
好的，为您清洗识别如下：
```json
[
  {"id": "t1", "title": "园游会", "artist": "周杰伦", "album": "七里香"}
]
```
以上为识别结果。
''',
      );

      final Map<String, ParsedSongInfo> result =
          await AIMetadataParser.parseBatch(
            client: client,
            items: const <AIInputItem>[
              AIInputItem(id: 't1', filename: '周杰伦-七里香-06.园游会[SQ].flac'),
            ],
          );

      expect(result, hasLength(1));
      expect(result['t1']?.title, '园游会');
      expect(result['t1']?.artist, '周杰伦');
      expect(result['t1']?.album, '七里香');
    });

    test('容错：缺少 album 字段、字段带多余空格或 title 为空', () async {
      final _FakeAIClient client = _FakeAIClient(
        (_) async => '''
[
  {"id": "t1", "title": "  夜曲  ", "artist": " 周杰伦 "},
  {"id": "t2", "title": "", "artist": "未知歌手"}
]
''',
      );

      final Map<String, ParsedSongInfo> result =
          await AIMetadataParser.parseBatch(
            client: client,
            items: const <AIInputItem>[
              AIInputItem(id: 't1', filename: '夜曲.mp3'),
              AIInputItem(id: 't2', filename: 'blank.mp3'),
            ],
          );

      expect(result, hasLength(1));
      expect(result['t1']?.title, '夜曲');
      expect(result['t1']?.artist, '周杰伦');
      expect(result['t1']?.album, '');
    });

    test('非法响应结构抛出 AIMetadataParseException', () async {
      final _FakeAIClient client = _FakeAIClient((_) async => '这不是合法的 json 内容');

      await expectLater(
        AIMetadataParser.parseBatch(
          client: client,
          items: const <AIInputItem>[
            AIInputItem(id: 't1', filename: 'song.mp3'),
          ],
        ),
        throwsA(isA<AIMetadataParseException>()),
      );
    });
  });
}
