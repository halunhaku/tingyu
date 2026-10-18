import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_store.dart';
import '../design/tokens/tokens.dart';

final Provider<SettingsStore> settingsStoreProvider = Provider<SettingsStore>(
  (Ref ref) => SettingsStore(),
);

/// 偏好状态：永远带着一份可用的 [preferences]。
///
/// `settings.json` 损坏时仍以默认值启动应用，同时把可诊断错误交给设置页，
/// 由用户显式「恢复默认外观」覆盖坏文件——不静默丢弃。
class PreferencesState {
  const PreferencesState({required this.preferences, this.loadError});

  final AppPreferences preferences;
  final SettingsCorruptException? loadError;

  PreferencesState copyWith({
    AppPreferences? preferences,
    SettingsCorruptException? loadError,
    bool clearError = false,
  }) {
    return PreferencesState(
      preferences: preferences ?? this.preferences,
      loadError: clearError ? null : (loadError ?? this.loadError),
    );
  }
}

/// 外观偏好的唯一读取点（`main.dart` 的主题、设置页的控件都订阅它）。
///
/// 写操作先更新内存状态再落盘：切换主题/密度立即生效，不需要等 IO。
/// 落盘失败不回滚界面选择，但会记录到控制台，避免「看起来保存了」的假象被隐藏。
class PreferencesNotifier extends AsyncNotifier<PreferencesState> {
  @override
  Future<PreferencesState> build() async {
    final SettingsStore store = ref.watch(settingsStoreProvider);
    try {
      return PreferencesState(preferences: await store.read());
    } on SettingsCorruptException catch (error) {
      return PreferencesState(
        preferences: AppPreferences.defaults,
        loadError: error,
      );
    }
  }

  Future<void> setThemeMode(ThemeMode mode) =>
      _update((AppPreferences p) => p.copyWith(themeMode: mode));

  Future<void> setDensity(TyDensity density) =>
      _update((AppPreferences p) => p.copyWith(density: density));

  Future<void> setCoverTint(bool enabled) =>
      _update((AppPreferences p) => p.copyWith(coverTint: enabled));

  /// 显式恢复默认：覆盖损坏文件并清除错误。
  Future<void> reset() => _update((AppPreferences _) => AppPreferences.defaults);

  Future<void> _update(AppPreferences Function(AppPreferences) change) async {
    final PreferencesState current =
        state.value ?? const PreferencesState(preferences: AppPreferences.defaults);
    final AppPreferences next = change(current.preferences);
    state = AsyncValue<PreferencesState>.data(
      PreferencesState(preferences: next),
    );
    try {
      await ref.read(settingsStoreProvider).save(next);
    } on Object catch (error) {
      debugPrint('[preferences] 保存偏好失败（本次会话仍然生效）: $error');
    }
  }
}

final AsyncNotifierProvider<PreferencesNotifier, PreferencesState>
preferencesProvider =
    AsyncNotifierProvider<PreferencesNotifier, PreferencesState>(
      PreferencesNotifier.new,
    );
