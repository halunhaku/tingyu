import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../sources/quark/quark_drive_client.dart';

/// 夸克网盘登录页：应用内打开官方网页，登录完成后自动抓取凭证。
///
/// 为什么不自己实现账号/扫码登录：夸克没有面向第三方的公开授权接口，
/// 逆向出来的扫码接口随时可能失效。内嵌官方网页 + 读取系统 Cookie 存储
/// 是最稳的做法（旧版 Swift 也是这么做的，只是它用 WKWebView）。
///
/// 返回值为登录成功后的 Cookie 串；用户取消返回 null。
class QuarkLoginPage extends StatefulWidget {
  const QuarkLoginPage({super.key});

  /// 当前平台是否有官方 WebView 实现（webview_flutter 只覆盖 Android/iOS/macOS）。
  static bool get isSupported => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// 用网页版入口：未登录时它会跳到登录页（含扫码与账号登录）。
  static const String loginUrl = 'https://pan.quark.cn/list';

  @override
  State<QuarkLoginPage> createState() => _QuarkLoginPageState();
}

class _QuarkLoginPageState extends State<QuarkLoginPage> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    // 关键：用桌面 UA。移动 UA 会被导到"立即下载"推广页，拿不到网页版登录界面；
    // 这里刻意与 API 请求所用的 UA 保持一致（QuarkDriveClient.userAgent）。
    ..setUserAgent(QuarkDriveClient.userAgent)
    ..setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (String url) => _probeCookies(),
      ),
    )
    ..loadRequest(Uri.parse(QuarkLoginPage.loginUrl));

  final QuarkDriveClient _client = QuarkDriveClient();

  Timer? _poller;
  bool _checking = false;
  bool _busy = false;
  String _hint = '请在下方页面完成登录，成功后会自动返回';

  @override
  void initState() {
    super.initState();
    // 登录页可能长时间停留在同一 URL，靠轮询而不是页面事件来发现登录完成。
    _poller = Timer.periodic(const Duration(seconds: 3), (_) => _probeCookies());
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  /// 读取系统 Cookie 存储里的凭证并校验；成功即返回上一页。
  Future<void> _probeCookies() async {
    if (_checking || _busy || !mounted) {
      return;
    }
    _checking = true;
    try {
      final String cookie = await _readCookieHeader();
      if (cookie.isEmpty) {
        return;
      }
      final ({bool isValid, String nickname}) result = await _client.verifyCookie(cookie);
      if (result.isValid && mounted) {
        _poller?.cancel();
        Navigator.of(context).pop(cookie);
      }
    } finally {
      _checking = false;
    }
  }

  Future<String> _readCookieHeader() async {
    try {
      final List<WebViewCookie> cookies = await WebViewCookieManager()
          .getCookies(domain: Uri.parse(QuarkLoginPage.loginUrl));
      return cookies
          .where((WebViewCookie cookie) => cookie.value.isNotEmpty)
          .map((WebViewCookie cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
    } on Object {
      return '';
    }
  }

  /// 手动完成：给出更明确的提示，避免用户以为卡住了。
  Future<void> _finishManually() async {
    setState(() {
      _busy = true;
      _hint = '正在校验登录状态…';
    });
    final String cookie = await _readCookieHeader();
    if (cookie.isEmpty) {
      setState(() {
        _busy = false;
        _hint = '还没拿到登录凭证，请先在页面里完成登录';
      });
      return;
    }
    final ({bool isValid, String nickname}) result = await _client.verifyCookie(cookie);
    if (!mounted) {
      return;
    }
    if (result.isValid) {
      Navigator.of(context).pop(cookie);
      return;
    }
    setState(() {
      _busy = false;
      _hint = '未检测到有效登录（凭据可能未生效），请在页面里重新登录后再点完成';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录夸克网盘'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
          TextButton(
            onPressed: _busy ? null : _finishManually,
            child: const Text('完成'),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              _hint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
