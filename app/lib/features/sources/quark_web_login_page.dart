import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../sources/quark/quark_auth.dart';
import '../../sources/quark/quark_drive_client.dart';
import '../../sources/quark/quark_session.dart';
import '../../sources/quark/quark_web_navigation.dart';

/// 夸克登录（网页版）：应用内打开**官方登录页**，登录完成后自动读取系统 Cookie 存储里的凭证。
///
/// 三个已踩过的坑，都写在这里免得重犯：
/// 1. 不能打开 `pan.quark.cn` 网页版主界面：移动 UA 会被导到"立即下载"推广页，
///    桌面 UA 的桌面布局在手机宽度下排不开、无法滑动。
///    → 直接跳官方登录页：手机用移动版表单，桌面用扫码版。
/// 2. 不能沿用 WebView 默认 UA：它带 `wv` 与 `Version/4.0`，夸克会判定为"App 内嵌页"
///    并尝试拉起夸克 App，表现为"点登录没反应"。→ 去掉这两个标记。
/// 3. **必须接管 `intent://` 等非 http 跳转**：夸克登录页会发 intent 想拉起夸克 App。
///    WebView / url_launcher 都处理不了，点登录没反应；再点一次会碰到作废的登录态。
///    有浏览器回退地址时改在当前 WebView 里继续，不跳出到夸克 App。
///
/// 返回值：登录成功后的统一 [QuarkSession]；用户取消返回 null。
class QuarkWebLoginPage extends StatefulWidget {
  const QuarkWebLoginPage({super.key, required this.authCore});

  final QuarkAuthCore authCore;

  /// 官方登录页（地址取自夸克网页版前端 bundle）。
  static const String desktopLoginUrl =
      'https://uop.quark.cn/cas/custom/login?custom_login_type=common&client_id=532&display=pc';

  /// 手机不要打开 pan.quark.cn：移动 UA 会进「立即下载」推广页。
  /// 也不要打开 custom_login_type=mobile：那是拉起夸克 App 的短信页。
  /// PC 扫码页 + 桌面 UA 才能在 WebView 里把登录走完。
  static String get loginUrl => desktopLoginUrl;

  /// 登录链路会跨多个夸克域名；逐域读取并交给统一 CookieJar 去重。
  static const List<String> cookieOrigins = <String>[
    'https://pan.quark.cn',
    'https://drive.quark.cn',
    'https://drive-pc.quark.cn',
    'https://passport.quark.cn',
    'https://uop.quark.cn',
  ];

  @override
  State<QuarkWebLoginPage> createState() => _QuarkWebLoginPageState();
}

class _QuarkWebLoginPageState extends State<QuarkWebLoginPage> {
  final WebViewController _controller = WebViewController();

  Timer? _poller;
  bool _checking = false;
  bool _busy = false;
  String _currentUrl = '';
  String _hint = '请用夸克 App 扫描下方二维码，成功后会自动返回';

