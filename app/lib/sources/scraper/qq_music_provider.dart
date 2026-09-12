import 'package:dio/dio.dart';

import 'metadata_provider.dart';

/// QQ 音乐搜索（对齐 `Sources/Services/Scraper/QQMusicScraper.swift`）。
///
/// 用途：中文曲库的主元数据来源（歌名/歌手/专辑/封面），封面按 albumMid 拼 gtimg 地址。
/// 注意：该接口返回 `application/x-javascript`，必须走 [fetchJsonMap] 自行解析。
class QQMusicProvider implements MetadataSearcher {
  QQMusicProvider({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 8),
              ),
            );

  @override
  String get name => 'qqmusic';

  final Dio _dio;

  @override
  Future<MetadataCandidate?> search(String title, {String artist = ''}) async {
    final List<MetadataCandidate> candidates = await searchCandidates(title, artist: artist, limit: 1);
    return candidates.isEmpty ? null : candidates.first;
  }

  /// 供"手动匹配"界面使用：一次拿回多条候选。
  Future<List<MetadataCandidate>> searchCandidates(
    String title, {
    String artist = '',
    int limit = 10,
  }) async {
    final String query = _buildQuery(title, artist);
    if (query.isEmpty) {
      return const <MetadataCandidate>[];
    }

    final Map<String, dynamic>? body = await fetchJsonMap(
      _dio,
      'https://c.y.qq.com/soso/fcgi-bin/client_search_cp',
      query: <String, Object?>{'p': 1, 'n': limit, 'w': query, 'format': 'json'},
      timeoutSeconds: 8,
    );
    if (body == null) {
      return const <MetadataCandidate>[];
    }

    final List<MetadataCandidate> results = <MetadataCandidate>[];
    for (final dynamic entry in _songList(body)) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }
      final String? songMid = entry['songmid'] as String?;
      final String? songName = entry['songname'] as String?;
      final String? albumMid = entry['albummid'] as String?;
      final String? albumName = entry['albumname'] as String?;
      if (songMid == null || songName == null || albumMid == null || albumName == null) {
        continue;
      }
      results.add(
        MetadataCandidate(
          provider: name,
          title: songName,
          artist: _firstSinger(entry),
          album: albumName,
          coverUrl: coverUrlForAlbumMid(albumMid),
          sourceId: songMid,
          duration: Duration(seconds: _seconds(entry['interval']).round()),
        ),
      );
    }
    return results;
  }

  /// QQ 音乐封面地址模板（800×800）。
  static String coverUrlForAlbumMid(String albumMid) =>
      'https://y.gtimg.cn/music/photo_new/T002R800x800M000$albumMid.jpg';

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

  static List<dynamic> _songList(Map<String, dynamic> body) {
    final Object? data = body['data'];
    if (data is! Map<String, dynamic>) {
      return const <dynamic>[];
    }
    final Object? song = data['song'];
    if (song is! Map<String, dynamic>) {
      return const <dynamic>[];
    }
    final Object? list = song['list'];
    return list is List<dynamic> ? list : const <dynamic>[];
  }

  static String _firstSinger(Map<String, dynamic> entry) {
    final Object? singers = entry['singer'];
    if (singers is List<dynamic> && singers.isNotEmpty) {
      final Object? first = singers.first;
      if (first is Map<String, dynamic>) {
        return first['name'] as String? ?? '';
      }
    }
    return '';
  }

  static double _seconds(Object? value) => value is num ? value.toDouble() : 0;
}
