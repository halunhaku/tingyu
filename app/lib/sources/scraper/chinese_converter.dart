import 'package:flutter/services.dart' show rootBundle;

/// 繁体 → 简体转换。
///
/// 旧版用系统的 ICU `Traditional-Simplified` 变换；Flutter 没有等价 API，
/// 因此这里内置 OpenCC 的繁→简单字表（Apache-2.0，`assets/opencc/TSCharacters.txt`）。
///
/// 有意简化：只做**逐字**转换（取 OpenCC 给出的首选字形），不做词组级消歧
/// （OpenCC 的 `TSPhrases` 表约 800KB，对歌词场景收益不成比例）。
/// 若日后发现常见歌词有误转，再把词组表接进来即可，接口不变。
class ChineseConverter {
  ChineseConverter({Future<String> Function()? loadDictionary})
      : _loadDictionary = loadDictionary ?? _loadAsset;

  /// 表很大（约 5000 行）而绝大多数曲目不需要转换，故首次用到时才加载。
  static final ChineseConverter instance = ChineseConverter();

  final Future<String> Function() _loadDictionary;

  Map<String, String>? _dictionary;

  bool get isLoaded => _dictionary != null;

  /// 预加载字典（可在启动时后台调用，避免首次转换时的等待）。
  Future<void> ensureLoaded() async {
    _dictionary ??= parseDictionary(await _loadDictionary());
  }

  /// 简体输入会原样返回；未收录的字保持原样。
  Future<String> toSimplified(String text) async {
    if (text.isEmpty) {
      return text;
    }
    await ensureLoaded();
    final Map<String, String> dictionary = _dictionary!;
    final StringBuffer buffer = StringBuffer();
    bool converted = false;
    for (final int rune in text.runes) {
      final String character = String.fromCharCode(rune);
      final String? simplified = dictionary[character];
      if (simplified == null) {
        buffer.write(character);
      } else {
        buffer.write(simplified);
        converted = true;
      }
    }
    return converted ? buffer.toString() : text;
  }

  /// 解析 OpenCC 字表：`繁体<TAB>候选1 候选2 …`，取第一个候选；忽略注释与空行。
  static Map<String, String> parseDictionary(String content) {
    final Map<String, String> dictionary = <String, String>{};
    for (final String rawLine in content.split('\n')) {
      final String line = rawLine.trimRight();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final int tab = line.indexOf('\t');
      if (tab <= 0) {
        continue;
      }
      final String traditional = line.substring(0, tab);
      final List<String> candidates = line
          .substring(tab + 1)
          .trim()
          .split(' ')
          .where((String candidate) => candidate.isNotEmpty)
          .toList(growable: false);
      if (candidates.isEmpty) {
        continue;
      }
      dictionary[traditional] = candidates.first;
    }
    return dictionary;
  }

  static Future<String> _loadAsset() => rootBundle.loadString('assets/opencc/TSCharacters.txt');
}
