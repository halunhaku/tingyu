import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/preferences.dart';
import 'package:tingyu/data/settings_store.dart';
import 'package:tingyu/design/tokens/tokens.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tingyu-preferences-');
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  ProviderContainer container() {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        settingsStoreProvider.overrideWithValue(
          SettingsStore(supportDirectory: () async => dir),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('三项偏好写入后新容器读回（模拟重启）', () async {
    final ProviderContainer first = container();
    expect(
      (await first.read(preferencesProvider.future)).preferences,
      AppPreferences.defaults,
    );

    await first.read(preferencesProvider.notifier).setThemeMode(ThemeMode.dark);
    await first.read(preferencesProvider.notifier).setDensity(TyDensity.compact);
    await first.read(preferencesProvider.notifier).setCoverTint(false);

    final ProviderContainer second = container();
    final PreferencesState restored = await second.read(
      preferencesProvider.future,
    );
    expect(
      restored.preferences,
      const AppPreferences(
        themeMode: ThemeMode.dark,
        density: TyDensity.compact,
        coverTint: false,
      ),
    );
    expect(restored.loadError, isNull);
  });

  test('损坏 JSON：默认值启动，错误可诊断，reset 覆盖并清除', () async {
    final File file = File('${dir.path}${Platform.pathSeparator}settings.json');
    await file.writeAsString('{"themeMode":');

    final ProviderContainer c = container();
    final PreferencesState state = await c.read(preferencesProvider.future);
    expect(state.preferences, AppPreferences.defaults);
    expect(state.loadError, isA<SettingsCorruptException>());
    expect(state.loadError!.filePath, file.path);

    await c.read(preferencesProvider.notifier).reset();
    final PreferencesState after = c.read(preferencesProvider).requireValue;
    expect(after.loadError, isNull);
    expect(await SettingsStore(
      supportDirectory: () async => dir,
    ).read(), AppPreferences.defaults);
  });
}
