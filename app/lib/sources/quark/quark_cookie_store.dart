import '../../data/secure_store.dart';

/// 夸克网盘 Cookie 的读写入口，对齐旧版 `Sources/Services/Quark/QuarkCookieStore.swift`。
///
/// 与旧版的差异（有意）：Swift 版除 Keychain 外还会把 Cookie 明文写一份文件兜底，
/// 这里不保留——凭据只进 [SecureStore]（macOS/iOS Keychain、Windows DPAPI、Linux libsecret）。
class QuarkCookieStore {
  QuarkCookieStore({SecureStore? store}) : _store = store ?? SecureStore();

  /// 与 Swift 的 `account(for:)` 一致：`quark_cookie_<sourceId>`。
  static String accountFor(String sourceId) =>
      SecureStore.accountFor(SecureStore.quarkCookiePrefix, sourceId);

  final SecureStore _store;

  /// 读取来源的 Cookie；未保存或内容为空时返回 null（[SecureStore.read] 已做归一）。
  Future<String?> load(String sourceId) => _store.readQuarkCookie(sourceId);

  Future<void> save(String sourceId, String cookie) => _store.writeQuarkCookie(sourceId, cookie);

  Future<void> delete(String sourceId) => _store.deleteQuarkCookie(sourceId);
}
