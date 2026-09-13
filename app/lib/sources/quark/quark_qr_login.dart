import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import 'quark_session.dart';

/// 扫码登录的一次会话。
class QuarkQrSession {
  QuarkQrSession({
    required this.token,
    required this.qrContent,
    required this.cookieJar,
  });

  /// 服务端下发的登录票据（轮询时回传）。
  final String token;

  /// 二维码里编码的内容，交给夸克 App 扫描。
  final String qrContent;

  /// 申请 token 时服务端设置的 CAS Cookie；后续轮询与换票必须原样带回。
  final QuarkCookieJar cookieJar;
}

enum QuarkQrPhase { waitingScan, scanned, expired, error }

class QuarkQrPollResult {
  const QuarkQrPollResult({
    required this.phase,
    this.cookie,
    this.message = '',
  });

  final QuarkQrPhase phase;

  /// 仅在 [QuarkQrPhase.scanned]（已完成换取）时非空。
  final String? cookie;

  final String message;
}

/// 夸克扫码登录：申请二维码 → 轮询 → 用 service_ticket 换取 Cookie。
///
/// 这些端点没有官方第三方文档。实现跟随当前网页版扫码流：client_id 532，
/// token 阶段的 CAS Cookie 会贯穿轮询与换票，并手动跟随重定向收集 Set-Cookie。
class QuarkQrLogin {
  QuarkQrLogin({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              validateStatus: (int? status) => status != null,
            ),
          );

  /// 扫码登录使用普通浏览器 UA；旧 Electron PC UA 会触发过期/风控判断。
  static const String userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36';

  /// 当前夸克网页扫码登录客户端 ID。
  static const String clientId = '532';

  static const String clientVersion = '1.2';

  static const String _uopBase = 'https://uop.quark.cn/cas/ajax';

  static const String _scanPage = 'https://su.quark.cn/4_eMHBJ';

  static const String _panHost = 'https://pan.quark.cn';

  static const String _drivePcHost = 'https://drive-pc.quark.cn';

  final Dio _dio;

  /// 申请二维码；失败抛异常（消息可直接展示给用户）。
  Future<QuarkQrSession> start() async {
    final Response<dynamic> response = await _dio.get<dynamic>(
      '$_uopBase/getTokenForQrcodeLogin',
      queryParameters: <String, String>{
        'client_id': clientId,
        'v': clientVersion,
        'request_id': _randomRequestId(),
        'uc_param_str': '',
      },
      options: _casOptions(),
    );
    final Map<String, dynamic>? body = _decodeBody(response.data);
    final String token =
        _nested(body, <String>['data', 'members', 'token']) ?? '';
    final int status = _statusOf(body);
    if (response.statusCode != 200 || status != 2000000 || token.isEmpty) {
      throw QuarkQrLoginException(
        '申请二维码失败（HTTP ${response.statusCode ?? 0}，status=$status ${_messageOf(body)}）',
      );
    }

    final QuarkCookieJar cookieJar = QuarkCookieJar.empty();
    cookieJar.mergeSetCookie(
      response.headers['set-cookie'] ?? const <String>[],
    );

    const String businessParameters =
        'S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0';
    // 不能用 Uri.replace(queryParameters:)：Dart 会把空字符串编码成裸的
    // `uc_param_str`（没有等号）。夸克短链遇到该形式会在重定向时丢掉整组
    // token/client_id 参数，手机确认页随后只能提示“登录请求已过期”。
    final String scan =
        '$_scanPage?token=${Uri.encodeQueryComponent(token)}'
        '&client_id=$clientId&ssb=weblogin&uc_param_str='
        '&uc_biz_str=${Uri.encodeQueryComponent(businessParameters)}';
    return QuarkQrSession(token: token, qrContent: scan, cookieJar: cookieJar);
  }

  /// 轮询一次；用户确认后会自动完成换取并返回 Cookie 串。
  Future<QuarkQrPollResult> poll(QuarkQrSession session) async {
    final Response<dynamic> response = await _dio.get<dynamic>(
      '$_uopBase/getServiceTicketByQrcodeToken',
      queryParameters: <String, String>{
        'client_id': clientId,
        'v': clientVersion,
        'token': session.token,
        'request_id': _randomRequestId(),
        'uc_param_str': '',
      },
      options: _casOptions(cookie: session.cookieJar.header),
    );
    session.cookieJar.mergeSetCookie(
      response.headers['set-cookie'] ?? const <String>[],
    );

    final Map<String, dynamic>? body = _decodeBody(response.data);
    final int status = _statusOf(body);
    final String ticket =
        _nested(body, <String>['data', 'members', 'service_ticket']) ?? '';

    switch (status) {
      case 2000000:
        if (ticket.isEmpty) {
          return const QuarkQrPollResult(
            phase: QuarkQrPhase.error,
            message: '已扫码但未拿到登录票据，请重试',
          );
        }
        final ({String? cookie, String error}) exchange = await _exchangeTicket(
          ticket,
          session.cookieJar,
        );
        if (exchange.cookie == null || exchange.cookie!.isEmpty) {
          return QuarkQrPollResult(
            phase: QuarkQrPhase.error,
            message: exchange.error.isEmpty
                ? '换取登录凭证失败，请重试'
                : '换取登录凭证失败：${exchange.error}',
          );
        }
        return QuarkQrPollResult(
          phase: QuarkQrPhase.scanned,
          cookie: exchange.cookie,
        );
      case 50004001:
        return const QuarkQrPollResult(
          phase: QuarkQrPhase.waitingScan,
          message: '等待手机扫码',
        );
      case 50004002:
        return const QuarkQrPollResult(
          phase: QuarkQrPhase.expired,
          message: '二维码已过期，请刷新',
        );
      case 50004003:
        return QuarkQrPollResult(
          phase: QuarkQrPhase.error,
          message: _messageOf(body).isEmpty ? '扫码登录失败，请重试' : _messageOf(body),
        );
      case 50004004:
        return const QuarkQrPollResult(
          phase: QuarkQrPhase.error,
          message: '已在夸克 App 中取消登录',
        );
      default:
        return QuarkQrPollResult(
          phase: QuarkQrPhase.waitingScan,
          message: '等待手机扫码（status=$status）',
        );
    }
  }

