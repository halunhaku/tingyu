import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../design/components/buttons.dart';
import '../../design/components/dialogs.dart';
import '../../design/components/feedback.dart';
import '../../design/components/inputs.dart';
import '../../design/components/structure.dart';
import '../../design/layout/form_factor.dart';
import '../../design/theme.dart';
import '../../design/tokens/metrics.dart';
import '../../sources/ai/ai_client.dart';
import '../../sources/ai/ai_config.dart';
import '../../sources/ai/ai_library_refactor_service.dart';

/// AI 识别与曲库清洗设置页面（`DESIGN.md` §6.1/§6.4）。
///
/// 结构：页头（compact 自带返回）→ 总开关 → 服务商配置 → 批量维护。
/// 所有写操作仍然走既有的 `AISettingsRepository`（密钥只进安全存储），
/// 这一层只换表现。
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
    AISettings settings, {
    bool? isEnabled,
    AIProviderPreset? preset,
  }) async {
    final AISettings next = settings.copyWith(
      isEnabled: isEnabled,
      preset: preset,
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
    );
    await ref.read(aiSettingsProvider.notifier).save(next);
  }

  Future<void> _testConnection(AISettings settings) async {
    setState(() {
      _isTesting = true;
      _testMessage = null;
      _testSuccess = null;
    });
    final AIClient client = AIClient(
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
    );
    try {
      final bool ok = await client.testConnection();
      if (!mounted) {
        return;
      }
      setState(() {
        _isTesting = false;
        _testSuccess = ok;
        _testMessage = ok ? '连接成功：模型返回了内容' : '连接失败：端点或密钥不可用';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isTesting = false;
        _testSuccess = false;
        _testMessage = '连接失败：$error';
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

    if (!mounted) {
      return;
    }
    setState(() {
      _isRefactoring = false;
      _refactorProgress = finalState;
    });
    TySnack.show(
      context,
      _isCancelled
          ? '清洗已停止：已检查 ${finalState.processed} 首，纠偏 ${finalState.updated} 首'
          : '清洗完成：共检查 ${finalState.processed} 首，纠偏 ${finalState.updated} 首',
    );
  }

  @override
  Widget build(BuildContext context) {
    final TyMetrics metrics = context.metrics;
    final AsyncValue<AISettings> asyncSettings = ref.watch(aiSettingsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.pagePadding,
            TySpace.x20,
            metrics.pagePadding,
            TySpace.x12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (context.canPop())
                Align(
                  alignment: Alignment.centerLeft,
                  child: TyIconAction(
                    icon: Icons.arrow_back,
                    semanticLabel: '返回',
                    tooltip: '返回',
                    onPressed: () => context.pop(),
                  ),
                ),
              TyPageHeader(title: 'AI 智能识别', subtitle: '用大语言模型清洗曲库里的乱码与噪音字段'),
            ],
          ),
        ),
        Expanded(
          child: TyAsyncView<AISettings>(
            value: asyncSettings,
            loading: (BuildContext context) => const Padding(
              padding: EdgeInsets.symmetric(horizontal: TySpace.x20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TySkeleton(height: 16, width: 200),
                  SizedBox(height: TySpace.x16),
                  TySkeleton.line(),
                  TySkeleton.line(),
                ],
              ),
            ),
            error: (BuildContext context, Object error, StackTrace? stack) =>
                TyErrorView(
                  title: '加载配置失败',
                  detail: '$error',
                  onRetry: () => ref.invalidate(aiSettingsProvider),
                ),
            data: (BuildContext context, AISettings settings) {
              _syncFromSettings(settings);
              return ListView(
                key: const PageStorageKey<String>('ai-settings'),
                padding: EdgeInsets.fromLTRB(
                  metrics.pagePadding,
                  0,
                  metrics.pagePadding,
                  TySpace.x32,
                ),
                children: <Widget>[
                  TyInsetGroup(
                    title: '总开关',
                    footer: settings.isEnabled ? null : '关闭后不会调用任何模型，曲库字段保持原样。',
                    children: <Widget>[
                      TySettingsRow.switchRow(
                        title: '启用智能识别',
                        description: '清洗乱码、音轨序号等噪音，提取标准歌名、歌手与专辑',
                        value: settings.isEnabled,
                        onChanged: (bool value) =>
                            _saveSettings(settings, isEnabled: value),
                      ),
                    ],
                  ),
                  if (settings.isEnabled) ...<Widget>[
                    const SizedBox(height: TySpace.x24),
                    TyInsetGroup(
                      title: '服务商配置',
                      children: <Widget>[
                        TySettingsRow.selectRow(
                          title: '预设服务商',
                          value: settings.preset.displayName,
                          onTap: () => _pickPreset(settings),
                        ),
                        _field(
                          controller: _baseUrlController,
                          label: 'API 端点 (Base URL)',
                          hint: 'https://api.deepseek.com/v1',
                          onChanged: () => _saveSettings(settings),
                        ),
                        _field(
                          controller: _modelController,
                          label: '模型名称 (Model)',
                          hint: 'deepseek-chat',
                          onChanged: () => _saveSettings(settings),
                        ),
                        _field(
                          controller: _apiKeyController,
                          label: 'API 密钥 (API Key)',
                          hint: '本地 Ollama 可留空',
                          obscureText: _obscureKey,
                          suffix: TyIconAction(
                            icon: _obscureKey
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            semanticLabel: _obscureKey ? '显示密钥' : '隐藏密钥',
                            tooltip: _obscureKey ? '显示密钥' : '隐藏密钥',
                            size: TyIconSize.inline,
                            onPressed: () =>
                                setState(() => _obscureKey = !_obscureKey),
                          ),
                          helperText: '密钥只写入系统安全存储，不进入数据库',
                          onChanged: () => _saveSettings(settings),
                        ),
                      ],
                    ),
                    const SizedBox(height: TySpace.x24),
                    TyInsetGroup(
                      title: '连接检查',
                      footer: '测试连接会用当前填写的端点与密钥发一次最小请求。',
                      children: <Widget>[
                        TySettingsRow.actionRow(
                          title: '测试连接',
                          description: _testMessage ?? '确认端点、模型与密钥是否可用',
                          leading: Icon(
                            _testSuccess == null
                                ? Icons.cable
                                : (_testSuccess!
                                      ? Icons.check_circle_outline
                                      : Icons.error_outline),
                            size: TyIconSize.inline,
                            color: _testSuccess == null
                                ? context.ty.colors.textSecondary
                                : (_testSuccess!
                                      ? context.ty.colors.success
                                      : context.ty.colors.danger),
                          ),
                          actionLabel: _isTesting ? '测试中…' : '测试',
                          busy: _isTesting,
                          onTap: _isTesting
                              ? null
                              : () => _testConnection(settings),
                        ),
                      ],
                    ),
                    const SizedBox(height: TySpace.x24),
                    TyInsetGroup(
                      title: '批量维护',
                      footer: '清洗只改动歌名、歌手与专辑三个字段；原文件不动。',
                      children: <Widget>[
                        TySettingsRow.actionRow(
                          title: '清洗整库',
                          description: '对当前曲库所有曲目批量识别并纠偏',
                          leading: const Icon(
                            Icons.auto_fix_high,
                            size: TyIconSize.inline,
                          ),
                          actionLabel: _isRefactoring ? '清洗中…' : '开始',
                          busy: _isRefactoring,
                          onTap: _isRefactoring ? null : _startRefactor,
                        ),
                        if (_isRefactoring)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              TySpace.x16,
                              TySpace.x8,
                              TySpace.x16,
                              TySpace.x16,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Semantics(
                                  liveRegion: true,
                                  value: _refactorProgress == null
                                      ? '正在清洗'
                                      : '已清洗 ${_refactorProgress!.processed} / '
                                            '${_refactorProgress!.total}',
                                  child: TyProgressBar(
                                    value: _refactorProgress?.ratio,
                                  ),
                                ),
                                const SizedBox(height: TySpace.x8),
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: Text(
                                        _refactorProgress == null
                                            ? '正在清洗…'
                                            : '正在清洗 (${_refactorProgress!.processed}/'
                                                  '${_refactorProgress!.total}) · '
                                                  '已纠偏 ${_refactorProgress!.updated} 首',
                                        style: context.ty.typography.bodyS
                                            .copyWith(
                                              color: context
                                                  .ty
                                                  .colors
                                                  .textSecondary,
                                            ),
                                      ),
                                    ),
                                    TyButton(
                                      label: '停止',
                                      variant: TyButtonVariant.secondary,
                                      dense: true,
                                      onPressed: () =>
                                          setState(() => _isCancelled = true),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required VoidCallback onChanged,
    bool obscureText = false,
    String? helperText,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TySpace.x16,
        TySpace.x8,
        TySpace.x16,
        TySpace.x12,
      ),
      child: TyTextField(
        controller: controller,
        label: label,
        hint: hint,
        obscureText: obscureText,
        helperText: helperText,
        suffix: suffix,
        onChanged: (String _) => onChanged(),
      ),
    );
  }

  Future<void> _pickPreset(AISettings settings) async {
    final AIProviderPreset? picked = await showTyDialog<AIProviderPreset>(
      context,
      child: TyDialog(
        title: '预设服务商',
        actions: <Widget>[
          TyButton(
            label: '取消',
            variant: TyButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final AIProviderPreset preset in AIProviderPreset.values)
              TySettingsRow(
                title: preset.displayName,
                trailing: preset == settings.preset
                    ? Icon(
                        Icons.check,
                        size: TyIconSize.compact,
                        color: context.ty.colors.accent,
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(preset),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == settings.preset) {
      return;
    }
    _baseUrlController.text = picked.defaultBaseUrl;
    _modelController.text = picked.defaultModel;
    await _saveSettings(settings, preset: picked);
  }
}
