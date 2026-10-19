import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/design/components/buttons.dart';
import 'package:tingyu/design/components/feedback.dart';
import 'package:tingyu/features/sources/quark_qr_login_page.dart';
import 'package:tingyu/features/sources/quark_web_login_page.dart';

import 'support/pump.dart';

/// 扫码 / 网页登录这两页平时没人截图，也没有真机回归：样式漂了、加载态退化成
/// 转圈、失败态没有出口，都不会被测到。这里把它们的纯展示层钉住：
/// 三形态 × 浅深主题 + 三态（加载 / 就绪 / 失败）。
void main() {
  const List<Size> sizes = <Size>[
    TyTestSizes.phone,
    TyTestSizes.tablet,
    TyTestSizes.desktop,
  ];

  testWidgets('扫码登录：三形态 × 两主题都渲染，加载用骨架、失败有重试', (
    WidgetTester tester,
  ) async {
    for (final Brightness brightness in Brightness.values) {
      for (final Size size in sizes) {
        // 加载中：骨架而不是转圈（DESIGN §10.4）。
        await pumpTyApp(
          tester,
          brightness: brightness,
          size: size,
          home: QuarkQrLoginView(
            status: '正在申请二维码…',
            qrContent: null,
            loading: true,
            failed: false,
            secondsLeft: 120,
            lifetimeSeconds: 120,
            openLabel: '在夸克 App 中打开并确认',
            hint: '也可以用另一台设备上的夸克 App 扫码。',
            onBack: () {},
            onRefresh: () {},
            onOpenInApp: () {},
          ),
        );
        expect(find.byType(TySkeleton), findsWidgets, reason: '$size $brightness');
        expect(
          find.byType(CircularProgressIndicator),
          findsNothing,
          reason: '登录页加载态不得用转圈（DESIGN §10.4）',
        );
        expect(find.text('扫码登录夸克网盘'), findsOneWidget);

        // 就绪：二维码画框 + 倒计时 + 主操作。
        await pumpTyApp(
          tester,
          brightness: brightness,
          size: size,
          home: QuarkQrLoginView(
            status: '请打开夸克 App → 扫一扫',
            qrContent: 'https://uop.quark.cn/qr?token=demo',
            loading: false,
            failed: false,
            secondsLeft: 96,
            lifetimeSeconds: 120,
            openLabel: '在夸克 App 中打开并确认',
            hint: '也可以用另一台设备上的夸克 App 扫码。',
            onBack: () {},
            onRefresh: () {},
            onOpenInApp: () {},
          ),
        );
        expect(find.text('二维码 96 秒后自动更新'), findsOneWidget);
        expect(find.text('在夸克 App 中打开并确认'), findsOneWidget);

        // 失败：错误视图 + 重试出口，不是一行红字。
        await pumpTyApp(
          tester,
          brightness: brightness,
          size: size,
          home: QuarkQrLoginView(
            status: '申请二维码失败：网络不可达',
            qrContent: null,
            loading: false,
            failed: true,
            secondsLeft: 0,
            lifetimeSeconds: 120,
            openLabel: '在夸克 App 中打开并确认',
            hint: '也可以用另一台设备上的夸克 App 扫码。',
            onBack: () {},
            onRefresh: () {},
            onOpenInApp: () {},
          ),
        );
        expect(find.byType(TyErrorView), findsOneWidget);
        expect(find.widgetWithText(TyButton, '重试'), findsOneWidget);
      }
    }
  });

  testWidgets('网页登录：三形态 × 两主题都渲染，忙碌时给进度条与禁用主操作', (
    WidgetTester tester,
  ) async {
    for (final Brightness brightness in Brightness.values) {
      for (final Size size in sizes) {
        await pumpTyApp(
          tester,
          brightness: brightness,
          size: size,
          home: QuarkWebLoginChrome(
            hint: '请用夸克 App 扫描下方二维码，成功后会自动返回',
            currentUrl: 'https://uop.quark.cn/cas/custom/login?client_id=532',
            busy: true,
            onBack: () {},
            onRefresh: () {},
            onFinish: () {},
            // WebView 在 widget 测试里跑不起来：槽位塞占位块，测的是外壳。
            child: const ColoredBox(color: Color(0xFF000000)),
          ),
        );

        expect(find.text('登录夸克网盘'), findsOneWidget);
        expect(find.byType(TyProgressBar), findsOneWidget);
        expect(find.textContaining('uop.quark.cn'), findsOneWidget);
        final TyButton finish = tester.widget<TyButton>(
          find.widgetWithText(TyButton, '完成'),
        );
        expect(finish.onPressed, isNull, reason: '校验进行中要禁用主操作');
      }
    }
  });
}
