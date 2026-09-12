import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../shared/add_to_playlist.dart';
import '../player/player_bar.dart';

/// 桌面外壳：左侧栏 + 内容区 + 底部悬浮播放条（对齐旧版 `MacOSContentView` 的布局）。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late final TextEditingController _searchController =
      TextEditingController(text: ref.read(searchQueryProvider));

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: <Widget>[
          SizedBox(width: 248, child: _Sidebar(searchController: _searchController)),
          const VerticalDivider(width: 1),
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Padding(
                    // 给底部悬浮播放条留出空间（旧版是 84pt 的滚动缩进）。
                    padding: const EdgeInsets.only(bottom: 84),
                    child: widget.child,
                  ),
                ),
                const Positioned(left: 0, right: 0, bottom: 0, child: PlayerBar()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.searchController});

  final TextEditingController searchController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String path = GoRouterState.of(context).uri.path;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool hasQuery = ref.watch(searchQueryProvider).isNotEmpty;

    return Container(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索歌曲、艺术家或专辑',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: !hasQuery
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          searchController.clear();
                          ref.read(searchQueryProvider.notifier).clear();
                        },
                      ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (String value) {
                ref.read(searchQueryProvider.notifier).set(value);
                if (value.trim().isNotEmpty && path != '/library') {
                  context.go('/library');
                }
              },
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: <Widget>[
                _NavTile(icon: Icons.library_music, label: '曲库', route: '/library', current: path),
                _NavTile(icon: Icons.schedule, label: '最近添加', route: '/recent', current: path),
                _NavTile(icon: Icons.person, label: '艺术家', route: '/artists', current: path),
                _NavTile(icon: Icons.album, label: '专辑', route: '/albums', current: path),
                _NavTile(icon: Icons.favorite, label: '收藏', route: '/favorites', current: path),
                const _SidebarGroup(title: '来源'),
                _SourceList(current: path),
                _SidebarGroup(
                  title: '播放列表',
                  trailing: IconButton(
                    iconSize: 16,
                    tooltip: '新建播放列表',
                    icon: const Icon(Icons.add),
                    onPressed: () async {
                      final String? name =
                          await promptPlaylistName(context, title: '新建播放列表', confirmLabel: '创建');
                      if (name == null || name.trim().isEmpty) {
                        return;
                      }
                      final String id = 'pl-${DateTime.now().microsecondsSinceEpoch}';
                      await ref.read(playlistRepositoryProvider).create(id: id, name: name.trim());
                      if (context.mounted) {
                        context.go('/playlist/$id');
                      }
                    },
                  ),
                ),
                const _PlaylistList(),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _NavTile(
                    icon: Icons.settings,
                    label: '设置',
                    route: '/settings',
                    current: path,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarGroup extends StatelessWidget {
  const _SidebarGroup({required this.title, this.trailing});

  final String title;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 8, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _SourceList extends ConsumerWidget {
  const _SourceList({required this.current});

  final String current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<MusicSource>> sources = ref.watch(sourcesProvider);
    return sources.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(8),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (Object error, StackTrace stack) => Padding(
        padding: const EdgeInsets.all(8),
        child: Text('来源读取失败：$error', style: Theme.of(context).textTheme.bodySmall),
      ),
      data: (List<MusicSource> list) {
        if (list.isEmpty) {
          return const _SidebarHint('尚未添加来源');
        }
        return Column(
          children: <Widget>[
            for (final MusicSource source in list)
              _NavTile(
                icon: switch (source.kind) {
                  'webdav' => Icons.cloud,
                  'quark' => Icons.cloud_queue,
                  _ => Icons.folder,
                },
                label: source.name,
                subtitle: '${source.trackCount} 首',
                route: '/source/${source.id}',
                current: current,
              ),
          ],
        );
      },
    );
  }
}

class _PlaylistList extends ConsumerWidget {
  const _PlaylistList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String path = GoRouterState.of(context).uri.path;
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);
    return playlists.when(
      loading: () => const SizedBox.shrink(),
      error: (Object error, StackTrace stack) => const SizedBox.shrink(),
      data: (List<Playlist> list) {
        if (list.isEmpty) {
          return const _SidebarHint('尚未创建播放列表');
        }
        return Column(
          children: <Widget>[
            for (final Playlist playlist in list)
              _NavTile(
                icon: Icons.queue_music,
                label: playlist.name,
                route: '/playlist/${playlist.id}',
                current: path,
              ),
          ],
        );
      },
    );
  }
}

class _SidebarHint extends StatelessWidget {
  const _SidebarHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.route,
    required this.current,
    this.subtitle,
  });

  final IconData icon;

  final String label;

  final String route;

  final String current;

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final bool selected = current == route;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => context.go(route),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? scheme.secondaryContainer : null,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 16, color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: selected ? scheme.onSecondaryContainer : null,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
