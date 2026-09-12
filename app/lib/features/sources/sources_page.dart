import 'dart:io' show Platform;

import 'package:drift/drift.dart' show Value;
import 'package:file_selector/file_selector.dart';
import 'package:tingyu_saf/tingyu_saf.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/secure_store.dart';
import '../../sources/quark/quark_drive_client.dart';
import '../../sources/webdav/webdav_client.dart';
import '../shared/empty_state.dart';
import 'quark_login_page.dart';
import 'source_sync.dart';

/// 来源管理：列出、添加、同步、删除本地目录 / WebDAV / 夸克网盘。
///
/// 对应旧版 `Sources/UI/Shared/SourceManagerView.swift`：本地目录用系统目录选择器，
/// WebDAV 用表单（地址/账号/应用专用密码），夸克粘贴 Cookie 并选择文件夹。
class SourcesPage extends ConsumerWidget {
  const SourcesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<MusicSource>> sources = ref.watch(sourcesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text('来源管理', style: Theme.of(context).textTheme.titleLarge),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _showAddDialog(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('添加来源'),
              ),
            ],
          ),
        ),
        Expanded(
          child: sources.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, StackTrace stack) =>
                EmptyState(icon: Icons.error_outline, title: '读取来源失败', message: '$error'),
            data: (List<MusicSource> list) {
              if (list.isEmpty) {
                return const EmptyState(
                  icon: Icons.folder_open,
                  title: '还没有来源',
                  message: '添加本地目录、WebDAV 或夸克网盘后即可扫描曲库',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (BuildContext context, int index) =>
                    SourceTile(source: list[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('添加来源'),
        contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.folder),
                title: const Text('本地目录'),
                subtitle: const Text('选择电脑上的音乐文件夹'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _addLocalFolder(context, ref);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud),
                title: const Text('WebDAV'),
                subtitle: const Text('坚果云等支持 WebDAV 的网盘'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _addWebDav(context, ref);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_queue),
                title: const Text('夸克网盘'),
                subtitle: Text(
                  QuarkLoginPage.isSupported ? '应用内登录后自动获取凭证' : '粘贴网页版 Cookie 后选择文件夹',
                ),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _addQuark(context, ref);
                },
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
        ],
      ),
    );
  }

  Future<void> _addLocalFolder(BuildContext context, WidgetRef ref) async {
    // Android：必须走 SAF 目录授权（分区存储下直接读 /sdcard 会 EACCES）。
    // 桌面：普通文件系统路径，用系统目录选择器。
    final String id = 'src-${DateTime.now().microsecondsSinceEpoch}';
    if (Platform.isAndroid) {
      final String? treeUri = await TingyuSaf.pickDirectory();
      if (treeUri == null || treeUri.isEmpty) {
        return; // 用户取消
      }
      await ref.read(sourceRepositoryProvider).upsert(
            MusicSourcesCompanion.insert(
              id: id,
              name: _displayNameOfTreeUri(treeUri),
              kind: 'local',
              localBookmark: Value<String?>(treeUri),
            ),
          );
    } else {
      final String? path = await getDirectoryPath(confirmButtonText: '选择');
      if (path == null || path.isEmpty) {
        return;
      }
      final String name = path.split('/').where((String part) => part.isNotEmpty).last;
      await ref.read(sourceRepositoryProvider).upsert(
            MusicSourcesCompanion.insert(
              id: id,
              name: name,
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
    final String path = colon >= 0 ? decoded.substring(colon + 1) : decoded;
    final String name = path.split('/').where((String part) => part.isNotEmpty).lastOrNull ?? '本地音乐';
    return name;
  }

  Future<void> _addWebDav(BuildContext context, WidgetRef ref) async {
    final _WebDavFormResult? form = await showDialog<_WebDavFormResult>(
      context: context,
      builder: (BuildContext dialogContext) => const _WebDavFormDialog(),
    );
    if (form == null) {
      return;
    }

    final WebDavClient client = WebDavClient();
    final bool ok = await client.testConnection(
      url: Uri.parse(form.url),
      username: form.username,
      password: form.password,
    );
    if (!context.mounted) {
      return;
    }
    if (!ok) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('连接失败'),
          content: const Text('WebDAV 认证失败，请检查地址、账号与应用专用密码'),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('好')),
          ],
        ),
      );
      return;
    }

    final String id = 'src-${DateTime.now().microsecondsSinceEpoch}';
    await SecureStore().writeWebDavPassword(id, form.password);
    await ref.read(sourceRepositoryProvider).upsert(
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

  Future<void> _addQuark(BuildContext context, WidgetRef ref) async {
    final String? cookie = await _obtainQuarkCookie(context);
    if (cookie == null || cookie.trim().isEmpty) {
      return;
    }

    final QuarkDriveClient client = QuarkDriveClient();
    final ({bool isValid, String nickname}) check = await client.verifyCookie(cookie.trim());
    if (!context.mounted) {
      return;
    }
    if (!check.isValid) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('Cookie 无效'),
          content: const Text('夸克网盘登录凭据已失效，请重新登录后复制最新 Cookie'),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('好')),
          ],
        ),
      );
      return;
    }

    final String id = 'src-${DateTime.now().microsecondsSinceEpoch}';
    await SecureStore().writeQuarkCookie(id, cookie.trim());
    if (!context.mounted) {
      return;
    }

    // 与旧版一致：登录后选择曲库所在文件夹（不选则扫描根目录）。
    final String? folderFid = await _pickQuarkFolder(context, client, cookie.trim());
    if (!context.mounted) {
      return;
    }
    if (folderFid == null) {
      return; // 用户取消
    }

    await ref.read(sourceRepositoryProvider).upsert(
          MusicSourcesCompanion.insert(
            id: id,
            name: '夸克网盘',
            kind: 'quark',
            quarkAccountName: Value<String?>(check.nickname),
            quarkFolderFid: Value<String?>(folderFid.isEmpty ? null : folderFid),
          ),
        );
    if (!context.mounted) {
      return;
    }
    await _syncAndReport(context, ref, id);
  }

  /// 取夸克凭证：支持 WebView 的平台走应用内登录，其余平台保留粘贴入口。
  Future<String?> _obtainQuarkCookie(BuildContext context) async {
    if (QuarkLoginPage.isSupported) {
      final String? cookie = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(builder: (_) => const QuarkLoginPage()),
      );
      return cookie;
    }
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => const _QuarkCookieDialog(),
    );
  }

  /// 选择夸克曲库目录：返回 fid（''=根目录），取消返回 null。
  Future<String?> _pickQuarkFolder(
    BuildContext context,
    QuarkDriveClient client,
    String cookie,
  ) async {
    final List<QuarkItem> folders;
    try {
      folders = (await client.listFolder(cookie: cookie)).where((QuarkItem item) => item.isFolder).toList();
    } on Object catch (error) {
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: const Text('读取夸克目录失败'),
            content: Text('$error'),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('好')),
            ],
          ),
        );
      }
      return '';
    }
    if (!context.mounted) {
      return null;
    }
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => SimpleDialog(
        title: const Text('选择曲库文件夹'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, ''),
            child: const Text('使用根目录（扫描全部）'),
          ),
          const Divider(height: 1),
          for (final QuarkItem folder in folders)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, folder.id),
              child: Text(folder.name),
            ),
        ],
      ),
    );
  }

  /// 添加后立即同步一次，并跳到来源页看结果。
  Future<void> _syncAndReport(BuildContext context, WidgetRef ref, String sourceId) async {
    final MusicSource? source = await ref.read(sourceRepositoryProvider).byId(sourceId);
    if (source != null) {
      await ref.read(sourceSyncProvider.notifier).sync(source);
    }
    if (context.mounted) {
      context.go('/source/$sourceId');
    }
  }
}

