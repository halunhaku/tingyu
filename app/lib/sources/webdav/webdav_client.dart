import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../../data/models/scanned_track.dart';
import '../local/local_library_scanner.dart';
import '../scraper/smart_title_parser.dart';
import '../source_adapter.dart';
import 'webdav_xml_parser.dart';

/// WebDAV 来源异常。
///
/// 文案与旧版 `WebDAVError.errorDescription` 逐字一致：迁移后用户看到的提示不能变，
/// 因此 [toString] 直接返回该文案（不像 Swift 那样走 `LocalizedError`）。
class WebDavException implements Exception {
  const WebDavException(this.message);

  /// 面向用户的完整文案。
  final String message;

  @override
  String toString() => message;
}

/// 401：账号或应用专用密码不对。
class WebDavUnauthorized extends WebDavException {
  const WebDavUnauthorized() : super('WebDAV 认证失败，请检查账号和应用专用密码');
}

/// 403：账号无权访问该目录。
class WebDavForbidden extends WebDavException {
  const WebDavForbidden() : super('WebDAV 拒绝访问该目录 (403 Forbidden)');
}

/// 429 / 503：服务端流控（坚果云专用文案）。
class WebDavRateLimited extends WebDavException {
  const WebDavRateLimited.temporaryFlowControl() : super(flowControlMessage);

  const WebDavRateLimited.blocked() : super(blockedMessage);

  /// 旧版 503 默认文案。
  static const String flowControlMessage = '坚果云提示请求过于频繁 (503 临时流控)，请等待 5-10 分钟自动解封';

  /// 响应体里带 `BlockedTemporarily` 时改用这条。
  static const String blockedMessage = '坚果云提示请求过于频繁（临时封禁中），请稍候 5-10 分钟自动解封';

  /// 对应 Swift 里 `String(data: data, encoding: .utf8)?.contains("BlockedTemporarily")`。
  static WebDavRateLimited forResponseBody(String? body) =>
      body != null && body.contains('BlockedTemporarily')
          ? const WebDavRateLimited.blocked()
          : const WebDavRateLimited.temporaryFlowControl();
}

/// 非 2xx 且非 401/403/429/503。
class WebDavServerError extends WebDavException {
  WebDavServerError(this.statusCode) : super('WebDAV 服务器返回错误 ($statusCode): HTTP $statusCode');

  final int statusCode;
}

/// 传输层失败（连接超时、断网、TLS 等）。
class WebDavNetworkError extends WebDavException {
  WebDavNetworkError(this.cause) : super('网络连接失败: ${_describe(cause)}');

  /// 原始错误，保留排查线索；文案只取其中的描述部分。
  final Object cause;

  static String _describe(Object error) => error is DioException ? error.message ?? error.toString() : error.toString();
}

/// WebDAV 客户端，对齐旧版 `Sources/Services/WebDAV/WebDAVClient.swift`。
///
/// 与旧版的差异：
/// - 传输层换成 dio（`URLSession` → `Dio`），错误类型从 `URLError` 变成 [DioException]；
///   非 2xx 通过 `validateStatus: (_) => true` 交给本类判定，语义与旧版一致。
/// - 旧版 `timeoutIntervalForRequest = 15s` 映射为 `connectTimeout`，
///   `timeoutIntervalForResource = 60s` 映射为 `receiveTimeout`。
/// - 新增可选的 `isCancelled`（旧版没有取消），供 `SourceAdapter.scan` 契约使用。
class WebDavClient {
  WebDavClient({Dio? dio, this.throttle = const Duration(milliseconds: 120)})
      : _dio = dio ?? _defaultDio();

  /// 旧版 `WebDAVClient.propfindBody`（Swift 多行字面量的缩进已被剥掉，这里逐字复刻）。
  static const String propfindBody = '<?xml version="1.0" encoding="utf-8"?>\n'
      '<d:propfind xmlns:d="DAV:">\n'
      '  <d:prop>\n'
      '    <d:displayname />\n'
      '    <d:resourcetype />\n'
      '    <d:getcontentlength />\n'
      '    <d:getcontenttype />\n'
      '    <d:getlastmodified />\n'
      '    <d:getetag />\n'
      '  </d:prop>\n'
      '</d:propfind>';

  static const WebDavXmlParser _parser = WebDavXmlParser();

  final Dio _dio;

  /// 每个目录请求之后的限流间隔；测试里可传 `Duration.zero`。
  /// 目录之间的限流间隔；旧版硬编码 120ms，这里可注入以便测试。
  final Duration throttle;

