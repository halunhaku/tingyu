import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/theme.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('桌面沿用紧凑密度，移动端用标准密度（48dp 点击目标）', () {
    for (final TargetPlatform desktop in <TargetPlatform>[
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = desktop;
      expect(
        buildTingyuTheme(Brightness.light).visualDensity,
        VisualDensity.compact,
        reason: '$desktop 的桌面观感不能变',
      );
    }

    for (final TargetPlatform mobile in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      debugDefaultTargetPlatformOverride = mobile;
      expect(
        buildTingyuTheme(Brightness.light).visualDensity,
        VisualDensity.standard,
        reason: '$mobile 上紧凑密度会把点击目标压到 48dp 以下',
      );
    }
  });
}