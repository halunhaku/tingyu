import 'package:flutter/material.dart';

/// 旧版 `Color.appleMusicRed`（0.98, 0.14, 0.24）。
const Color appleMusicRed = Color(0xFFFA243C);

/// 听屿主题：Material 3 打底，强调色沿用旧版的 Apple Music 红。
ThemeData buildTingyuTheme(Brightness brightness) {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: appleMusicRed,
    brightness: brightness,
  );
  final ThemeData base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
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
