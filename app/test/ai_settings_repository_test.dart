import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/secure_store.dart';
import 'package:tingyu/sources/ai/ai_config.dart';
import 'package:tingyu/sources/ai/ai_settings_repository.dart';

class _FakeSecureStore extends SecureStore {
  _FakeSecureStore([Map<String, String>? initial])
    : _memory = initial != null
          ? Map<String, String>.from(initial)
          : <String, String>{};

  final Map<String, String> _memory;

  @override
  Future<void> write(String account, String value) async {
    _memory[account] = value;
  }

  @override
  Future<String?> read(String account) async {
    final String? val = _memory[account]?.trim();
    if (val != null && val.isNotEmpty) {
      return val;
    }
    return null;
  }

  @override
  Future<void> delete(String account) async {
    _memory.remove(account);
  }
}

void main() {
  group('AISettingsRepository 配置持久化与迁移', () {
    test('初始未配置时返回默认设置', () async {
      final _FakeSecureStore store = _FakeSecureStore();
      final AISettingsRepository repo = AISettingsRepository(store: store);

      final AISettings settings = await repo.load();
      expect(settings.isEnabled, isFalse);
      expect(settings.preset, AIProviderPreset.deepseek);
      expect(settings.baseUrl, 'https://api.deepseek.com/v1');
      expect(settings.model, 'deepseek-chat');
      expect(settings.apiKey, isEmpty);
    });

    test('保存设置后读取一致', () async {
      final _FakeSecureStore store = _FakeSecureStore();
      final AISettingsRepository repo = AISettingsRepository(store: store);

      const AISettings toSave = AISettings(
        isEnabled: true,
        preset: AIProviderPreset.qwen,
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        model: 'qwen-plus',
        apiKey: 'sk-qwen-test',
      );

      await repo.save(toSave);

      final AISettings loaded = await repo.load();
      expect(loaded.isEnabled, isTrue);
      expect(loaded.preset, AIProviderPreset.qwen);
      expect(
        loaded.baseUrl,
        'https://dashscope.aliyuncs.com/compatible-mode/v1',
      );
      expect(loaded.model, 'qwen-plus');
      expect(loaded.apiKey, 'sk-qwen-test');
    });

    test('旧版 Swift 钥匙串无缝兼容（读取 legacy tingyu_ai_api_key）', () async {
      final _FakeSecureStore store = _FakeSecureStore(<String, String>{
        'tingyu_ai_api_key': 'legacy-swift-key-12345',
      });
      final AISettingsRepository repo = AISettingsRepository(store: store);

      final AISettings loaded = await repo.load();
      expect(loaded.apiKey, 'legacy-swift-key-12345');
      expect(loaded.isEnabled, isFalse);
    });

    test('损坏的 JSON 内容容错回退为默认配置，不抛异常', () async {
      final _FakeSecureStore store = _FakeSecureStore(<String, String>{
        AISettingsRepository.settingsAccount: 'invalid json content { [',
      });
      final AISettingsRepository repo = AISettingsRepository(store: store);

      final AISettings loaded = await repo.load();
      expect(loaded.isEnabled, isFalse);
      expect(loaded.preset, AIProviderPreset.deepseek);
    });
  });
}
