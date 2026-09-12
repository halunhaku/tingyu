import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../sources/quark/quark_drive_client.dart';

/// 手机端：扫描桌面版显示的配对二维码，接管其夸克登录凭证。
///
/// 桌面端登录（官方扫码）成功后，会开一个**局域网内**的临时服务，二维码里只有一个
/// `http://<ip>:<port>/q?t=<一次性口令>`；这里扫码 → 取回凭证 → 校验 → 返回。
/// 之所以这么绕：夸克的手机号/验证码登录有风控（滑块 + 设备指纹），第三方客户端普遍绕不过，
/// 而"桌面登录 + 手机接管"完全不触发风控。
class QuarkImportPage extends StatefulWidget {
  const QuarkImportPage({super.key});

  @override
  State<QuarkImportPage> createState() => _QuarkImportPageState();
}

class _QuarkImportPageState extends State<QuarkImportPage> {
  final MobileScannerController _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final QuarkDriveClient _client = QuarkDriveClient();
  final TextEditingController _manual = TextEditingController();

  bool _busy = false;
  String _status = '把桌面版听屿上的二维码对准取景框';

  @override
  void dispose() {
    _scanner.dispose();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) {
      return;
    }
    for (final Barcode barcode in capture.barcodes) {
      final String? value = barcode.rawValue;
      if (value != null && value.startsWith('http')) {
        await _import(value);
        return;
      }
    }
  }

  Future<void> _import(String url) async {
    setState(() {
      _busy = true;
      _status = '正在取回凭证…';
    });
    try {
      final Response<Map<String, dynamic>> response = await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          validateStatus: (int? status) => status != null && status < 500,
        ),
      ).get<Map<String, dynamic>>(url);
      final String cookie = (response.data?['cookie'] as String?) ?? '';
      if (cookie.isEmpty) {
        setState(() {
          _busy = false;
          _status = '没能取到凭证（可能是链接已过期），请在桌面端重新打开该页面';
        });
        return;
      }
      setState(() => _status = '正在校验凭证…');
      final ({bool isValid, String nickname}) check = await _client.verifyCookie(cookie);
      if (!mounted) {
        return;
      }
      if (check.isValid) {
        Navigator.of(context).pop(cookie);
        return;
      }
      setState(() {
        _busy = false;
        _status = '凭证校验失败，请在桌面端重新登录后重试';
      });
    } on Object catch (error) {
      setState(() {
        _busy = false;
        _status = '取回失败：$error（手机需与电脑在同一 Wi-Fi）';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('扫码接管桌面端登录')),
      body: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(_status, style: Theme.of(context).textTheme.bodySmall),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: MobileScanner(controller: _scanner, onDetect: _onDetect),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _manual,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '或手动粘贴配对链接',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _busy
                      ? null
                      : () {
                          final String url = _manual.text.trim();
                          if (url.isNotEmpty) {
                            _import(url);
                          }
                        },
                  child: const Text('导入'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              '桌面端：来源管理 → 夸克网盘一行的「手机接管」→ 显示二维码。'
              '手机与电脑需在同一 Wi-Fi；凭证只在两台设备之间直传。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 便于测试的纯函数：从配对响应体里取出 Cookie。
String cookieFromPairResponse(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is Map<String, dynamic>) {
    return decoded['cookie'] as String? ?? '';
  }
  return '';
}
