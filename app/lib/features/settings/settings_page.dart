import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/preferences.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/models/library_summaries.dart';
import '../../data/settings_store.dart';
import '../../design/components/buttons.dart';
import '../../design/components/dialogs.dart';
import '../../design/components/feedback.dart';
import '../../design/components/structure.dart';
import '../../design/format.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../../design/tokens/motion.dart';
import '../../design/tokens/tokens.dart';
import '../../design/theme.dart';
import '../../sources/ai/ai_config.dart';
import '../sources/source_sync.dart';

/// 设置页分组：slug 是路由 `/settings/<slug>` 的稳定标识（英文，不随文案改动）。
abstract final class SettingsSections {
  static const String appearance = 'appearance';
  static const String playback = 'playback';
  static const String library = 'library';
  static const String sources = 'sources';
  static const String ai = 'ai';
  static const String data = 'data';
  static const String about = 'about';

  /// 页面内固定顺序。
  static const List<String> order = <String>[
    appearance,
    playback,
    library,
    sources,
    ai,
    data,
    about,
  ];

  /// 分组标题（同时用作分组卡片的标题）。
  static String title(String slug) => switch (slug) {
    appearance => '外观',
    playback => '播放',
    library => '音乐库',
    sources => '来源',
    ai => '智能',
    data => '数据',
    about => '关于',
    _ => slug,
  };
}

/// 设置页：外观 / 播放 / 音乐库 / 来源 / 智能 / 数据 / 关于。
///
/// 深链 `/settings/<slug>` 滚到对应分组（未知 slug 显示全部，不报错）。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key, this.section});

  /// 分组 slug；null = 显示全部。
  final String? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _SettingsBody(section: section);
}

class _SettingsBody extends ConsumerStatefulWidget {
  const _SettingsBody({this.section});

  final String? section;

  @override
  ConsumerState<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends ConsumerState<_SettingsBody> {
  /// 每个分组的锚点：`section` 变化时把分组滚进视野。
  late final Map<String, GlobalKey> _anchors = <String, GlobalKey>{
    for (final String slug in SettingsSections.order) slug: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    _scrollToSection();
  }

  @override
  void didUpdateWidget(_SettingsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      _scrollToSection();
    }
  }

