import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/settings_store.dart';
import 'package:tingyu/design/tokens/tokens.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tingyu-settings-');
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  SettingsStore store() => SettingsStore(supportDirectory: () async => dir);

  File file() => File('${dir.path}${Platform.pathSeparator}settings.json');

  test('无文件时返回默认偏好', () async {
    expect(await store().read(), AppPreferences.defaults);
  });

  test('保存后重新读取恢复三项偏好', () async {
    const AppPreferences preferences = AppPreferences(
      themeMode: ThemeMode.dark,
      density: TyDensity.compact,
      coverTint: false,
    );
    await store().save(preferences);

    expect(await store().read(), preferences);
    expect(await File('${file().path}.tmp').exists(), isFalse);
    expect(await file().exists(), isTrue);
  });

  test('损坏 JSON 抛可恢复错误且保留原文件', () async {
    await dir.create(recursive: true);
    await file().writeAsString('{not json');

    await expectLater(
      store().read(),
      throwsA(isA<SettingsCorruptException>()),
    );
    expect(await file().exists(), isTrue);
    expect(await file().readAsString(), '{not json');
  });

  test('未知枚举值与错误类型逐项回退，不丢其他字段', () async {
    await file().writeAsString(
      '{"themeMode":"neon","density":"ultra","coverTint":"yes"}',
    );
    expect(await store().read(), AppPreferences.defaults);

    await file().writeAsString(
      '{"themeMode":"light","density":"compact","coverTint":false}',
    );
    expect(
      await store().read(),
      const AppPreferences(
        themeMode: ThemeMode.light,
        density: TyDensity.compact,
        coverTint: false,
      ),
    );
  });
}
