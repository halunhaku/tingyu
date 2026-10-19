import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/design/tokens/color.dart';
import 'package:tingyu/design/tokens/tokens.dart';

/// 视觉密度与命中区：平台不再决定 Material 密度，尺寸全部走 TyMetrics。
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('主题不再按平台压密度：桌面与移动都是 standard', () {
    for (final TargetPlatform platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        TyTheme.build(brightness: Brightness.light).visualDensity,
        VisualDensity.standard,
        reason: '$platform 的视觉密度必须由 TyDensity 控制，而不是平台',
      );
    }
  });

  test('密度偏好只改变行高/内边距，不改变触控命中区下限', () {
    for (final FormFactor formFactor in FormFactor.values) {
      final TyMetrics comfortable = TyMetrics.resolve(
        formFactor,
        TyDensity.comfortable,
      );
      final TyMetrics compact = TyMetrics.resolve(
        formFactor,
        TyDensity.compact,
      );

      if (formFactor == FormFactor.compact) {
        // 触屏列表行高不随密度压缩，保证 56 的行命中区；表格形态不存在。
        expect(compact.rowHeight, comfortable.rowHeight);
        expect(compact.tableRowHeight, 0);
        expect(compact.hitTarget, greaterThanOrEqualTo(44));
        expect(comfortable.hitTarget, greaterThanOrEqualTo(44));
        expect(compact.chipHeight, greaterThanOrEqualTo(32));
      } else {
        expect(
          compact.tableRowHeight,
          lessThan(comfortable.tableRowHeight),
          reason: '$formFactor 紧凑密度的表格行必须更矮',
        );
        expect(compact.rowHeight, lessThan(comfortable.rowHeight));
      }
    }
  });

  test('主题的 Material 色板由 token 派生（不是种子直接染色）', () {
    for (final Brightness brightness in Brightness.values) {
      final TyColors colors = TyColors.of(brightness);
      final ColorScheme scheme = TyTheme.build(
        brightness: brightness,
      ).colorScheme;
      expect(scheme.primary, colors.accent);
      expect(scheme.surface, colors.surface);
      expect(scheme.onSurface, colors.textPrimary);
      expect(scheme.surfaceTint, Colors.transparent);
    }
  });
}