  void _scrollToSection() {
    final String? slug = widget.section;
    if (slug == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final BuildContext? target = _anchors[slug]?.currentContext;
      if (target == null) {
        return;
      }
      final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
      Scrollable.ensureVisible(
        target,
        alignment: 0,
        // 严格判据：减少动态时不做滚动动画，直接定位。
        duration: reduceMotion ? Duration.zero : TyDuration.base,
        curve: TyCurve.standard,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final TyMetrics metrics = context.metrics;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        metrics.pagePadding,
        TySpace.x20,
        metrics.pagePadding,
        TySpace.x32,
      ),
      children: <Widget>[
        const TyPageHeader(title: '设置', subtitle: '外观、播放、曲库与数据'),
        _group(
          SettingsSections.appearance,
          children: _appearanceChildren(),
        ),
        _group(
          SettingsSections.playback,
          children: <Widget>[
            _infoRow(
              '播放引擎',
              ref.read(audioHandlerProvider).engineName,
            ),
            _infoRow('系统媒体会话', 'Now Playing / 媒体键 / 锁屏（audio_service）'),
          ],
        ),
        _group(
          SettingsSections.library,
          footer: '远端来源（WebDAV / 夸克）的曲目需要先同步；'
              '曲目缺少歌手 / 专辑 / 歌词时可在来源页点「补全元数据」。',
          children: _libraryChildren(),
        ),
        _group(
          SettingsSections.sources,
          children: _sourceChildren(),
        ),
        _group(
          SettingsSections.ai,
          children: <Widget>[
            TySettingsRow.navRow(
              title: 'AI 识别与清洗',
              description: _aiDescription(),
              onTap: () => context.push('/ai'),
            ),
          ],
        ),
        _group(
          SettingsSections.data,
          children: <Widget>[
            FutureBuilder<Directory>(
              // 走 provider 而不是在 build 里直接起 Future：否则每次重建都会重新
              // 问一次系统目录（配置页重建很频繁），测试里也没法替换。
              future: ref.watch(dataDirectoryProvider.future),
              builder: (BuildContext context, AsyncSnapshot<Directory> snap) {
                final String path = snap.data?.path ?? '…';
                return _infoRow('数据目录', path, copyable: true);
              },
            ),
            _infoRow('曲库文件', 'library.sqlite（SQLite / drift）'),
            _infoRow('封面缓存', 'covers/（只存文件名，二进制落盘）'),
          ],
        ),
        _group(
          SettingsSections.about,
          footer: '这是纯 Swift 版的重写版本，桌面端（macOS / Windows / Linux）与移动端共用一套代码；'
              '旧版仍在维护期内，迁移方案见 docs/crossplatform-migration.md。',
          children: <Widget>[
            _infoRow('版本', '0.1.0 (Flutter 预览版)'),
            // 构建戳：开发期用来确认"手机上装的到底是哪一次构建"。
            _infoRow(
              '构建',
              const String.fromEnvironment(
                'BUILD_STAMP',
                defaultValue: '本地构建',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _group(
    String slug, {
    required List<Widget> children,
    String? footer,
  }) {
    return Padding(
      key: _anchors[slug],
      padding: const EdgeInsets.only(bottom: TySpace.x12),
      child: TyInsetGroup(
        title: SettingsSections.title(slug),
        footer: footer,
        children: children,
      ),
    );
  }

  /// 外观：主题模式 / 密度 / 封面取色 + 偏好文件损坏时的恢复入口。
  List<Widget> _appearanceChildren() {
    final AsyncValue<PreferencesState> prefs = ref.watch(preferencesProvider);
    final PreferencesState? state = prefs.value;
    if (state == null) {
      if (prefs.hasError) {
        return <Widget>[
          TyErrorView(
            compact: true,
            title: '外观偏好读取失败',
            detail: '${prefs.error}',
            onRetry: () => ref.invalidate(preferencesProvider),
          ),
        ];
      }
      return const <Widget>[
        _LoadingRow(),
        _LoadingRow(),
      ];
    }
    final AppPreferences current = state.preferences;
    final PreferencesNotifier notifier = ref.read(
      preferencesProvider.notifier,
    );
    final SettingsCorruptException? corrupt = state.loadError;
    return <Widget>[
      if (corrupt != null)
        TyErrorView(
          compact: true,
          title: '外观偏好文件损坏，本次使用默认外观',
          detail: '$corrupt',
          retryLabel: '恢复默认外观',
          onRetry: notifier.reset,
        ),
      TySettingsRow.selectRow(
        title: '主题模式',
        description: '跟随系统时随系统深浅色切换',
        value: _themeModeLabel(current.themeMode),
        onTap: () => _pick(
          title: '主题模式',
          options: <(ThemeMode, String)>[
            (ThemeMode.system, '跟随系统'),
            (ThemeMode.light, '浅色'),
            (ThemeMode.dark, '深色'),
          ],
          current: current.themeMode,
          onPicked: notifier.setThemeMode,
        ),
      ),
      TySettingsRow.selectRow(
        title: '界面密度',
        description: '紧凑密度让列表与表格在同一屏显示更多行',
        value: current.density.isCompact ? '紧凑' : '舒适',
        onTap: () => _pick(
          title: '界面密度',
          options: <(TyDensity, String)>[
            (TyDensity.comfortable, '舒适'),
            (TyDensity.compact, '紧凑'),
          ],
          current: current.density,
          onPicked: notifier.setDensity,
        ),
      ),
      TySettingsRow.switchRow(
        title: '封面动态取色',
        description: '舞台背景与播放条按封面取色；关闭后使用中性渐变',
        value: current.coverTint,
        onChanged: notifier.setCoverTint,
      ),
      TySettingsRow.actionRow(
        title: '恢复默认外观',
        description: '主题模式 / 密度 / 封面取色回到初始值',
        actionLabel: '恢复默认',
        onTap: () async {
          await notifier.reset();
          if (mounted) {
            TySnack.show(context, '外观已恢复默认');
          }
        },
      ),
    ];
  }

  List<Widget> _libraryChildren() {
    final AsyncValue<List<Track>> tracks = ref.watch(allTracksProvider);
    final AsyncValue<List<MusicSource>> sources = ref.watch(sourcesProvider);
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);
    final AsyncValue<List<AlbumSummary>> albums = ref.watch(albumsProvider);
    final AsyncValue<List<ArtistSummary>> artists = ref.watch(artistsProvider);
    final Map<String, SourceSyncState> sync = ref.watch(sourceSyncProvider);
    final bool syncing = sync.values.any(
      (SourceSyncState state) => state.running,
    );
    final List<MusicSource> list = sources.value ?? const <MusicSource>[];
    return <Widget>[
      _infoRow('曲目', '${tracks.value?.length ?? 0}'),
      _infoRow('专辑', '${albums.value?.length ?? 0}'),
      _infoRow('艺术家', '${artists.value?.length ?? 0}'),
      _infoRow('播放列表', '${playlists.value?.length ?? 0}'),
      _infoRow('来源', '${list.length}'),
      TySettingsRow.actionRow(
        title: '同步全部来源',
        description: syncing ? '正在逐个重新扫描并合并入库' : '逐个重新扫描并合并入库',
        actionLabel: syncing ? '同步中…' : '开始',
        busy: syncing,
        onTap: () async {
          for (final MusicSource source in list) {
            await ref.read(sourceSyncProvider.notifier).sync(source);
          }
          if (mounted) {
            TySnack.show(context, '已同步 ${list.length} 个来源');
          }
        },
      ),
    ];
  }

  List<Widget> _sourceChildren() {
    final AsyncValue<List<MusicSource>> sources = ref.watch(sourcesProvider);
    final List<MusicSource> list = sources.value ?? const <MusicSource>[];
    return <Widget>[
      TySettingsRow.navRow(
        title: '来源管理',
        description: '本地目录 / WebDAV / 夸克网盘',
        onTap: () => context.go('/sources'),
      ),
      for (final MusicSource source in list)
        TySettingsRow.navRow(
          title: source.name,
          description: _sourceDescription(source),
          onTap: () => context.push('/source/${source.id}'),
        ),
    ];
  }

  static String _sourceDescription(MusicSource source) {
    final String kind = switch (source.kind) {
      'webdav' => 'WebDAV',
      'quark' => '夸克网盘',
      _ => '本地目录',
    };
    final String status = source.syncStatus.isEmpty
        ? '尚未同步'
        : source.syncStatus;
    final DateTime? syncedAt = source.lastSyncedAt;
    final String synced = syncedAt == null
        ? ''
        : ' · ${formatRelativeTime(syncedAt)}';
    return '$kind · ${source.trackCount} 首 · $status$synced';
  }

  String _aiDescription() {
    final AsyncValue<AISettings> settings = ref.watch(aiSettingsProvider);
    final AISettings? value = settings.value;
    if (value == null) {
      return settings.hasError ? '配置读取失败' : '正在读取配置…';
    }
    return value.isEnabled
        ? '${value.preset.displayName} · 已启用'
        : '未启用';
  }

  Widget _infoRow(String label, String value, {bool copyable = false}) {
    return TySettingsRow(
      title: label,
      description: value,
      trailing: copyable
          ? TyIconAction(
              icon: Icons.copy_all_outlined,
              semanticLabel: '复制$label',
              tooltip: '复制$label',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                TySnack.show(context, '已复制$label');
              },
            )
          : null,
    );
  }

  static String _themeModeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };

  /// 选项选择器：一个对话框列出全部取值，当前值带勾。
  Future<void> _pick<T>({
    required String title,
    required List<(T, String)> options,
    required T current,
    required ValueChanged<T> onPicked,
  }) async {
    final TyTokens ty = context.ty;
    final T? picked = await showTyDialog<T>(
      context,
      child: TyDialog(
        title: title,
        actions: <Widget>[
          TyButton(
            label: '取消',
            variant: TyButtonVariant.secondary,
            dense: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final (T value, String label) in options)
              TySettingsRow(
                title: label,
                trailing: value == current
                    ? Icon(
                        Icons.check,
                        size: TyIconSize.compact,
                        color: ty.colors.accent,
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(value),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      onPicked(picked);
    }
  }
}

/// 偏好尚未读出时的骨架行（不走页面级转圈）。
class _LoadingRow extends StatelessWidget {
  const _LoadingRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(TySpace.x16),
      child: TySkeleton(height: TySpace.x16, width: 180),
    );
  }
}
