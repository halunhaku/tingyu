import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/design/tokens/tokens.dart';

/// 统一 UI 测试入口：注入尺寸 → 解析外壳形态与尺寸令牌 → 提供设计系统主题。
///
/// 用法：
/// ```dart
/// await pumpTyApp(tester, home: const TyLibraryPage(), size: TyTestSizes.phone);
/// ```
/// 断言布局时用 [TyTestSizes] 的三个参考尺寸，避免每个测试各写一套魔数。
Future<void> pumpTyApp(
  WidgetTester tester, {
  required Widget home,
  Size size = TyTestSizes.desktop,
  Brightness brightness = Brightness.light,
  TyDensity density = TyDensity.comfortable,
  List<Override> overrides = const <Override>[],
  TextStyle? textStyle,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final TyLayoutScope scope = layoutScopeFor(size, density);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        formFactorProvider.overrideWithValue(scope.formFactor),
        ...overrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: TyTheme.build(brightness: brightness, density: density),
        home: TyLayoutScope(
          width: scope.width,
          formFactor: scope.formFactor,
          metrics: scope.metrics,
          traits: scope.traits,
          child: home,
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 参考尺寸（`docs/UX_REDESIGN.md` §12 的验收尺寸）。
abstract final class TyTestSizes {
  /// 桌面大窗。
  static const Size desktop = Size(1440, 900);

  /// 桌面最小可用窗（`TyLayoutScope.minWindowSize` 之上）。
  static const Size desktopMin = Size(1280, 720);

  /// medium 形态（NavigationRail）。
  static const Size tablet = Size(900, 800);

  /// 手机竖屏。
  static const Size phone = Size(412, 915);

  /// 手机小屏（边界）。
  static const Size phoneSmall = Size(360, 640);
}

/// 按尺寸与密度构造布局作用域（测试与真实外壳共用同一套解析逻辑）。
TyLayoutScope layoutScopeFor(
  Size size, [
  TyDensity density = TyDensity.comfortable,
]) {
  final FormFactor formFactor = FormFactor.ofWidth(size.width);
  return TyLayoutScope(
    width: size.width,
    formFactor: formFactor,
    metrics: TyMetrics.resolve(formFactor, density),
    traits: PlatformTraits.forPlatform(defaultTargetPlatform),
    child: const SizedBox.shrink(),
  );
}

/// 读取某个尺寸下的尺寸令牌（断言行高、网格列数等）。
TyMetrics metricsFor(Size size, [TyDensity density = TyDensity.comfortable]) =>
    TyMetrics.resolve(FormFactor.ofWidth(size.width), density);

/// 有界推进若干帧：结束态**不能**用 `pumpAndSettle` 的页面（骨架微光、播放音柱
/// 这类永久动画）必须用这个。
Future<void> pumpFrames(
  WidgetTester tester, {
  int frames = 20,
  Duration step = const Duration(milliseconds: 50),
}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// 推进直到 [condition] 成立；超时就失败（比 `pumpAndSettle` 更早、更有信息量）。
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration step = const Duration(milliseconds: 50),
  int maxFrames = 200,
}) async {
  for (int i = 0; i < maxFrames; i++) {
    if (condition()) {
      return;
    }
    await tester.pump(step);
  }
  if (!condition()) {
    fail('pumpUntil 超时：条件未在 ${maxFrames * step.inMilliseconds}ms 内成立');
  }
}

/// 收尾：先把树拆掉再结束测试。
///
/// 真实的 drift 曲库（`databaseProvider` 覆盖成内存库、或页面自己读来源/歌单流）
/// 会在 widget 测试里留下流查询的定时器，框架据此判定「树拆掉后仍有 pending timer」；
/// 先把 provider 释放掉，订阅取消，定时器随之消失。
Future<void> unmountApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // 多推一段时间：让防抖这类一次性定时器落地，避免被判定成「树拆掉后仍有 pending timer」。
  await tester.pump(const Duration(seconds: 1));
}

/// 读取当前挂载的布局作用域（测试里断言 traits / metrics 用）。
TyLayoutScope layoutScopeOf(WidgetTester tester) =>
    TyLayoutScope.of(tester.element(find.byType(TyLayoutScope).first));

/// 在指定平台的能力下执行测试体。
///
/// `testWidgets` 会在**每次用例结束时**断言「foundation debug 变量已还原」，
/// 而 `tearDown` 跑在那之后——所以平台的覆盖必须在用例体内 try/finally 里恢复。
Future<void> withTargetPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}