/// 来源列表行：名称、同步状态、曲目数、操作按钮。
class SourceTile extends ConsumerWidget {
  const SourceTile({super.key, required this.source});

  final MusicSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SourceSyncState sync = ref.watch(sourceSyncProvider)[source.id] ?? const SourceSyncState();
    final IconData icon = switch (source.kind) {
      'webdav' => Icons.cloud,
      'quark' => Icons.cloud_queue,
      _ => Icons.folder,
    };

    return ListTile(
      leading: Icon(icon),
      title: Text(source.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('${source.trackCount} 首 · ${source.syncStatus}'),
          if (source.lastSyncedAt != null)
            Text(
              '上次同步：${source.lastSyncedAt!.toLocal().toString().split('.').first}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (sync.running)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(value: sync.progress, minHeight: 2),
            ),
          if (sync.message.isNotEmpty && sync.running)
            Text(sync.message, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextButton(
            onPressed: sync.running ? null : () => ref.read(sourceSyncProvider.notifier).sync(source),
            child: const Text('同步'),
          ),
          if (source.kind == 'quark' && QuarkLoginPage.isSupported)
            TextButton(
              onPressed: sync.running ? null : () => _reloginQuark(context, ref),
              child: const Text('重新登录'),
            ),
          IconButton(
            tooltip: '打开',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => context.go('/source/${source.id}'),
          ),
          IconButton(
            tooltip: '删除来源',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
    );
  }

  /// 重新登录夸克：更新安全存储里的凭据，不改动已入库的曲目。
  Future<void> _reloginQuark(BuildContext context, WidgetRef ref) async {
    final String? cookie = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QuarkLoginPage()),
    );
    if (cookie == null || cookie.trim().isEmpty) {
      return;
    }
    await SecureStore().writeQuarkCookie(source.id, cookie.trim());
    final QuarkDriveClient client = QuarkDriveClient();
    final ({bool isValid, String nickname}) check = await client.verifyCookie(cookie.trim());
    await ref.read(sourceRepositoryProvider).updateSyncStatus(
          source.id,
          status: check.isValid ? '登录已更新（${check.nickname}）' : '夸克凭据已失效',
        );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('删除来源「${source.name}」？'),
        content: Text('将同时删除该来源下的 ${source.trackCount} 首曲目，并把它们从所有播放列表中移除。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await ref.read(sourceRepositoryProvider).delete(source.id);
    await SecureStore().delete(SecureStore.accountFor(SecureStore.quarkCookiePrefix, source.id));
    await SecureStore().delete(SecureStore.accountFor(SecureStore.webdavPasswordPrefix, source.id));
    // Android：同时释放 SAF 目录授权，避免系统设置里留下僵尸权限。
    final String? treeUri = source.localBookmark;
    if (Platform.isAndroid && treeUri != null && treeUri.startsWith('content://')) {
      await TingyuSaf.releasePermission(treeUri);
    }
  }
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

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加 WebDAV'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://dav.jianguoyun.com/dav/',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _username,
              decoration: const InputDecoration(labelText: '账号'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '应用专用密码'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '显示名称（可留空）'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            if (_url.text.trim().isEmpty || _username.text.trim().isEmpty) {
              return;
            }
            Navigator.pop(
              context,
              _WebDavFormResult(
                url: _url.text.trim(),
                username: _username.text.trim(),
                password: _password.text,
                name: _name.text.trim(),
              ),
            );
          },
          child: const Text('连接并扫描'),
        ),
      ],
    );
  }
}

class _QuarkCookieDialog extends StatefulWidget {
  const _QuarkCookieDialog();

  @override
  State<_QuarkCookieDialog> createState() => _QuarkCookieDialogState();
}

class _QuarkCookieDialogState extends State<_QuarkCookieDialog> {
  final TextEditingController _cookie = TextEditingController();

  @override
  void dispose() {
    _cookie.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('夸克网盘 Cookie'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('在浏览器登录 pan.quark.cn 后打开开发者工具，复制请求头里的 Cookie 整行粘贴到下面。'),
            const SizedBox(height: 8),
            TextField(
              controller: _cookie,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '__pus=...; __puus=...'),
            ),
            const SizedBox(height: 8),
            const Text('Cookie 只写入系统安全存储（钥匙串），不会写进数据库。'),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _cookie.text),
          child: const Text('验证并扫描'),
        ),
      ],
    );
  }
}
