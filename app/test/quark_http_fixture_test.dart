import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/sources/http_retry.dart';
import 'package:tingyu/sources/quark/quark_drive_client.dart';
import 'package:tingyu/sources/quark/quark_session.dart';

void main() {
  test('真实 loopback HTTP：夸克分页、Cookie 刷新与直链接口契约', () async {
    final List<_QuarkRequest> requests = <_QuarkRequest>[];
    int rootAttempts = 0;
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final StreamSubscription<HttpRequest> subscription = server.listen((
      HttpRequest request,
    ) async {
      final String body = await utf8.decoder.bind(request).join();
      requests.add(_QuarkRequest.from(request, body));
      final String path = _decodedPath(request.uri);

      if (path == 'pc/1/clouddrive/file/sort') {
        final String fid = request.uri.queryParameters['pdir_fid']!;
        if (fid == '0' && rootAttempts++ == 0) {
          request.response.headers.set(
            HttpHeaders.setCookieHeader,
            '__puus=fresh; Path=/',
          );
          await _sendJson(request, <String, Object?>{
            'status': HttpStatus.tooManyRequests,
            'message': 'fixture retry',
          }, statusCode: HttpStatus.tooManyRequests);
          return;
        }

        final List<Map<String, Object?>> list = fid == '0'
            ? <Map<String, Object?>>[
                <String, Object?>{
                  'fid': 'folder-1',
                  'file_name': '巡演现场',
                  'file_type': 0,
                },
                <String, Object?>{
                  'fid': 'root-audio',
                  'file_name': '周杰伦 - 晴天.mp3',
                  'file_type': 1,
                  'size': 4096,
                  'format_type': 'mp3',
                },
                <String, Object?>{
                  'fid': 'cover-only',
                  'file_name': 'cover.jpg',
                  'file_type': 1,
                  'size': 1024,
                },
              ]
            : <Map<String, Object?>>[
                <String, Object?>{
                  'fid': 'nested-audio',
                  'file_name': '园游会 - 周杰伦 - 叶惠美.flac',
                  'file_type': 1,
                  'size': 8192,
                  'format_type': 'flac',
                },
              ];
        await _sendJson(request, <String, Object?>{
          'status': HttpStatus.ok,
          'data': <String, Object?>{'list': list, 'total': list.length},
        });
        return;
      }

      if (path == 'pc/1/clouddrive/file/download' && request.method == 'POST') {
        await _sendJson(request, <String, Object?>{
          'status': HttpStatus.ok,
          'data': <String, Object?>{
            'download_url':
                'http://${InternetAddress.loopbackIPv4.address}:${server.port}/audio/fixture.wav',
          },
        });
        return;
      }

      await _sendJson(request, <String, Object?>{
        'status': 404,
        'message': 'unexpected $path',
      }, statusCode: HttpStatus.notFound);
    });

    final Uri pcBase = Uri.parse(
      'http://${InternetAddress.loopbackIPv4.address}:${server.port}/pc/',
    );
    final Uri cdnBase = Uri.parse(
      'http://${InternetAddress.loopbackIPv4.address}:${server.port}/cdn/',
    );
    final Dio dio = Dio(BaseOptions(validateStatus: (int? _) => true));
    final QuarkDriveClient client = QuarkDriveClient(
      dio: dio,
      folderDelay: Duration.zero,
      retry: const HttpRetry(baseDelay: Duration.zero),
      pcBaseUrl: pcBase,
      cdnBaseUrl: cdnBase,
    );
    final QuarkSession session = QuarkSession(
      cookieJar: QuarkCookieJar.parse('session=abc; __puus=stale'),
    );

    try {
      final QuarkScanResult result = await client.scan(
        folderFid: '0',
        sourceId: 'fixture-quark',
        session: session,
        maxDepth: 2,
        maxFiles: 50,
      );

      expect(rootAttempts, 2);
      expect(
        result.tracks.map((ScannedTrack track) => track.filePathOrUrl),
        <String>['quark://root-audio', 'quark://nested-audio'],
      );
      expect(result.tracks.first.title, '晴天');
      expect(result.tracks.first.artist, '周杰伦');
      expect(result.tracks.last.title, '园游会');
      expect(result.tracks.last.album, '叶惠美');
      expect(result.cancelled, isFalse);
      expect(result.truncated, isFalse);
      expect(session.cookieHeader, 'session=abc; __puus=fresh');

      final Uri download = await client.getDownloadUrl('root-audio', session);
      expect(download.path, '/audio/fixture.wav');

      final Iterable<_QuarkRequest> sortRequests = requests.where(
        (_QuarkRequest request) => request.path == 'pc/1/clouddrive/file/sort',
      );
      expect(sortRequests, hasLength(3));
      for (final _QuarkRequest request in requests) {
        expect(request.path.startsWith('cdn/'), isFalse);
        expect(request.cookie, contains('session=abc'));
        expect(request.userAgent, QuarkDriveClient.userAgent);
        expect(request.referer, 'https://pan.quark.cn/');
        expect(request.origin, 'https://pan.quark.cn');
      }
      expect(
        requests.where(
          (_QuarkRequest request) =>
              request.path == 'pc/1/clouddrive/file/download',
        ),
        hasLength(1),
      );

      final _QuarkRequest rootRequest = sortRequests.first;
      expect(rootRequest.queryParameters['pdir_fid'], '0');
      expect(rootRequest.queryParameters['_page'], '1');
      expect(rootRequest.queryParameters['_size'], '100');

      final _QuarkRequest downloadRequest = requests.singleWhere(
        (_QuarkRequest request) =>
            request.path == 'pc/1/clouddrive/file/download',
      );
      expect(downloadRequest.method, 'POST');
      expect(
        downloadRequest.headers[HttpHeaders.contentTypeHeader],
        'application/json;charset=UTF-8',
      );
      expect(jsonDecode(downloadRequest.body), <String, Object?>{
        'fids': <String>['root-audio'],
      });
      expect(downloadRequest.cookie, 'session=abc; __puus=fresh');
    } finally {
      dio.close(force: true);
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}

class _QuarkRequest {
  const _QuarkRequest({
    required this.method,
    required this.path,
    required this.queryParameters,
    required this.headers,
    required this.body,
  });

  factory _QuarkRequest.from(HttpRequest request, String body) {
    return _QuarkRequest(
      method: request.method,
      path: _decodedPath(request.uri),
      queryParameters: request.uri.queryParameters,
      headers: _readHeaders(request.headers),
      body: body,
    );
  }

  final String method;
  final String path;
  final Map<String, String> queryParameters;
  final Map<String, String> headers;
  final String body;

  String? get cookie => headers[HttpHeaders.cookieHeader];
  String? get userAgent => headers[HttpHeaders.userAgentHeader];
  String? get referer => headers[HttpHeaders.refererHeader];
  String? get origin => headers['origin'];
}

Map<String, String> _readHeaders(HttpHeaders headers) {
  final Map<String, String> values = <String, String>{};
  headers.forEach((String name, List<String> headerValues) {
    values[name.toLowerCase()] = headerValues.join(', ');
  });
  return values;
}

String _decodedPath(Uri uri) =>
    uri.pathSegments.where((String segment) => segment.isNotEmpty).join('/');

Future<void> _sendJson(
  HttpRequest request,
  Object body, {
  int statusCode = HttpStatus.ok,
}) async {
  request.response.statusCode = statusCode;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}
