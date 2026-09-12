import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 一次元数据检索的候选结果（跨来源统一形状）。
class MetadataCandidate {
  const MetadataCandidate({
    required this.provider,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.sourceId,
    this.duration = Duration.zero,
  });

  /// 产出该候选的来源名（`qqmusic` / `netease` / …）。
  final String provider;

  final String title;

  final String artist;

  final String album;

  /// 可直接下载的封面地址（QQ 音乐按 albumMid 拼出，网易云用 picUrl）。
  final String? coverUrl;

  /// 来源内部 id（网易云 songId），供需要二次请求的接口使用。
  final String? sourceId;

  final Duration duration;

  /// 标题是否匹配（沿用旧实现的宽松判据：互相包含即视为同一首）。
  bool matchesTitle(String other) {
    final String candidate = title.trim().toLowerCase();
    final String target = other.trim().toLowerCase();
    if (candidate.isEmpty || target.isEmpty) {
      return false;
    }
    return candidate.contains(target) || target.contains(candidate);
  }
}

/// 歌词检索的输入（LRCLIB 用标题/艺术家/专辑/时长；网易云用候选里的 songId）。
class LyricsQuery {
  const LyricsQuery({
    required this.title,
    this.artist = '',
    this.album = '',
    this.duration = Duration.zero,
  });

  final String title;

  final String artist;

  final String album;

  final Duration duration;
}

/// 可搜索曲目元数据的来源。
abstract interface class MetadataSearcher {
  String get name;

  Future<MetadataCandidate?> search(String title, {String artist = ''});
}

/// 可获取歌词的来源。
abstract interface class LyricsProvider {
  String get name;

  /// [candidate] 是同一来源的搜索结果（可能为 null，例如 LRCLIB 不需要）。
  Future<String?> fetchLyrics(LyricsQuery query, {MetadataCandidate? candidate});
}

/// 只能按专辑名/艺术家查封面地址的来源（iTunes Search API）。
abstract interface class CoverLookup {
  String get name;

  Future<String?> coverUrl({required String album, String artist = ''});
}

/// 能给出艺术家头像地址的来源（网易云艺术家搜索）。
abstract interface class ArtistLookup {
  String get name;

  Future<String?> avatarUrl(String artist);
}

/// 请求上游接口并按 JSON 解析。
///
/// 上游的 `Content-Type` 五花八门（QQ 音乐是 `application/x-javascript`，
/// 网易云是 `text/plain`，iTunes 是 `text/javascript`），dio 会据此把响应当成字符串，
/// 用它内置的类型推断会直接失败。这里统一按文本取回再自行 `jsonDecode`，
/// 失败（网络错误 / 非 2xx / 非 JSON）一律返回 null —— 元数据抓取是尽力而为。
Future<Map<String, dynamic>?> fetchJsonMap(
  Dio dio,
  String url, {
  Map<String, Object?>? query,
  Map<String, String>? headers,
  int timeoutSeconds = 10,
}) async {
  try {
    final Response<String> response = await dio.get<String>(
      url,
      queryParameters: query,
      options: Options(
        headers: headers,
        responseType: ResponseType.plain,
        sendTimeout: Duration(seconds: timeoutSeconds),
        receiveTimeout: Duration(seconds: timeoutSeconds),
        validateStatus: (int? status) => status == 200,
      ),
    );
    final String? body = response.data;
    if (body == null || body.isEmpty) {
      return null;
    }
    final Object? decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on DioException {
    return null;
  } on FormatException {
    return null;
  }
}

/// 图片下载（封面 / 艺术家头像），统一超时与 UA。
class ImageDownloader {
  ImageDownloader({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 20),
              ),
            );

  final Dio _dio;

  Future<Uint8List?> download(String url, {Map<String, String>? headers}) async {
    try {
      final Response<List<int>> response = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: headers,
          // 封面地址常返回 302/307 到 CDN。
          followRedirects: true,
          validateStatus: (int? status) => status != null && status >= 200 && status < 300,
        ),
      );
      final List<int>? data = response.data;
      if (data == null || data.isEmpty) {
        return null;
      }
      return Uint8List.fromList(data);
    } on DioException {
      // 封面/歌词属于尽力而为，失败不影响其余流程。
      return null;
    }
  }
}
