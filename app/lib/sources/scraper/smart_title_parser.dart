/// 从混乱的文件名里解析「标题 / 艺术家 / 专辑」。
///
/// 直接对齐旧版 `Sources/Services/Scraper/SmartTitleParser.swift`：
/// 抓取源（Quark / WebDAV）只能拿到文件名，这一步是后续元数据抓取的输入。
/// 其中「第二段是艺术家」的特例来自本库的文件命名习惯（`歌手 - 歌名 - 专辑` 与
/// `歌名 - 周杰伦` 混用），行为与原实现一致。
class ParsedSongInfo {
  const ParsedSongInfo({
    required this.title,
    this.artist = '',
    this.album = '',
  });

  final String title;

  final String artist;

  final String album;

  @override
  String toString() => 'ParsedSongInfo($title | $artist | $album)';
}

class SmartTitleParser {
  static const String fallbackArtist = '未知艺术家';

  static const String fallbackAlbum = '未知专辑';

  /// 文件名里常见的噪声后缀：码率、音质、版本标注。
  static final List<RegExp> _noisePatterns = <RegExp>[
    RegExp(r'\s*\[(?:HQ|SQ|FLAC|Hi-Res|320k|128k|\d+kbps|无损|高品质|现场|Live|官方|伴奏|Remix).*?\]',
        caseSensitive: false),
    RegExp(r'\s*\((?:HQ|SQ|FLAC|Hi-Res|320k|128k|\d+kbps|无损|高品质|现场|Live|伴奏|Remix|韩语中字|live版).*?\)',
        caseSensitive: false),
    RegExp(r'[-_](?:320k|128k|flac|hq|sq)', caseSensitive: false),
  ];

  static final RegExp _leadingNumber = RegExp(r'^\s*\d{1,3}\s*[-._\s]\s*');

  /// 判断某一段是否"看起来像艺术家"。
  ///
  /// 只保留原实现的判据：周杰伦（含简繁与"周杰"前缀）。这是本库的命名习惯，
  /// 不是通用规则——通用艺术家识别属于元数据抓取的职责。
  static bool _looksLikeKnownArtist(String part) {
    final String value = part.trim();
    return value == '周杰伦' || value == '周杰倫' || value.contains('周杰');
  }

  static ParsedSongInfo parse(
    String filename, {
    String fallbackArtist = SmartTitleParser.fallbackArtist,
    String fallbackAlbum = SmartTitleParser.fallbackAlbum,
  }) {
    String clean = filename;

    // 1. 去掉扩展名（调用方可能已经去掉，重复处理安全）。
    final int dot = clean.lastIndexOf('.');
    if (dot > 0 && dot >= clean.length - 5) {
      final String extension = clean.substring(dot + 1).toLowerCase();
      if (_audioExtensions.contains(extension)) {
        clean = clean.substring(0, dot);
      }
    }

    // 2. 去掉开头的曲序编号。
    clean = stripLeadingNumbers(clean);

    // 3. 按分隔符切段。
    final List<String> parts = clean
        .split(RegExp(r'[-_|]'))
        .map(cleanPart)
        .where((String part) => part.isNotEmpty)
        .toList(growable: false);

    if (parts.length >= 3) {
      // 歌名 - 艺术家 - 专辑（例如 `花海-周杰伦-魔杰座`）
      if (_looksLikeKnownArtist(parts[1])) {
        return ParsedSongInfo(title: parts[0], artist: parts[1], album: parts[2]);
      }
      // 艺术家 - 歌名 - 专辑/版本（例如 `周杰伦 - 晴天 - 叶惠美`）
      return ParsedSongInfo(
        title: stripLeadingNumbers(parts[1]),
        artist: stripLeadingNumbers(parts[0]),
        album: cleanPart(parts[2]),
      );
    }
    if (parts.length == 2) {
      // 歌名 - 艺术家（例如 `明明就 - 周杰伦`）
      if (_looksLikeKnownArtist(parts[1])) {
        return ParsedSongInfo(
          title: stripLeadingNumbers(parts[0]),
          artist: stripLeadingNumbers(parts[1]),
          album: fallbackAlbum,
        );
      }
      // 艺术家 - 歌名（例如 `周杰伦 - 园游会 (Live)`）
      return ParsedSongInfo(
        title: stripLeadingNumbers(parts[1]),
        artist: stripLeadingNumbers(parts[0]),
        album: fallbackAlbum,
      );
    }
    if (parts.isNotEmpty) {
      return ParsedSongInfo(title: parts.first, artist: fallbackArtist, album: fallbackAlbum);
    }
    return ParsedSongInfo(title: cleanPart(clean), artist: fallbackArtist, album: fallbackAlbum);
  }

  /// 去掉首尾标点、剥离噪声标注。
  static String cleanPart(String input) {
    String value = _trimPunctuation(input);
    for (final RegExp pattern in _noisePatterns) {
      value = value.replaceAll(pattern, '');
    }
    return _trimPunctuation(value);
  }

  /// 去掉开头的曲序编号（`01. ` / `3 - ` / `12_`）。
  static String stripLeadingNumbers(String input) {
    final String result = input.replaceFirst(_leadingNumber, '');
    return _trimPunctuation(result);
  }

  static const Set<String> _audioExtensions = <String>{
    'mp3',
    'flac',
    'm4a',
    'aac',
    'wav',
    'ogg',
    'opus',
    'aiff',
    'alac',
  };

  static String _trimPunctuation(String value) => value.replaceAll(RegExp(r'^[.\s_-]+|[.\s_-]+$'), '');
}
