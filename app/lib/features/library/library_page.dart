import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../shared/empty_state.dart';
import '../shared/track_row.dart';

/// 曲库页：整库、最近添加、收藏、搜索结果共用一套列表。
///
/// 与旧版一致：搜索框在侧栏，命中结果回到曲库列表展示。
class LibraryPage extends ConsumerWidget {
  const LibraryPage({
    super.key,
    this.recentOnly = false,
    this.favoritesOnly = false,
  });

  final bool recentOnly;

  final bool favoritesOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 原生 macOS 在曲库出现时后台补全所有缺失元数据的歌曲。
    ref.watch(autoLibraryEnrichmentProvider);
    final String query = ref.watch(searchQueryProvider);
    final AsyncValue<List<Track>> tracks;
    final String title;
    if (favoritesOnly) {
      tracks = ref.watch(favoritesProvider);
      title = '收藏';
    } else if (recentOnly) {
      tracks = ref.watch(recentlyAddedProvider);
      title = '最近添加';
    } else {
      tracks = ref.watch(visibleTracksProvider);
      title = query.trim().isEmpty ? '曲库' : '搜索“${query.trim()}”';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              tracks.maybeWhen(
                data: (List<Track> list) => Text(
                  '${list.length} 首',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                orElse: () => const SizedBox.shrink(),
              ),
              // 桌面侧栏左下角已有设置；只有移动端没有侧栏，才在标题栏放入口。
              if (Platform.isAndroid || Platform.isIOS)
                IconButton(
                  tooltip: '设置',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => context.push('/settings'),
                ),
            ],
          ),
        ),
        if ((Platform.isAndroid || Platform.isIOS) &&
            favoritesOnly == false &&
            recentOnly == false &&
            query.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/artists'),
                    icon: const Icon(Icons.person_outline, size: 18),
                    label: const Text('艺术家'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/albums'),
                    icon: const Icon(Icons.album_outlined, size: 18),
                    label: const Text('专辑'),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: tracks.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, StackTrace stack) => EmptyState(
              icon: Icons.error_outline,
              title: '曲库读取失败',
              message: '$error',
            ),
            data: (List<Track> list) {
              if (list.isEmpty) {
                return EmptyState(
                  icon: Icons.library_music_outlined,
                  title: favoritesOnly ? '还没有收藏' : '曲库是空的',
                  message: '在设置里添加本地目录、WebDAV 或夸克来源后点击同步',
                  action: FilledButton(
                    onPressed: () => context.go('/sources'),
                    child: const Text('添加来源'),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: list.length,
                itemBuilder: (BuildContext context, int index) {
                  final Track track = list[index];
                  return _TrackRowWithPlayback(
                    track: track,
                    index: index + 1,
                    queue: list,
                    startIndex: index,
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

/// 把"点击播放"的队列语义固定下来：播放当前列表并从该行开始。
class _TrackRowWithPlayback extends ConsumerWidget {
  const _TrackRowWithPlayback({
    required this.track,
    required this.index,
    required this.queue,
    required this.startIndex,
  });

  final Track track;

  final int index;

  final List<Track> queue;

  final int startIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<String> playingIds = ref
        .watch(playbackProvider.notifier)
        .trackIds;
    final int playingIndex = ref.watch(playbackProvider).index;
    final bool isPlaying =
        playingIndex >= 0 &&
        playingIndex < playingIds.length &&
        playingIds[playingIndex] == track.id;

    return TrackRow(
      track: track,
      index: index,
      isPlaying: isPlaying,
      onTap: () => ref
          .read(playbackProvider.notifier)
          .playTracks(queue, startIndex: startIndex),
    );
  }
}
