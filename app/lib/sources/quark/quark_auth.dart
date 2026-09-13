import 'quark_cookie_store.dart';
import 'quark_drive_client.dart';
import 'quark_session.dart';

/// 扫码、WebView 与手工导入共用的认证核心。
class QuarkAuthCore {
  QuarkAuthCore({QuarkDriveClient? client, QuarkCookieStore? cookieStore})
    : _client = client ?? QuarkDriveClient(),
      _cookieStore = cookieStore ?? QuarkCookieStore();

  final QuarkDriveClient _client;
  final QuarkCookieStore _cookieStore;

  /// 规范化并校验登录方式返回的原始 Cookie。
  Future<QuarkSession> authenticate(String rawCookie) async {
    final QuarkCookieJar jar = QuarkCookieJar.parse(rawCookie);
    if (jar.isEmpty) {
      throw const QuarkCookieFormatException();
    }

    final QuarkSession candidate = QuarkSession(cookieJar: jar);
    final QuarkSessionCheck check = await _client.validateSession(candidate);
    switch (check.state) {
      case QuarkSessionState.valid:
        return QuarkSession(
          cookieJar: jar,
          nickname: check.nickname.isEmpty ? '夸克用户' : check.nickname,
        );
      case QuarkSessionState.expired:
        throw const QuarkSessionExpiredException();
      case QuarkSessionState.unavailable:
        throw QuarkAuthUnavailableException(check.message);
    }
  }

  /// 把已校验会话绑定到来源并写进系统安全存储。
  Future<QuarkSession> bindAndSave(
    String sourceId,
    QuarkSession session,
  ) async {
    if (session.isEmpty) {
      throw const QuarkCookieFormatException();
    }
    await _cookieStore.save(sourceId, session.cookieHeader);
    return session.bind(
      sourceId: sourceId,
      onCookieChanged: (String cookie) => _cookieStore.save(sourceId, cookie),
    );
  }

  /// 恢复业务访问使用的会话。API 响应带回的新 Cookie 会自动持久化。
  Future<QuarkSession> restore(String sourceId, {bool validate = false}) async {
    final String? rawCookie = await _cookieStore.load(sourceId);
    if (rawCookie == null) {
      throw const QuarkUnauthenticated();
    }
    final QuarkCookieJar jar = QuarkCookieJar.parse(rawCookie);
    if (jar.isEmpty) {
      throw const QuarkUnauthenticated();
    }
    QuarkSession session = QuarkSession(cookieJar: jar).bind(
      sourceId: sourceId,
      onCookieChanged: (String cookie) => _cookieStore.save(sourceId, cookie),
    );
    if (!validate) {
      return session;
    }

    final QuarkSessionCheck check = await _client.validateSession(session);
    if (check.state == QuarkSessionState.expired) {
      throw const QuarkUnauthenticated();
    }
    if (check.state == QuarkSessionState.unavailable) {
      throw QuarkAuthUnavailableException(check.message);
    }
    if (check.nickname.isNotEmpty) {
      session = QuarkSession(
        cookieJar: jar,
        nickname: check.nickname,
        sourceId: sourceId,
        onCookieChanged: (String cookie) => _cookieStore.save(sourceId, cookie),
      );
    }
    return session;
  }
}

sealed class QuarkAuthException implements Exception {
  const QuarkAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class QuarkCookieFormatException extends QuarkAuthException {
  const QuarkCookieFormatException()
    : super('Cookie 为空或格式不正确，请粘贴完整的 Cookie 请求头');
}

class QuarkSessionExpiredException extends QuarkAuthException {
  const QuarkSessionExpiredException() : super('Cookie 已失效或过期，请重新选择登录方式');
}

class QuarkAuthUnavailableException extends QuarkAuthException {
  QuarkAuthUnavailableException(String detail)
    : super(detail.isEmpty ? '暂时无法校验夸克登录，请检查网络后重试' : '暂时无法校验夸克登录：$detail');
}
