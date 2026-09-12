import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../sources/quark/quark_drive_client.dart';
import '../../sources/quark/quark_qr_login.dart';

/// 夸克扫码登录页：应用内直接出二维码，用夸克 App 扫一下就完成。
///
/// 返回登录成功后的 Cookie 串；用户取消返回 null。
class QuarkQrLoginPage extends StatefulWidget {
  const QuarkQrLoginPage({super.key, this.allowWebFallback = false});

  /// 是否提供"改用网页登录"入口（WebView 方案，桌面端或其他兜底场景用）。
  final bool allowWebFallback;

  @override
  State<QuarkQrLoginPage> createState() => _QuarkQrLoginPageState();
}

class _QuarkQrLoginPageState extends State<QuarkQrLoginPage> {
  final QuarkQrLogin _login = QuarkQrLogin();
  final QuarkDriveClient _client = QuarkDriveClient();

  QuarkQrSession? _session;
  Timer? _poller;
  String _status = '正在申请二维码…';
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poller = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _failed = false;
      _status = '正在申请二维码…';
    });
    try {
      final QuarkQrSession session = await _login.start();
      if (!mounted) {
        return;
      }
      setState(() {
        _session = session;
        _loading = false;
        _status = '请打开夸克 App → 扫一扫';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _failed = true;
        _status = '申请二维码失败：$error';
      });
    }
  }

  bool _polling = false;

  Future<void> _tick() async {
    final QuarkQrSession? session = _session;
    if (session == null || _polling || _loading || !mounted) {
      return;
    }
    _polling = true;
    try {
      final QuarkQrPollResult result = await _login.poll(session);
      if (!mounted) {
        return;
      }
      switch (result.phase) {
        case QuarkQrPhase.waitingScan:
          setState(() => _status = result.message);
        case QuarkQrPhase.expired:
          setState(() {
            _failed = true;
            _status = result.message;
          });
        case QuarkQrPhase.error:
          setState(() {
            _failed = true;
            _status = result.message;
          });
        case QuarkQrPhase.scanned:
          final String cookie = result.cookie!;
          setState(() => _status = '已扫码，正在校验…');
          // 再校验一次，确保拿到的是可用凭证（顺便取到昵称）。
          final ({bool isValid, String nickname}) check = await _client.verifyCookie(cookie);
          if (!mounted) {
            return;
          }
          if (check.isValid) {
            _poller?.cancel();
            Navigator.of(context).pop(cookie);
          } else {
            setState(() {
              _failed = true;
              _status = '扫码完成但凭据校验失败，请刷新二维码重试';
            });
          }
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _status = '轮询失败：$error');
      }
    } finally {
      _polling = false;
    }
  }

  /// 把二维码内容当链接打开：夸克 App 注册了该域名的处理，会直接给出"确认登录"。
  Future<void> _openInQuarkApp(String qrContent) async {
    try {
      final bool opened = await launchUrl(Uri.parse(qrContent), mode: LaunchMode.externalApplication);
      setState(() => _status = opened ? '已交给夸克 App，请在 App 内确认登录' : '没有可打开该链接的应用');
    } on Object catch (error) {
      setState(() => _status = '打开失败：$error');
    }
  }

  /// 兜底入口：手动粘贴浏览器里的 Cookie。
  Future<void> _pasteCookie() async {
    final TextEditingController controller = TextEditingController();
    final String? cookie = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('粘贴夸克 Cookie'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('在电脑浏览器登录 pan.quark.cn 后，从开发者工具里复制整行 Cookie 粘贴到下面。'),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '__pus=...; __puus=...',
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('校验并使用'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (cookie == null || cookie.trim().isEmpty || !mounted) {
      return;
    }
    setState(() => _status = '正在校验粘贴的 Cookie…');
    final ({bool isValid, String nickname}) check = await _client.verifyCookie(cookie.trim());
    if (!mounted) {
      return;
    }
    if (check.isValid) {
      _poller?.cancel();
      Navigator.of(context).pop(cookie.trim());
    } else {
      setState(() => _status = '该 Cookie 校验失败，请重新复制');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final QuarkQrSession? session = _session;

    return Scaffold(
      appBar: AppBar(
        title: const Text('扫码登录夸克网盘'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新二维码',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
          // 兜底：扫码接口万一被夸克改掉，用户还能粘贴浏览器里的 Cookie 自救。
          IconButton(
            tooltip: '粘贴 Cookie（兜底）',
            icon: const Icon(Icons.content_paste),
            onPressed: _pasteCookie,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _loading
                      ? const SizedBox(
                          width: 220,
                          height: 220,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : session == null
                          ? SizedBox(
                              width: 220,
                              height: 220,
                              child: Center(
                                child: Icon(Icons.qr_code_2, size: 64, color: scheme.outline),
                              ),
                            )
                          : QrImageView(
                              data: session.qrContent,
                              size: 220,
                              backgroundColor: Colors.white,
                            ),
                ),
                const SizedBox(height: 16),
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                if (session != null)
                  // 同一台手机上没法"扫自己的屏幕"：二维码内容本身是个链接，
                  // 直接交给系统打开（有夸克 App 就跳 App，在 App 里确认即可）。
                  FilledButton.icon(
                    onPressed: () => _openInQuarkApp(session.qrContent),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('在夸克 App 中打开并确认'),
                  ),
                const SizedBox(height: 8),
                Text(
                  '另一种方式：用另一台设备上的夸克 App 扫码。\n'
                  '二维码约 2 分钟有效，过期点右上角刷新。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                if (_failed) ...<Widget>[
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: _refresh,
                    child: const Text('重新获取二维码'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