  @override
  void initState() {
    super.initState();
    _prepare();
    // 登录成功后页面可能停在回调地址，靠轮询而不是页面事件来发现。
    _poller = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _probeCookies(),
    );
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
        // WebView 的平台侧消息可能在页面 dispose 之后才投递到 Dart；
        // dispose 只取消了定时器，这里必须自己挡住 setState。
        onPageStarted: (String url) {
          if (!mounted) {
            return;
          }
          setState(() => _currentUrl = url);
        },
        onPageFinished: (String url) {
          if (!mounted) {
            return;
          }
          setState(() => _currentUrl = url);
          _fitDesktopLayout();
          _rewriteIntentLinks();
          _probeCookies();
        },
        onNavigationRequest: (NavigationRequest request) =>
            _handleNavigation(request),
      ),
    );
    // 控制台日志打给 logcat，便于线上排查登录卡点。
    await _controller.setOnConsoleMessage(
      (JavaScriptConsoleMessage message) => debugPrint(
        '[quark-webview] ${message.level.name}: ${message.message}',
      ),
    );
    await _controller.setUserAgent(await _userAgent());
    await _enableAndroidThirdPartyCookies();
    await _controller.loadRequest(Uri.parse(QuarkWebLoginPage.loginUrl));
  }

  /// CAS 登录跨 uop / pan / drive 多个域；Android 默认拦截第三方 Cookie。
  Future<void> _enableAndroidThirdPartyCookies() async {
    final Object cookiePlatform = WebViewCookieManager().platform;
    final Object controllerPlatform = _controller.platform;
    if (controllerPlatform is AndroidWebViewController) {
      // 默认 false：桌面登录页按 360px 排版，二维码被媒体查询藏掉，只剩两个空输入框。
      await controllerPlatform.setUseWideViewPort(true);
      if (cookiePlatform is AndroidWebViewCookieManager) {
        await cookiePlatform.setAcceptThirdPartyCookies(
          controllerPlatform,
          true,
        );
      }
    }
  }

  /// 非 http(s) 跳转：尽量抽成 https 回退地址，继续留在本页登录。
  Future<NavigationDecision> _handleNavigation(
    NavigationRequest request,
  ) async {
    final Uri? inApp = resolveQuarkWebNavigation(request.url);
    if (inApp == null) {
      debugPrint('[quark-webview] 拦截无法继续的跳转: ${request.url}');
      await _continueAfterAppHandoff();
      return NavigationDecision.prevent;
    }
    if (inApp.toString() == request.url) {
      return NavigationDecision.navigate;
    }
    debugPrint('[quark-webview] intent 回退到 $inApp');
    await _controller.loadRequest(inApp);
    unawaited(_probeCookies());
    return NavigationDecision.prevent;
  }

  /// 短信验证通过后夸克常只发 `quark://` / 无 fallback 的 intent。
  /// 请求其实已经成功（验证码被用掉），这里立刻收 Cookie 并打开网盘页把会话补齐。
  Future<void> _continueAfterAppHandoff() async {
    if (mounted) {
      setState(() => _hint = '正在完成登录…');
    }
    await _probeCookies();
    if (mounted == false) {
      return;
    }
    await _controller.loadRequest(Uri.parse('https://pan.quark.cn/list'));
  }

  Future<void> _fitDesktopLayout() async {
    try {
      await _controller.runJavaScript(r'''(function () {
  document.querySelectorAll('meta[name="viewport"]').forEach(function (node) {
    node.remove();
  });
  var meta = document.createElement('meta');
  meta.name = 'viewport';
  meta.content = 'width=1280, initial-scale=0.28, maximum-scale=3, user-scalable=yes';
  document.head.appendChild(meta);
})();''');
    } on Object catch (error) {
      debugPrint('[quark-webview] 适配桌面布局失败: $error');
    }
  }

  Future<void> _rewriteIntentLinks() async {
    try {
      await _controller.runJavaScript(r'''(function () {
  function fallback(href) {
    var match = href.match(/S\.browser_fallback_url=([^;]+)/);
    if (match) {
      try { return decodeURIComponent(match[1]); } catch (e) { return null; }
    }
    return null;
  }
  document.addEventListener('click', function (event) {
    var node = event.target;
    while (node && node.tagName !== 'A') {
      node = node.parentElement;
    }
    if (!node || !node.href || node.href.indexOf('intent:') !== 0) {
      return;
    }
    var next = fallback(node.href);
    if (next) {
      event.preventDefault();
      event.stopPropagation();
      window.location.href = next;
    }
  }, true);
})();''');
    } on Object catch (error) {
      debugPrint('[quark-webview] 注入 intent 拦截失败: $error');
    }
  }

  /// 登录页必须用桌面 UA，否则会进下载推广页或 App 唤起页。
  Future<String> _userAgent() async {
    return QuarkDriveClient.userAgent;
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
      try {
        final QuarkSession session = await widget.authCore.authenticate(cookie);
        if (mounted) {
          _poller?.cancel();
          Navigator.of(context).pop(session);
        }
      } on QuarkAuthException {
        // 尚未登录的匿名 Cookie 或临时网络失败都不打断官方登录页，继续轮询。
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
        final List<WebViewCookie> cookies = await manager.getCookies(
          domain: Uri.parse(origin),
        );
        for (final WebViewCookie cookie in cookies) {
          if (cookie.value.isNotEmpty) {
            merged[cookie.name] = cookie.value;
          }
        }
      } on Object {
        // 某个域读不到不影响另一个域。
      }
    }
    return merged.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');
  }

  Future<void> _finishManually() async {
    setState(() {
      _busy = true;
      _hint = '正在校验登录状态…';
    });
    final String cookie = await _readCookieHeader();
    if (!mounted) {
      return;
    }
    if (cookie.isEmpty) {
      setState(() {
        _busy = false;
        _hint = '还没拿到登录凭证，请先在页面里完成登录';
      });
      return;
    }
    try {
      final QuarkSession session = await widget.authCore.authenticate(cookie);
      if (mounted) {
        Navigator.of(context).pop(session);
      }
    } on QuarkAuthException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _hint = error.message;
        });
      }
    }
  }

  Widget _buildWebView() {
    const Set<Factory<OneSequenceGestureRecognizer>> gestures =
        <Factory<OneSequenceGestureRecognizer>>{
          Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
        };
    if (Platform.isAndroid) {
      return WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams(
          controller: _controller.platform,
          displayWithHybridComposition: true,
          gestureRecognizers: gestures,
        ),
      );
    }
    return WebViewWidget(controller: _controller, gestureRecognizers: gestures);
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
          Expanded(child: _buildWebView()),
        ],
      ),
    );
  }
}
