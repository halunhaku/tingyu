import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models/scanned_track.dart';
import '../local/local_library_scanner.dart';
import '../scraper/smart_title_parser.dart';

/// 夸克网盘里的一个条目（目录或文件），对齐旧版 `QuarkItem`。
class QuarkItem {
  const QuarkItem({
    required this.id,
    required this.name,
    required this.isFolder,
    required this.size,
    required this.formatType,
  });

  /// 网盘内的 `fid`，播放地址形如 `quark://<fid>`。
  final String id;

  final String name;

  final bool isFolder;

  /// 字节数；目录恒为 0。
  final int size;

  /// 网盘给出的格式标记（如 `mp3`），缺失时目录回退 `dir`、文件回退 `file`。
  final String formatType;
}

/// 夸克来源异常的基类；`message` 与旧版 `QuarkError.errorDescription` 逐字一致。
sealed class QuarkException implements Exception {
  const QuarkException(this.message);

  /// 面向用户的提示文案。
  final String message;

  @override
  String toString() => message;
}

/// 登录凭据失效。
class QuarkUnauthenticated extends QuarkException {
  const QuarkUnauthenticated() : super('夸克网盘登录凭据已失效，请重新登录');
}

/// 请求过于频繁。
class QuarkRateLimited extends QuarkException {
  const QuarkRateLimited() : super('夸克网盘请求过于频繁，请稍候再试');
}

/// 网络或接口返回了非预期状态。
class QuarkNetworkError extends QuarkException {
  QuarkNetworkError(String detail) : super('夸克网络连接异常: $detail');
}

/// 响应结构与预期不符。
class QuarkParseError extends QuarkException {
  QuarkParseError(String detail) : super('夸克数据解析失败: $detail');
}

/// 一次递归扫描的结果。
class QuarkScanResult {
  const QuarkScanResult(this.tracks, {this.cancelled = false});

  final List<ScannedTrack> tracks;

  /// 调用方在扫描途中要求中止。
  final bool cancelled;
}

/// 夸克网盘 API 客户端，对齐旧版 `Sources/Services/Quark/QuarkDriveClient.swift`。
///
/// 只做「列目录 / 取直链 / 校验 Cookie」三件事，产出的都是事实数据：
/// 扫描结果交给 `SourceAdapter` 包装，播放交给播放引擎。
class QuarkDriveClient {
  QuarkDriveClient({
    Dio? dio,
    DateTime Function()? clock,
    Duration? folderDelay,
  })  : _dio = dio ?? Dio(_baseOptions()),
        _clock = clock ?? DateTime.now,
        folderDelay = folderDelay ?? defaultFolderDelay;

  /// 旧版 `URLSessionConfiguration.timeoutIntervalForRequest`。
  static const Duration requestTimeout = Duration(seconds: 20);

  /// 旧版 `URLSessionConfiguration.timeoutIntervalForResource`：整次传输的预算。
  static const Duration resourceTimeout = Duration(seconds: 90);

  /// 直链有效期，与旧版写入缓存时的 5400s 一致。
  static const Duration downloadUrlTtl = Duration(seconds: 5400);

  /// 目录之间的间隔，避免触发风控（旧版固定 80ms）。
  static const Duration defaultFolderDelay = Duration(milliseconds: 80);

  /// 占位专辑名（旧版字面量；同时出现在 [ScannedTrack.placeholderAlbums]）。
  static const String libraryAlbum = '夸克曲库';

  /// 与旧版 `QuarkDriveClient.userAgent` 逐字一致。
  static const String userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/3.23.0 Chrome/112.0.5615.165 Electron/23.3.13 Safari/537.36 Channel/pckk_other_ch';

  static const String _pcHost = 'https://drive-pc.quark.cn';

  static const String _cdnHost = 'https://drive.quark.cn';

  static const String _referer = 'https://pan.quark.cn/';

  static const String _origin = 'https://pan.quark.cn';

  static const String _acceptJson = 'application/json, text/plain, */*';

  /// 直链在响应里的候选字段，顺序即优先级。
  static const List<String> downloadUrlKeys = <String>[
    'download_url',
    'download_url_https',
    'downloadUrl',
    'url',
  ];

  /// 旧版用 ephemeral 配置：不落 Cookie 存储。Dio 侧在请求里显式带 Cookie，
  /// 连接/接收超时映射 `timeoutIntervalForRequest`，发送（整次传输）映射资源超时。
  static BaseOptions _baseOptions() => BaseOptions(
        connectTimeout: requestTimeout,
        receiveTimeout: requestTimeout,
        sendTimeout: resourceTimeout,
      );

