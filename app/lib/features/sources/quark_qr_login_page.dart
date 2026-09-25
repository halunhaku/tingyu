import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tingyu_saf/tingyu_saf.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../sources/quark/quark_auth.dart';
import '../../sources/quark/quark_qr_login.dart';
import '../../sources/quark/quark_session.dart';

/// 夸克扫码登录页：申请二维码、轮询确认，再交给统一认证核心校验。
class QuarkQrLoginPage extends StatefulWidget {
  const QuarkQrLoginPage({super.key, required this.authCore});

  final QuarkAuthCore authCore;

  @override
  State<QuarkQrLoginPage> createState() => _QuarkQrLoginPageState();
}

class _QuarkQrLoginPageState extends State<QuarkQrLoginPage> {
  final QuarkQrLogin _login = QuarkQrLogin();

  /// 实测 token 约 181 秒失效；两分钟主动轮换，避免用户扫到临期二维码。
  static const Duration _qrLifetime = Duration(seconds: 120);

  QuarkQrSession? _session;
  Timer? _poller;
  DateTime? _issuedAt;
  String _status = '正在申请二维码…';
  bool _loading = true;
  bool _failed = false;
  bool _polling = false;

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

  int get _secondsLeft {
    final DateTime? issuedAt = _issuedAt;
    if (issuedAt == null) {
      return _qrLifetime.inSeconds;
    }
    final int left =
        _qrLifetime.inSeconds - DateTime.now().difference(issuedAt).inSeconds;
    return left < 0 ? 0 : left;
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
        _issuedAt = DateTime.now();
        _loading = false;
        _failed = false;
        _status = Platform.isAndroid || Platform.isIOS
            ? '请点下方按钮，在夸克 App 里确认（不用扫这个屏幕）'
            : '请打开夸克 App → 扫一扫';
      });
      if (Platform.isAndroid || Platform.isIOS) {
        unawaited(_openInQuarkApp(session.qrContent));
      }
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

  Future<void> _tick() async {
    final QuarkQrSession? session = _session;
    if (session == null || _polling || _loading || _failed || !mounted) {
      return;
    }
    if (_secondsLeft <= 0) {
      await _refresh();
      if (mounted && !_failed) {
        setState(() => _status = '二维码已自动更新，请重新扫描');
      }
      return;
    }

    _polling = true;
    setState(() {});
    try {
      final QuarkQrPollResult result = await _login.poll(session);
      if (!mounted) {
        return;
      }
      switch (result.phase) {
        case QuarkQrPhase.waitingScan:
          setState(() => _status = result.message);
        case QuarkQrPhase.expired:
          setState(() => _status = '二维码已过期，正在换一张…');
          await _refresh();
        case QuarkQrPhase.error:
          setState(() {
            _failed = true;
            _status = result.message;
          });
        case QuarkQrPhase.scanned:
          setState(() => _status = '已确认，正在返回听屿…');
          if (Platform.isAndroid) {
            await TingyuSaf.bringToForeground();
          }
          try {
            final QuarkSession authenticated = await widget.authCore
                .authenticate(result.cookie ?? '');
            if (!mounted) {
              return;
            }
            _poller?.cancel();
            Navigator.of(context).pop(authenticated);
          } on QuarkAuthException catch (error) {
            setState(() {
              _failed = true;
              _status = error.message;
            });
          }
      }
    } on Object catch (error, stackTrace) {
      if (mounted) {
        final String detail = '${error.runtimeType}: $error';
        debugPrint('[quark-qr] $detail\n$stackTrace');
        setState(() {
          _failed = true;
          _status = '轮询失败：$detail';
        });
      }
    } finally {
      _polling = false;
    }
  }

  /// 同机无法扫描自己的屏幕，可把二维码链接交给夸克 App 打开确认。
  Future<void> _openInQuarkApp(String qrContent) async {
    try {
      bool opened = false;
      if (Platform.isAndroid) {
        opened = await TingyuSaf.openInQuark(qrContent);
      } else {
        opened = await launchUrl(
          Uri.parse(qrContent),
          mode: LaunchMode.externalApplication,
        );
      }
      if (mounted) {
        setState(
          () => _status = opened ? '已打开夸克 App，请在里面点确认' : '没找到夸克 App，请先安装后再点按钮',
        );
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _status = '打开失败：$error');
      }
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
                            child: Icon(
                              Icons.qr_code_2,
                              size: 64,
                              color: scheme.outline,
                            ),
                          ),
                        )
                      : QrImageView(
                          data: session.qrContent,
                          size: 220,
                          backgroundColor: Colors.white,
                        ),
                ),
                const SizedBox(height: 12),
                if (session != null && !_loading && !_failed)
                  Text(
                    '二维码 $_secondsLeft 秒后自动更新',
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                const SizedBox(height: 8),
                Text(_status, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                if (session != null)
                  FilledButton.icon(
                    onPressed: () => _openInQuarkApp(session.qrContent),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(
                      Platform.isAndroid || Platform.isIOS
                          ? '打开夸克 App 确认登录'
                          : '在夸克 App 中打开并确认',
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  Platform.isAndroid || Platform.isIOS
                      ? '同一部手机不用扫自己的屏幕。点按钮跳到夸克 App，点确认即可。\n二维码每 2 分钟自动换一次。'
                      : '也可以用另一台设备上的夸克 App 扫码。\n二维码每 2 分钟自动换一次；扫码后请尽快在手机上确认。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
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
