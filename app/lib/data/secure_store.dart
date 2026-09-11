import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 凭据存储：WebDAV 密码、Quark Cookie 等只能进系统安全存储
/// （macOS/iOS Keychain、Windows DPAPI、Linux libsecret）。
///
/// 与旧版 Swift 的差异：`QuarkCookieStore.swift` 会把 Cookie 额外写一份
/// 明文文件做兜底，这里**不保留**该行为——明文凭据落盘是纯亏。
class SecureStore {
  SecureStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  /// 账号名前缀；完整账号名是 `<prefix>_<sourceId>`。
  static const String webdavPasswordPrefix = 'webdav_password';

  static const String quarkCookiePrefix = 'quark_cookie';

  final FlutterSecureStorage _storage;

  static String accountFor(String prefix, String sourceId) => '${prefix}_$sourceId';

  Future<void> write(String account, String value) => _storage.write(key: account, value: value);

  Future<String?> read(String account) async {
    final String? value = await _storage.read(key: account);
    if (value == null) {
      return null;
    }
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> delete(String account) => _storage.delete(key: account);

  // 便捷入口，避免调用方拼错账号名。
  Future<void> writeWebDavPassword(String sourceId, String password) =>
      write(accountFor(webdavPasswordPrefix, sourceId), password);

  Future<String?> readWebDavPassword(String sourceId) =>
      read(accountFor(webdavPasswordPrefix, sourceId));

  Future<void> writeQuarkCookie(String sourceId, String cookie) =>
      write(accountFor(quarkCookiePrefix, sourceId), cookie);

  Future<String?> readQuarkCookie(String sourceId) => read(accountFor(quarkCookiePrefix, sourceId));

  Future<void> deleteQuarkCookie(String sourceId) => delete(accountFor(quarkCookiePrefix, sourceId));
}
