import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 排版令牌（`DESIGN.md` §4）。
///
/// 规则：
/// - 零体积方案：不打包字体文件。`fontFamily` 留空（使用各平台系统字体），
///   仅提供 CJK/Latin 回退链，避免 macOS/Windows/Android 三端观感分裂。
/// - `letterSpacing` 统一为 0（[labelS] 除外）：M3 的拉丁字距在中英混排下过散。
/// - 时间 / 计数 / 序号样式带 `tabularFigures`，跳动时不抖动。
/// - 样式**不带颜色**：颜色由使用处按语义选择（`textPrimary` / `textSecondary` / …），
///   这样同一号字可以在不同语义下复用。
@immutable
class TyType {
  TyType() : platform = defaultTargetPlatform;

  /// 用于解析平台字体栈（测试可传入固定平台）。
  const TyType.forPlatform(this.platform);

  final TargetPlatform platform;

  /// 当前平台的 CJK/Latin 回退链。
  List<String> get fontFamilyFallback {
    switch (platform) {
      case TargetPlatform.macOS:
        return const <String>['PingFang SC', 'Helvetica Neue', 'Arial Unicode MS'];
      case TargetPlatform.iOS:
        return const <String>['PingFang SC', 'Helvetica Neue'];
      case TargetPlatform.windows:
        return const <String>[
          'Segoe UI Variable Text',
          'Segoe UI',
          'Microsoft YaHei UI',
          'Microsoft YaHei',
        ];
      case TargetPlatform.android:
        return const <String>['Roboto', 'Noto Sans CJK SC', 'Noto Sans SC'];
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
        return const <String>['Noto Sans', 'Noto Sans CJK SC', 'DejaVu Sans'];
    }
  }

  TextStyle _base(double size, FontWeight weight, double height) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    height: height,
    letterSpacing: 0,
    fontFamilyFallback: fontFamilyFallback,
  );

  /// 40 / 700 / 1.20 — 舞台曲名（超长降级 [displayM]）。
  TextStyle get displayL => _base(40, FontWeight.w700, 1.20);

  /// 32 / 700 / 1.25 — 详情页主标题（专辑 / 艺人 / 歌单）。
  TextStyle get displayM => _base(32, FontWeight.w700, 1.25);

  /// 26 / 600 / 1.30 — 页面标题。
  TextStyle get titleXL => _base(26, FontWeight.w600, 1.30);

  /// 20 / 600 / 1.35 — 面板标题、对话框标题、compact 舞台曲名。
  TextStyle get titleL => _base(20, FontWeight.w600, 1.35);

  /// 17 / 600 / 1.40 — 分组标题、卡片标题、设置分组名。
  TextStyle get titleM => _base(17, FontWeight.w600, 1.40);

  /// 16 / 400 / 1.60 — 舞台艺术家、说明段落。
  TextStyle get bodyL => _base(16, FontWeight.w400, 1.60);

  /// 15 / 400 / 1.50 — 曲目名、正文、菜单项（默认正文字号）。
  TextStyle get bodyM => _base(15, FontWeight.w400, 1.50);

  /// 13 / 400 / 1.50 — 专辑名、年份、计数、来源状态行（默认元数据字号）。
  TextStyle get bodyS => _base(13, FontWeight.w400, 1.50);

  /// 15 / 500 / 1.40 — 按钮、分段控件当前项。
  TextStyle get labelL => _base(15, FontWeight.w500, 1.40);

  /// 13 / 500 / 1.40 — chip、导航标签、次级按钮。
  TextStyle get labelM => _base(13, FontWeight.w500, 1.40);

  /// 11 / 600 / 1.30 / ls 0.3 — overline、徽标（仅短标签）。
  TextStyle get labelS =>
      _base(11, FontWeight.w600, 1.30).copyWith(letterSpacing: 0.3);

  /// 15 / 500 / 1.40 + tabular — 时长、进度时间。
  TextStyle get numericM =>
      _base(15, FontWeight.w500, 1.40).copyWith(fontFeatures: _tabular);

  /// 13 / 500 / 1.40 + tabular — 列表计数、徽标数字。
  TextStyle get numericS =>
      _base(13, FontWeight.w500, 1.40).copyWith(fontFeatures: _tabular);

  static const List<FontFeature> _tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// 全部样式，供 `TextTheme` 映射使用。
  List<TextStyle> get all => <TextStyle>[
    displayL,
    displayM,
    titleXL,
    titleL,
    titleM,
    bodyL,
    bodyM,
    bodyS,
    labelL,
    labelM,
    labelS,
    numericM,
    numericS,
  ];

  /// 供 `ThemeData.textTheme` 使用的映射（Material 内建控件继承同一套字体与色阶）。
  TextTheme toTextTheme(Color primary, Color secondary, Color tertiary) {
    TextStyle c(TextStyle s, Color color) => s.copyWith(color: color);
    return TextTheme(
      displayLarge: c(displayL, primary),
      displayMedium: c(displayM, primary),
      headlineLarge: c(titleXL, primary),
      headlineMedium: c(titleXL, primary),
      headlineSmall: c(titleL, primary),
      titleLarge: c(titleL, primary),
      titleMedium: c(titleM, primary),
      titleSmall: c(titleM, secondary),
      bodyLarge: c(bodyL, primary),
      bodyMedium: c(bodyM, primary),
      bodySmall: c(bodyS, secondary),
      labelLarge: c(labelL, primary),
      labelMedium: c(labelM, secondary),
      labelSmall: c(labelS, tertiary),
    );
  }
}
