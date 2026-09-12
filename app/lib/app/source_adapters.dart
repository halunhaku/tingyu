import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/secure_store.dart';
import '../sources/local/local_source_adapter.dart';
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
      return LocalSourceAdapter(
        sourceId: source.id,
        folderPath: source.localFolderPath ?? '',
      );
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
      return (source.localFolderPath ?? '').isNotEmpty;
  }
}
