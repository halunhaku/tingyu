import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../shared/add_to_playlist.dart';
import '../shared/empty_state.dart';
import '../shared/track_row.dart';

/// 播放列表页：顺序播放、拖拽重排、移除曲目、重命名与删除。
class PlaylistPage extends ConsumerWidget {
  const PlaylistPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);
    final Playlist? playlist = playlists.value?.where((Playlist item) => item.id == playlistId).firstOrNull;
    final AsyncValue<List<Track>> tracks = ref.watch(playlistTracksProvider(playlistId));

    if (playlist == null) {
      return const EmptyState(icon: Icons.queue_music, title: '播放列表不存在');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(playlist.name, style: Theme.of(context).textTheme.titleLarge),
                    Text(
                      '${tracks.value?.length ?? 0} 首',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: (tracks.value?.isEmpty ?? true)
                    ? null
                    : () => ref.read(playbackProvider.notifier).playTracks(tracks.value!),
                icon: const Icon(Icons.play_arrow),
                label: const Text('播放全部'),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '重命名',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final String? name = await promptPlaylistName(
                    context,
                    title: '重命名播放列表',
                    confirmLabel: '保存',
                    initial: playlist.name,
                  );
                  if (name == null || name.trim().isEmpty) {
                    return;
                  }
                  await ref.read(playlistRepositoryProvider).rename(playlistId, name.trim());
                },
              ),
              IconButton(
                tooltip: '删除播放列表',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final bool? confirmed = await showDialog<bool>(
                    context: context,
                    builder: (BuildContext dialogContext) => AlertDialog(
                      title: Text('删除播放列表「${playlist.name}」？'),
                      content: const Text('曲目本身不会被删除。'),
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
                  await ref.read(playlistRepositoryProvider).delete(playlistId);
                  if (context.mounted) {
                    context.go('/library');
                  }
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tracks.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, StackTrace stack) =>
                EmptyState(icon: Icons.error_outline, title: '读取失败', message: '$error'),
            data: (List<Track> list) {
              if (list.isEmpty) {
                return const EmptyState(
                  icon: Icons.queue_music,
                  title: '播放列表是空的',
                  message: '在曲库里右键歌曲 → 添加到播放列表',
                );
              }
              return ReorderableListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: list.length,
                onReorderItem: (int oldIndex, int newIndex) async {
                  await ref.read(playlistRepositoryProvider).move(
                        playlistId,
                        from: oldIndex,
                        to: newIndex,
                      );
                  ref.invalidate(playlistTracksProvider(playlistId));
                },
                itemBuilder: (BuildContext context, int index) {
                  final Track track = list[index];
                  return TrackRow(
                    key: ValueKey<String>(track.id),
                    track: track,
                    index: index + 1,
                    onTap: () => ref
                        .read(playbackProvider.notifier)
                        .playTracks(list, startIndex: index),
                    trailing: IconButton(
                      tooltip: '从播放列表移除',
                      iconSize: 16,
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () async {
                        await ref.read(playlistRepositoryProvider).removeAt(playlistId, index);
                        ref.invalidate(playlistTracksProvider(playlistId));
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
