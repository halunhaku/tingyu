import 'dart:convert';

import '../scraper/smart_title_parser.dart';
import 'ai_client.dart';

/// 提交给 AI 的待识别曲目条目。
class AIInputItem {
  const AIInputItem({required this.id, required this.filename});

  final String id;
  final String filename;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'filename': filename,
  };
}

/// AI 返回内容无法被解析为规范元数据结构时抛出。
class AIMetadataParseException implements Exception {
  const AIMetadataParseException([this.message = 'AI 输出的 JSON 无法解析']);

  final String message;

  @override
  String toString() => message;
}

/// AI 音乐元数据批量清洗与识别器。
abstract final class AIMetadataParser {
  static const String _systemPrompt = '''
你是一位资深的华语与国际音乐元数据专家。用户会提供一组包含噪声、乱码或特殊格式的音频文件名。
请凭借你庞大的音乐常识，识别出每首歌曲的真实信息：
1. title: 标准中文或官方歌曲名（不要带Live、伴奏、前导序号、点号等噪声）
2. artist: 标准主要歌手或音乐人（华语歌曲优先使用常见标准简体中文，如 周杰伦、陈奕迅）
3. album: 该歌曲所属的正式录音室专辑或官方原声带名称（若无法确定可填已知专辑）

必须严格只输出合法的 JSON 数组，严禁包含任何 Markdown 标记外的多余解释。格式示例：
[
  {"id": "1", "title": "园游会", "artist": "周杰伦", "album": "七里香"},
  {"id": "2", "title": "早操", "artist": "周杰伦", "album": "不能说的秘密 电影原声带"}
]
''';

  /// 批量请求 AI 并将结果还原为以曲目 ID 为键的 [ParsedSongInfo] 映射。
  static Future<Map<String, ParsedSongInfo>> parseBatch({
    required AIClient client,
    required List<AIInputItem> items,
  }) async {
    if (items.isEmpty) {
      return const <String, ParsedSongInfo>{};
    }

    final String inputJson = jsonEncode(
      items.map((AIInputItem e) => e.toJson()).toList(growable: false),
    );

    final List<ChatMessage> messages = <ChatMessage>[
      const ChatMessage(role: 'system', content: _systemPrompt),
      ChatMessage(role: 'user', content: '请清洗并识别以下歌曲文件名：\n$inputJson'),
    ];

    final String responseText = await client.complete(
      messages,
      temperature: 0.1,
    );

    return parseResponse(responseText);
  }

  /// 从模型返回的原始文本中清洗提取并反序列化元数据结果。
  static Map<String, ParsedSongInfo> parseResponse(String rawText) {
    final String cleanJson = _cleanJsonText(rawText);

    dynamic decoded;
    try {
      decoded = jsonDecode(cleanJson);
    } on Object catch (error) {
      throw AIMetadataParseException('AI 输出的 JSON 无法解析: $error');
    }

    if (decoded is! List) {
      throw const AIMetadataParseException('AI 输出的结构不是预期的 JSON 数组');
    }

    final Map<String, ParsedSongInfo> map = <String, ParsedSongInfo>{};
    for (final dynamic item in decoded) {
      if (item is! Map) {
        continue;
      }
      final String id = item['id']?.toString().trim() ?? '';
      final String title = item['title']?.toString().trim() ?? '';
      final String artist = item['artist']?.toString().trim() ?? '';
      final String album = item['album']?.toString().trim() ?? '';

      if (id.isNotEmpty && title.isNotEmpty) {
        map[id] = ParsedSongInfo(title: title, artist: artist, album: album);
      }
    }

    return map;
  }

  static String _cleanJsonText(String text) {
    String trimmed = text.trim();

    final int codeStart = trimmed.indexOf('```');
    if (codeStart != -1) {
      final int firstNewline = trimmed.indexOf('\n', codeStart);
      final int lastBackticks = trimmed.lastIndexOf('```');
      if (firstNewline != -1 && lastBackticks > firstNewline) {
        trimmed = trimmed.substring(firstNewline + 1, lastBackticks).trim();
      }
    }

    final int firstBracket = trimmed.indexOf('[');
    final int lastBracket = trimmed.lastIndexOf(']');
    if (firstBracket != -1 && lastBracket > firstBracket) {
      trimmed = trimmed.substring(firstBracket, lastBracket + 1).trim();
    }

    return trimmed;
  }
}