  /// 换票时手动跟随重定向；Dio 默认不会替应用保存中间响应的 Cookie。
  Future<({String? cookie, String error})> _exchangeTicket(
    String ticket,
    QuarkCookieJar cookieJar,
  ) async {
    final List<String> trace = <String>[];
    try {
      final Response<dynamic> response = await _getFollowingRedirects(
        Uri.parse('$_panHost/account/info').replace(
          queryParameters: <String, String>{
            'st': ticket,
            'lw': 'scan',
            'fr': 'pc',
            'platform': 'pc',
          },
        ),
        cookieJar,
        trace: trace,
      );
      final int exchangeStatus = response.statusCode ?? 0;

      // 访问首页与轻量目录接口，补齐 drive-pc/.quark.cn 域会话 Cookie。
      try {
        await _getFollowingRedirects(
          Uri.parse('$_panHost/'),
          cookieJar,
          trace: trace,
          extraHeaders: const <String, String>{
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Upgrade-Insecure-Requests': '1',
          },
        );
        await _getFollowingRedirects(
          Uri.parse('$_drivePcHost/1/clouddrive/file/sort').replace(
            queryParameters: const <String, String>{
              'pr': 'ucpro',
              'fr': 'pc',
              'pdir_fid': '0',
              '_page': '1',
              '_size': '1',
              '_fetch_total': '1',
            },
          ),
          cookieJar,
          trace: trace,
          extraHeaders: const <String, String>{
            'Origin': _panHost,
            'Referer': '$_panHost/',
          },
        );
      } on Object catch (error) {
        trace.add('bootstrap:${error.runtimeType}');
      }

      final List<String> cookies = cookieJar.cookies.entries
          .where(
            (MapEntry<String, String> entry) =>
                entry.key != 'push_vurl' && entry.key != 'logout_id',
          )
          .map(
            (MapEntry<String, String> entry) => '${entry.key}=${entry.value}',
          )
          .toList(growable: false);
      if (!cookieJar.cookies.containsKey('__pus')) {
        final String names = cookieJar.cookies.keys.join(',');
        return (
          cookie: null,
          error:
              '未收到 __pus（HTTP $exchangeStatus；cookies=${names.isEmpty ? 'none' : names}；${trace.join(' → ')}）',
        );
      }
      return (cookie: cookies.join('; '), error: '');
    } on Object catch (error) {
      return (
        cookie: null,
        error:
            '${error.runtimeType}: $error${trace.isEmpty ? '' : '；${trace.join(' → ')}'}',
      );
    }
  }

  Future<Response<dynamic>> _getFollowingRedirects(
    Uri initial,
    QuarkCookieJar cookieJar, {
    Map<String, String> extraHeaders = const <String, String>{},
    List<String>? trace,
  }) async {
    Uri current = initial;
    for (int hop = 0; hop < 6; hop++) {
      final Response<dynamic> response = await _dio.getUri<dynamic>(
        current,
        options: Options(
          headers: <String, String>{
            ..._headers(cookie: cookieJar.header),
            ...extraHeaders,
          },
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (int? status) => status != null,
        ),
      );
      cookieJar.mergeSetCookie(
        response.headers['set-cookie'] ?? const <String>[],
      );
      final int status = response.statusCode ?? 0;
      final String? location = response.headers.value('location');
      trace?.add('${current.host}${current.path}:$status');
      if (status >= 300 && status < 400 && location != null) {
        current = current.resolve(location);
        continue;
      }
      return response;
    }
    throw const QuarkQrLoginException('登录跳转次数过多，请重试');
  }

  Options _casOptions({String cookie = ''}) => Options(
    headers: _headers(cookie: cookie),
    responseType: ResponseType.plain,
  );

  static Map<String, dynamic>? _decodeBody(Object? data) {
    Object? decoded = data;
    if (data is String) {
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) {
      return null;
    }
    return decoded.map<String, dynamic>(
      (Object? key, Object? value) => MapEntry<String, dynamic>('$key', value),
    );
  }

  static Map<String, String> _headers({String cookie = ''}) => <String, String>{
    'User-Agent': userAgent,
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': '$_panHost/',
    if (cookie.isNotEmpty) 'Cookie': cookie,
  };

  static String _randomRequestId() {
    const String chars = 'abcdef0123456789';
    final Random random = Random.secure();
    return List<String>.generate(
      32,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  static int _statusOf(Map<String, dynamic>? body) {
    final Object? status = body?['status'];
    return status is int
        ? status
        : (status is String ? int.tryParse(status) ?? 0 : 0);
  }

  static String _messageOf(Map<String, dynamic>? body) {
    final Object? message = body?['message'];
    return message is String ? message : '';
  }

  static String? _nested(Map<String, dynamic>? body, List<String> path) {
    Object? current = body;
    for (final String key in path) {
      if (current is! Map<String, dynamic>) {
        return null;
      }
      current = current[key];
    }
    return current is String ? current : null;
  }
}

class QuarkQrLoginException implements Exception {
  const QuarkQrLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}
