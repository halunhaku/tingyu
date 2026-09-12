import 'dart:typed_data';

import 'metadata_provider.dart';
import 'smart_title_parser.dart';

/// 富化输入：库里一条曲目的当前元数据。
class EnrichmentInput {
  const EnrichmentInput({
    required this.title,
    this.artist = SmartTitleParser.fallbackArtist,
    this.album = SmartTitleParser.fallbackAlbum,
    this.lyrics,
    this.hasCover = false,
    this.duration = Duration.zero,
  });

  /// 文件名解析出来的标题（可能是"歌手 - 歌名"这类脏字符串）。
  final String title;

  final String artist;

  final String album;

  final String? lyrics;

  /// 已有封面时不再去抓封面。
  final bool hasCover;

  final Duration duration;
}

/// 富化结果：只描述"该写回什么"，不碰数据库与文件系统。
class EnrichmentResult {
  const EnrichmentResult({
    this.title,
    this.artist,
    this.album,
    this.lyrics,
    this.coverUrl,
    this.coverBytes,
    this.isSkipped = false,
  });

  static const EnrichmentResult skipped = EnrichmentResult(isSkipped: true);

  /// 仅当需要改动时才非空；null 表示保持原值。
  final String? title;

  final String? artist;

  final String? album;

  final String? lyrics;

  final String? coverUrl;

  final Uint8List? coverBytes;

  final bool isSkipped;

  bool get hasChanges =>
      title != null || artist != null || album != null || lyrics != null || coverBytes != null;
}

/// 元数据富化编排（对齐 `Sources/Services/Scraper/MetadataEnricher.swift` 的第 1–5 步）。
///
/// 管道顺序与原实现一致：
/// 1. 用文件名解析出干净的查询词，并在必要时回写标题/艺术家/专辑；
/// 2. QQ 音乐 → 中文曲库的主元数据（歌手/专辑/封面）；
/// 3. LRCLIB → 歌词主来源（带时间轴）；
/// 4. 网易云 → 歌词兜底；
/// 5. 网易云 → 封面兜底；iTunes → 最后的封面兜底。
///
/// 每个来源都是可选注入的，缺失的环节自动跳过。
class MetadataEnricher {
  const MetadataEnricher({
    required this.searcher,
    required this.lyricsProvider,
    this.fallbackSearcher,
    this.fallbackLyricsProvider,
    this.coverLookup,
    required this.downloader,
  });

  /// 主搜索来源（QQ 音乐）。
  final MetadataSearcher searcher;

  /// 主歌词来源（LRCLIB）。
  final LyricsProvider lyricsProvider;

  /// 兜底搜索来源（网易云）。
  final MetadataSearcher? fallbackSearcher;

  /// 兜底歌词来源（网易云），需要 [fallbackSearcher] 提供候选 id。
  final LyricsProvider? fallbackLyricsProvider;

  /// 最后的封面兜底（iTunes）。
  final CoverLookup? coverLookup;

  final ImageDownloader downloader;

  /// 疑似"艺术家名被当成了歌名"时中止富化，避免用错误查询词污染元数据。
  static const String suspiciousTitle = '周杰伦';

