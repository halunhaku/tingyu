import 'dart:math';

import 'package:dio/dio.dart';

import '../../data/secure_store.dart';

/// 扫码登录的一次会话。
class QuarkQrSession {
  const QuarkQrSession({required this.token, required this.qrContent});

  /// 服务端下发的登录票据（轮询时回传）。
  final String token;

  /// 二维码里编码的内容，交给夸克 App 扫描。
  final String qrContent;
}

enum QuarkQrPhase { waitingScan, scanned, expired, error }

class QuarkQrPollResult {
  const QuarkQrPollResult({required this.phase, this.cookie, this.message = ''});

  final QuarkQrPhase phase;

  /// 仅在 [QuarkQrPhase.scanned]（已完成换取）时非空。
  final String? cookie;

  final String message;
}

/// 夸克扫码登录（第三方客户端通行做法：申请二维码 → 轮询 → 用 service_ticket 换取 Cookie）。
///
/// 为什么不走网页登录：夸克的网页版登录页对运行环境有设备指纹与 App 跳转校验，
/// 在应用内 WebView 里会表现为"点登录没反应 / 二维码空白"（已实测复现）。
/// 网页登录里也没有面向第三方的 redirect_uri，因此"系统浏览器 + 回调"这条路同样拿不到凭证。
///
/// 注意：以下接口是**逆向**得到的（没有官方文档），夸克调整签名或风控就可能失效，
/// 届时需要按同一思路重新抓取接口。
class QuarkQrLogin {
  QuarkQrLogin({Dio? dio, SecureStore? secureStore})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
                validateStatus: (int? status) => status != null && status < 500,
              ),
            ),
        _secureStore = secureStore ?? SecureStore();

  /// 与 `QuarkDriveClient.userAgent` 保持一致的桌面 UA；UA 换掉容易触发风控。
  static const String userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) '
      'quark-cloud-drive/3.23.0 Chrome/112.0.5615.165 Electron/23.3.13 Safari/537.36 '
      'Channel/pckk_other_ch';

  /// 夸克 PC 客户端的固定参数（逆向所得）。
  static const String clientId = '386';

  static const String clientVersion = '1.2';

  static const String appVersion = '3.24.0';

  static const String channel = 'pckk@information_ch';

  static const String _uopBase = 'https://uop.quark.cn/cas/ajax';

  static const String _scanPage = 'https://su.quark.cn/4_eMHBJ';

  static const String _panLoginUrl = 'https://pan.quark.cn/desktop/account/login';

  static const String _deviceIdAccount = 'quark_device_id';

  final Dio _dio;

  final SecureStore _secureStore;

  /// 申请二维码；失败抛异常（消息可直接展示给用户）。
  Future<QuarkQrSession> start() async {
    final Map<String, String> params = await _baseParams();
    final Response<Map<String, dynamic>> response = await _dio.get<Map<String, dynamic>>(
      '$_uopBase/getTokenForQrcodeLogin',
      queryParameters: params,
      options: _options,
    );
    final Map<String, dynamic>? body = response.data;
    final String token = _nested(body, <String>['data', 'members', 'token']) ?? '';
    final int status = _statusOf(body);
    if (status != 2000000 || token.isEmpty) {
      throw QuarkQrLoginException('申请二维码失败（status=$status ${_messageOf(body)}）');
    }

    final Uri scan = Uri.parse(_scanPage).replace(
      queryParameters: <String, String>{
        'token': token,
        'client_id': clientId,
        'sch': channel,
        'sve': appVersion,
        'ssb': 'weblogin',
        'uc_param_str': '',
        'uc_biz_str': 'S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0',
      },
    );
    return QuarkQrSession(token: token, qrContent: scan.toString());
  }

  /// 轮询一次；用户确认后会自动完成换取并返回 Cookie 串。
  Future<QuarkQrPollResult> poll(QuarkQrSession session) async {
    final Map<String, String> params = await _baseParams();
    params['token'] = session.token;
    final Response<Map<String, dynamic>> response = await _dio.get<Map<String, dynamic>>(
      '$_uopBase/getServiceTicketByQrcodeToken',
      queryParameters: params,
      options: _options,
    );
    final Map<String, dynamic>? body = response.data;
    final int status = _statusOf(body);
    final String ticket = _nested(body, <String>['data', 'members', 'service_ticket']) ?? '';

    switch (status) {
      case 2000000:
        if (ticket.isEmpty) {
          return const QuarkQrPollResult(
            phase: QuarkQrPhase.error,
            message: '已扫码但未拿到登录票据，请重试',
          );
        }
        final String? cookie = await _exchangeTicket(ticket);
        if (cookie == null || cookie.isEmpty) {
          return const QuarkQrPollResult(
            phase: QuarkQrPhase.error,
            message: '换取登录凭证失败，请重试',
          );
        }
        return QuarkQrPollResult(phase: QuarkQrPhase.scanned, cookie: cookie);
      case 50004001:
        return const QuarkQrPollResult(phase: QuarkQrPhase.waitingScan, message: '等待手机扫码');
      case 50004002:
        return const QuarkQrPollResult(phase: QuarkQrPhase.expired, message: '二维码已过期，请刷新');
      default:
        return QuarkQrPollResult(
          phase: QuarkQrPhase.waitingScan,
          message: '等待手机扫码（status=$status）',
        );
    }
  }

  /// 用 service_ticket 换取 pan.quark.cn 的会话 Cookie。
  ///
  /// 两个端点都试：PC 客户端走的 `/desktop/account/login`（GoQuark 的做法），
  /// 失败再退回 `/account/info?lw=scan`（QuarkLite 的做法）。
  Future<String?> _exchangeTicket(String ticket) async {
    final Map<String, String> device = await _deviceIdentity();
    final List<Map<String, String>> attempts = <Map<String, String>>[
      <String, String>{
        'url': _panLoginUrl,
        'st': ticket,
        'fr': 'pc',
        'pr': 'ucpro',
        'mi': device['mi']!,
        'ut': device['ut']!,
      },
      <String, String>{
        'url': 'https://pan.quark.cn/account/info',
        'st': ticket,
        'lw': 'scan',
      },
    ];

    for (final Map<String, String> attempt in attempts) {
      final String url = attempt.remove('url')!;
      try {
        final Response<dynamic> response = await _dio.get<dynamic>(
          url,
          queryParameters: attempt,
          options: _options,
        );
        final Map<String, String> cookies = _cookiesOf(response.headers['set-cookie'] ?? const <String>[]);
        if (cookies.isNotEmpty) {
          return cookies.entries.map((MapEntry<String, String> e) => '${e.key}=${e.value}').join('; ');
        }
      } on Object {
        // 换下一个端点。
      }
    }
    return null;
  }

  static Map<String, String> _cookiesOf(List<String> headers) {
    final Map<String, String> cookies = <String, String>{};
    for (final String header in headers) {
      final String pair = header.split(';').first.trim();
      final int eq = pair.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final String name = pair.substring(0, eq).trim();
      // 这两个是退出/推送相关标记，不是会话凭证。
      if (name == 'push_vurl' || name == 'logout_id') {
        continue;
      }
      cookies[name] = pair.substring(eq + 1).trim();
    }
    return cookies;
  }

  Options get _options => Options(
        headers: <String, String>{
          'User-Agent': userAgent,
          'Accept': 'application/json, text/plain, */*',
          'Referer': 'https://pan.quark.cn/',
          'Origin': 'https://pan.quark.cn',
        },
        responseType: ResponseType.json,
      );

  Future<Map<String, String>> _baseParams() async {
    final Map<String, String> device = await _deviceIdentity();
    return <String, String>{
      'pr': 'ucpro',
      'fr': 'pc',
      'sys': 'darwin',
      'client_id': clientId,
      'v': clientVersion,
      'request_id': DateTime.now().microsecondsSinceEpoch.toString(),
      'uc_param_str': 'utprfr',
      'ut': device['ut']!,
      'mi': device['mi']!,
    };
  }

  /// 设备身份：`ut` 是随机但固定的机器码，`mi` 是夸克设备列表里显示的名字。
  Future<Map<String, String>> _deviceIdentity() async {
    String? id = await _secureStore.read(_deviceIdAccount);
    if (id == null || id.isEmpty) {
      id = _randomDeviceId();
      await _secureStore.write(_deviceIdAccount, id);
    }
    return <String, String>{'ut': id, 'mi': '听屿'};
  }

  static String _randomDeviceId() {
    const String chars = 'abcdef0123456789';
    final Random random = Random.secure();
    return List<String>.generate(32, (_) => chars[random.nextInt(chars.length)]).join();
  }

  static int _statusOf(Map<String, dynamic>? body) {
    final Object? status = body?['status'];
    return status is int ? status : (status is String ? int.tryParse(status) ?? 0 : 0);
  }

  static String _messageOf(Map<String, dynamic>? body) => body?['message'] as String? ?? '';

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
