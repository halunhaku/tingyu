import 'package:dio/dio.dart';

import 'metadata_provider.dart';

/// iTunes Search API（对齐 `Sources/Services/Scraper/iTunesCoverScraper.swift`）。
///
/// 用途：封面的最后兜底（中文曲库命中率不高，但英文/国际专辑效果好）。
/// 注意：该接口返回 `text/javascript`，必须走 [fetchJsonMap] 自行解析。
class ITunesCoverProvider implements CoverLookup {
  ITunesCoverProvider({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
              ),
            );

  @override
  String get name => 'itunes';

  final Dio _dio;

  @override
  Future<String?> coverUrl({required String album, String artist = ''}) async {
    final String cleanAlbum = album.trim();
    if (cleanAlbum.isEmpty || cleanAlbum == '未知专辑') {
      return null;
    }
    final String cleanArtist = artist.trim();
    final String term = (cleanArtist.isEmpty || cleanArtist == '未知艺术家')
        ? cleanAlbum
        : '$cleanAlbum $cleanArtist';

    final Map<String, dynamic>? body = await fetchJsonMap(
      _dio,
      'https://itunes.apple.com/search',
      query: <String, Object?>{'term': term, 'entity': 'album', 'limit': 1},
      timeoutSeconds: 15,
    );
    final Object? results = body?['results'];
    if (results is! List<dynamic> || results.isEmpty) {
      return null;
    }
    final Object? first = results.first;
    if (first is! Map<String, dynamic>) {
      return null;
    }
    final String? artworkUrl = first['artworkUrl100'] as String?;
    if (artworkUrl == null || artworkUrl.isEmpty) {
      return null;
    }
    return highResolutionUrl(artworkUrl);
  }

  /// iTunes 返回 100×100 缩略图地址，替换尺寸段即得到大图。
  static String highResolutionUrl(String artworkUrl100) =>
      artworkUrl100.replaceAll('100x100bb', '600x600bb');
}
