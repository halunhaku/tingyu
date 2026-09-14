import 'dart:collection';
import 'dart:io' show HttpDate;

/// 夸克会话里的 Cookie 容器。
///
/// 登录方式只负责拿到原始 Cookie；解析、去重、响应更新都统一收敛到这里。
class QuarkCookieJar {
  QuarkCookieJar._(LinkedHashMap<String, String> cookies) : _cookies = cookies;

  factory QuarkCookieJar.empty() =>
      QuarkCookieJar._(LinkedHashMap<String, String>());

  /// 解析浏览器请求头或 WebView 汇总出来的 Cookie。
  factory QuarkCookieJar.parse(String raw) {
    final QuarkCookieJar jar = QuarkCookieJar.empty();
    String value = raw.trim();
    if (value.toLowerCase().startsWith('cookie:')) {
      value = value.substring(value.indexOf(':') + 1).trim();
    }
    value = value.replaceAll(RegExp(r'[\r\n]+'), ';');
    for (final String part in value.split(';')) {
      jar._putCookiePair(part);
    }
    return jar;
  }

  static final RegExp _validName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

  static const Set<String> _setCookieAttributes = <String>{
    'domain',
    'expires',
    'httponly',
    'max-age',
    'partitioned',
    'path',
    'samesite',
    'secure',
  };

  final LinkedHashMap<String, String> _cookies;

  bool get isEmpty => _cookies.isEmpty;

  bool get isNotEmpty => _cookies.isNotEmpty;

  Map<String, String> get cookies => Map<String, String>.unmodifiable(_cookies);

  String get header => _cookies.entries
      .map((MapEntry<String, String> entry) => '${entry.key}=${entry.value}')
      .join('; ');

  /// 合并 HTTP 响应里的 Set-Cookie。返回会话是否发生变化。
  bool mergeSetCookie(Iterable<String> headers) {
    bool changed = false;
    for (final String header in headers) {
      final List<String> parts = header.split(';');
      if (parts.isEmpty) {
        continue;
      }
      final String pair = parts.first.trim();
      final int equals = pair.indexOf('=');
      if (equals <= 0) {
        continue;
      }
      final String name = pair.substring(0, equals).trim();
      if (!_validName.hasMatch(name)) {
        continue;
      }
      final String value = pair.substring(equals + 1).trim();
      final bool deleted = value.isEmpty || _deletesCookie(parts.skip(1));
      if (deleted) {
        changed = _cookies.remove(name) != null || changed;
      } else if (_cookies[name] != value) {
        _cookies[name] = value;
        changed = true;
      }
    }
    return changed;
  }

  static bool _deletesCookie(Iterable<String> attributes) {
    for (final String attribute in attributes) {
      final String trimmed = attribute.trim();
      final int equals = trimmed.indexOf('=');
      if (equals <= 0) {
        continue;
      }
      final String name = trimmed.substring(0, equals).trim().toLowerCase();
      final String value = trimmed.substring(equals + 1).trim();
      if (name == 'max-age' && (int.tryParse(value) ?? 1) <= 0) {
        return true;
      }
      if (name == 'expires') {
        try {
          if (!HttpDate.parse(value).isAfter(DateTime.now().toUtc())) {
            return true;
          }
        } on Object {
          // 夸克会返回 `Mon, 14-Sep-2026 ...` 这类非 RFC HTTP-date；
          // 无法解析的 Expires 不应中断轮询，也不应误删现有会话。
        }
      }
    }
    return false;
  }

  void _putCookiePair(String rawPair) {
    final String pair = rawPair.trim();
    final int equals = pair.indexOf('=');
    if (equals <= 0) {
      return;
    }
    final String name = pair.substring(0, equals).trim();
    final String value = pair.substring(equals + 1).trim();
    if (!_validName.hasMatch(name) ||
        _setCookieAttributes.contains(name.toLowerCase()) ||
        value.isEmpty) {
      return;
    }
    _cookies[name] = value;
  }
}

typedef QuarkCookiePersist = Future<void> Function(String cookie);

/// 扫码、WebView 与 Cookie 导入最终产生的统一会话。
class QuarkSession {
  QuarkSession({
    required this.cookieJar,
    this.nickname = '夸克用户',
    this.sourceId,
    this.onCookieChanged,
  });

  final QuarkCookieJar cookieJar;

  final String nickname;

  /// 尚未写入来源数据库的登录会话没有 sourceId。
  final String? sourceId;

  final QuarkCookiePersist? onCookieChanged;

  Future<void> _persistQueue = Future<void>.value();

  String get cookieHeader => cookieJar.header;

  bool get isEmpty => cookieJar.isEmpty;

  /// 把业务请求收到的 Set-Cookie 合并进当前会话；绑定来源后会立即写回安全存储。
  Future<void> mergeSetCookie(Iterable<String> headers) async {
    if (!cookieJar.mergeSetCookie(headers)) {
      return;
    }
    final QuarkCookiePersist? persist = onCookieChanged;
    if (persist != null) {
      final Future<void> write = _persistQueue.then<void>(
        (_) => persist(cookieHeader),
        onError: (_) => persist(cookieHeader),
      );
      _persistQueue = write;
      await write;
    }
  }

  QuarkSession bind({
    required String sourceId,
    required QuarkCookiePersist onCookieChanged,
  }) {
    return QuarkSession(
      cookieJar: cookieJar,
      nickname: nickname,
      sourceId: sourceId,
      onCookieChanged: onCookieChanged,
    );
  }
}

enum QuarkSessionState { valid, expired, unavailable }

class QuarkSessionCheck {
  const QuarkSessionCheck({
    required this.state,
    this.nickname = '',
    this.message = '',
  });

  final QuarkSessionState state;

  final String nickname;

  final String message;
}
