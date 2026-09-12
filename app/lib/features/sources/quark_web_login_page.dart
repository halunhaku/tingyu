import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../sources/quark/quark_drive_client.dart';

/// 夸克登录（网页版）：应用内打开**官方登录页**，登录完成后自动读取系统 Cookie 存储里的凭证。
///
/// 三个已踩过的坑，都写在这里免得重犯：
/// 1. 不能打开 `pan.quark.cn` 网页版主界面：移动 UA 会被导到"立即下载"推广页，
///    桌面 UA 的桌面布局在手机宽度下排不开、无法滑动。
///    → 直接跳官方登录页：手机用移动版表单，桌面用扫码版。
/// 2. 不能沿用 WebView 默认 UA：它带 `wv` 与 `Version/4.0`，夸克会判定为"App 内嵌页"
///    并尝试拉起夸克 App，表现为"点登录没反应"。→ 去掉这两个标记。
/// 3. **必须接管 `intent://` 等非 http 跳转**：夸克登录页在手机上会通过 intent 跳转拉起
///    夸克 App 做授权（浏览器就是这么做的）；WebView 自己不会处理，于是同样表现为"点了没反应"。
///    这里改成交给系统打开（`url_launcher` 在 Android 上会正确解析 intent://）。
///
/// 返回值：登录成功后的 Cookie 串；用户取消返回 null。
class QuarkWebLoginPage extends StatefulWidget {
  const QuarkWebLoginPage({super.key});

  /// 官方登录页（地址取自夸克网页版前端 bundle）。
  static const String mobileLoginUrl =
      'https://uop.quark.cn/cas/custom/login?custom_login_type=mobile&client_id=503&display=mobile';

  static const String desktopLoginUrl =
      'https://uop.quark.cn/cas/custom/login?custom_login_type=common&client_id=532&display=pc';

  static String get loginUrl => Platform.isMacOS ? desktopLoginUrl : mobileLoginUrl;

  /// 登录后凭证落在 `.quark.cn` 域上，两个站点都读一遍再合并。
  static const List<String> cookieOrigins = <String>[
    'https://pan.quark.cn',
    'https://uop.quark.cn',
  ];

  @override
  State<QuarkWebLoginPage> createState() => _QuarkWebLoginPageState();
}

class _QuarkWebLoginPageState extends State<QuarkWebLoginPage> {
  final WebViewController _controller = WebViewController();

  final QuarkDriveClient _client = QuarkDriveClient();

  Timer? _poller;
  bool _checking = false;
  bool _busy = false;
  String _currentUrl = '';
  String _hint = '请在下方页面完成登录，成功后会自动返回';

  @override
  void initState() {
    super.initState();
    _prepare();
    // 登录成功后页面可能停在回调地址，靠轮询而不是页面事件来发现。
    _poller = Timer.periodic(const Duration(seconds: 3), (_) => _probeCookies());
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _prepare() async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (String url) => setState(() => _currentUrl = url),
        onPageFinished: (String url) {
          setState(() => _currentUrl = url);
          _probeCookies();
        },
        onNavigationRequest: (NavigationRequest request) => _handleNavigation(request),
      ),
    );
    // 控制台日志打给 logcat，便于线上排查登录卡点。
    await _controller.setOnConsoleMessage(
      (JavaScriptConsoleMessage message) =>
          debugPrint('[quark-webview] ${message.level.name}: ${message.message}'),
    );
    await _controller.setUserAgent(await _userAgent());
    await _controller.loadRequest(Uri.parse(QuarkWebLoginPage.loginUrl));
  }

  /// 非 http(s) 跳转（`intent://`、`quark://` 等）交给系统：
  /// 这正是"打开夸克 App 授权登录"的入口，WebView 自己处理不了。
  Future<NavigationDecision> _handleNavigation(NavigationRequest request) async {
    final Uri? uri = Uri.tryParse(request.url);
    final String scheme = uri?.scheme ?? '';
    if (scheme.isEmpty || scheme == 'http' || scheme == 'https') {
      return NavigationDecision.navigate;
    }
    try {
      await launchUrl(uri!, mode: LaunchMode.externalApplication);
      setState(() => _hint = '已打开夸克 App，请在 App 内确认后返回本页');
    } on Object catch (error) {
      debugPrint('[quark-webview] 打开外部应用失败: $error');
      setState(() => _hint = '无法打开夸克 App：$error');
    }
    return NavigationDecision.prevent;
  }

  /// 桌面用与 API 一致的 UA；手机用去掉 `wv` / `Version/x.x` 的干净浏览器 UA。
  Future<String> _userAgent() async {
    if (Platform.isMacOS) {
      return QuarkDriveClient.userAgent;
    }
    const String fallback = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
    try {
      final String? system = await _controller.getUserAgent();
      if (system == null || system.isEmpty) {
        return fallback;
      }
      return system
          .replaceAll(RegExp(r';\s*wv\b'), '')
          .replaceAll(RegExp(r'\s*Version/[\d.]+'), '');
    } on Object {
      return fallback;
    }
  }

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
    final Map<String, String> merged = <String, String>{};
    final WebViewCookieManager manager = WebViewCookieManager();
    for (final String origin in QuarkWebLoginPage.cookieOrigins) {
      try {
        final List<WebViewCookie> cookies = await manager.getCookies(domain: Uri.parse(origin));
        for (final WebViewCookie cookie in cookies) {
          if (cookie.value.isNotEmpty) {
            merged[cookie.name] = cookie.value;
          }
        }
      } on Object {
        // 某个域读不到不影响另一个域。
      }
    }
    return merged.entries.map((MapEntry<String, String> e) => '${e.key}=${e.value}').join('; ');
  }

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
      _hint = '未检测到有效登录，请完成登录后再点「完成」';
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(_hint, style: Theme.of(context).textTheme.bodySmall),
                if (_currentUrl.isNotEmpty)
                  Text(
                    _currentUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
