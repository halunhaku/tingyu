import 'dart:async';
import 'dart:io' show Platform;

import 'package:drift/drift.dart' show Value;
import 'package:file_selector/file_selector.dart';
import 'package:tingyu_saf/tingyu_saf.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/source_adapters.dart';
import '../../data/db/database.dart';
import '../../data/secure_store.dart';
import '../../design/components/buttons.dart';
import '../../design/components/context_menu.dart';
import '../../design/components/dialogs.dart';
import '../../design/components/feedback.dart';
import '../../design/components/inputs.dart';
import '../../design/components/interactive.dart';
import '../../design/components/source_card.dart';
import '../../design/components/structure.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tokens/voice_archive.dart';
import '../../design/theme.dart';
import '../../sources/quark/quark_auth.dart';
import '../../sources/quark/quark_drive_client.dart';
import '../../sources/quark/quark_session.dart';
import '../../sources/webdav/webdav_client.dart';
import 'quark_qr_login_page.dart';
import 'quark_web_login_page.dart';
import 'source_status.dart';
import 'source_sync.dart';

/// 骨架卡片高度：与 `TySourceCard` 的无详情形态对齐（含徽标 + 名称 + 状态行）。
const double _sourceCardSkeletonHeight = 128;

/// 来源管理：列出、添加、同步、删除本地目录 / WebDAV / 夸克网盘。
///
/// 对应旧版 `Sources/UI/Shared/SourceManagerView.swift`：本地目录用系统目录选择器，
/// WebDAV 用表单；夸克按平台提供扫码、WebView、Cookie 导入并统一选择文件夹。
///
/// 状态语汇（`docs/UX_REDESIGN.md` §4.5）在卡片上完整呈现：
/// 未配置 / 已连接 · N 首 · 上次同步 x / 同步中（进度条 + 计数）/ 失败（原因 + 重试）；
/// 「登录中」属于登录页（`QuarkQrLoginPage` / `QuarkWebLoginPage`）的呈现。
class SourcesPage extends ConsumerWidget {
  const SourcesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyTokens inherited = context.ty;
    return Theme(
      data: TyTheme.build(
        brightness: inherited.brightness,
        density: inherited.density,
        colors: VoiceArchiveColors.of(inherited.brightness),
      ),
      child: Builder(
        builder: (BuildContext themedContext) => _page(themedContext, ref),
      ),
    );
  }

  Widget _page(BuildContext context, WidgetRef ref) {
    final TyMetrics metrics = context.metrics;
    final AsyncValue<List<MusicSource>> sources = ref.watch(sourcesProvider);
    final List<MusicSource> list = sources.value ?? const <MusicSource>[];
    final int count = list.length;
    final int trackCount = list.fold<int>(
      0,
      (int total, MusicSource source) => total + source.trackCount,
    );
    final String subtitle = switch (sources) {
      AsyncError<List<MusicSource>>() => '无法读取来源',
      AsyncLoading<List<MusicSource>>() => '正在读取来源',
      _ when count == 0 => '连接本地或云端音乐',
      _ => '$count 个来源 · $trackCount 首音乐',
    };
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                metrics.pagePadding,
                TySpace.x20,
                metrics.pagePadding,
                TySpace.x12,
              ),
              child: TyPageHeader(
                title: '来源管理',
                subtitle: subtitle,
                actions: <Widget>[
                  if (context.formFactor.isCompact)
                    TyIconAction(
                      icon: Icons.add,
                      semanticLabel: '添加来源',
                      tooltip: '添加来源',
                      onPressed: () => _showAddDialog(context, ref),
                    )
                  else
                    TyButton(
                      label: '添加来源',
                      icon: Icons.add,
                      onPressed: () => _showAddDialog(context, ref),
                    ),
                ],
              ),
            ),
            Expanded(
              child: TyAsyncView<List<MusicSource>>(
                value: sources,
                loading: (BuildContext context) =>
                    _listSkeleton(context, metrics),
                error:
                    (BuildContext context, Object error, StackTrace? stack) =>
                        TyErrorView(
                          title: '读取来源失败',
                          detail: _sourceReadErrorDetail(error),
                          onRetry: () => ref.invalidate(sourcesProvider),
                        ),
                data: (BuildContext context, List<MusicSource> list) {
                  if (list.isEmpty) {
                    return _EmptySources(
                      onAdd: (_AddSourceKind kind) =>
                          _chooseAddKind(context, ref, kind),
                    );
                  }
                  return ListView(
                    key: const Key('sources-list'),
                    padding: EdgeInsets.fromLTRB(
                      metrics.pagePadding,
                      0,
                      metrics.pagePadding,
                      TySpace.x16,
                    ),
                    children: <Widget>[
                      _SourceOverview(sources: list),
                      const TySectionHeader(title: '音乐来源', count: null),
                      for (int index = 0; index < list.length; index++) ...[
                        if (index > 0) const SizedBox(height: TySpace.x12),
                        _SourceCard(source: list[index], ordinal: index + 1),
                      ],
                      const SizedBox(height: TySpace.x16),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _listSkeleton(BuildContext context, TyMetrics metrics) {
    final bool compact = context.formFactor.isCompact;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        metrics.pagePadding,
        0,
        metrics.pagePadding,
        TySpace.x16,
      ),
      children: <Widget>[
        const TySkeleton(height: 88, radius: TyRadius.sm),
        const SizedBox(height: TySpace.x24),
        for (int index = 0; index < (compact ? 2 : 3); index++) ...<Widget>[
          if (index > 0) const SizedBox(height: TySpace.x12),
          const TySkeleton(
            height: _sourceCardSkeletonHeight,
            radius: TyRadius.sm,
          ),
        ],
      ],
    );
  }

  Future<void> _chooseAddKind(
    BuildContext context,
    WidgetRef ref,
    _AddSourceKind kind,
  ) async {
    switch (kind) {
      case _AddSourceKind.local:
        await _addLocalFolder(context, ref);
      case _AddSourceKind.webdav:
        await _addWebDav(context, ref);
      case _AddSourceKind.quark:
        await _addQuark(context, ref);
    }
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    final _AddSourceKind? kind = await showTyDialog<_AddSourceKind>(
      context,
      child: TyDialog(
        title: '添加来源',
        subtitle: '添加后会立即扫描一次',
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
            TySettingsRow.navRow(
              title: '本地目录',
              description: context.traits.touchPrimary
                  ? '选择本机上的音乐文件夹'
                  : '选择电脑上的音乐文件夹',
              leading: const _RowIcon(Icons.folder_outlined),
              onTap: () => Navigator.of(context).pop(_AddSourceKind.local),
            ),
            TySettingsRow.navRow(
              title: 'WebDAV',
              description: '坚果云等支持 WebDAV 的网盘',
              leading: const _RowIcon(Icons.cloud_outlined),
              onTap: () => Navigator.of(context).pop(_AddSourceKind.webdav),
            ),
            TySettingsRow.navRow(
              title: '夸克网盘',
              description: '扫码、网页登录或 Cookie 导入',
              leading: const _RowIcon(Icons.cloud_queue),
              onTap: () => Navigator.of(context).pop(_AddSourceKind.quark),
            ),
          ],
        ),
      ),
    );
    if (kind == null || !context.mounted) {
      return;
    }
    await _chooseAddKind(context, ref, kind);
  }

  Future<void> _addLocalFolder(BuildContext context, WidgetRef ref) async {
    // Android：必须走 SAF 目录授权（分区存储下直接读 /sdcard 会 EACCES）。
    // iOS：文档选择器 + 安全作用域书签（沙盒外目录拿不到可持久化的路径）。
    // 桌面：普通文件系统路径，用系统目录选择器。
    final String id = 'src-${DateTime.now().microsecondsSinceEpoch}';
    // guard-ok: 目录选择器按平台能力分支（SAF / 安全书签只存在于对应平台），不是布局分支。
    if (Platform.isAndroid) {
      final String? treeUri = await TingyuSaf.pickDirectory();
      if (treeUri == null || treeUri.isEmpty) {
        return; // 用户取消
      }
      await ref
          .read(sourceRepositoryProvider)
          .upsert(
            MusicSourcesCompanion.insert(
              id: id,
              name: _displayNameOfTreeUri(treeUri),
              kind: 'local',
              localBookmark: Value<String?>(treeUri),
            ),
          );
      // guard-ok: 同上，iOS 的安全作用域书签只有 iOS 需要。
    } else if (Platform.isIOS) {
      final PickedFolder? picked = await TingyuSaf.pickFolderBookmark();
      if (picked == null) {
        return; // 用户取消
      }
      await ref
          .read(sourceRepositoryProvider)
          .upsert(
            MusicSourcesCompanion.insert(
              id: id,
              name: _displayNameOfPath(picked.path),
              kind: 'local',
              localBookmark: Value<String?>(picked.bookmark),
            ),
          );
    } else {
      final String? path = await getDirectoryPath(confirmButtonText: '选择');
      if (path == null || path.isEmpty) {
        return;
      }
      await ref
          .read(sourceRepositoryProvider)
          .upsert(
            MusicSourcesCompanion.insert(
              id: id,
              name: _displayNameOfPath(path),
              kind: 'local',
              localFolderPath: Value<String?>(path),
            ),
          );
    }
    if (!context.mounted) {
      return;
    }
    await _syncAndReport(context, ref, id);
  }

  /// 从 SAF tree URI 里取一个可读的目录名（形如 `content://.../tree/primary%3AMusic`）。
  static String _displayNameOfTreeUri(String treeUri) {
    final String tail = treeUri.split('/').last;
    final String decoded = Uri.decodeComponent(tail);
    final int colon = decoded.indexOf(':');
    return _displayNameOfPath(
      colon >= 0 ? decoded.substring(colon + 1) : decoded,
    );
  }

  /// 取目录路径的最后一段作为来源名（`/a/b/音乐` → `音乐`）。
  static String _displayNameOfPath(String path) =>
      path.split('/').where((String part) => part.isNotEmpty).lastOrNull ??
      '本地音乐';

  Future<void> _addWebDav(BuildContext context, WidgetRef ref) async {
    final _WebDavFormResult? form = await _connectWebDavWithRetry(context);
    if (form == null || !context.mounted) {
      return;
    }

    final String id = 'src-${DateTime.now().microsecondsSinceEpoch}';
    await SecureStore().writeWebDavPassword(id, form.password);
    if (context.mounted) {
      _showCredentialStorageWarning(context);
    }
    await ref
        .read(sourceRepositoryProvider)
        .upsert(
          MusicSourcesCompanion.insert(
            id: id,
            name: form.name.isEmpty ? Uri.parse(form.url).host : form.name,
            kind: 'webdav',
            webdavUrl: Value<String?>(form.url),
            webdavUsername: Value<String?>(form.username),
          ),
        );
    if (!context.mounted) {
      return;
    }
    await _syncAndReport(context, ref, id);
  }

  /// 表单 + 连接测试；认证失败回到表单让用户改，而不是静默结束。
  Future<_WebDavFormResult?> _connectWebDavWithRetry(
    BuildContext context,
  ) async {
    while (true) {
      final _WebDavFormResult? form = await showTyDialog<_WebDavFormResult>(
        context,
        child: const _WebDavFormDialog(),
      );
      if (form == null || !context.mounted) {
        return null;
      }
      final WebDavClient client = WebDavClient();
      final bool ok = await client.testConnection(
        url: Uri.parse(form.url),
        username: form.username,
        password: form.password,
      );
      if (!context.mounted) {
        return null;
      }
      if (ok) {
        return form;
      }
      final bool retry =
          await showTyDialog<bool>(
            context,
            child: TyDialog(
              title: '连接失败',
              actions: <Widget>[
                TyButton(
                  label: '取消',
                  variant: TyButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
                TyButton(
                  label: '重新填写',
                  variant: TyButtonVariant.secondary,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ],
              child: TyErrorView(
                compact: true,
                title: 'WebDAV 认证失败',
                detail: '请检查地址、账号与应用专用密码（${Uri.parse(form.url).host}）。',
              ),
            ),
          ) ??
          false;
      if (!retry || !context.mounted) {
        return null;
      }
    }
  }

  Future<void> _addQuark(BuildContext context, WidgetRef ref) async {
    final QuarkDriveClient client = QuarkDriveClient();
    final QuarkAuthCore authCore = QuarkAuthCore(client: client);
    final QuarkSession? session = await obtainQuarkSession(
      context,
      authCore: authCore,
    );
    if (session == null || !context.mounted) {
      return;
    }

    // 登录后选择曲库所在文件夹（不选则扫描根目录）。取消时不会留下孤立凭据。
    final String? folderFid = await _pickQuarkFolder(context, client, session);
    if (!context.mounted || folderFid == null) {
      return;
    }

    final String id = 'src-${DateTime.now().microsecondsSinceEpoch}';
    await authCore.bindAndSave(id, session);
    if (!context.mounted) {
      return;
    }
    _showCredentialStorageWarning(context);
    await ref
        .read(sourceRepositoryProvider)
        .upsert(
          MusicSourcesCompanion.insert(
            id: id,
            name: '夸克网盘',
            kind: 'quark',
            quarkAccountName: Value<String?>(session.nickname),
            quarkFolderFid: Value<String?>(
              folderFid.isEmpty ? null : folderFid,
            ),
          ),
        );
    if (!context.mounted) {
      return;
    }
    await _syncAndReport(context, ref, id);
  }

  /// 选择夸克曲库目录：返回 fid（''=根目录），取消或读取失败放弃时返回 null。
  Future<String?> _pickQuarkFolder(
    BuildContext context,
    QuarkDriveClient client,
    QuarkSession session,
  ) async {
    final List<QuarkItem>? folders = await _listQuarkFolders(
      context,
      client,
      session,
    );
    if (!context.mounted || folders == null) {
      return null;
    }
    return showTyDialog<String>(
      context,
      child: TyDialog(
        form: true,
        title: '选择曲库文件夹',
        subtitle: '只扫描这个文件夹及其子目录；不选则扫描根目录',
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
            TySettingsRow.navRow(
              title: '使用根目录（扫描全部）',
              description: '曲库文件在网盘根目录时选这项',
              onTap: () => Navigator.of(context).pop(''),
            ),
            if (folders.isEmpty)
              Padding(
                padding: const EdgeInsets.all(TySpace.x16),
                child: Text(
                  '网盘根目录下没有文件夹，只能扫描根目录。',
                  style: context.ty.typography.bodyS.copyWith(
                    color: context.ty.colors.textSecondary,
                  ),
                ),
              )
            else
              for (final QuarkItem folder in folders)
                TySettingsRow(
                  title: folder.name,
                  onTap: () => Navigator.of(context).pop(folder.id),
                ),
          ],
        ),
      ),
    );
  }

  /// 读取夸克根目录文件夹；读取期间不静默卡住，失败给「重试 / 放弃」而不是悄悄扫根目录。
  Future<List<QuarkItem>?> _listQuarkFolders(
    BuildContext context,
    QuarkDriveClient client,
    QuarkSession session,
  ) async {
    while (true) {
      try {
        return await _withProgress(
          context,
          '正在读取夸克目录…',
          () async =>
              (await client.listFolder(session: session)).items
                  .where((QuarkItem item) => item.isFolder)
                  .toList(),
        );
      } on Object catch (error) {
        if (!context.mounted) {
          return null;
        }
        final bool retry =
            await showTyDialog<bool>(
              context,
              child: TyDialog(
                title: '读取夸克目录失败',
                actions: <Widget>[
                  TyButton(
                    label: '放弃添加',
                    variant: TyButtonVariant.ghost,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  TyButton(
                    label: '重试',
                    variant: TyButtonVariant.secondary,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ],
                child: TyErrorView(compact: true, title: '$error'),
              ),
            ) ??
            false;
        if (!retry || !context.mounted) {
          return null;
        }
      }
    }
  }

  /// 慢操作期间给一个不可关闭的进度弹窗（读取远端目录 / 登录换票）。
  static Future<T> _withProgress<T>(
    BuildContext context,
    String title,
    Future<T> Function() task,
  ) async {
    unawaited(
      showTyDialog<void>(
        context,
        barrierDismissible: false,
        child: TyDialog(
          title: title,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: TySpace.x8),
            child: TyProgressBar(),
          ),
        ),
      ),
    );
    try {
      return await task();
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  /// 添加后立即同步一次，并跳到来源页看结果。
  Future<void> _syncAndReport(
    BuildContext context,
    WidgetRef ref,
    String sourceId,
  ) async {
    final MusicSource? source = await ref
        .read(sourceRepositoryProvider)
        .byId(sourceId);
    if (source != null) {
      await ref.read(sourceSyncProvider.notifier).sync(source);
    }
    if (context.mounted) {
      context.push('/source/$sourceId');
    }
  }
}

String _sourceReadErrorDetail(Object error) {
  final String detail = error.toString().replaceFirst(
    RegExp(r'^(Bad state|Exception|StateError):\s*'),
    '',
  );
  return detail.isEmpty ? '来源列表暂时无法读取，请重试。' : '$detail。';
}

class _SourceOverview extends ConsumerWidget {
  const _SourceOverview({required this.sources});

  final List<MusicSource> sources;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyTokens ty = context.ty;
    final Map<String, SourceSyncState> sync = ref.watch(sourceSyncProvider);
    final int totalTracks = sources.fold<int>(
      0,
      (int total, MusicSource source) => total + source.trackCount,
    );
    final int connected = sources.where((MusicSource source) {
      final SourceSyncState state = sync[source.id] ?? const SourceSyncState();
      return describeSourceStatus(source, state).tone ==
          TySourceStatusTone.connected;
    }).length;
    final int syncing = sources.where((MusicSource source) {
      return sync[source.id]?.running ?? false;
    }).length;
    return Semantics(
      container: true,
      label:
          '${sources.length} 个来源，$totalTracks 首音乐，'
          '${syncing > 0 ? '$syncing 个同步中' : '$connected 个已连接'}',
      child: Container(
        padding: const EdgeInsets.all(TySpace.x16),
        decoration: BoxDecoration(
          color: ty.colors.surfaceRaised,
          borderRadius: TyRadius.smAll,
          border: Border.all(color: ty.colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.graphic_eq,
                  size: TyIconSize.compact,
                  color: ty.colors.accent,
                ),
                const SizedBox(width: TySpace.x6),
                Text(
                  '声档接入',
                  style: ty.typography.labelS.copyWith(
                    color: ty.colors.textTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: TySpace.x12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: _OverviewMetric(
                    value: '${sources.length}',
                    label: '来源',
                  ),
                ),
                const _OverviewDivider(),
                Expanded(
                  child: _OverviewMetric(value: '$totalTracks', label: '曲目'),
                ),
                const _OverviewDivider(),
                Expanded(
                  child: _OverviewMetric(
                    value: '${syncing > 0 ? syncing : connected}',
                    label: syncing > 0 ? '同步中' : '已连接',
                    accent: syncing > 0,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewMetric extends StatelessWidget {
  const _OverviewMetric({
    required this.value,
    required this.label,
    this.accent = false,
  });

  final String value;
  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ty.typography.titleL.copyWith(
            color: accent ? ty.colors.accent : ty.colors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: TySpace.x2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ty.typography.labelM.copyWith(color: ty.colors.textTertiary),
        ),
      ],
    );
  }
}

class _OverviewDivider extends StatelessWidget {
  const _OverviewDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: TySpace.x40,
      margin: const EdgeInsets.symmetric(horizontal: TySpace.x12),
      color: context.ty.colors.border,
    );
  }
}

class _EmptySources extends StatelessWidget {
  const _EmptySources({required this.onAdd});

  final ValueChanged<_AddSourceKind> onAdd;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool compact = context.formFactor.isCompact;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double gap = TySpace.x12;
        final double optionWidth = compact
            ? constraints.maxWidth
            : (constraints.maxWidth - gap * 2) / 3;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            context.metrics.pagePadding,
            compact ? TySpace.x8 : TySpace.x24,
            context.metrics.pagePadding,
            TySpace.x24,
          ),
          children: <Widget>[
            Container(
              padding: EdgeInsets.all(compact ? TySpace.x20 : TySpace.x32),
              decoration: BoxDecoration(
                color: ty.colors.surfaceRaised,
                borderRadius: TyRadius.smAll,
                border: Border.all(color: ty.colors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '建立声档',
                    style: ty.typography.labelS.copyWith(
                      color: ty.colors.accent,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: TySpace.x8),
                  Text(
                    '还没有音乐来源',
                    style: ty.typography.titleL.copyWith(
                      color: ty.colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: TySpace.x6),
                  Text(
                    '连接一个位置后，听屿会扫描曲目并在这里保存同步状态。不会自动上传文件。',
                    style: ty.typography.bodyM.copyWith(
                      color: ty.colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: TySpace.x24),
                  Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: <Widget>[
                      SizedBox(
                        width: optionWidth,
                        child: _AddSourceOption(
                          key: const Key('sources-add-local'),
                          title: '本地目录',
                          description: '扫描这台设备上的音乐文件',
                          icon: Icons.folder_outlined,
                          onTap: () => onAdd(_AddSourceKind.local),
                        ),
                      ),
                      SizedBox(
                        width: optionWidth,
                        child: _AddSourceOption(
                          key: const Key('sources-add-webdav'),
                          title: 'WebDAV',
                          description: '连接坚果云等兼容服务',
                          icon: Icons.cloud_outlined,
                          onTap: () => onAdd(_AddSourceKind.webdav),
                        ),
                      ),
                      SizedBox(
                        width: optionWidth,
                        child: _AddSourceOption(
                          key: const Key('sources-add-quark'),
                          title: '夸克网盘',
                          description: '扫码或导入会话访问云端曲库',
                          icon: Icons.cloud_queue,
                          onTap: () => onAdd(_AddSourceKind.quark),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AddSourceOption extends StatelessWidget {
  const _AddSourceOption({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return ClipRRect(
      borderRadius: TyRadius.smAll,
      child: TyInteractive(
        onTap: onTap,
        semanticLabel: '添加$title，$description',
        builder: (BuildContext context, TyInteractionState state) {
          return Container(
            constraints: const BoxConstraints(minHeight: 112),
            padding: const EdgeInsets.all(TySpace.x16),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                state.overlay(ty.colors),
                ty.colors.surfaceSunken,
              ),
              border: Border.all(color: ty.colors.border),
              borderRadius: TyRadius.smAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: TySpace.x40,
                      height: TySpace.x40,
                      decoration: BoxDecoration(
                        color: ty.colors.surfaceRaised,
                        borderRadius: TyRadius.smAll,
                      ),
                      child: Icon(
                        icon,
                        size: TyIconSize.normal,
                        color: ty.colors.accent,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.arrow_forward,
                      size: TyIconSize.compact,
                      color: ty.colors.textTertiary,
                    ),
                  ],
                ),
                const SizedBox(height: TySpace.x12),
                Text(
                  title,
                  style: ty.typography.titleM.copyWith(
                    color: ty.colors.textPrimary,
                  ),
                ),
                const SizedBox(height: TySpace.x2),
                Text(
                  description,
                  style: ty.typography.bodyS.copyWith(
                    color: ty.colors.textSecondary,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 弹窗里的行图标：色值走 token，尺寸走图标 token。
class _RowIcon extends StatelessWidget {
  const _RowIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Icon(
      icon,
      size: TyIconSize.normal,
      color: context.ty.colors.textSecondary,
    );
  }
}

enum _AddSourceKind { local, webdav, quark }

/// 来源卡片：把 provider 里的状态翻译成 `TySourceCard` 的纯展示 props。
class _SourceCard extends ConsumerWidget {
  const _SourceCard({required this.source, required this.ordinal});

  final MusicSource source;
  final int ordinal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SourceSyncState sync =
        ref.watch(sourceSyncProvider)[source.id] ?? const SourceSyncState();
    final SourceStatusView view = describeSourceStatus(source, sync);
    return TySourceCard(
      key: Key('source-card-${source.id}'),
      name: source.name,
      typeLabel: view.typeLabel,
      typeIcon: view.typeIcon,
      statusLabel: view.statusLabel,
      statusTone: view.tone,
      detail: view.detail,
      syncing: sync.running,
      progress: sync.total > 0 ? sync.progress : null,
      progressLabel: sync.running ? view.progressLabel : null,
      trackCount: source.trackCount,
      ordinal: ordinal,
      primaryAction: _primaryAction(context, ref, view),
      onTap: () => context.push('/source/${source.id}'),
      menuActions: <TyMenuAction>[
        TyMenuAction(
          label: '打开来源',
          icon: Icons.chevron_right,
          onSelected: () => context.push('/source/${source.id}'),
        ),
        TyMenuAction(
          label: '补全元数据',
          icon: Icons.auto_fix_high,
          enabled: !sync.running,
          onSelected: () =>
              ref.read(sourceSyncProvider.notifier).enrichSource(source.id),
        ),
        if (source.kind == 'quark')
          TyMenuAction(
            label: '重新登录',
            icon: Icons.login,
            enabled: !sync.running,
            onSelected: () => reloginQuarkSource(context, ref, source),
          ),
        TyMenuAction(
          label: '复制诊断信息',
          icon: Icons.copy_all_outlined,
          onSelected: () => copySourceDiagnostics(context, source, sync),
        ),
        TyMenuAction(
          label: '删除来源',
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () => confirmDeleteSource(context, ref, source),
        ),
      ],
    );
  }

  /// 主操作按恢复路径给：同步 / 重试 / 重新登录 / 删除（未配置的来源只能重来）。
  TySourceAction _primaryAction(
    BuildContext context,
    WidgetRef ref,
    SourceStatusView view,
  ) {
    if (view.busy) {
      return TySourceAction(
        label: view.primaryLabel,
        icon: view.primaryIcon,
        busy: true,
      );
    }
    return TySourceAction(
      label: view.primaryLabel,
      icon: view.primaryIcon,
      onPressed: switch (view.remediation) {
        SourceRemediation.relogin => () => reloginQuarkSource(
          context,
          ref,
          source,
        ),
        SourceRemediation.reconfigure => () => confirmDeleteSource(
          context,
          ref,
          source,
        ),
        _ => () => ref.read(sourceSyncProvider.notifier).sync(source),
      },
    );
  }
}

/// 删除来源：连同凭据与系统授权一起归还（卡片与详情页共用）。
Future<void> confirmDeleteSource(
  BuildContext context,
  WidgetRef ref,
  MusicSource source,
) async {
  final bool confirmed = await tyConfirm(
    context,
    title: '删除来源「${source.name}」？',
    message: '将同时删除该来源下的 ${source.trackCount} 首曲目，并把它们从所有播放列表中移除。',
    confirmLabel: '删除',
    destructive: true,
  );
  if (!confirmed) {
    return;
  }
  await ref.read(sourceRepositoryProvider).delete(source.id);
  // 缓存的适配器跟着来源一起丢掉：它还持有已删除来源的 URL 凭据与直链缓存。
  ref.read(sourceAdapterCacheProvider).evict(source.id);
  await SecureStore().delete(
    SecureStore.accountFor(SecureStore.quarkCookiePrefix, source.id),
  );
  await SecureStore().delete(
    SecureStore.accountFor(SecureStore.webdavPasswordPrefix, source.id),
  );
  // 同时归还系统授权，避免留下僵尸权限：Android 的 SAF 目录授权、iOS 的安全作用域。
  final String? token = source.localBookmark;
  // guard-ok: 系统授权归还 API 只在对应平台存在（能力分支，不是依赖平台的布局/样式）。
  if (Platform.isAndroid && token != null && token.startsWith('content://')) {
    await TingyuSaf.releasePermission(token);
    // guard-ok: 同上。
  } else if (Platform.isIOS && token != null && token.isNotEmpty) {
    await TingyuSaf.releaseBookmark(token);
  }
}

/// 平台入口层：手机直接扫码（WebView 会被夸克拦截）；桌面扫码 / 网页 / Cookie。
Future<QuarkSession?> obtainQuarkSession(
  BuildContext context, {
  QuarkAuthCore? authCore,
}) async {
  final QuarkAuthCore core = authCore ?? QuarkAuthCore();
  const List<_QuarkLoginMethod> mobileMethods = <_QuarkLoginMethod>[
    _QuarkLoginMethod.qr,
  ];
  final List<_QuarkLoginMethod> methods = context.traits.touchPrimary
      ? mobileMethods
      : <_QuarkLoginMethod>[
          _QuarkLoginMethod.qr,
          if (Platform.isMacOS) _QuarkLoginMethod.web,
          _QuarkLoginMethod.paste,
        ];
  if (methods.length == 1) {
    return Navigator.of(context).push<QuarkSession>(
      MaterialPageRoute<QuarkSession>(
        builder: (_) => QuarkQrLoginPage(authCore: core),
      ),
    );
  }
  final _QuarkLoginMethod? method = await showTyDialog<_QuarkLoginMethod>(
    context,
    child: TyDialog(
      title: '登录夸克网盘',
      subtitle: '登录成功后只把凭据写入系统安全存储',
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
          for (int index = 0; index < methods.length; index++)
            TySettingsRow.navRow(
              title: methods[index].label + (index == 0 ? '（推荐）' : ''),
              description: methods[index].description,
              leading: _RowIcon(methods[index].icon),
              onTap: () => Navigator.of(context).pop(methods[index]),
            ),
        ],
      ),
    ),
  );
  if (!context.mounted || method == null) {
    return null;
  }
  switch (method) {
    case _QuarkLoginMethod.qr:
      return Navigator.of(context).push<QuarkSession>(
        MaterialPageRoute<QuarkSession>(
          builder: (_) => QuarkQrLoginPage(authCore: core),
        ),
      );
    case _QuarkLoginMethod.web:
      return Navigator.of(context).push<QuarkSession>(
        MaterialPageRoute<QuarkSession>(
          builder: (_) => QuarkWebLoginPage(authCore: core),
        ),
      );
    case _QuarkLoginMethod.paste:
      return showTyDialog<QuarkSession>(
        context,
        child: _QuarkCookieDialog(authCore: core),
      );
  }
}

/// 更新已有来源的登录，不改动已入库曲目。
Future<void> reloginQuarkSource(
  BuildContext context,
  WidgetRef ref,
  MusicSource source,
) async {
  final QuarkAuthCore authCore = QuarkAuthCore();
  final QuarkSession? session = await obtainQuarkSession(
    context,
    authCore: authCore,
  );
  if (session == null) {
    return;
  }
  await authCore.bindAndSave(source.id, session);
  if (context.mounted) {
    _showCredentialStorageWarning(context);
  }
  await ref
      .read(sourceRepositoryProvider)
      .updateSyncStatus(source.id, status: '登录已更新（${session.nickname}）');
}

void _showCredentialStorageWarning(BuildContext context) {
  if (!SecureStore.usedFallback) {
    return;
  }
  TySnack.show(
    context,
    '当前是未签名开发构建：系统安全存储不可用，凭据暂存于仅当前用户可读的本地文件。'
    '正式构建不会使用此回退。',
  );
}

enum _QuarkLoginMethod {
  qr('扫码登录', '显示二维码，用夸克 App 扫码确认', Icons.qr_code_2),
  web('网页登录', '在夸克官方页面完成登录', Icons.language),
  paste('Cookie 导入', '高级用户或调试场景', Icons.content_paste);

  const _QuarkLoginMethod(this.label, this.description, this.icon);

  final String label;
  final String description;
  final IconData icon;
}

class _WebDavFormResult {
  const _WebDavFormResult({
    required this.url,
    required this.username,
    required this.password,
    required this.name,
  });

  final String url;

  final String username;

  final String password;

  final String name;
}

class _WebDavFormDialog extends StatefulWidget {
  const _WebDavFormDialog();

  @override
  State<_WebDavFormDialog> createState() => _WebDavFormDialogState();
}

class _WebDavFormDialogState extends State<_WebDavFormDialog> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _name = TextEditingController();

  String? _urlError;
  String? _usernameError;

  /// 提交过一次之后逐键校验：错误信息不会在用户打字时闪出来。
  bool _submitted = false;

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  /// 逐字段校验（`docs/UX_REDESIGN.md` §4.5：失败不得静默）。
  bool _validate() {
    final String url = _url.text.trim();
    final Uri? parsed = Uri.tryParse(url);
    final bool shaped =
        parsed != null &&
        (parsed.scheme == 'http' || parsed.scheme == 'https') &&
        parsed.host.isNotEmpty;
    final String? urlError = url.isEmpty
        ? '请输入 WebDAV 地址'
        : (shaped ? null : '地址需以 http:// 或 https:// 开头');
    final String? usernameError = _username.text.trim().isEmpty
        ? '请输入账号'
        : null;
    setState(() {
      _submitted = true;
      _urlError = urlError;
      _usernameError = usernameError;
    });
    return urlError == null && usernameError == null;
  }

  void _submit() {
    if (!_validate()) {
      return;
    }
    Navigator.of(context).pop(
      _WebDavFormResult(
        url: _url.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        name: _name.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TyDialog(
      form: true,
      title: '添加 WebDAV',
      subtitle: '坚果云等网盘需要先在「安全选项」里生成应用专用密码',
      actions: <Widget>[
        TyButton(
          label: '取消',
          variant: TyButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
        TyButton(label: '连接并扫描', onPressed: _submit),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TyTextField(
            controller: _url,
            label: '服务器地址',
            hint: 'https://dav.jianguoyun.com/dav/',
            errorText: _urlError,
            onChanged: (_) {
              if (_submitted) {
                _validate();
              }
            },
          ),
          const SizedBox(height: TySpace.x12),
          TyTextField(
            controller: _username,
            label: '账号',
            errorText: _usernameError,
            onChanged: (_) {
              if (_submitted) {
                _validate();
              }
            },
          ),
          const SizedBox(height: TySpace.x12),
          TyTextField(
            controller: _password,
            label: '应用专用密码',
            obscureText: true,
            helperText: '留空表示按匿名访问（仅对开放只读的目录有效）',
          ),
          const SizedBox(height: TySpace.x12),
          TyTextField(controller: _name, label: '显示名称（可留空）', hint: '默认取服务器主机名'),
        ],
      ),
    );
  }
}

class _QuarkCookieDialog extends StatefulWidget {
  const _QuarkCookieDialog({required this.authCore});

  final QuarkAuthCore authCore;

  @override
  State<_QuarkCookieDialog> createState() => _QuarkCookieDialogState();
}

class _QuarkCookieDialogState extends State<_QuarkCookieDialog> {
  final TextEditingController _cookie = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _cookie.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_cookie.text.trim().isEmpty) {
      setState(() => _error = '请粘贴 Cookie 整行');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final QuarkSession session = await widget.authCore.authenticate(
        _cookie.text,
      );
      if (mounted) {
        Navigator.of(context).pop(session);
      }
    } on QuarkAuthException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return TyDialog(
      form: true,
      title: '导入夸克 Cookie',
      subtitle: '在浏览器登录 pan.quark.cn 后，从开发者工具复制请求头里的 Cookie 整行',
      actions: <Widget>[
        TyButton(
          label: '取消',
          variant: TyButtonVariant.ghost,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        TyButton(label: '校验并使用', onPressed: _busy ? null : _submit),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _cookie,
            enabled: !_busy,
            minLines: 4,
            maxLines: 8,
            // 贴进来的是超长单行 Cookie，等宽字体便于对照。
            style: ty.typography.bodyS.copyWith(fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: 'Cookie: __pus=...; __puus=...',
              errorText: _error,
            ),
          ),
          const SizedBox(height: TySpace.x12),
          Text(
            '凭据完成规范化与会话校验后，只写入系统安全存储，不会进入数据库。',
            style: ty.typography.bodyS.copyWith(color: ty.colors.textTertiary),
          ),
          if (_busy) ...<Widget>[
            const SizedBox(height: TySpace.x12),
            const TyProgressBar(),
          ],
        ],
      ),
    );
  }
}
