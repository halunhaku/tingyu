import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../shared/add_to_playlist.dart';
import '../shared/empty_state.dart';

/// 歌单页：新建、重命名、删除，点击进入歌单详情。
///
/// 对应旧版 `Sources/UI/iOS/IOSPlaylistsView.swift`：右上角新建，列表显示每个
/// 歌单的曲目数；重命名/删除走长按菜单（桌面侧栏的等价入口在 `AppShell`）。
class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text('歌单', style: Theme.of(context).textTheme.titleLarge),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _createPlaylist(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('新建'),
              ),
            ],
          ),
        ),
        Expanded(
          child: playlists.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, StackTrace stack) =>
                EmptyState(icon: Icons.error_outline, title: '歌单读取失败', message: '$error'),
            data: (List<Playlist> list) {
              if (list.isEmpty) {
                return EmptyState(
                  icon: Icons.queue_music,
                  title: '还没有歌单',
                  message: '点右上角「新建」，或在歌曲上选择「添加到播放列表…」',
                  action: FilledButton(
                    onPressed: () => _createPlaylist(context, ref),
                    child: const Text('新建歌单'),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (BuildContext context, int index) =>
                    _PlaylistTile(playlist: list[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 新建歌单；id 与「添加到播放列表…」里的就地新建保持同一套约定。
  static Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
    final String? name = await promptPlaylistName(context, title: '新建歌单', confirmLabel: '创建');
    if (name == null || name.trim().isEmpty) {
      return;
    }
    await ref.read(playlistRepositoryProvider).create(
          id: 'pl-${DateTime.now().microsecondsSinceEpoch}',
          name: name.trim(),
        );
  }
}

/// 歌单行：名称 + 曲目数；长按或尾部按钮弹出重命名/删除。
class _PlaylistTile extends ConsumerWidget {
  const _PlaylistTile({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Track>> tracks = ref.watch(playlistTracksProvider(playlist.id));
    final String subtitle = tracks.when(
      loading: () => '读取中…',
      error: (Object error, StackTrace stack) => '曲目读取失败',
      data: (List<Track> list) => '${list.length} 首',
    );

    return ListTile(
      leading: const Icon(Icons.queue_music),
      title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle),
      trailing: IconButton(
        tooltip: '更多',
        icon: const Icon(Icons.more_vert),
        onPressed: () => _showMenu(context, ref),
      ),
      onTap: () => context.go('/playlist/${playlist.id}'),
      onLongPress: () => _showMenu(context, ref),
    );
  }

  Future<void> _showMenu(BuildContext context, WidgetRef ref) async {
    final String? selected = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除歌单'),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !context.mounted) {
      return;
    }

    switch (selected) {
      case 'rename':
        final String? name = await promptPlaylistName(
          context,
          title: '重命名歌单',
          confirmLabel: '保存',
          initial: playlist.name,
        );
        if (name == null || name.trim().isEmpty) {
          return;
        }
        await ref.read(playlistRepositoryProvider).rename(playlist.id, name.trim());
      case 'delete':
        final bool? confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: Text('删除歌单「${playlist.name}」？'),
            content: const Text('歌单里的曲目本身不会被删除。'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed != true) {
          return;
        }
        await ref.read(playlistRepositoryProvider).delete(playlist.id);
    }
  }
}
