import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens/color.dart';
import 'tokens/metrics.dart';
import 'tokens/tokens.dart';
import 'tokens/typography.dart';

/// 设计系统主题构建（`DESIGN.md` §1 / §2 / §4）。
///
/// - Material `ColorScheme` 由 token **显式派生**（不是 `fromSeed` 直接使用），
///   确保 M3 的容器色不会把中性色染成粉红（修 V1）。
/// - `surfaceTint` 一律透明：M3 的 elevation tint 会破坏「封面是唯一高彩度物体」的原则。
/// - `visualDensity` 固定 standard：行高与命中区由 token 决定，避免 Material 再压一次（修 S2）。
abstract final class TyTheme {
  static ThemeData build({
    required Brightness brightness,
    TyDensity density = TyDensity.comfortable,
  }) {
    final TyColors c = TyColors.of(brightness);
    final TyType type = TyType();
    final ColorScheme scheme = colorScheme(brightness);
    final TyTokens tokens = TyTokens(
      brightness: brightness,
      density: density,
      colors: c,
      typography: type,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[tokens],
      scaffoldBackgroundColor: c.canvas,
      canvasColor: c.canvas,
      dividerColor: c.border,
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: c.surfaceHover,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textTheme: type.toTextTheme(
        c.textPrimary,
        c.textSecondary,
        c.textTertiary,
      ),
      iconTheme: IconThemeData(color: c.textSecondary, size: TyIconSize.normal),
      dividerTheme: DividerThemeData(
        color: c.border,
        thickness: 1,
        space: 1,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all<double>(8),
        radius: const Radius.circular(TyRadius.full),
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.hovered)
              ? c.borderStrong
              : c.border,
        ),
        crossAxisMargin: TySpace.x2,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        padding: const EdgeInsets.symmetric(
          horizontal: TySpace.x8,
          vertical: TySpace.x6,
        ),
        decoration: BoxDecoration(
          color: c.surfaceOverlay,
          borderRadius: TyRadius.smAll,
          border: Border.all(color: c.border),
          boxShadow: tokens.elevation(TyElevation.popover),
        ),
        textStyle: type.bodyS.copyWith(color: c.textPrimary),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStateProperty.all<Color>(c.surfaceOverlay),
          surfaceTintColor: WidgetStateProperty.all<Color>(Colors.transparent),
          elevation: WidgetStateProperty.all<double>(0),
          shadowColor: WidgetStateProperty.all<Color>(Colors.transparent),
          padding: WidgetStateProperty.all<EdgeInsetsGeometry>(
            const EdgeInsets.symmetric(vertical: TySpace.x4),
          ),
          shape: WidgetStateProperty.all<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: TyRadius.mdAll,
              side: BorderSide(color: c.border),
            ),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.surfaceOverlay,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: TyRadius.mdAll,
          side: BorderSide(color: c.border),
        ),
        textStyle: type.bodyM.copyWith(color: c.textPrimary),
        labelTextStyle: WidgetStateProperty.all<TextStyle>(
          type.bodyM.copyWith(color: c.textPrimary),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: TyRadius.lgAll,
          side: BorderSide(color: c.border),
        ),
        titleTextStyle: type.titleL.copyWith(color: c.textPrimary),
        contentTextStyle: type.bodyM.copyWith(color: c.textSecondary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surfaceRaised,
        modalBackgroundColor: c.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: TyRadius.sheetTop),
        dragHandleColor: c.borderStrong,
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.surfaceOverlay,
        contentTextStyle: type.bodyM.copyWith(color: c.textPrimary),
        actionTextColor: c.accent,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: TyRadius.smAll,
          side: BorderSide(color: c.border),
        ),
      ),
      cardTheme: CardThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: TyRadius.lgAll,
          side: BorderSide(color: c.border),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceSunken,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: TySpace.x12,
          vertical: TySpace.x8,
        ),
        hintStyle: type.bodyM.copyWith(color: c.textTertiary),
        errorStyle: type.bodyS.copyWith(color: c.danger),
        border: OutlineInputBorder(
          borderRadius: TyRadius.smAll,
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: TyRadius.smAll,
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: TyRadius.smAll,
          borderSide: BorderSide(color: c.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: TyRadius.smAll,
          borderSide: BorderSide(color: c.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: TyRadius.smAll,
          borderSide: BorderSide(color: c.danger, width: 1.5),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? c.onAccent
              : c.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? c.accent
              : c.borderStrong,
        ),
        trackOutlineColor: WidgetStateProperty.all<Color>(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? c.accent
              : Colors.transparent,
        ),
        checkColor: WidgetStateProperty.all<Color>(c.onAccent),
        side: BorderSide(color: c.borderStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TyRadius.xs),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? c.accent
              : c.borderStrong,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: c.accent,
        inactiveTrackColor: c.borderStrong,
        thumbColor: c.accent,
        overlayColor: c.accentSoft,
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.borderStrong,
        circularTrackColor: Colors.transparent,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accent,
          textStyle: type.labelL,
          minimumSize: const Size(0, TySpace.x32),
          padding: const EdgeInsets.symmetric(horizontal: TySpace.x12),
          shape: RoundedRectangleBorder(borderRadius: TyRadius.smAll),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: c.onAccent,
          disabledBackgroundColor: c.surfaceSunken,
          disabledForegroundColor: c.textDisabled,
          textStyle: type.labelL,
          padding: const EdgeInsets.symmetric(horizontal: TySpace.x16),
          shape: RoundedRectangleBorder(borderRadius: TyRadius.smAll),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          side: BorderSide(color: c.borderStrong),
          textStyle: type.labelL,
          padding: const EdgeInsets.symmetric(horizontal: TySpace.x16),
          shape: RoundedRectangleBorder(borderRadius: TyRadius.smAll),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: c.textSecondary,
          highlightColor: Colors.transparent,
          hoverColor: c.surfaceHover,
          shape: RoundedRectangleBorder(borderRadius: TyRadius.smAll),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.textSecondary,
        textColor: c.textPrimary,
        selectedColor: c.accent,
        selectedTileColor: c.surfaceSelected,
        contentPadding: const EdgeInsets.symmetric(horizontal: TySpace.x16),
        shape: RoundedRectangleBorder(borderRadius: TyRadius.smAll),
      ),
      shadowColor: Colors.transparent,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// 由 token 派生的 Material `ColorScheme`（中性色不被种子染色）。
  static ColorScheme colorScheme(Brightness brightness) {
    final TyColors c = TyColors.of(brightness);
    final ColorScheme base = ColorScheme.fromSeed(
      seedColor: c.accent,
      brightness: brightness,
    );
    final bool dark = brightness == Brightness.dark;
    return base.copyWith(
      primary: c.accent,
      onPrimary: c.onAccent,
      primaryContainer: c.accentSoft,
      onPrimaryContainer: c.accent,
      secondary: c.accent,
      onSecondary: c.onAccent,
      secondaryContainer: c.accentSoft,
      onSecondaryContainer: c.accent,
      tertiary: c.textSecondary,
      onTertiary: c.surface,
      error: c.danger,
      onError: dark ? c.canvas : Colors.white,
      errorContainer: c.danger,
      onErrorContainer: dark ? c.canvas : Colors.white,
      surface: c.surface,
      onSurface: c.textPrimary,
      onSurfaceVariant: c.textSecondary,
      surfaceContainerLowest: c.canvas,
      surfaceContainerLow: c.surface,
      surfaceContainer: c.surfaceSunken,
      surfaceContainerHigh: dark ? c.surfaceRaised : c.surfaceSunken,
      surfaceContainerHighest: dark ? c.surfaceOverlay : c.border,
      outline: c.borderStrong,
      outlineVariant: c.border,
      shadow: Colors.transparent,
      scrim: c.scrim,
      inverseSurface: c.textPrimary,
      onInverseSurface: c.canvas,
      inversePrimary: c.accentHover,
      surfaceTint: Colors.transparent,
    );
  }

  /// 读取设计系统令牌；未挂载时回退到「跟随当前亮度 + 舒适密度」的默认值，避免崩溃。
  static TyTokens of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TyTokens? tokens = theme.extension<TyTokens>();
    if (tokens != null) {
      return tokens;
    }
    final Brightness brightness = theme.brightness;
    return TyTokens(
      brightness: brightness,
      density: TyDensity.comfortable,
      colors: TyColors.of(brightness),
      typography: TyType(),
    );
  }
}

/// `context.ty`：读取设计系统令牌的简写。
extension TyThemeContext on BuildContext {
  TyTokens get ty => TyTheme.of(this);
}
