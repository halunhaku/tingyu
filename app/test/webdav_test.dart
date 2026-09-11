import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/sources/source_adapter.dart';
import 'package:tingyu/sources/webdav/webdav_client.dart';
import 'package:tingyu/sources/webdav/webdav_source_adapter.dart';
import 'package:tingyu/sources/webdav/webdav_xml_parser.dart';

const String _baseUrl = 'https://dav.example.com:8443/dav/';

const String _username = 'user';

const String _password = 'p@ss word';

const String _authHeader = 'Basic dXNlcjpwQHNzIHdvcmQ=';

Uri get _rootUri => Uri.parse(_baseUrl);

/// 固定的路由响应（不碰外网）。
class _FakeResponse {
  const _FakeResponse(this.status, this.body);

  final int status;

  final String body;
}

/// 记录请求并按路径返回固定响应的 [HttpClientAdapter]。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.routes);

  /// key 是路径（如 `/dav/Music/`）；未配置的路径直接抛错，方便发现越界请求。
  final Map<String, _FakeResponse> routes;

  final List<RequestOptions> requests = <RequestOptions>[];

  /// 返回非 null 时该请求以传输层错误结束。
  DioException? Function(RequestOptions options)? failure;

  List<String> get requestedPaths => requests.map((RequestOptions options) => options.uri.path).toList();

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final DioException? error = failure?.call(options);
    if (error != null) {
      throw error;
    }
    final _FakeResponse? route = routes[options.uri.path];
    if (route == null) {
      throw StateError('测试未配置路由: ${options.method} ${options.uri.path}');
    }
    return ResponseBody.fromString(route.body, route.status, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/xml; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

WebDavClient _client(_FakeAdapter adapter, {Duration throttle = Duration.zero}) =>
    WebDavClient(dio: Dio()..httpClientAdapter = adapter, throttle: throttle);

Future<SourceScanResult> _scan(
  WebDavClient client, {
  int maxDepth = 8,
  int maxFiles = 5000,
  void Function(int done, String name)? onProgress,
  bool Function()? isCancelled,
}) =>
    client.scan(
      rootUrl: _rootUri,
      sourceId: 'webdav-1',
      username: _username,
      password: _password,
      maxDepth: maxDepth,
      maxFiles: maxFiles,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );

String _entry({
  required String href,
  String? displayName,
  bool collection = false,
  int? length,
  String? etag,
  String? lastModified,
}) {
  final StringBuffer buffer = StringBuffer('<d:response><d:href>')..write(href)..write('</d:href><d:propstat><d:prop>');
  if (displayName != null) {
    buffer.write('<d:displayname>$displayName</d:displayname>');
  }
  buffer.write(collection ? '<d:resourcetype><d:collection/></d:resourcetype>' : '<d:resourcetype/>');
  if (length != null) {
    buffer.write('<d:getcontentlength>$length</d:getcontentlength>');
  }
  if (etag != null) {
    buffer.write('<d:getetag>"$etag"</d:getetag>');
  }
  if (lastModified != null) {
    buffer.write('<d:getlastmodified>$lastModified</d:getlastmodified>');
  }
  buffer.write('<d:getcontenttype>application/octet-stream</d:getcontenttype>');
  buffer.write('</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>');
  return buffer.toString();
}

String _multistatus(List<String> entries) =>
    '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">${entries.join()}</d:multistatus>';

/// 真实服务器会出现的 multistatus：collection + 文件、带引号 etag、percent-encoded 中文 href。
const String _sampleXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>/dav/</d:displayname>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/Music/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Music</d:displayname>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/Music/%E6%99%B4%E5%A4%A9-%E5%91%A8%E6%9D%B0%E4%BC%A6.mp3</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>晴天-周杰伦.mp3</d:displayname>
        <d:resourcetype />
        <d:getcontentlength>5242880</d:getcontentlength>
        <d:getcontenttype>audio/mpeg</d:getcontenttype>
        <d:getlastmodified>Fri, 12 Sep 2025 03:04:05 GMT</d:getlastmodified>
        <d:getetag>"etag-1"</d:getetag>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/Music/only-href.mp3</d:href>
    <d:propstat>
      <d:prop />
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>   </d:href>
    <d:propstat>
      <d:prop />
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

void main() {
  group('WebDavXmlParser', () {
    test('解析带命名空间的 multistatus（collection / 引号 etag / 中文 href）', () {
      final List<WebDavItem> items = const WebDavXmlParser().parse(_sampleXml);

      // 空 href 的条目按旧版丢弃。
      expect(items, hasLength(4));

      expect(items[0].href, '/dav/');
      expect(items[0].isDirectory, isTrue);
      expect(items[0].contentLength, 0);
      expect(items[0].etag, isNull);

      expect(items[1].href, '/dav/Music/');
      expect(items[1].displayName, 'Music');
      expect(items[1].isDirectory, isTrue);

      final WebDavItem file = items[2];
      expect(file.href, '/dav/Music/%E6%99%B4%E5%A4%A9-%E5%91%A8%E6%9D%B0%E4%BC%A6.mp3');
      expect(file.displayName, '晴天-周杰伦.mp3');
      expect(file.isDirectory, isFalse);
      expect(file.contentLength, 5242880);
      expect(file.etag, 'etag-1');
      expect(file.lastModified, 'Fri, 12 Sep 2025 03:04:05 GMT');

      // 属性缺失时与旧版一致地取默认值。
      expect(items[3].href, '/dav/Music/only-href.mp3');
      expect(items[3].displayName, isNull);
      expect(items[3].etag, isNull);
      expect(items[3].contentLength, 0);
    });

    test('忽略前缀大小写与默认命名空间', () {
      const String upper = '<?xml version="1.0" encoding="utf-8"?>'
          '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/dav/a.mp3</D:href>'
          '<D:propstat><D:prop><D:getetag>"e"</D:getetag></D:prop></D:propstat>'
          '</D:response></D:multistatus>';
      const String plain = '<?xml version="1.0" encoding="utf-8"?>'
          '<multistatus xmlns="DAV:">'
          '<response><href>/dav/b/</href>'
          '<propstat><prop><resourcetype><collection/></resourcetype></prop></propstat>'
          '</response></multistatus>';

      const WebDavXmlParser parser = WebDavXmlParser();

      expect(parser.parse(upper).single.etag, 'e');
      expect(parser.parse(upper).single.href, '/dav/a.mp3');
      expect(parser.parse(plain).single.isDirectory, isTrue);
    });
  });

  group('href 解析与路径规范化', () {
    final Uri root = _rootUri;
    final Uri currentDir = Uri.parse('${_baseUrl}Music/');

    test('已是绝对 URL 时原样使用', () {
      expect(
        WebDavClient.resolveItemUrl('https://cdn.example.com/music/a%20b.mp3', baseUrl: root, currentDirUrl: currentDir)?.toString(),
        'https://cdn.example.com/music/a%20b.mp3',
      );
    });

    test('站绝对路径拼 scheme + host + port，中文与空格补编码', () {
      expect(
        WebDavClient.resolveItemUrl('/dav/Music/中文 歌.mp3', baseUrl: root, currentDirUrl: currentDir)?.toString(),
        'https://dav.example.com:8443/dav/Music/%E4%B8%AD%E6%96%87%20%E6%AD%8C.mp3',
      );
      expect(
        WebDavClient.resolveItemUrl('/dav/a%20b.mp3', baseUrl: root, currentDirUrl: currentDir)?.toString(),
        'https://dav.example.com:8443/dav/a%20b.mp3',
      );
      expect(
        WebDavClient.resolveItemUrl('/dav/x.mp3', baseUrl: Uri.parse('https://dav.example.com/dav/'), currentDirUrl: currentDir)?.toString(),
        'https://dav.example.com/dav/x.mp3',
      );
    });

    test('相对路径按当前目录解析', () {
      expect(
        WebDavClient.resolveItemUrl('Deep/Finale.mp3', baseUrl: root, currentDirUrl: currentDir)?.toString(),
        'https://dav.example.com:8443/dav/Music/Deep/Finale.mp3',
      );
      expect(
        WebDavClient.resolveItemUrl('../other/a.mp3', baseUrl: root, currentDirUrl: currentDir)?.toString(),
        'https://dav.example.com:8443/dav/other/a.mp3',
      );
    });

    test('空 href 返回 null', () {
      expect(WebDavClient.resolveItemUrl('   ', baseUrl: root, currentDirUrl: currentDir), isNull);
    });

    test('normalizePath 先 percent-decode 再去首尾斜杠', () {
      expect(WebDavClient.normalizePath('/dav/%E4%B8%AD%E6%96%87/'), '/dav/中文/');
      expect(WebDavClient.normalizePath('dav'), '/dav/');
      expect(WebDavClient.normalizePath('/dav/'), '/dav/');
      // 旧版这里得到 "//"，会让"从服务器根目录扫描"静默失败；本实现修正为 '/'。
      expect(WebDavClient.normalizePath('/'), '/');
      expect(WebDavClient.normalizePath(''), '/');
      expect(WebDavClient.normalizePath('///'), '/');
    });
  });

  group('WebDavClient.scan', () {
    late _FakeAdapter adapter;

    setUp(() {
      adapter = _FakeAdapter(<String, _FakeResponse>{
        '/dav/': _FakeResponse(
          200,
          _multistatus(<String>[
            _entry(href: '/dav/', displayName: '/dav/', collection: true),
            _entry(href: '/dav/Music/', displayName: 'Music', collection: true),
            _entry(href: '/dav/@eaDir/', displayName: '@eaDir', collection: true),
            _entry(href: '/dav/%23recycle/', displayName: '#recycle', collection: true),
            _entry(href: '/dav/.Trash/', displayName: '.Trash', collection: true),
            _entry(href: '/other/loose.mp3', displayName: 'loose.mp3', length: 4096, etag: 'out'),
            _entry(href: '/dav/.hidden.mp3', displayName: '.hidden.mp3', length: 4096),
            _entry(href: '/dav/cover.jpg', displayName: 'cover.jpg', length: 4096),
          ]),
        ),
        '/dav/Music/': _FakeResponse(
          200,
          _multistatus(<String>[
            _entry(href: '/dav/Music/', displayName: 'Music', collection: true),
            _entry(
              href: '/dav/Music/%E6%99%B4%E5%A4%A9-%E5%91%A8%E6%9D%B0%E4%BC%A6.mp3',
              displayName: ' 晴天-周杰伦.mp3 ',
              length: 5242880,
              etag: 'etag-1',
              lastModified: 'Fri, 12 Sep 2025 03:04:05 GMT',
            ),
            _entry(href: '/dav/Music/%E4%B8%AD%E6%96%87%E6%AD%8C.mp3', length: 1048576),
            _entry(href: 'https://dav.example.com:8443/dav/Music/Deep/', displayName: 'Deep', collection: true),
            _entry(href: '/dav/Music/notes.txt', displayName: 'notes.txt', length: 12),
          ]),
        ),
        '/dav/Music/Deep/': _FakeResponse(
          200,
          _multistatus(<String>[
            _entry(href: 'Finale.mp3', length: 2048),
          ]),
        ),
      });
    });

    test('PROPFIND 请求形态：Depth/Content-Type/Authorization 与请求体', () async {
      await _scan(_client(adapter));

      expect(adapter.requests, isNotEmpty);
      for (final RequestOptions options in adapter.requests) {
        expect(options.method, 'PROPFIND');
        expect(options.headers['Depth'], '1');
        expect(options.headers[Headers.contentTypeHeader], 'application/xml; charset=utf-8');
        expect(options.headers['Authorization'], _authHeader);
        expect(options.data, WebDavClient.propfindBody);
      }
      expect(WebDavClient.propfindBody, contains('<d:getcontentlength />'));
      expect(WebDavClient.propfindBody, contains('<d:getetag />'));
      expect(WebDavClient.propfindBody, contains('<d:resourcetype />'));
    });

    test('BFS 扫描：边界、跳过规则与曲目构造', () async {
      final List<String> progress = <String>[];
      final SourceScanResult result = await _scan(
        _client(adapter),
        onProgress: (int done, String name) => progress.add('$done:$name'),
      );

      // @eaDir / #recycle / .Trash 从未被请求，说明没被当成目录递归。
      expect(adapter.requestedPaths, <String>['/dav/', '/dav/Music/', '/dav/Music/Deep/']);
      expect(result.skipped, 0);
      expect(result.cancelled, isFalse);

      expect(result.tracks.map((ScannedTrack track) => track.filePathOrUrl).toList(), <String>[
        'https://dav.example.com:8443/dav/Music/%E6%99%B4%E5%A4%A9-%E5%91%A8%E6%9D%B0%E4%BC%A6.mp3',
        'https://dav.example.com:8443/dav/Music/%E4%B8%AD%E6%96%87%E6%AD%8C.mp3',
        'https://dav.example.com:8443/dav/Music/Deep/Finale.mp3',
      ]);

      final ScannedTrack first = result.tracks[0];
      expect(first.title, '晴天');
      expect(first.artist, '周杰伦');
      expect(first.album, 'WebDAV 曲库');
      expect(first.duration, 0);
      expect(first.fileFormat, 'mp3');
      expect(first.fileSize, 5242880);
      expect(first.etag, 'etag-1');

      // displayname 缺失时回退到 percent-decoded 文件名。
      expect(result.tracks[1].title, '中文歌');
      expect(result.tracks[1].artist, ScannedTrack.unknownArtist);
      expect(result.tracks[1].album, 'WebDAV 曲库');
      expect(result.tracks[1].etag, isNull);

      expect(result.tracks[2].title, 'Finale');
      expect(result.tracks[2].fileSize, 2048);

      expect(progress, <String>['1:晴天', '2:中文歌', '3:Finale']);
    });

    test('maxDepth 限制递归层级', () async {
      final SourceScanResult result = await _scan(_client(adapter), maxDepth: 0);

      expect(adapter.requestedPaths, <String>['/dav/']);
      expect(result.tracks, isEmpty);
    });

    test('maxFiles 截断已发现的曲目', () async {
      final SourceScanResult result = await _scan(_client(adapter), maxFiles: 1);

      expect(adapter.requestedPaths, <String>['/dav/', '/dav/Music/']);
      expect(result.tracks.map((ScannedTrack track) => track.title).toList(), <String>['晴天']);
    });

    test('isCancelled 立刻返回且不发起请求', () async {
      final SourceScanResult result = await _scan(_client(adapter), isCancelled: () => true);

      expect(result.cancelled, isTrue);
      expect(result.tracks, isEmpty);
      expect(adapter.requests, isEmpty);
    });

    test('每个目录之间沿用旧版 120ms 限流', () async {
      final Stopwatch watch = Stopwatch()..start();
      await _scan(WebDavClient(dio: Dio()..httpClientAdapter = adapter));
      watch.stop();

      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(100));
    });
  });

  group('错误映射', () {
    test('401 → WebDavUnauthorized', () async {
      final _FakeAdapter adapter = _FakeAdapter(<String, _FakeResponse>{'/dav/': const _FakeResponse(401, '')});

      await expectLater(
        _scan(_client(adapter)),
        throwsA(
          isA<WebDavUnauthorized>().having(
            (WebDavUnauthorized error) => error.message,
            'message',
            'WebDAV 认证失败，请检查账号和应用专用密码',
          ),
        ),
      );
    });

    test('403 → WebDavForbidden', () async {
      final _FakeAdapter adapter = _FakeAdapter(<String, _FakeResponse>{'/dav/': const _FakeResponse(403, '')});

      await expectLater(
        _scan(_client(adapter)),
        throwsA(
          isA<WebDavForbidden>().having(
            (WebDavForbidden error) => error.message,
            'message',
            'WebDAV 拒绝访问该目录 (403 Forbidden)',
          ),
        ),
      );
    });

    test('429 → 默认流控文案', () async {
      final _FakeAdapter adapter = _FakeAdapter(<String, _FakeResponse>{'/dav/': const _FakeResponse(429, '')});

      await expectLater(
        _scan(_client(adapter)),
        throwsA(isA<WebDavRateLimited>().having((WebDavRateLimited error) => error.message, 'message', WebDavRateLimited.flowControlMessage)),
      );
    });

    test('503 且响应体不含 BlockedTemporarily → 临时流控文案', () async {
      final _FakeAdapter adapter = _FakeAdapter(<String, _FakeResponse>{
        '/dav/': const _FakeResponse(503, '<html><body>Service Unavailable</body></html>'),
      });

      await expectLater(
        _scan(_client(adapter)),
        throwsA(
          isA<WebDavRateLimited>().having(
            (WebDavRateLimited error) => error.message,
            'message',
            '坚果云提示请求过于频繁 (503 临时流控)，请等待 5-10 分钟自动解封',
          ),
        ),
      );
    });

    test('503 且响应体含 BlockedTemporarily → 临时封禁文案', () async {
      final _FakeAdapter adapter = _FakeAdapter(<String, _FakeResponse>{
        '/dav/': const _FakeResponse(503, '<error><code>BlockedTemporarily</code></error>'),
      });

      await expectLater(
        _scan(_client(adapter)),
        throwsA(
          isA<WebDavRateLimited>().having(
            (WebDavRateLimited error) => error.message,
            'message',
            '坚果云提示请求过于频繁（临时封禁中），请稍候 5-10 分钟自动解封',
          ),
        ),
      );
    });

    test('根目录 500 → WebDavServerError', () async {
      final _FakeAdapter adapter = _FakeAdapter(<String, _FakeResponse>{'/dav/': const _FakeResponse(500, '')});

      await expectLater(
        _scan(_client(adapter)),
        throwsA(
          isA<WebDavServerError>()
              .having((WebDavServerError error) => error.statusCode, 'statusCode', 500)
              .having((WebDavServerError error) => error.message, 'message', 'WebDAV 服务器返回错误 (500): HTTP 500'),
        ),
      );
    });

    test('子目录 500 → 跳过该目录但不中断扫描', () async {
      final _FakeAdapter adapter = _FakeAdapter(<String, _FakeResponse>{
        '/dav/': _FakeResponse(
          200,
          _multistatus(<String>[
            _entry(href: '/dav/', displayName: '/dav/', collection: true),
            _entry(href: '/dav/Broken/', displayName: 'Broken', collection: true),
            _entry(href: '/dav/ok.mp3', displayName: 'ok.mp3', length: 10, etag: 'ok'),
          ]),
        ),
        '/dav/Broken/': const _FakeResponse(500, ''),
      });

      final SourceScanResult result = await _scan(_client(adapter));

      expect(result.tracks.map((ScannedTrack track) => track.title).toList(), <String>['ok']);
      expect(result.skipped, 1);
    });

    test('根目录传输失败 → WebDavNetworkError；子目录失败只跳过', () async {
      final _FakeAdapter rootFailure = _FakeAdapter(<String, _FakeResponse>{'/dav/': const _FakeResponse(200, '')})
        ..failure = (RequestOptions options) => DioException.connectionError(requestOptions: options, reason: 'Connection refused');

      await expectLater(
        _scan(_client(rootFailure)),
        throwsA(
          isA<WebDavNetworkError>()
              .having((WebDavNetworkError error) => error.message, 'message', startsWith('网络连接失败: '))
              .having((WebDavNetworkError error) => error.message, 'message', contains('Connection refused')),
        ),
      );

      final _FakeAdapter childFailure = _FakeAdapter(<String, _FakeResponse>{
        '/dav/': _FakeResponse(
          200,
          _multistatus(<String>[
            _entry(href: '/dav/', displayName: '/dav/', collection: true),
            _entry(href: '/dav/Broken/', displayName: 'Broken', collection: true),
            _entry(href: '/dav/ok.mp3', displayName: 'ok.mp3', length: 10, etag: 'ok'),
          ]),
        ),
      })
        ..failure = (RequestOptions options) =>
            options.uri.path == '/dav/Broken/' ? DioException.connectionError(requestOptions: options, reason: 'Connection refused') : null;

      final SourceScanResult result = await _scan(_client(childFailure));

      expect(result.tracks.map((ScannedTrack track) => track.title).toList(), <String>['ok']);
      expect(result.skipped, 1);
    });

    test('异常 toString 返回与旧版逐字一致的中文文案', () {
      expect(const WebDavUnauthorized().toString(), 'WebDAV 认证失败，请检查账号和应用专用密码');
      expect(const WebDavForbidden().toString(), 'WebDAV 拒绝访问该目录 (403 Forbidden)');
      expect(const WebDavRateLimited.temporaryFlowControl().toString(), WebDavRateLimited.flowControlMessage);
      expect(const WebDavRateLimited.blocked().toString(), WebDavRateLimited.blockedMessage);
      expect(WebDavServerError(502).toString(), 'WebDAV 服务器返回错误 (502): HTTP 502');
      expect(WebDavNetworkError('超时').toString(), '网络连接失败: 超时');
    });
  });

  group('testConnection', () {
    test('Depth 0 探测，2xx 为 true', () async {
      final _FakeAdapter adapter = _FakeAdapter(<String, _FakeResponse>{'/dav/': const _FakeResponse(207, '')});

      expect(await _client(adapter).testConnection(url: _rootUri, username: _username, password: _password), isTrue);
      expect(adapter.requests.single.headers['Depth'], '0');
      expect(adapter.requests.single.headers['Authorization'], _authHeader);
    });

    test('非 2xx 为 false', () async {
      final _FakeAdapter adapter = _FakeAdapter(<String, _FakeResponse>{'/dav/': const _FakeResponse(401, '')});

      expect(await _client(adapter).testConnection(url: _rootUri, username: _username, password: _password), isFalse);
    });
  });

  group('WebDavSourceAdapter', () {
    late WebDavSourceAdapter adapter;

    setUp(() {
      adapter = WebDavSourceAdapter(
        sourceId: 'webdav-1',
        credentials: WebDavCredentials(rootUrl: _baseUrl, username: _username, password: _password),
      );
    });

    test('open() 产出带 Basic 鉴权头的 PlaybackItem', () async {
      const String url = 'https://dav.example.com:8443/dav/Music/%E4%B8%AD%E6%96%87%E6%AD%8C.mp3';

      final PlaybackItem item = await adapter.open(url);

      expect(item.httpHeaders['Authorization'], _authHeader);
      expect(item.uri.toString(), url);
      expect(item.id, url);
      expect(item.title, '中文歌.mp3');
    });

    test('scan() 用注入的 client，凭据来自 WebDavCredentials', () async {
      final _FakeAdapter http = _FakeAdapter(<String, _FakeResponse>{
        '/dav/': _FakeResponse(
          200,
          _multistatus(<String>[
            _entry(href: '/dav/', displayName: '/dav/', collection: true),
            _entry(href: '/dav/%E6%99%B4%E5%A4%A9.mp3', displayName: '晴天.mp3', length: 10),
          ]),
        ),
      });

      final SourceAdapter source = WebDavSourceAdapter(
        sourceId: 'webdav-1',
        credentials: WebDavCredentials(rootUrl: _baseUrl, username: _username, password: _password),
        client: WebDavClient(dio: Dio()..httpClientAdapter = http, throttle: Duration.zero),
      );

      final SourceScanResult result = await source.scan();

      expect(source.sourceId, 'webdav-1');
      expect(http.requests.single.headers['Authorization'], _authHeader);
      expect(result.tracks.single.title, '晴天');
      expect(result.tracks.single.filePathOrUrl, 'https://dav.example.com:8443/dav/%E6%99%B4%E5%A4%A9.mp3');
    });
  });
}
