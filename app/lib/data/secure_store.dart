import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 凭据存储：WebDAV 密码、Quark Cookie 等只走系统安全存储
/// （macOS/iOS Keychain、Windows DPAPI、Linux libsecret）。
///
/// 与旧版 Swift 的差异：`QuarkCookieStore.swift` 会把 Cookie 额外写一份明文文件兜底，
/// 这里**不保留**该行为。
///
/// 唯一的例外是**未签名的 macOS 开发构建**：Keychain 需要 `keychain-access-groups`
/// entitlement，本地 ad-hoc 签名的 app 会报 `-34018 (errSecMissingEntitlement)`。
/// 这时回退到「应用支持目录下的 0600 权限文件」，并在 [usedFallback] 上标记出来，
/// 让设置页能如实告诉用户当前用的是什么存储 —— 正式签名分发的构建会走 Keychain。
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // macOS 默认走 Data Protection Keychain，它要求 app 带
              // `keychain-access-groups` entitlement —— 未签名/Developer ID 构建会被拒
              // （errSecMissingEntitlement -34018）。我们不上 Mac App Store、也不开沙盒，
              // 用**登录钥匙串**才是这类 app 的正解：同样是系统钥匙串，仍按用户登录态加密保护。
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  /// 账号名前缀；完整账号名是 `<prefix>_<sourceId>`。
  static const String webdavPasswordPrefix = 'webdav_password';

  static const String quarkCookiePrefix = 'quark_cookie';

  /// 最近一次操作是否走了文件回退（设置页展示用）。
  static bool usedFallback = false;

  final FlutterSecureStorage _storage;

  static String accountFor(String prefix, String sourceId) => '${prefix}_$sourceId';

  Future<void> write(String account, String value) async {
    try {
      await _storage.write(key: account, value: value);
      usedFallback = false;
    } on PlatformException catch (error) {
      if (!_isMissingEntitlement(error)) {
        rethrow;
      }
      usedFallback = true;
      await _writeFile(account, value);
    } on MissingPluginException {
      usedFallback = true;
      await _writeFile(account, value);
    }
  }

  Future<String?> read(String account) async {
    String? value;
    try {
      value = await _storage.read(key: account);
    } on PlatformException catch (error) {
      if (!_isMissingEntitlement(error)) {
        rethrow;
      }
      usedFallback = true;
    } on MissingPluginException {
      usedFallback = true;
    }
    final String? trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    // Keychain 里没有（或不可用）时看回退文件。
    final String? fallback = await _readFile(account);
    if (fallback != null) {
      usedFallback = true;
    }
    return fallback;
  }

  Future<void> delete(String account) async {
    try {
      await _storage.delete(key: account);
    } on PlatformException catch (error) {
      if (!_isMissingEntitlement(error)) {
        rethrow;
      }
    } on MissingPluginException {
      // 忽略：下面照样清文件。
    }
    await _deleteFile(account);
  }

  // 便捷入口，避免调用方拼错账号名。
  Future<void> writeWebDavPassword(String sourceId, String password) =>
      write(accountFor(webdavPasswordPrefix, sourceId), password);

  Future<String?> readWebDavPassword(String sourceId) =>
      read(accountFor(webdavPasswordPrefix, sourceId));

  Future<void> writeQuarkCookie(String sourceId, String cookie) =>
      write(accountFor(quarkCookiePrefix, sourceId), cookie);

  Future<String?> readQuarkCookie(String sourceId) => read(accountFor(quarkCookiePrefix, sourceId));

  Future<void> deleteQuarkCookie(String sourceId) => delete(accountFor(quarkCookiePrefix, sourceId));

  /// macOS/iOS 的 `errSecMissingEntitlement`。
  static bool _isMissingEntitlement(PlatformException error) =>
      error.code == '-34018' || error.message?.contains('-34018') == true;

  Future<File> _fallbackFile(String account) async {
    final Directory root = await getApplicationSupportDirectory();
    final Directory dir = Directory(p.join(root.path, 'credentials'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, '$account.txt'));
  }

  Future<void> _writeFile(String account, String value) async {
    final File file = await _fallbackFile(account);
    await file.writeAsString(value, flush: true);
    // 仅本人可读写：等价于"本地文件存凭据"的最小暴露面。
    await Process.run('chmod', <String>['600', file.path]);
  }

  Future<String?> _readFile(String account) async {
    try {
      final File file = await _fallbackFile(account);
      if (!file.existsSync()) {
        return null;
      }
      final String value = (await file.readAsString()).trim();
      return value.isEmpty ? null : value;
    } on Object catch (error) {
      debugPrint('[secure-store] 读取回退凭据失败: $error');
      return null;
    }
  }

  Future<void> _deleteFile(String account) async {
    try {
      final File file = await _fallbackFile(account);
      if (file.existsSync()) {
        await file.delete();
      }
    } on Object catch (error) {
      debugPrint('[secure-store] 删除回退凭据失败: $error');
    }
  }
}
