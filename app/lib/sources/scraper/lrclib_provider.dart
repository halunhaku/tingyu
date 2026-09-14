import 'package:dio/dio.dart';

import 'chinese_converter.dart';
import 'metadata_provider.dart';

/// LRCLIB（对齐 `Sources/Services/Scraper/LRCLIBScraper.swift`）。
///
/// 用途：歌词的主来源（带时间轴），按 标题 / 艺术家 / 专辑 / 时长 精确检索。
/// 该接口返回标准 `application/json`，但仍统一走 [fetchJsonMap] 以免上游改头。
class LrclibProvider implements LyricsProvider {
  LrclibProvider({Dio? dio, ChineseConverter? converter})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
              ),
            ),
        _converter = converter ?? ChineseConverter.instance;

  /// LRCLIB 要求带可识别的 UA，沿用旧版写法。
  static const String userAgent = 'Tingyu/1.0 (https://github.com/halunhaku/tingyu)';

  @override
  String get name => 'lrclib';

  final Dio _dio;

  final ChineseConverter _converter;

  @override
  Future<String?> fetchLyrics(LyricsQuery query, {MetadataCandidate? candidate}) async {
    final String trackName = query.title.trim();
    if (trackName.isEmpty) {
      return null;
    }

    final Map<String, dynamic>? body = await fetchJsonMap(
      _dio,
      'https://lrclib.net/api/get',
      query: <String, Object?>{
        'track_name': trackName,
        if (query.artist.trim().isNotEmpty) 'artist_name': query.artist.trim(),
        if (query.album.trim().isNotEmpty) 'album_name': query.album.trim(),
        if (query.duration > Duration.zero) 'duration': query.duration.inSeconds,
      },
      headers: <String, String>{'User-Agent': userAgent},
      timeoutSeconds: 15,
    );
    if (body == null) {
      return null;
    }

    final String synced = body['syncedLyrics'] as String? ?? '';
    if (synced.isNotEmpty) {
      return _converter.toSimplified(synced);
    }
    final String plain = body['plainLyrics'] as String? ?? '';
    if (plain.isNotEmpty) {
      return _converter.toSimplified(plain);
    }
    return null;
  }
}
