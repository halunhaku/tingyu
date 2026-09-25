import 'dart:convert';

import '../../data/secure_store.dart';
import 'ai_config.dart';

/// AI 设置的持久化仓库，利用系统安全存储存取配置与 API 密钥。
class AISettingsRepository {
  AISettingsRepository({SecureStore? store}) : _store = store ?? SecureStore();

  static const String settingsAccount = 'tingyu_ai_settings';
  static const String legacyApiKeyAccount = 'tingyu_ai_api_key';

  final SecureStore _store;

  /// 加载当前 AI 设置。
  ///
  /// 若尚未保存过设置，但旧版 Swift 钥匙串中存有 API Key，会自动将其无缝带入。
  Future<AISettings> load() async {
    final String? raw = await _store.read(settingsAccount);
    if (raw != null && raw.isNotEmpty) {
      try {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return AISettings.fromJson(decoded);
        }
        if (decoded is Map) {
          return AISettings.fromJson(Map<String, dynamic>.from(decoded));
        }
      } on Object {
        // 损坏的配置容错回退为默认设置
      }
    }

    // 检查旧版 Swift 钥匙串留下的 API Key
    final String? legacyKey = await _store.read(legacyApiKeyAccount);
    if (legacyKey != null && legacyKey.isNotEmpty) {
      return AISettings(apiKey: legacyKey);
    }

    return const AISettings();
  }

  /// 保存 AI 设置。
  Future<void> save(AISettings settings) async {
    final String raw = jsonEncode(settings.toJson());
    await _store.write(settingsAccount, raw);
  }
}
