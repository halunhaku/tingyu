import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../sources/ai/ai_client.dart';
import '../../sources/ai/ai_config.dart';
import '../../sources/ai/ai_library_refactor_service.dart';

/// AI 识别与曲库清洗设置页面。
class AISettingsPage extends ConsumerStatefulWidget {
  const AISettingsPage({super.key});

  @override
  ConsumerState<AISettingsPage> createState() => _AISettingsPageState();
}

class _AISettingsPageState extends ConsumerState<AISettingsPage> {
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();

  bool _obscureKey = true;
  bool _isTesting = false;
  String? _testMessage;
  bool? _testSuccess;

  bool _isRefactoring = false;
  bool _isCancelled = false;
  RefactorProgress? _refactorProgress;

  bool _loaded = false;

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _syncFromSettings(AISettings settings) {
    if (!_loaded) {
      _baseUrlController.text = settings.baseUrl;
      _modelController.text = settings.model;
      _apiKeyController.text = settings.apiKey;
      _loaded = true;
    }
  }

  Future<void> _saveSettings(
    AISettings current, {
    AIProviderPreset? preset,
    bool? isEnabled,
  }) async {
    final AISettings updated = current.copyWith(
      isEnabled: isEnabled ?? current.isEnabled,
      preset: preset ?? current.preset,
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
    );
    await ref.read(aiSettingsProvider.notifier).save(updated);
  }

  Future<void> _testConnection(AISettings settings) async {
    setState(() {
      _isTesting = true;
      _testMessage = null;
      _testSuccess = null;
    });

    await _saveSettings(settings);

    final AIClient client = AIClient(
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
    );

    try {
      final bool ok = await client.testConnection();
      if (!mounted) return;
      setState(() {
        _isTesting = false;
        _testSuccess = ok;
        _testMessage = ok ? '连接成功' : '未收到有效回复';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _isTesting = false;
        _testSuccess = false;
        _testMessage = '连接失败: $error';
      });
    }
  }

  Future<void> _startRefactor() async {
    setState(() {
      _isRefactoring = true;
      _isCancelled = false;
      _refactorProgress = null;
    });

    final AILibraryRefactorService service = ref.read(
      aiLibraryRefactorServiceProvider,
    );

    final RefactorProgress finalState = await service.refactorAll(
      onProgress: (RefactorProgress p) {
        if (mounted) {
          setState(() => _refactorProgress = p);
        }
      },
      isCancelled: () => _isCancelled,
    );

    if (!mounted) return;
    setState(() {
      _isRefactoring = false;
      _refactorProgress = finalState;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _isCancelled
              ? '清洗已停止：已检查 ${finalState.processed} 首，纠偏 ${finalState.updated} 首'
              : '清洗完成：共检查 ${finalState.processed} 首，纠偏 ${finalState.updated} 首',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<AISettings> asyncSettings = ref.watch(aiSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('AI 智能识别')),
      body: asyncSettings.when(
        data: (AISettings settings) {
          _syncFromSettings(settings);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: <Widget>[
              _Section(
                title: '总开关',
                children: <Widget>[
                  SwitchListTile(
                    title: const Text('启用智能识别'),
                    subtitle: const Text('支持通过大语言模型清洗乱码、音轨序号等噪音，提取标准歌名、歌手与专辑'),
                    value: settings.isEnabled,
                    onChanged: (bool value) =>
                        _saveSettings(settings, isEnabled: value),
                  ),
                ],
              ),
              if (settings.isEnabled) ...<Widget>[
                _Section(
                  title: '服务商配置',
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: DropdownButtonFormField<AIProviderPreset>(
                        initialValue: settings.preset,
                        decoration: const InputDecoration(
                          labelText: '预设服务商',
                          border: OutlineInputBorder(),
                        ),
                        items: AIProviderPreset.values.map((
                          AIProviderPreset p,
                        ) {
                          return DropdownMenuItem<AIProviderPreset>(
                            value: p,
                            child: Text(p.displayName),
                          );
                        }).toList(),
                        onChanged: (AIProviderPreset? newPreset) {
                          if (newPreset != null) {
                            _baseUrlController.text = newPreset.defaultBaseUrl;
                            _modelController.text = newPreset.defaultModel;
                            _saveSettings(settings, preset: newPreset);
                          }
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: TextField(
                        controller: _baseUrlController,
                        decoration: const InputDecoration(
                          labelText: 'API 端点 (Base URL)',
                          hintText: 'https://api.deepseek.com/v1',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => _saveSettings(settings),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: TextField(
                        controller: _modelController,
                        decoration: const InputDecoration(
                          labelText: '模型名称 (Model)',
                          hintText: 'deepseek-chat',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => _saveSettings(settings),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: TextField(
                        controller: _apiKeyController,
                        obscureText: _obscureKey,
                        decoration: InputDecoration(
                          labelText: 'API 密钥 (API Key)',
                          hintText: '本地 Ollama 可留空',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscureKey
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                            onPressed: () =>
                                setState(() => _obscureKey = !_obscureKey),
                          ),
                        ),
                        onChanged: (_) => _saveSettings(settings),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Row(
                        children: <Widget>[
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.cable),
                            label: const Text('测试连接'),
                            onPressed: _isTesting
                                ? null
                                : () => _testConnection(settings),
                          ),
                          const SizedBox(width: 12),
                          if (_isTesting)
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          if (_testMessage != null)
                            Expanded(
                              child: Row(
                                children: <Widget>[
                                  Icon(
                                    _testSuccess == true
                                        ? Icons.check_circle
                                        : Icons.error,
                                    size: 18,
                                    color: _testSuccess == true
                                        ? Colors.green
                                        : Colors.red,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      _testMessage!,
                                      style: TextStyle(
                                        color: _testSuccess == true
                                            ? Colors.green
                                            : Colors.red,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                _Section(
                  title: '批量维护',
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.auto_fix_high),
                      title: const Text('清洗整库'),
                      subtitle: const Text('对当前曲库所有曲目批量进行 AI 智能识别并纠偏歌名、歌手与专辑'),
                    ),
                    if (_isRefactoring && _refactorProgress != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            LinearProgressIndicator(
                              value: _refactorProgress!.ratio,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '正在清洗 (${_refactorProgress!.processed}/${_refactorProgress!.total}) · 已纠偏 ${_refactorProgress!.updated} 首',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Row(
                        children: <Widget>[
                          FilledButton.icon(
                            icon: const Icon(Icons.auto_awesome),
                            label: Text(_isRefactoring ? '清洗中…' : '开始清洗整库'),
                            onPressed: _isRefactoring ? null : _startRefactor,
                          ),
                          if (_isRefactoring) ...<Widget>[
                            const SizedBox(width: 12),
                            OutlinedButton(
                              onPressed: () =>
                                  setState(() => _isCancelled = true),
                              child: const Text('停止'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object err, _) => Center(child: Text('加载配置失败: $err')),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}
