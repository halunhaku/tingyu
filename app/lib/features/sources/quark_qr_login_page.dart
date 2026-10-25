import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/components/buttons.dart';
import '../../design/components/feedback.dart';
import '../../design/components/structure.dart';
import '../../design/layout/form_factor.dart';
import '../../design/theme.dart';
import '../../design/tokens/metrics.dart';
import '../../design/tokens/tokens.dart';
import '../../sources/quark/quark_auth.dart';
import '../../sources/quark/quark_qr_login.dart';
import '../../sources/quark/quark_session.dart';

/// 夸克扫码登录页：申请二维码、轮询确认，再交给统一认证核心校验。
///
/// 表现层全部交给 [QuarkQrLoginView]（纯展示、可测），这一层只管状态与副作用。
class QuarkQrLoginPage extends StatefulWidget {
  const QuarkQrLoginPage({super.key, required this.authCore});

  final QuarkAuthCore authCore;

  @override
  State<QuarkQrLoginPage> createState() => _QuarkQrLoginPageState();
}

class _QuarkQrLoginPageState extends State<QuarkQrLoginPage>
    with SingleTickerProviderStateMixin {
  final QuarkQrLogin _login = QuarkQrLogin();

  /// 实测 token 约 181 秒失效；两分钟主动轮换，避免用户扫到临期二维码。
  static const Duration _qrLifetime = Duration(seconds: 120);

  QuarkQrSession? _session;
  Timer? _poller;

  /// 每秒推进一次：倒计时环与「还有 N 秒」文案都靠它，不靠轮询节奏（2 秒）。
  late final Ticker _ticker;
  DateTime? _issuedAt;
  String _status = '正在申请二维码…';
  bool _loading = true;
  bool _failed = false;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((Duration _) => _onTickFrame())..start();
    _refresh();
    _poller = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _poller?.cancel();
    _ticker.dispose();
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

  void _onTickFrame() {
    // 只在真的需要重绘时 setState：每秒一次，且仅在二维码有效期内。
    if (!mounted || _session == null || _loading || _failed) {
      return;
    }
    setState(() {});
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
      final bool handheld = context.traits.touchPrimary;
      setState(() {
        _session = session;
        _issuedAt = DateTime.now();
        _loading = false;
        _failed = false;
        _status = handheld
            ? '请点下方按钮，在夸克 App 里确认（不用扫这个屏幕）'
            : '请打开夸克 App → 扫一扫';
      });
      if (handheld) {
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

  Future<void> _poll() async {
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
      final bool opened = await launchUrl(
        Uri.parse(qrContent),
        mode: LaunchMode.externalApplication,
      );
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
    final bool handheld = context.traits.touchPrimary;
    return Scaffold(
      backgroundColor: context.ty.colors.canvas,
      body: QuarkQrLoginView(
        status: _status,
        qrContent: _session?.qrContent,
        loading: _loading,
        failed: _failed,
        secondsLeft: _secondsLeft,
        lifetimeSeconds: _qrLifetime.inSeconds,
        openLabel: handheld ? '打开夸克 App 确认登录' : '在夸克 App 中打开并确认',
        hint: handheld
            ? '同一部手机不用扫自己的屏幕：点按钮跳到夸克 App，点确认即可。\n二维码每 2 分钟自动换一次。'
            : '也可以用另一台设备上的夸克 App 扫码。\n二维码每 2 分钟自动换一次；扫码后请尽快在手机上确认。',
        onBack: () => Navigator.of(context).maybePop(),
        onRefresh: _loading ? null : _refresh,
        onOpenInApp: _session == null
            ? null
            : () => _openInQuarkApp(_session!.qrContent),
      ),
    );
  }
}

/// 扫码登录的纯展示层：状态 + 回调进，像素出。
///
/// 真机上的登录页与测试渲染的是同一份布局——扫码这类页面平时没人截图，
/// 一旦样式漂了就没人发现。
class QuarkQrLoginView extends StatelessWidget {
  const QuarkQrLoginView({
    super.key,
    required this.status,
    required this.qrContent,
    required this.loading,
    required this.failed,
    required this.secondsLeft,
    required this.lifetimeSeconds,
    required this.openLabel,
    required this.hint,
    this.onBack,
    this.onRefresh,
    this.onOpenInApp,
  });

  /// 二维码边长（`DESIGN.md` §3.3 的封面尺寸之外的单列上限）。
  static const double qrSize = 220;

  final String status;

  /// null = 还没有二维码（申请失败或首次加载）。
  final String? qrContent;

  final bool loading;
  final bool failed;
  final int secondsLeft;
  final int lifetimeSeconds;
  final String openLabel;
  final String hint;
  final VoidCallback? onBack;
  final VoidCallback? onRefresh;
  final VoidCallback? onOpenInApp;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final TyMetrics metrics = context.metrics;
    final String? qr = qrContent;
    final bool ready = !loading && !failed && qr != null;
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: metrics.pagePadding,
            vertical: TySpace.x24,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (onBack != null)
                      TyIconAction(
                        icon: Icons.arrow_back,
                        semanticLabel: '返回',
                        tooltip: '返回',
                        onPressed: onBack,
                      ),
                    const SizedBox(width: TySpace.x8),
                    Expanded(
                      child: Text(
                        '扫码登录夸克网盘',
                        style: ty.typography.titleL.copyWith(
                          color: ty.colors.textPrimary,
                        ),
                      ),
                    ),
                    TyIconAction(
                      icon: Icons.refresh,
                      semanticLabel: '刷新二维码',
                      tooltip: '刷新二维码',
                      onPressed: onRefresh,
                    ),
                  ],
                ),
                const SizedBox(height: TySpace.x20),
                TyPanel(
                  child: Column(
                    children: <Widget>[
                      _QrFrame(
                        qr: qr,
                        loading: loading,
                        failed: failed,
                        onRetry: onRefresh,
                      ),
                      const SizedBox(height: TySpace.x16),
                      if (ready) ...<Widget>[
                        TyProgressBar(
                          value: 1 -
                              (secondsLeft / lifetimeSeconds).clamp(0.0, 1.0),
                        ),
                        const SizedBox(height: TySpace.x8),
                        Text(
                          '二维码 $secondsLeft 秒后自动更新',
                          textAlign: TextAlign.center,
                          style: ty.typography.numericS.copyWith(
                            color: ty.colors.textTertiary,
                          ),
                        ),
                        const SizedBox(height: TySpace.x12),
                      ],
                      if (failed)
                        TyErrorView(
                          compact: true,
                          title: '没有拿到二维码',
                          detail: status,
                          onRetry: onRefresh,
                        )
                      else
                        Text(
                          status,
                          textAlign: TextAlign.center,
                          style: ty.typography.bodyS.copyWith(
                            color: ty.colors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: TySpace.x16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    if (qr != null && !failed)
                      TyButton(
                        label: openLabel,
                        icon: Icons.open_in_new,
                        onPressed: onOpenInApp,
                      ),
                  ],
                ),
                const SizedBox(height: TySpace.x12),
                Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: ty.typography.bodyS.copyWith(
                    color: ty.colors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 二维码画框：白底是**实物语义**（相机要能读到），不是主题色。
class _QrFrame extends StatelessWidget {
  const _QrFrame({
    required this.qr,
    required this.loading,
    required this.failed,
    required this.onRetry,
  });

  final String? qr;
  final bool loading;
  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final Widget content;
    if (loading) {
      content = const TySkeleton(
        width: QuarkQrLoginView.qrSize,
        height: QuarkQrLoginView.qrSize,
        radius: TyRadius.sm,
      );
    } else if (qr == null || failed) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.qr_code_2,
            size: TySpace.x64,
            color: ty.colors.textTertiary,
          ),
          const SizedBox(height: TySpace.x8),
          Text(
            '还没有二维码',
            style: ty.typography.bodyS.copyWith(color: ty.colors.textTertiary),
          ),
        ],
      );
    } else {
      content = QrImageView(
        data: qr!,
        size: QuarkQrLoginView.qrSize,
        // guard-ok: 二维码必须黑白高对比，白底不能跟随主题。
        backgroundColor: Colors.white,
      );
    }
    return SizedBox(
      width: QuarkQrLoginView.qrSize,
      height: QuarkQrLoginView.qrSize,
      child: DecoratedBox(
        // guard-ok: 二维码白底（相机识别需要），深色主题下同样保持白底。
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(TyRadius.md),
          border: Border.all(color: ty.colors.border),
        ),
        child: Center(child: content),
      ),
    );
  }
}