  final Dio _dio;

  final DateTime Function() _clock;

  /// 目录之间的间隔；测试可传 [Duration.zero]。
  final Duration folderDelay;

  final Map<String, _CachedDownloadUrl> _downloadCache = <String, _CachedDownloadUrl>{};

  String? _refreshedPuus;

  /// CDN 直链需要的请求头；播放引擎原样带上即可（不与 API 头共用，Accept 不同）。
  static Map<String, String> playbackHeaders(String cookie) => <String, String>{
        'Cookie': cookie,
        'User-Agent': userAgent,
        'Referer': _referer,
        'Origin': _origin,
        'Accept': '*/*',
      };

  // MARK: - Cookie 校验

  /// 校验 Cookie 是否可用。
  ///
  /// 与旧版一致：任何失败（网络/状态码/结构）都返回 `isValid == false`，不抛异常。
  Future<({bool isValid, String nickname})> verifyCookie(String cookie) async {
    const String url =
        '$_pcHost/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=0&_page=1&_size=1';
    try {
      final _QuarkResponse response = await _send(url, cookie: cookie);
      if (response.statusCode != 200) {
        return (isValid: false, nickname: '');
      }
      final Map<String, dynamic>? json = response.json;
      if (json == null || _asInt(json['status']) != 200) {
        return (isValid: false, nickname: '');
      }
      return (isValid: true, nickname: '夸克用户');
    } on QuarkException {
      return (isValid: false, nickname: '');
    }
  }

  // MARK: - 目录与文件列举

  /// 列出目录内容；`fid == '0'` 表示根目录。
  ///
  /// 结构不符（缺 `data.list`、非 JSON）时返回空列表，与旧版一致。
  Future<List<QuarkItem>> listFolder({String fid = '0', required String cookie}) async {
    final String url =
        '$_pcHost/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=$fid&_page=1&_size=100&_fetch_total=1&_sort=file_type:asc,file_name:asc';

    final _QuarkResponse response = await _send(url, cookie: cookie);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw QuarkNetworkError('读取夸克文件列表失败 (HTTP ${response.statusCode})');
    }

    final Map<String, dynamic>? json = response.json;
    final Object? data = json?['data'];
    if (data is! Map<String, dynamic>) {
      return <QuarkItem>[];
    }
    final Object? list = data['list'];
    if (list is! List) {
      return <QuarkItem>[];
    }