  Future<EnrichmentResult> enrich(EnrichmentInput input) async {
    final ParsedSongInfo parsed = SmartTitleParser.parse(
      input.title,
      fallbackArtist: input.artist,
      fallbackAlbum: input.album,
    );

    final String queryTitle = parsed.title.trim();
    if (queryTitle.isEmpty || queryTitle == input.artist || queryTitle == suspiciousTitle) {
      return EnrichmentResult.skipped;
    }

    String artist = _placeholderArtist(input.artist) ? parsed.artist : input.artist;
    String album = _placeholderAlbum(input.album) ? parsed.album : input.album;
    String? title = _looksMessy(input.title) ? queryTitle : null;

    final bool needsSearch = !input.hasCover || _placeholderArtist(input.artist) || _placeholderAlbum(input.album);
    if (!needsSearch && input.hasCover && (input.lyrics?.isNotEmpty ?? false)) {
      // 元数据与封面/歌词都已齐备，无需联网。
      return const EnrichmentResult();
    }

    Uint8List? coverBytes;
    String? coverUrl;

    // 2. 主搜索来源：歌手 / 专辑 / 封面
    if (needsSearch) {
      final MetadataCandidate? candidate = await searcher.search(queryTitle, artist: artist);
      if (candidate != null && candidate.matchesTitle(queryTitle)) {
        if (candidate.artist.isNotEmpty) {
          artist = candidate.artist;
        }
        if (candidate.album.isNotEmpty) {
          album = candidate.album;
        }
        if (!input.hasCover && candidate.coverUrl != null) {
          coverBytes = await downloader.download(candidate.coverUrl!);
          coverUrl = candidate.coverUrl;
        }
      }
    }

    // 3. 歌词主来源：LRCLIB（只认标题/艺术家/专辑/时长）
    String? lyrics;
    if (input.lyrics?.isNotEmpty != true) {
      lyrics = await lyricsProvider.fetchLyrics(
        LyricsQuery(
          title: queryTitle,
          artist: _placeholderArtist(artist) ? '' : artist,
          album: _placeholderAlbum(album) ? '' : album,
          duration: input.duration,
        ),
      );
    }

    MetadataCandidate? fallbackCandidate;

    // 4. 歌词兜底：网易云（需要候选 id）
    if ((lyrics == null || lyrics.isEmpty) && fallbackSearcher != null && fallbackLyricsProvider != null) {
      fallbackCandidate = await fallbackSearcher!.search(queryTitle, artist: artist);
      if (fallbackCandidate != null && fallbackCandidate.matchesTitle(queryTitle)) {
        lyrics = await fallbackLyricsProvider!.fetchLyrics(
          LyricsQuery(title: queryTitle, artist: artist, album: album, duration: input.duration),
          candidate: fallbackCandidate,
        );
      }
    }

    // 5. 封面兜底：网易云
    if (coverBytes == null && !input.hasCover && fallbackSearcher != null) {
      fallbackCandidate ??= await fallbackSearcher!.search(queryTitle, artist: artist);
      final String? url = fallbackCandidate?.matchesTitle(queryTitle) == true
          ? fallbackCandidate?.coverUrl
          : null;
      if (url != null) {
        coverBytes = await downloader.download(url);
        coverUrl = url;
      }
    }

    // 5b. 封面最后兜底：iTunes（按专辑名/歌手查）
    if (coverBytes == null && !input.hasCover && coverLookup != null) {
      final String lookupAlbum = _placeholderAlbum(album) ? queryTitle : album;
      final String? url = await coverLookup!.coverUrl(
        album: lookupAlbum,
        artist: _placeholderArtist(artist) ? '' : artist,
      );
      if (url != null) {
        coverBytes = await downloader.download(url);
        coverUrl = url;
      }
    }

    return EnrichmentResult(
      title: title,
      artist: artist == input.artist ? null : artist,
      album: album == input.album ? null : album,
      lyrics: (lyrics != null && lyrics.isNotEmpty && lyrics != input.lyrics) ? lyrics : null,
      coverUrl: coverUrl,
      coverBytes: coverBytes,
    );
  }

  /// 旧实现把"未知艺术家 / 未知专辑 / 夸克曲库 / 空"视为占位。
  static bool _placeholderArtist(String value) => value.isEmpty || value == SmartTitleParser.fallbackArtist;

  static bool _placeholderAlbum(String value) =>
      value.isEmpty ||
      value == SmartTitleParser.fallbackAlbum ||
      value == '夸克曲库' ||
      value == 'WebDAV 曲库';

  /// 标题里带分隔符或音频扩展名时，说明它还是文件名而不是歌名。
  static bool _looksMessy(String title) {
    final String lower = title.toLowerCase();
    if (lower.endsWith('.mp3') || lower.endsWith('.flac') || lower.endsWith('.m4a')) {
      return true;
    }
    return title.contains('-') || title.contains('_') || title.contains('.');
  }
}
