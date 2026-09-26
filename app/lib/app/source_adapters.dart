import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tingyu_saf/tingyu_saf.dart';

import '../data/db/database.dart';
import '../data/secure_store.dart';
import '../sources/local/local_bookmark_source_adapter.dart';
import '../sources/local/local_source_adapter.dart';
import '../sources/local/saf_source_adapter.dart';
import '../sources/quark/quark_source_adapter.dart';
import '../sources/source_adapter.dart';
import '../sources/webdav/webdav_source_adapter.dart';
import 'providers.dart';

/// 按来源类型构造适配器；凭据（WebDAV 密码、Quark Cookie）从系统安全存储取。
///
/// 扫描（`/sources` 页面）与播放（`TrackResolver`）共用同一套构造逻辑，
/// 避免两处各自拼接凭据导致行为不一致。
Future<SourceAdapter> buildSourceAdapter(
  Ref ref,
  MusicSource source, {
  SecureStore? secureStore,
}) async {
  final SecureStore store = secureStore ?? SecureStore();
  switch (source.kind) {
    case 'webdav':
      final String? password = await store.readWebDavPassword(source.id);
      return WebDavSourceAdapter(
        sourceId: source.id,
        credentials: WebDavCredentials(
          rootUrl: source.webdavUrl ?? '',
          username: source.webdavUsername ?? '',
          password: password ?? '',
        ),
      );
    case 'quark':
      return QuarkSourceAdapter(
        sourceId: source.id,
        folderFid: source.quarkFolderFid ?? '0',
      );
    default:
      // 本地目录"怎么拿到文件"由 local_bookmark 决定：
      // Android 是 SAF 授权的 tree URI，iOS 是安全作用域书签，
      // 其余情况（桌面、以及从旧版迁移过来的路径）就是普通文件系统路径。
      final String? token = source.localBookmark;
      if (Platform.isAndroid && token != null && token.startsWith('content://')) {
        return SafSourceAdapter(sourceId: source.id, treeUri: token);
      }
      if (Platform.isIOS && token != null && token.isNotEmpty) {
        return LocalBookmarkSourceAdapter(sourceId: source.id, bookmark: token);
      }
      return LocalSourceAdapter(
        sourceId: source.id,
        folderPath: source.localFolderPath ?? '',
      );
  }
}

/// 每个来源一个长驻适配器实例。
///
/// 为什么要缓存：夸克每次 `open()` 都要向网盘换一次直链，而直链在
/// `QuarkDriveClient` 里按 fid 缓存 5400s —— 每首歌都重建适配器，等于这个缓存从来
/// 没生效过，每次播放都要多打一次网盘接口（还会顺带多读一次系统安全存储）。
///
/// 失效条件写进指纹：来源行里参与构造的字段（URL / 账号 / 目录授权 / fid）+ 凭据
/// 写入次数（[SecureStore.credentialEpoch]）。改了配置或重新登录，指纹就变，下次
/// 取用时自动重建，不会把旧密码、旧 Cookie 一直用下去。
class SourceAdapterCache {
  SourceAdapterCache(this._ref);

  final Ref _ref;

  final Map<String, _CachedAdapter> _entries = <String, _CachedAdapter>{};

  Future<SourceAdapter> of(MusicSource source) {
    final String fingerprint = _fingerprint(source);
    final _CachedAdapter? cached = _entries[source.id];
    if (cached != null && cached.fingerprint == fingerprint) {
      return cached.adapter;
    }
    // 缓存的是 Future 而不是实例：同时到达的多个解析请求共用同一次构造
    // （安全存储读取 + 客户端装配），不会各建一个。
    final Future<SourceAdapter> adapter = buildSourceAdapter(_ref, source);
    final _CachedAdapter entry = _CachedAdapter(fingerprint, adapter);
    _entries[source.id] = entry;
    adapter.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        // 构造失败不留在缓存里，否则这个来源会一直复用同一个失败结果。
        if (identical(_entries[source.id], entry)) {
          _entries.remove(source.id);
        }
      },
    );
    return adapter;
  }

  /// 来源被删除/重新登录时手动清理（不清理也只是占一个条目的内存）。
  void evict(String sourceId) => _entries.remove(sourceId);

  Future<SourceAdapter> ofId(String sourceId) async {
    final MusicSource? source = await _ref
        .read(sourceRepositoryProvider)
        .byId(sourceId);
    if (source == null) {
      throw StateError('来源不存在: $sourceId');
    }
    return of(source);
  }

  static String _fingerprint(MusicSource source) => <Object?>[
    source.kind,
    source.localFolderPath,
    source.localBookmark,
    source.webdavUrl,
    source.webdavUsername,
    source.webdavRootPath,
    source.quarkFolderFid,
    SecureStore.credentialEpoch,
  ].join('\u0000');
}

class _CachedAdapter {
  const _CachedAdapter(this.fingerprint, this.adapter);

  final String fingerprint;

  final Future<SourceAdapter> adapter;
}

/// 适配器缓存；来源列表变化时无需重建（指纹会兜住）。
final Provider<SourceAdapterCache> sourceAdapterCacheProvider =
    Provider<SourceAdapterCache>((Ref ref) => SourceAdapterCache(ref));

/// 本地目录的授权是否仍然有效：Android 查 SAF 持久化授权，iOS 解析安全作用域书签，
/// 桌面只有路径本身（非空即算可用）。
Future<bool> localFolderAccessValid(MusicSource source) async {
  final String? token = source.localBookmark;
  if (Platform.isAndroid) {
    return token != null &&
        token.startsWith('content://') &&
        await _safPermissionValid(token);
  }
  if (Platform.isIOS) {
    if (token == null || token.isEmpty) {
      return false;
    }
    try {
      // 解析成功即视为有效：插件顺手开启安全作用域，随后的扫描与播放都靠它。
      return (await TingyuSaf.resolveBookmark(token)) != null;
    } on Object {
      return false;
    }
  }
  return (source.localFolderPath ?? '').isNotEmpty;
}

/// SAF 授权是否仍有效；插件不可用（非 Android）时按无效处理。
Future<bool> _safPermissionValid(String treeUri) async {
  try {
    return await TingyuSaf.hasPermission(treeUri);
  } on Object {
    return false;
  }
}

/// 来源凭据是否齐备（用于 UI 提示"需要重新登录/填写密码"）。
Future<bool> sourceHasCredentials(MusicSource source, {SecureStore? secureStore}) async {
  final SecureStore store = secureStore ?? SecureStore();
  switch (source.kind) {
    case 'webdav':
      return (await store.readWebDavPassword(source.id)) != null;
    case 'quark':
      return (await store.readQuarkCookie(source.id)) != null;
    default:
      return localFolderAccessValid(source);
  }
}
