import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../design/tokens/tokens.dart';

/// 应用级外观偏好（`{themeMode, density, coverTint}`）。
///
/// 不含敏感信息；凭据继续走 `SecureStore`。JSON 落盘在
/// `getApplicationSupportDirectory()/settings.json`。
@immutable
class AppPreferences {
  const AppPreferences({
    this.themeMode = ThemeMode.system,
    this.density = TyDensity.comfortable,
    this.coverTint = true,
  });

  final ThemeMode themeMode;
  final TyDensity density;

  /// 舞台/播放条是否用封面取色（关闭后使用中性渐变）。
  final bool coverTint;

  static const AppPreferences defaults = AppPreferences();

  AppPreferences copyWith({
    ThemeMode? themeMode,
    TyDensity? density,
    bool? coverTint,
  }) {
    return AppPreferences(
      themeMode: themeMode ?? this.themeMode,
      density: density ?? this.density,
      coverTint: coverTint ?? this.coverTint,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'themeMode': switch (themeMode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    },
    'density': density.name,
    'coverTint': coverTint,
  };

  /// 宽容解析：未知字段/未知枚举值逐项回退默认，不因一项坏值丢弃其余偏好。
  factory AppPreferences.fromJson(Map<String, Object?> json) {
    final Object? mode = json['themeMode'];
    final ThemeMode themeMode = switch (mode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final Object? density = json['density'];
    final TyDensity resolvedDensity = density == TyDensity.compact.name
        ? TyDensity.compact
        : TyDensity.comfortable;
    final Object? tint = json['coverTint'];
    return AppPreferences(
      themeMode: themeMode,
      density: resolvedDensity,
      coverTint: tint is bool ? tint : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppPreferences &&
      other.themeMode == themeMode &&
      other.density == density &&
      other.coverTint == coverTint;

  @override
  int get hashCode => Object.hash(themeMode, density, coverTint);
}

/// `settings.json` 存在但无法解析（保留原文件供诊断，不静默覆盖）。
class SettingsCorruptException implements Exception {
  const SettingsCorruptException(this.filePath, this.cause);

  final String filePath;
  final Object cause;

  @override
  String toString() => 'settings.json 损坏（$filePath）：$cause';
}

/// 偏好文件读写：临时文件写完后 rename，避免半截 JSON。
class SettingsStore {
  SettingsStore({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  /// 无文件时返回默认值；文件损坏时抛出 [SettingsCorruptException]，原文件保留。
  Future<AppPreferences> read() async {
    final File file = await _file();
    if (!await file.exists()) {
      return AppPreferences.defaults;
    }
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('settings.json 顶层不是 JSON 对象');
      }
      return AppPreferences.fromJson(decoded);
    } on Object catch (error) {
      debugPrint('[settings] 读取偏好失败: $error');
      throw SettingsCorruptException(file.path, error);
    }
  }

  Future<void> save(AppPreferences preferences) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    final File temp = File('${file.path}.tmp');
    try {
      await temp.writeAsString(jsonEncode(preferences.toJson()), flush: true);
      await temp.rename(file.path);
    } on Object {
      if (await temp.exists()) {
        await temp.delete();
      }
      rethrow;
    }
  }

  Future<File> _file() async {
    final Directory dir = await _supportDirectory();
    return File(p.join(dir.path, 'settings.json'));
  }
}
