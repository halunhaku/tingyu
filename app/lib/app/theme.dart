import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 旧版 `Color.appleMusicRed`（0.98, 0.14, 0.24）。
const Color appleMusicRed = Color(0xFFFA243C);

/// 各平台密度：桌面沿用紧凑密度（鼠标指向精确，旧版观感也如此）；
/// Android/iOS 上用 `VisualDensity.compact` 会把 Material 的点击目标压到
/// 48dp 以下，触屏上容易点不中，因此移动端保持标准密度。
VisualDensity platformVisualDensity(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => VisualDensity.compact,
      _ => VisualDensity.standard,
    };

/// 听屿主题：Material 3 打底，强调色沿用旧版的 Apple Music 红。
ThemeData buildTingyuTheme(Brightness brightness) {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: appleMusicRed,
    brightness: brightness,
  );
  final ThemeData base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: platformVisualDensity(defaultTargetPlatform),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: ZoomPageTransitionsBuilder(),
        TargetPlatform.windows: ZoomPageTransitionsBuilder(),
      },
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.4),
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    cardTheme: base.cardTheme.copyWith(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
  );
}
