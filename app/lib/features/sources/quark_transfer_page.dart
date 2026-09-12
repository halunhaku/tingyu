import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 桌面端：把已登录的夸克凭证交给手机。
///
/// 为什么用"局域网一次性配对"而不是把凭证直接塞进二维码：
/// 夸克的 Cookie 可能上千字符，二维码容量吃紧、扫起来也慢；这里二维码里只放一个
/// 短链接（`http://<本机IP>:<端口>/q?t=<一次性token>`），手机扫到后**只在局域网内**
/// 取一次凭证，取完立即关闭服务。
///
/// 安全边界：token 随机、一次性、120 秒后失效；服务只绑定本机地址且只响应这一个路径。
class QuarkTransferPage extends StatefulWidget {
  const QuarkTransferPage({super.key, required this.cookie});

  final String cookie;

  @override
  State<QuarkTransferPage> createState() => _QuarkTransferPageState();
}

class _QuarkTransferPageState extends State<QuarkTransferPage> {
  static const Duration _ttl = Duration(minutes: 2);

  HttpServer? _server;
  Timer? _timer;
  String _status = '正在准备配对链接…';
  String? _pairUrl;
  bool _served = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_server?.close(force: true));
    super.dispose();
  }

  Future<void> _start() async {
    final String? host = await _lanAddress();
    if (host == null) {
      setState(() => _status = '没有找到局域网地址，请确认已连接 Wi-Fi');
      return;
    }
    final String token = _randomToken();
    final HttpServer server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    final String pairUrl = 'http://$host:${server.port}/q?t=$token';
    setState(() {
      _pairUrl = pairUrl;
      _status = '请在手机上：来源管理 → 添加来源 → 夸克网盘 → 扫描此码';
    });

    _timer = Timer(_ttl, () {
      if (mounted && !_served) {
        setState(() => _status = '配对链接已过期，请关闭本页重新打开');
      }
      unawaited(server.close(force: true));
    });

    unawaited(() async {
      await for (final HttpRequest request in server) {
        if (request.uri.path != '/q' || request.uri.queryParameters['t'] != token) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, String>{'cookie': widget.cookie}));
        await request.response.close();
        _served = true;
        if (mounted) {
          setState(() => _status = '已发送给手机，本页可以关闭了');
        }
        await server.close(force: true);
        break;
      }
    }());
  }

  static Future<String?> _lanAddress() async {
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final NetworkInterface interface in interfaces) {
        for (final InternetAddress address in interface.addresses) {
          if (!address.isLoopback) {
            return address.address;
          }
        }
      }
    } on Object {
      return null;
    }
    return null;
  }

  static String _randomToken() {
    const String chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final Random random = Random.secure();
    return List<String>.generate(12, (_) => chars[random.nextInt(chars.length)]).join();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('手机扫码接管登录')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (_pairUrl != null)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(data: _pairUrl!, size: 220, backgroundColor: Colors.white),
                  )
                else
                  const SizedBox(
                    width: 220,
                    height: 220,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                const SizedBox(height: 16),
                Text(_status, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  '二维码只包含一个局域网地址与一次性口令；凭证通过本机网络直传，'
                  '不会经过任何第三方服务器。手机与这台电脑需要在同一个 Wi-Fi 下。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                if (_pairUrl != null) ...<Widget>[
                  const SizedBox(height: 16),
                  SelectableText(
                    _pairUrl!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall,
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
