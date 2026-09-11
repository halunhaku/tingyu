import 'package:dio/dio.dart';

import 'chinese_converter.dart';
import 'metadata_provider.dart';

/// 网易云音乐（对齐 `Sources/Services/Scraper/NetEaseScraper.swift`）。
///
/// 用途：歌词的兜底来源 + 封面的兜底来源；歌词统一转简体后返回。
/// 注意：该接口返回 `text/plain`，必须走 [fetchJsonMap] 自行解析。
class NetEaseProvider implements MetadataSearcher, LyricsProvider, ArtistLookup {
  NetEaseProvider({Dio? dio, ChineseConverter? converter})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
              ),
            ),
        _converter = converter ?? ChineseConverter.instance;

  static const Map<String, String> browserHeaders = <String, String>{
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
    'Referer': 'https://music.163.com',
  };

  @override
  String get name => 'netease';

  final Dio _dio;

  final ChineseConverter _converter;

  @override
  Future<MetadataCandidate?> search(String title, {String artist = ''}) async {
    final String query = _buildQuery(title, artist);
    if (query.isEmpty) {
      return null;
    }

    final Map<String, dynamic>? body = await fetchJsonMap(
      _dio,
      'https://music.163.com/api/search/get/web',
      query: <String, Object?>{
        'csrf_token': '',
        's': query,
        'type': 1,
        'offset': 0,
        'total': 'true',
        'limit': 1,
      },
      headers: browserHeaders,
    );
    final Object? result = body?['result'];
    if (result is! Map<String, dynamic>) {
      return null;
    }
    final Object? songs = result['songs'];
    if (songs is! List<dynamic> || songs.isEmpty) {
      return null;
    }
    final Object? first = songs.first;
    if (first is! Map<String, dynamic>) {
      return null;
    }
    final Object? songId = first['id'];
    final String? songTitle = first['name'] as String?;
    if (songId == null || songTitle == null) {
      return null;
    }

    String albumName = '';
    String? picUrl;
    final Object? album = first['album'];
    if (album is Map<String, dynamic>) {
      albumName = album['name'] as String? ?? '';
      picUrl = album['picUrl'] as String?;
    }

    return MetadataCandidate(
      provider: name,
      title: songTitle,
      artist: _firstArtist(first),
      album: albumName,
      coverUrl: picUrl,
      sourceId: songId.toString(),
    );
  }

  @override
  Future<String?> fetchLyrics(LyricsQuery query, {MetadataCandidate? candidate}) async {
    final String? songId = candidate?.sourceId;
    if (songId == null || songId.isEmpty) {
      return null;
    }

    final Map<String, dynamic>? body = await fetchJsonMap(
      _dio,
      'https://music.163.com/api/song/lyric',
      query: <String, Object?>{'os': 'pc', 'id': songId, 'lv': -1, 'kv': -1, 'tv': -1},
      headers: browserHeaders,
    );
    final Object? lrc = body?['lrc'];
    if (lrc is! Map<String, dynamic>) {
      return null;
    }
    final String lyric = (lrc['lyric'] as String? ?? '').trim();
    if (lyric.isEmpty) {
      return null;
    }
    return _converter.toSimplified(lyric);
  }

  @override
  Future<String?> avatarUrl(String artist) async {
    final String name = artist.trim();
    if (name.isEmpty) {
      return null;
    }

    final Map<String, dynamic>? body = await fetchJsonMap(
      _dio,
      'https://music.163.com/api/search/get/web',
      query: <String, Object?>{'s': name, 'type': 100, 'offset': 0, 'total': 'true', 'limit': 1},
      headers: browserHeaders,
      timeoutSeconds: 8,
    );
    final Object? result = body?['result'];
    if (result is! Map<String, dynamic>) {
      return null;
    }
    final Object? artists = result['artists'];
    if (artists is! List<dynamic> || artists.isEmpty) {
      return null;
    }
    final Object? first = artists.first;
    if (first is! Map<String, dynamic>) {
      return null;
    }
    final String url = (first['img1v1Url'] as String?) ?? (first['picUrl'] as String?) ?? '';
    if (url.isEmpty) {
      return null;
    }
    return url.contains('?') ? '$url&param=500y500' : '$url?param=500y500';
  }

  /// 网易云的 `picUrl` 可以加 `param` 参数取更高分辨率。
  static String highResolutionCoverUrl(String picUrl) =>
      picUrl.contains('?') ? '$picUrl&param=800y800' : '$picUrl?param=800y800';

  static String _buildQuery(String title, String artist) {
    final String cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      return '';
    }
    final String cleanArtist = artist.trim();
    if (cleanArtist.isEmpty || cleanArtist == '未知艺术家') {
      return cleanTitle;
    }
    return '$cleanTitle $cleanArtist';
  }

  static String _firstArtist(Map<String, dynamic> song) {
    final Object? artists = song['artists'];
    if (artists is List<dynamic> && artists.isNotEmpty) {
      final Object? first = artists.first;
      if (first is Map<String, dynamic>) {
        return first['name'] as String? ?? '';
      }
    }
    return '';
  }
}
