import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/sources/http_retry.dart';
import 'package:tingyu/sources/source_adapter.dart';
import 'package:tingyu/sources/webdav/webdav_client.dart';

const String _username = 'fixture-user';
const String _password = 'fixture password';
const String _authorization = 'Basic Zml4dHVyZS11c2VyOmZpeHR1cmUgcGFzc3dvcmQ=';

void main() {
  test('真实 loopback HTTP：鉴权、中文路径、503/429 重试与完整扫描', () async {
    final List<_DavRequest> requests = <_DavRequest>[];
    int rootAttempts = 0;
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final StreamSubscription<HttpRequest> subscription = server.listen((
      HttpRequest request,
    ) async {
      final String body = await utf8.decoder.bind(request).join();
      final _DavRequest recorded = _DavRequest.from(request, body);
      requests.add(recorded);
      final String path = _decodedPath(request.uri);

      if (path == 'dav') {
        rootAttempts++;
        if (rootAttempts == 1) {
          await _sendText(
            request,
            HttpStatus.serviceUnavailable,
            'temporarily unavailable',
          );
          return;
        }
        if (rootAttempts == 2) {
          request.response.headers.set(HttpHeaders.retryAfterHeader, '0');
          await _sendText(request, HttpStatus.tooManyRequests, 'retry');
          return;
        }
        await _sendXml(
          request,
          _multistatus(<String>[
            _entry(href: '/dav/', displayName: 'dav', collection: true),
            _entry(
              href: '/dav/%E9%9F%B3%E4%B9%90/',
              displayName: '音乐',
              collection: true,
            ),
            _entry(
              href: '/dav/%23recycle/',
              displayName: '#recycle',
              collection: true,
            ),
            _entry(
              href: '/dav/cover.jpg',
              displayName: 'cover.jpg',
              length: 1024,
            ),
          ]),
        );
        return;
      }

      if (path == 'dav/音乐') {
        await _sendXml(
          request,
          _multistatus(<String>[
            _entry(
              href: '/dav/%E9%9F%B3%E4%B9%90/',
              displayName: '音乐',
              collection: true,
            ),
            _entry(
              href: '/dav/%E9%9F%B3%E4%B9%90/%E5%91%A8%E6%9D%B0%E4%BC%A6%20-%20%E5%A4%9C%E8%88%AA%20mix.flac',
              displayName: '周杰伦 - 夜航 mix.flac',
              length: 4096,
              etag: 'fixture-etag',
            ),
          ]),
        );
        return;
      }

      await _sendText(request, HttpStatus.notFound, 'unexpected path $path');
    });

    final Dio dio = Dio(BaseOptions(validateStatus: (int? _) => true));
    final WebDavClient client = WebDavClient(
      dio: dio,
      throttle: Duration.zero,
      retry: const HttpRetry(baseDelay: Duration.zero),
    );
    final Uri root = Uri.parse(
      'http://${InternetAddress.loopbackIPv4.address}:${server.port}/dav/',
    );

    try {
      final SourceScanResult result = await client.scan(
        rootUrl: root,
        sourceId: 'fixture-webdav',
        username: _username,
        password: _password,
      );

      expect(rootAttempts, 3);
      expect(requests.map((_DavRequest request) => request.path), <String>[
        'dav',
        'dav',
        'dav',
        'dav/音乐',
      ]);
      for (final _DavRequest request in requests) {
        expect(request.method, 'PROPFIND');
        expect(request.authorization, _authorization);
        expect(request.depth, anyOf('0', '1'));
        expect(request.body, WebDavClient.propfindBody);
      }

      expect(result.tracks, hasLength(1));
      final ScannedTrack track = result.tracks.single;
      expect(track.title, '夜航 mix');
      expect(track.artist, '周杰伦');
      expect(track.album, 'WebDAV 曲库');
      expect(track.fileFormat, 'flac');
      expect(track.fileSize, 4096);
      expect(track.etag, 'fixture-etag');
      expect(
        track.filePathOrUrl,
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}'
        '/dav/%E9%9F%B3%E4%B9%90/'
        '%E5%91%A8%E6%9D%B0%E4%BC%A6%20-%20%E5%A4%9C%E8%88%AA%20mix.flac',
      );
      expect(result.skipped, 0);
      expect(result.cancelled, isFalse);
      expect(result.truncated, isFalse);
      expect(result.isAuthoritative, isTrue);
    } finally {
      dio.close(force: true);
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('真实 loopback HTTP：子目录 403 只跳过该目录', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final StreamSubscription<HttpRequest> subscription = server.listen((
      HttpRequest request,
    ) async {
      await utf8.decoder.bind(request).join();
      final String path = _decodedPath(request.uri);
      if (path == 'dav') {
        await _sendXml(
          request,
          _multistatus(<String>[
            _entry(href: '/dav/', collection: true),
            _entry(
              href: '/dav/denied/',
              displayName: 'denied',
              collection: true,
            ),
            _entry(href: '/dav/one.mp3', displayName: 'one.mp3', length: 1),
            _entry(href: '/dav/two.mp3', displayName: 'two.mp3', length: 2),
          ]),
        );
        return;
      }
      if (path == 'dav/denied') {
        await _sendText(request, HttpStatus.forbidden, 'forbidden');
        return;
      }
      await _sendText(request, HttpStatus.notFound, 'unexpected path $path');
    });

    final Dio dio = Dio(BaseOptions(validateStatus: (int? _) => true));
    final WebDavClient client = WebDavClient(
      dio: dio,
      throttle: Duration.zero,
      retry: const HttpRetry(baseDelay: Duration.zero),
    );
    final Uri root = Uri.parse(
      'http://${InternetAddress.loopbackIPv4.address}:${server.port}/dav/',
    );

    try {
      final SourceScanResult result = await client.scan(
        rootUrl: root,
        sourceId: 'fixture-webdav',
        username: _username,
        password: _password,
      );

      expect(result.skipped, 1);
      expect(result.cancelled, isFalse);
      expect(result.tracks.map((ScannedTrack track) => track.title), <String>[
        'one',
        'two',
      ]);
      expect(result.isAuthoritative, isFalse);
    } finally {
      dio.close(force: true);
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('真实 loopback HTTP：取消只保留取消前的完整曲目边界', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final StreamSubscription<HttpRequest> subscription = server.listen((
      HttpRequest request,
    ) async {
      await utf8.decoder.bind(request).join();
      final String path = _decodedPath(request.uri);
      if (path == 'dav') {
        await _sendXml(
          request,
          _multistatus(<String>[
            _entry(href: '/dav/', collection: true),
            _entry(href: '/dav/one.mp3', displayName: 'one.mp3', length: 1),
            _entry(href: '/dav/two.mp3', displayName: 'two.mp3', length: 2),
          ]),
        );
        return;
      }
      await _sendText(request, HttpStatus.notFound, 'unexpected path $path');
    });

    final Dio dio = Dio(BaseOptions(validateStatus: (int? _) => true));
    final WebDavClient client = WebDavClient(
      dio: dio,
      throttle: Duration.zero,
      retry: const HttpRetry(baseDelay: Duration.zero),
    );
    bool cancel = false;
    final Uri root = Uri.parse(
      'http://${InternetAddress.loopbackIPv4.address}:${server.port}/dav/',
    );

    try {
      final SourceScanResult result = await client.scan(
        rootUrl: root,
        sourceId: 'fixture-webdav',
        username: _username,
        password: _password,
        onProgress: (int _, String _) => cancel = true,
        isCancelled: () => cancel,
      );

      expect(result.cancelled, isTrue);
      expect(result.tracks.map((ScannedTrack track) => track.title), <String>[
        'one',
      ]);
      expect(result.isAuthoritative, isFalse);
    } finally {
      dio.close(force: true);
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}

class _DavRequest {
  const _DavRequest({
    required this.method,
    required this.path,
    required this.depth,
    required this.authorization,
    required this.body,
  });

  factory _DavRequest.from(HttpRequest request, String body) => _DavRequest(
    method: request.method,
    path: _decodedPath(request.uri),
    depth: request.headers.value('Depth'),
    authorization: request.headers.value(HttpHeaders.authorizationHeader),
    body: body,
  );

  final String method;
  final String path;
  final String? depth;
  final String? authorization;
  final String body;
}

String _decodedPath(Uri uri) =>
    uri.pathSegments.where((String segment) => segment.isNotEmpty).join('/');

Future<void> _sendXml(HttpRequest request, String body) async {
  request.response.statusCode = HttpStatus.multiStatus;
  request.response.headers.contentType = ContentType(
    'application',
    'xml',
    charset: 'utf-8',
  );
  request.response.write(body);
  await request.response.close();
}

Future<void> _sendText(HttpRequest request, int status, String body) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.text;
  request.response.write(body);
  await request.response.close();
}

String _multistatus(List<String> entries) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">${entries.join()}</d:multistatus>';

String _entry({
  required String href,
  String? displayName,
  bool collection = false,
  int? length,
  String? etag,
}) {
  final StringBuffer buffer = StringBuffer('<d:response><d:href>')
    ..write(href)
    ..write('</d:href><d:propstat><d:prop>');
  if (displayName != null) {
    buffer.write(
      '<d:displayname>${const HtmlEscape().convert(displayName)}</d:displayname>',
    );
  }
  buffer.write(
    collection
        ? '<d:resourcetype><d:collection/></d:resourcetype>'
        : '<d:resourcetype/>',
  );
  if (length != null) {
    buffer.write('<d:getcontentlength>$length</d:getcontentlength>');
  }
  if (etag != null) {
    buffer.write('<d:getetag>"$etag"</d:getetag>');
  }
  buffer
    ..write('</d:prop><d:status>HTTP/1.1 200 OK</d:status>')
    ..write('</d:propstat></d:response>');
  return buffer.toString();
}
