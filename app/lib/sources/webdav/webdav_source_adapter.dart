import '../../playback/playback_item.dart';
import '../source_adapter.dart';
import 'webdav_client.dart';

/// WebDAV 来源的连接信息。
class WebDavCredentials {
  WebDavCredentials({
    required this.rootUrl,
    required this.username,
    required this.password,
  }) : rootUri = Uri.parse(rootUrl);

  /// 用户填写的根目录 URL（`https://dav.jianguoyun.com/dav/`）。
  final String rootUrl;

  final String username;

  /// 应用专用密码；由调用方从 `SecureStore.readWebDavPassword` 取出。
  final String password;

  /// 构造时即校验，非法 URL 在这里就报错而不是等扫描时。
  final Uri rootUri;
}

/// WebDAV 来源：把 [WebDavClient] 接到来源层契约上。
///
/// 与旧版的差异：旧版把「扫描」和「播放鉴权」分散在 `LibraryScannerService` 与播放器里，
/// 这里统一到 [SourceAdapter]：扫描只产出事实，播放时把 Basic 鉴权放进
/// [PlaybackItem.httpHeaders]（凭据不进 URL，避免泄漏到日志与缓存键）。
class WebDavSourceAdapter implements SourceAdapter {
  WebDavSourceAdapter({
    required this.sourceId,
    required this.credentials,
    WebDavClient? client,
  }) : _client = client ?? WebDavClient();

  @override
  final String sourceId;

  final WebDavCredentials credentials;

  final WebDavClient _client;

  @override
  Future<SourceScanResult> scan({
    void Function(int done, String name)? onProgress,
    bool Function()? isCancelled,
  }) =>
      _client.scan(
        rootUrl: credentials.rootUri,
        sourceId: sourceId,
        username: credentials.username,
        password: credentials.password,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );

  @override
  Future<PlaybackItem> open(String filePathOrUrl) async {
    final Uri uri = Uri.parse(filePathOrUrl);
    return PlaybackItem.fromUri(
      uri,
      httpHeaders: <String, String>{
        'Authorization': WebDavClient.basicAuthHeader(credentials.username, credentials.password),
      },
    );
  }
}