  static Dio _defaultDio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );

  /// 连接测试：`Depth: 0` 探测根目录，2xx 即成功。
  ///
  /// 与旧版的差异：旧版把 `URLError` 原样抛出，这里统一包成 [WebDavNetworkError]，
  /// 调用方只需处理 [WebDavException]。
  Future<bool> testConnection({
    required Uri url,
    required String username,
    required String password,
  }) async {
    final Response<Uint8List> response;
    try {
      response = await _propfind(url, depth: '0', authorization: basicAuthHeader(username, password));
    } on DioException catch (error) {
      throw WebDavNetworkError(error);
    }
    final int status = response.statusCode ?? 0;
    return status >= 200 && status <= 299;
  }

  /// 广度优先扫描整个 WebDAV 目录树。
  ///
  /// 只在 [maxDepth] 层内、最多 [maxFiles] 个音频文件；每个目录之间按 [throttle]
  /// 限流（旧版 120ms）。返回的曲目不含时长（远端拿不到，旧版同样写 0）。
  Future<SourceScanResult> scan({
    required Uri rootUrl,
    required String sourceId,
    required String username,
    required String password,
    int maxDepth = 8,
    int maxFiles = 5000,
    void Function(int done, String name)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final List<ScannedTrack> tracks = <ScannedTrack>[];
    final List<(Uri, int)> queue = <(Uri, int)>[(rootUrl, 0)];
    final String normalizedRootPath = normalizePath(rootUrl.path);
    final Set<String> visitedPaths = <String>{normalizedRootPath};
    final String authorization = basicAuthHeader(username, password);

    int skipped = 0;
    bool cancelled = false;

    while (!cancelled && queue.isNotEmpty && tracks.length < maxFiles) {
      final (Uri currentDirUrl, int depth) = queue.removeAt(0);
      if (depth > maxDepth) {
        continue;
      }
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }

      final Response<Uint8List> response;
      try {
        response = await _propfind(currentDirUrl, depth: '1', authorization: authorization);
      } on DioException catch (error) {
        // 根目录失败就整体失败；更深的目录只是被跳过。
        if (depth == 0) {
          throw WebDavNetworkError(error);
        }
        skipped++;
        continue;
      }

      final int status = response.statusCode ?? 0;
      final Uint8List body = response.data ?? Uint8List(0);

      if (status == 401) {
        throw const WebDavUnauthorized();
      }
      if (status == 403) {
        throw const WebDavForbidden();
      }
      if (status == 429 || status == 503) {
        throw WebDavRateLimited.forResponseBody(_decodeUtf8(body));
      }
      if (status < 200 || status > 299) {
        if (depth == 0) {
          throw WebDavServerError(status);
        }
        skipped++;
        continue;
      }

      // 目录之间温和限流，避免触发坚果云流控。
      await Future<void>.delayed(throttle);

      final List<WebDavItem> items;
      try {
        items = _parser.parse(_decodeUtf8(body));
      } on XmlException {
        // 旧版 XMLParser 解析失败时同样只是拿不到条目，不报错。
        skipped++;
        continue;
      }

      final String currentDirPath = normalizePath(currentDirUrl.path);
      for (final WebDavItem item in items) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }

        final Uri? itemUrl = resolveItemUrl(item.href, baseUrl: rootUrl, currentDirUrl: currentDirUrl);
        if (itemUrl == null) {
          continue;
        }

        final String itemPath = normalizePath(itemUrl.path);

        // 1. 跳过目录自身。
        if (itemPath == currentDirPath) {
          continue;
        }

        // 2. 严格边界：条目必须在 rootUrl 目录之内（拒绝父目录/兄弟目录）。
        if (!itemPath.startsWith(normalizedRootPath)) {
          continue;
        }

        // 3. 跳过垃圾/隐藏项（群晖 @eaDir、#recycle、.Trash 等）。
        final String lastSegment = lastPathSegment(itemUrl);
        if (lastSegment.startsWith('.') || lastSegment.startsWith('@') || lastSegment.startsWith('#')) {
          continue;
        }

        if (item.isDirectory) {
          if (!visitedPaths.contains(itemPath) && depth + 1 <= maxDepth) {
            visitedPaths.add(itemPath);
            queue.add((itemUrl, depth + 1));
          }
          continue;
        }

        final String extension = fileExtension(lastSegment).toLowerCase();
        if (!LocalLibraryScanner.supportedExtensions.contains(extension)) {
          continue;
        }

        // displayname 优先；缺失或全空白时退回文件名（已是 percent-decoded）。
        final String displayName = item.displayName?.trim() ?? '';
        final String rawName = displayName.isNotEmpty ? displayName : fileNameStem(lastSegment);

        final ParsedSongInfo parsed = SmartTitleParser.parse(rawName);
        onProgress?.call(tracks.length + 1, parsed.title);

        tracks.add(
          ScannedTrack(
            filePathOrUrl: itemUrl.toString(),
            title: parsed.title,
            artist: parsed.artist,
            album: parsed.album == ScannedTrack.unknownAlbum ? 'WebDAV 曲库' : parsed.album,
            duration: 0,
            fileFormat: extension,
            fileSize: item.contentLength,
            etag: item.etag,
          ),
        );

        if (tracks.length >= maxFiles) {
          break;
        }
      }
    }

    return SourceScanResult(tracks: tracks, skipped: skipped, cancelled: cancelled);
  }

  /// 规范化目录路径：percent-decode → 去首尾斜杠 → 包成 `/x/y/`。
  ///
  /// 修正了一处旧版缺陷：根路径 `/` 在旧实现里会得到 `//`，导致"从服务器根目录扫描"
  /// 时所有条目都过不了前缀边界检查，扫描静默返回空结果（旧版对
  /// `https://dav.jianguoyun.com/dav/` 这类带路径的根目录不受影响）。
  static String normalizePath(String path) {
    final String decoded = _percentDecode(path);
    final String trimmed = decoded.replaceFirst(RegExp(r'^/+'), '').replaceFirst(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? '/' : '/$trimmed/';
  }

  /// 旧版 `resolveItemUrl`：href 可能是绝对 URL、站绝对路径或相对路径。
  ///
  /// 与旧版的差异：旧版用 `addingPercentEncoding` 手工补编码（含 `%` 时额外放行 `%`），
  /// 这里直接交给 Dart 的 `Uri` —— 它同样只转义非法字符，并且会保留已有的 `%XX` 转义
  /// （不需要 `%` 特例）。无法解析时与旧版一样返回 `null`，调用方跳过该条目。
  static Uri? resolveItemUrl(String href, {required Uri baseUrl, required Uri currentDirUrl}) {
    final String clean = href.trim();
    if (clean.isEmpty) {
      return null;
    }

    // 已经是完整的绝对 URL。
    final Uri? direct = Uri.tryParse(clean);
    if (direct != null && direct.hasScheme) {
      return direct;
    }

    if (clean.startsWith('/')) {
      final String scheme = baseUrl.scheme.isEmpty ? 'http' : baseUrl.scheme;
      final String authority = baseUrl.hasPort ? '$scheme://${baseUrl.host}:${baseUrl.port}' : '$scheme://${baseUrl.host}';
      return Uri.tryParse('$authority$clean');
    }
    try {
      return currentDirUrl.resolve(clean);
    } on FormatException {
      return null;
    }
  }

  /// 旧版 `basicAuthHeader`。
  static String basicAuthHeader(String username, String password) =>
      'Basic ${base64.encode(utf8.encode('$username:$password'))}';

  /// 末段文件名（percent-decoded）；目录 URL 的结尾 `/` 不算一段。
  static String lastPathSegment(Uri uri) {
    final List<String> segments = uri.pathSegments;
    for (int index = segments.length - 1; index >= 0; index--) {
      if (segments[index].isNotEmpty) {
        return segments[index];
      }
    }
    return '';
  }

  /// 文件名去掉最后一段扩展名（旧版 `deletingPathExtension().lastPathComponent`）。
  static String fileNameStem(String segment) {
    final int dot = segment.lastIndexOf('.');
    return dot > 0 ? segment.substring(0, dot) : segment;
  }

  /// 扩展名（不含点），取不到时返回空串（旧版 `pathExtension`）。
  static String fileExtension(String segment) {
    final int dot = segment.lastIndexOf('.');
    return dot > 0 && dot < segment.length - 1 ? segment.substring(dot + 1) : '';
  }

  Future<Response<Uint8List>> _propfind(Uri url, {required String depth, required String authorization}) {
    return _dio.request<Uint8List>(
      url.toString(),
      data: propfindBody,
      options: Options(
        method: 'PROPFIND',
        contentType: 'application/xml; charset=utf-8',
        responseType: ResponseType.bytes,
        // 状态码全部交给自己判定，语义与旧版一致。
        validateStatus: (int? status) => true,
        headers: <String, dynamic>{
          'Depth': depth,
          'Authorization': authorization,
        },
      ),
    );
  }

  /// 旧版 `String(data:, encoding: .utf8)`：这里宽松解码，非法字节退化成 U+FFFD。
  static String _decodeUtf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

  static String _percentDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      // 旧版 `removingPercentEncoding ?? path`：转义非法时原样返回。
      return value;
    }
  }
}
