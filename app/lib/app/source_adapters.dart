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
