import '../../playback/playback_item.dart';
import '../source_adapter.dart';
import 'quark_auth.dart';
import 'quark_cookie_store.dart';
import 'quark_drive_client.dart';
import 'quark_session.dart';

/// 夸克网盘来源适配器：把 [QuarkDriveClient] 接进 M3 的来源层契约。
///
/// 一个实例对应 `music_sources` 里的一行（[sourceId] + 扫描根目录 [folderFid]）；
/// 会话每次由 [QuarkAuthCore] 从安全存储恢复，登录/登出不需要重建实例。
class QuarkSourceAdapter implements SourceAdapter {
  QuarkSourceAdapter({
    required this.sourceId,
    this.folderFid = '0',
    QuarkDriveClient? client,
    QuarkAuthCore? authCore,
    QuarkCookieStore? cookieStore,
    this.maxDepth = 5,
    this.maxFiles = 5000,
  }) {
    _client = client ?? QuarkDriveClient();
    _authCore =
        authCore ?? QuarkAuthCore(client: _client, cookieStore: cookieStore);
  }

  /// `quark://<fid>` 的 scheme 前缀。
  static const String uriScheme = 'quark://';

  @override
  final String sourceId;

  /// 扫描根目录的 fid（旧版 `MusicSource.quarkFolderFid`）；空则视作根目录。
  final String folderFid;

  /// 递归深度上限，与旧版默认值一致。
  final int maxDepth;

  /// 单次扫描曲目上限，与旧版默认值一致。
  final int maxFiles;

  late final QuarkDriveClient _client;

  late final QuarkAuthCore _authCore;

  /// 扫描目录树，产出曲目事实（不入库）。
  ///
  /// 凭据缺失抛 [QuarkUnauthenticated]；目录请求失败会中断整次扫描（旧版同样如此）。
  @override
  Future<SourceScanResult> scan({
    void Function(int done, String name)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final QuarkSession session = await _authCore.restore(sourceId);

    final QuarkScanResult result = await _client.scan(
      folderFid: folderFid.isEmpty ? '0' : folderFid,
      sourceId: sourceId,
      session: session,
      maxDepth: maxDepth,
      maxFiles: maxFiles,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );

    return SourceScanResult(tracks: result.tracks, cancelled: result.cancelled);
  }

  /// 把库里的 `quark://<fid>` 解析成带鉴权头的直链条目。
  ///
  /// API 响应带回的所有 Set-Cookie 都由 [QuarkSession] 合并并写回安全存储。
  @override
  Future<PlaybackItem> open(String filePathOrUrl) async {
    final String fid = _fidOf(filePathOrUrl);

    final QuarkSession session = await _authCore.restore(sourceId);
    final Uri uri = await _client.getDownloadUrl(fid, session);

    return PlaybackItem.fromUri(
      uri,
      httpHeaders: QuarkDriveClient.playbackHeaders(session),
    );
  }

  static String _fidOf(String filePathOrUrl) {
    if (!filePathOrUrl.startsWith(uriScheme)) {
      throw QuarkParseError('无效的夸克文件地址: $filePathOrUrl');
    }
    final String fid = filePathOrUrl.substring(uriScheme.length).trim();
    if (fid.isEmpty) {
      throw QuarkParseError('无效的夸克文件地址: $filePathOrUrl');
    }
    return fid;
  }
}
