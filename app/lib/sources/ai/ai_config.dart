/// AI 服务商预设与配置模型。
enum AIProviderPreset {
  deepseek(
    displayName: 'DeepSeek',
    defaultBaseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
  ),
  qwen(
    displayName: '通义千问 (Qwen)',
    defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
  ),
  kimi(
    displayName: 'Kimi (Moonshot)',
    defaultBaseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'moonshot-v1-8k',
  ),
  openai(
    displayName: 'OpenAI',
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
  ),
  ollama(
    displayName: '本地 Ollama',
    defaultBaseUrl: 'http://localhost:11434/v1',
    defaultModel: 'qwen2.5:7b',
  ),
  custom(
    displayName: '自定义',
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
  );

  const AIProviderPreset({
    required this.displayName,
    required this.defaultBaseUrl,
    required this.defaultModel,
  });

  final String displayName;
  final String defaultBaseUrl;
  final String defaultModel;
}

/// AI 配置状态模型。
class AISettings {
  const AISettings({
    this.isEnabled = false,
    this.preset = AIProviderPreset.deepseek,
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.model = 'deepseek-chat',
    this.apiKey = '',
  });

  final bool isEnabled;
  final AIProviderPreset preset;
  final String baseUrl;
  final String model;
  final String apiKey;

  AISettings copyWith({
    bool? isEnabled,
    AIProviderPreset? preset,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) {
    return AISettings(
      isEnabled: isEnabled ?? this.isEnabled,
      preset: preset ?? this.preset,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'isEnabled': isEnabled,
    'preset': preset.name,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': apiKey,
  };

  factory AISettings.fromJson(Map<String, dynamic> json) {
    final String presetName = json['preset'] as String? ?? 'deepseek';
    final AIProviderPreset preset = AIProviderPreset.values.firstWhere(
      (AIProviderPreset p) => p.name == presetName,
      orElse: () => AIProviderPreset.deepseek,
    );

    return AISettings(
      isEnabled: json['isEnabled'] as bool? ?? false,
      preset: preset,
      baseUrl: json['baseUrl'] as String? ?? preset.defaultBaseUrl,
      model: json['model'] as String? ?? preset.defaultModel,
      apiKey: json['apiKey'] as String? ?? '',
    );
  }
}
