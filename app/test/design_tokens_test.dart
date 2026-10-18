import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/tokens/color.dart';
import 'package:tingyu/design/tokens/tokens.dart';
import 'package:tingyu/design/theme.dart';

/// WCAG 相对亮度与对比度（用于固定设计系统的不变量：`DESIGN.md` §2 的实测值）。
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final double r = channel(c.r);
  final double g = channel(c.g);
  final double b = channel(c.b);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double _contrast(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('颜色令牌对比度不变量', () {
    void expectContrast(
      String name,
      Color foreground,
      Color background,
      double minimum,
    ) {
      final double ratio = _contrast(foreground, background);
      expect(
        ratio,
        greaterThanOrEqualTo(minimum),
        reason: '$name 对比度 $ratio 低于下限 $minimum',
      );
    }

    for (final (String label, TyColors c) in <(String, TyColors)>[
      ('浅色', TyColors.light),
      ('深色', TyColors.dark),
    ]) {
      test('$label：正文字号文本在画布与面板上均 ≥ 4.5:1', () {
        for (final Color surface in <Color>[c.canvas, c.surface]) {
          expectContrast('$label textPrimary', c.textPrimary, surface, 12);
          expectContrast('$label textSecondary', c.textSecondary, surface, 4.5);
          expectContrast('$label textTertiary', c.textTertiary, surface, 4.5);
        }
      });

      test('$label：强调色、状态色作为文字均 ≥ 4.5:1', () {
        expectContrast('$label accent', c.accent, c.canvas, 4.5);
        expectContrast('$label success', c.success, c.canvas, 4.5);
        expectContrast('$label warning', c.warning, c.canvas, 4.5);
        expectContrast('$label danger', c.danger, c.canvas, 4.5);
      });

      test('$label：强调底上的文字 ≥ 4.5:1', () {
        expectContrast('$label onAccent', c.onAccent, c.accent, 4.5);
      });

      test('$label：焦点环在画布上可见（≥ 3:1）', () {
        expectContrast('$label focusRing', c.focusRing, c.canvas, 3);
      });
    }
  });

  group('外壳形态断点', () {
    test('按宽度解析且边界精确', () {
      expect(FormFactor.ofWidth(319), FormFactor.compact);
      expect(FormFactor.ofWidth(639.99), FormFactor.compact);
      expect(FormFactor.ofWidth(640), FormFactor.medium);
      expect(FormFactor.ofWidth(1023.99), FormFactor.medium);
      expect(FormFactor.ofWidth(1024), FormFactor.expanded);
      expect(FormFactor.ofWidth(2560), FormFactor.expanded);
    });

    test('只有 expanded 具备检查器与侧栏', () {
      expect(FormFactor.compact.hasInspector, isFalse);
      expect(FormFactor.medium.hasInspector, isFalse);
      expect(FormFactor.expanded.hasInspector, isTrue);
      expect(FormFactor.medium.hasSidebar, isFalse);
      expect(FormFactor.expanded.hasSidebar, isTrue);
      expect(FormFactor.medium.hasRail, isTrue);
    });
  });

  group('尺寸令牌', () {
    test('compact 形态忽略紧凑密度（触控目标 44 硬约束）', () {
      final TyMetrics comfortable = TyMetrics.resolve(
        FormFactor.compact,
        TyDensity.comfortable,
      );
      final TyMetrics compact = TyMetrics.resolve(
        FormFactor.compact,
        TyDensity.compact,
      );
      expect(compact, same(comfortable));
      expect(compact.rowHeight, 56);
      expect(compact.hitTarget, 44);
    });

    test('expanded 紧凑密度压缩行高但不低于可读下限', () {
      final TyMetrics metrics = TyMetrics.resolve(
        FormFactor.expanded,
        TyDensity.compact,
      );
      expect(metrics.rowHeight, 40);
      expect(metrics.tableRowHeight, 40);
      expect(metrics.panelPadding, 12);
    });

    test('同一（形态, 密度）始终返回同一实例', () {
      expect(
        TyMetrics.resolve(FormFactor.medium, TyDensity.compact),
        same(TyMetrics.resolve(FormFactor.medium, TyDensity.compact)),
      );
    });

    test('网格列数按宽度自适应且不小于 2', () {
      final TyMetrics compact = TyMetrics.resolve(
        FormFactor.compact,
        TyDensity.comfortable,
      );
      final TyMetrics medium = TyMetrics.resolve(
        FormFactor.medium,
        TyDensity.comfortable,
      );
      final TyMetrics expanded = TyMetrics.resolve(
        FormFactor.expanded,
        TyDensity.comfortable,
      );
      expect(compact.gridColumns(412), 2);
      expect(medium.gridColumns(900), 5);
      expect(expanded.gridColumns(1440), 7);
      expect(expanded.gridColumns(320), 2);
    });

    test('传输条能力随形态收敛：compact 不占音量位，medium/expanded 有音量', () {
      expect(
        TyMetrics.resolve(FormFactor.compact, TyDensity.comfortable)
            .transportShowsVolume,
        isFalse,
      );
      expect(
        TyMetrics.resolve(FormFactor.medium, TyDensity.comfortable)
            .transportShowsVolume,
        isTrue,
      );
      expect(
        TyMetrics.resolve(FormFactor.expanded, TyDensity.comfortable)
            .transportShowsVolume,
        isTrue,
      );
    });
  });

  group('主题构建', () {
    test('浅色主题挂载 TyTokens 且中性面不被种子染色', () {
      final ThemeData theme = TyTheme.build(brightness: Brightness.light);
      final TyTokens? tokens = theme.extension<TyTokens>();
      expect(tokens, isNotNull);
      expect(tokens!.colors.canvas, TyColors.light.canvas);
      expect(theme.colorScheme.surface, TyColors.light.surface);
      expect(theme.colorScheme.surfaceTint, Colors.transparent);
      expect(theme.scaffoldBackgroundColor, TyColors.light.canvas);
      expect(theme.visualDensity, VisualDensity.standard);
    });

    test('深色主题不投影，浮层靠更亮的面板表达', () {
      final ThemeData theme = TyTheme.build(brightness: Brightness.dark);
      final TyTokens tokens = theme.extension<TyTokens>()!;
      expect(tokens.isDark, isTrue);
      expect(tokens.elevation(const <BoxShadow>[
        BoxShadow(color: Color(0x1A000000), blurRadius: 16),
      ]), isEmpty);
      expect(theme.colorScheme.primary, TyColors.dark.accent);
    });

    test('密度写入令牌并反映在 ThemeData 文本主题上', () {
      final ThemeData theme = TyTheme.build(
        brightness: Brightness.dark,
        density: TyDensity.compact,
      );
      expect(theme.extension<TyTokens>()!.density, TyDensity.compact);
      expect(theme.textTheme.titleLarge!.fontSize, 20);
      expect(theme.textTheme.bodyMedium!.fontSize, 15);
      expect(theme.textTheme.bodySmall!.fontSize, 13);
    });
  });
}