    final List<QuarkItem> items = <QuarkItem>[];
    for (final Object? entry in list) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }
      final Object? id = entry['fid'];
      final Object? name = entry['file_name'];
      if (id is! String || name is! String) {
        continue;
      }
      final int fileType = _asInt(entry['file_type']) ?? 0; // 0 = 目录，1 = 文件
      final bool isFolder = fileType == 0;
      final Object? formatType = entry['format_type'];
      items.add(
        QuarkItem(
          id: id,
          name: name,
          isFolder: isFolder,
          size: _asInt(entry['size']) ?? 0,
          formatType: formatType is String ? formatType : (isFolder ? 'dir' : 'file'),
        ),
      );
    }
    return items;
  }

  // MARK: - 递归扫描音频

  /// 从 [folderFid] 起 BFS 扫描，产出曲目事实（不写库）。
  ///
  /// [maxDepth] / [maxFiles] 由调用方决定（旧版默认 5 / 5000）；
  /// [isCancelled] 在每层目录前检查，命中即停下并返回已扫到的曲目。
  Future<QuarkScanResult> scan({
    required String folderFid,
    required String sourceId,
    required String cookie,
    required int maxDepth,
    required int maxFiles,
    void Function(int done, String name)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final List<ScannedTrack> tracks = <ScannedTrack>[];
    final List<(String, int)> queue = <(String, int)>[(folderFid, 0)];
    final Set<String> visitedFids = <String>{};
    bool cancelled = false;

    while (queue.isNotEmpty && tracks.length < maxFiles) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final (String currentFid, int depth) = queue.removeAt(0);
      if (depth > maxDepth) {
        continue;
      }
      if (!visitedFids.add(currentFid)) {
        continue;
      }

      final List<QuarkItem> items = await listFolder(fid: currentFid, cookie: cookie);

      for (final QuarkItem item in items) {
        if (item.isFolder) {
          if (depth + 1 <= maxDepth && !visitedFids.contains(item.id)) {
            queue.add((item.id, depth + 1));
          }
          continue;
        }

        final String name = item.name;
        final int dot = name.lastIndexOf('.');
        if (dot <= 0) {
          continue; // 无扩展名（含 `.hidden` 这类）一律不算音频
        }
        final String ext = name.substring(dot + 1).toLowerCase();
        if (!LocalLibraryScanner.supportedExtensions.contains(ext)) {
          continue;
        }

        final ParsedSongInfo parsed = SmartTitleParser.parse(name.substring(0, dot));
        onProgress?.call(tracks.length + 1, parsed.title);

        tracks.add(
          ScannedTrack(
            filePathOrUrl: 'quark://${item.id}',
            title: parsed.title,
            artist: parsed.artist,
            album: parsed.album == ScannedTrack.unknownAlbum ? libraryAlbum : parsed.album,
            fileFormat: ext,
            fileSize: item.size,
          ),
        );

        if (tracks.length >= maxFiles) {
          break;
        }
      }

      // 目录之间的礼貌间隔，旧版为固定 80ms。
      await Future<void>.delayed(folderDelay);
    }

    return QuarkScanResult(tracks, cancelled: cancelled);
  }

  // MARK: - 直链解析

  /// 取音频播放直链：先 `drive-pc.quark.cn`，失败再退 `drive.quark.cn`。
  ///
  /// 结果按 fid 缓存 5400s（旧版只写不读，这里补上读取——否则每次播放都要打两次网盘）。
  Future<Uri> getDownloadUrl(String fid, String cookie) async {
    final String trimmedCookie = cookie.trim();
    if (trimmedCookie.isEmpty) {
      throw const QuarkUnauthenticated();
    }

    final _CachedDownloadUrl? cached = _downloadCache[fid];
    if (cached != null && cached.expiresAt.isAfter(_clock())) {
      return cached.uri;
    }

    final List<String> endpoints = <String>[
      '$_pcHost/1/clouddrive/file/download?pr=ucpro&fr=pc',
      '$_cdnHost/1/clouddrive/file/download?pr=ucpro&fr=pc',
    ];

    QuarkException lastError = QuarkParseError('获取下载直链失败');
    for (final String endpoint in endpoints) {
      try {
        final Uri downloadUrl = await _requestDownloadUrl(endpoint, fid: fid, cookie: trimmedCookie);
        _downloadCache[fid] = _CachedDownloadUrl(downloadUrl, _clock().add(downloadUrlTtl));
        return downloadUrl;
      } on QuarkException catch (error) {
        lastError = error;
        if (error is QuarkUnauthenticated) {
          rethrow;
        }
      }
    }
    throw lastError;
  }

  /// 把最新一次响应里刷新出来的 `__puus` 合并回 Cookie 串（旧版 `cookieWithRefreshedPuus`）。
  ///
  /// 没有刷新过时原样返回，调用方可以据此判断要不要写回安全存储。
  String latestCookie(String original) {
    final String? puus = _refreshedPuus;
    if (puus == null || puus.isEmpty) {
      return original;
    }
    final List<String> parts = original
        .split(';')
        .map((String part) => part.trim())
        .where((String part) => part.isNotEmpty && !part.startsWith('__puus='))
        .toList();
    parts.add('__puus=$puus');
    return parts.join('; ');
  }

  /// 从下载接口响应里取直链；兼容 `data[]`、`data{}`、`data.list[]` 三种形状。
  static Uri? extractDownloadURL(Map<String, dynamic> json) {
    Uri? fromEntry(Map<String, dynamic> entry) {
      for (final String key in downloadUrlKeys) {
        final Object? value = entry[key];
        if (value is! String || value.isEmpty) {
          continue;
        }
        final Uri? uri = Uri.tryParse(value);
        if (uri != null && uri.scheme.isNotEmpty) {
          return uri;
        }
      }
      return null;
    }

    Uri? fromList(Object? list) {
      if (list is! List) {
        return null;
      }
      for (final Object? entry in list) {
        if (entry is! Map<String, dynamic>) {
          continue;
        }
        final Uri? found = fromEntry(entry);
        if (found != null) {
          return found;
        }
      }
      return null;
    }

    final Object? data = json['data'];
    final Uri? fromArray = fromList(data);
    if (fromArray != null) {
      return fromArray;
    }
    if (data is Map<String, dynamic>) {
      final Uri? direct = fromEntry(data);
      if (direct != null) {
        return direct;
      }
      return fromList(data['list']);
    }
    return null;
  }

  Future<Uri> _requestDownloadUrl(String endpoint, {required String fid, required String cookie}) async {
    final _QuarkResponse response = await _send(
      endpoint,
      cookie: cookie,
      jsonBody: true,
      body: <String, dynamic>{'fids': <String>[fid]},
    );

    final Map<String, dynamic> json = response.json ?? const <String, dynamic>{};
    final int statusCode = response.statusCode;
    final int? apiStatus = _asInt(json['status']);
    final int? apiCode = _asInt(json['code']);
    final Object? message = json['message'];
    final String apiMessage = message is String ? message : '';

    if (statusCode == 401 || apiStatus == 401 || apiCode == 31001 || apiMessage.contains('login')) {
      throw const QuarkUnauthenticated();
    }
    if (statusCode == 429 || apiStatus == 429) {
      throw const QuarkRateLimited();
    }
    if (statusCode < 200 || statusCode > 299) {
      final String detail = apiMessage.isEmpty ? 'HTTP $statusCode' : 'HTTP $statusCode $apiMessage';
      throw QuarkNetworkError('直链失败 $detail');
    }
    if (apiStatus != null && apiStatus != 200) {
      throw QuarkNetworkError(apiMessage.isEmpty ? '接口 status $apiStatus' : apiMessage);
    }

    final Uri? downloadUrl = extractDownloadURL(json);
    if (downloadUrl != null) {
      return downloadUrl;
    }

    final String body = response.body;
    final String preview = body.length > 180 ? body.substring(0, 180) : body;
    throw QuarkParseError('响应中没有 download_url $preview');
  }

  Future<_QuarkResponse> _send(
    String endpoint, {
    required String cookie,
    bool jsonBody = false,
    Object? body,
  }) async {
    try {
      final Response<dynamic> response = await _dio.request<dynamic>(
        endpoint,
        data: body,
        options: Options(
          method: jsonBody ? 'POST' : 'GET',
          headers: _apiHeaders(cookie: cookie, jsonBody: jsonBody),
          responseType: ResponseType.plain,
          // 状态码由调用方按夸克的语义映射，不让 dio 直接抛 DioException。
          validateStatus: (int? status) => true,
        ),
      );
      _capturePuus(response.headers);
      return _QuarkResponse(statusCode: response.statusCode ?? 0, body: _bodyText(response.data));
    } on DioException catch (error) {
      final Response<dynamic>? response = error.response;
      if (response == null) {
        throw QuarkNetworkError(error.message ?? error.type.name);
      }
      _capturePuus(response.headers);
      return _QuarkResponse(statusCode: response.statusCode ?? 0, body: _bodyText(response.data));
    }
  }

  /// 与旧版 `applyAPIHeaders` 一致。
  static Map<String, String> _apiHeaders({required String cookie, required bool jsonBody}) {
    final Map<String, String> headers = <String, String>{
      'Cookie': cookie,
      'User-Agent': userAgent,
      'Referer': _referer,
      'Origin': _origin,
      'Accept': _acceptJson,
    };
    if (jsonBody) {
      headers['Content-Type'] = 'application/json;charset=UTF-8';
    }
    return headers;
  }

  static String _bodyText(Object? data) {
    if (data is String) {
      return data;
    }
    if (data == null) {
      return '';
    }
    return jsonEncode(data);
  }

  /// 从 `Set-Cookie` 里抓出 `__puus`（旧版 `capturePuus`）。
  void _capturePuus(Headers? headers) {
    final List<String>? raw = headers?['set-cookie'];
    if (raw == null) {
      return;
    }
    for (final String value in raw) {
      for (final String part in value.split(RegExp(r'[;,]'))) {
        final String item = part.trim();
        if (!item.startsWith('__puus=')) {
          continue;
        }
        final String puus = item.substring('__puus='.length);
        if (puus.isEmpty) {
          continue;
        }
        _refreshedPuus = puus;
        return;
      }
    }
  }

  /// JSON 数字统一按整数解读（`size` / `status` / `code`）。
  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }
}

class _CachedDownloadUrl {
  const _CachedDownloadUrl(this.uri, this.expiresAt);

  final Uri uri;

  final DateTime expiresAt;
}

class _QuarkResponse {
  const _QuarkResponse({required this.statusCode, required this.body});

  final int statusCode;

  final String body;

  /// 响应体不是 JSON 对象时返回 null（旧版 `JSONSerialization` 失败的情形）。
  Map<String, dynamic>? get json {
    if (body.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
