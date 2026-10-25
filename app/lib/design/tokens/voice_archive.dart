import 'package:flutter/material.dart';

import 'color.dart';

/// C「声档」已批准令牌的适配器，仅在已迁移的舞台主题内使用。
/// 数值来源 docs/ui-redesign/tokens/voice-archive.v0.1.json；不新增主题架构。
abstract final class VoiceArchiveColors {
  static const TyColors light = TyColors(
    canvas: Color(0xFFFAFAFC),
    surface: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFF0F0F4),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceOverlay: Color(0xFFFFFFFF),
    surfaceHover: Color(0x0A18191D),
    surfacePressed: Color(0x1418191D),
    surfaceSelected: Color(0x1F9A5D09),
    border: Color(0xFFDFDFE6),
    borderStrong: Color(0xFF7D7D89),
    textPrimary: Color(0xFF18191D),
    textSecondary: Color(0xFF545460),
    textTertiary: Color(0xFF62626E),
    textDisabled: Color(0xFF9B9BA7),
    accent: Color(0xFF9A5D09),
    accentHover: Color(0xFF854E07),
    accentPressed: Color(0xFF703F05),
    accentSoft: Color(0x1F9A5D09),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF17663D),
    warning: Color(0xFF855000),
    danger: Color(0xFFAE3028),
    focusRing: Color(0xFF9A5D09),
    scrim: Color(0x66000000),
    skeletonBase: Color(0xFFE5E5EC),
    skeletonHighlight: Color(0xFFF2F2F6),
    coverPlaceholder: Color(0xFFE7E7ED),
  );

  static const TyColors dark = TyColors(
    canvas: Color(0xFF191A1E),
    surface: Color(0xFF202126),
    surfaceSunken: Color(0xFF15161A),
    surfaceRaised: Color(0xFF282930),
    surfaceOverlay: Color(0xFF30313A),
    surfaceHover: Color(0x0FF4F4F6),
    surfacePressed: Color(0x1AF4F4F6),
    surfaceSelected: Color(0x24E3B56B),
    border: Color(0xFF3D3E48),
    borderStrong: Color(0xFF8A8B99),
    textPrimary: Color(0xFFF4F4F6),
    textSecondary: Color(0xFFC4C4CF),
    textTertiary: Color(0xFFB3B3C0),
    textDisabled: Color(0xFF777783),
    accent: Color(0xFFE3B56B),
    accentHover: Color(0xFFEFC88A),
    accentPressed: Color(0xFFD5A45C),
    accentSoft: Color(0x24E3B56B),
    onAccent: Color(0xFF191A1E),
    success: Color(0xFF7DD7A0),
    warning: Color(0xFFE8BF70),
    danger: Color(0xFFFFA39C),
    focusRing: Color(0xFFE3B56B),
    scrim: Color(0x99000000),
    skeletonBase: Color(0xFF2C2D35),
    skeletonHighlight: Color(0xFF3A3B45),
    coverPlaceholder: Color(0xFF32333C),
  );

  static TyColors of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}
