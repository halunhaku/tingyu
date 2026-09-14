import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../shared/empty_state.dart';
import '../shared/track_row.dart';
import 'artists_page.dart';

/// 艺术家详情：头像 + 名字 + 统计，下方按专辑分组列出曲目，每组可单独播放。
///
/// 专辑之间按专辑名排序，组内沿用 [sortForAlbum]（碟号 → 曲序 → 标题）。
class ArtistDetailPage extends ConsumerWidget {
  const ArtistDetailPage({super.key, required this.artist});

  final String artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Track>> tracks = ref.watch(artistTracksProvider(artist));

    return tracks.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace stack) => EmptyState(
        icon: Icons.error_outline,
        title: '艺术家读取失败',
        message: '$error',
      ),
      data: (List<Track> list) {
        if (list.isEmpty) {
          return EmptyState(
            icon: Icons.person_outline,
            title: '没有这位艺术家的曲目',
            message: artist,
            action: TextButton(
              onPressed: () => context.go('/artists'),
              child: const Text('返回艺术家列表'),
            ),
          );
        }

        final Map<String, List<Track>> groups = _groupByAlbum(list);
        final List<_ArtistItem> items = <_ArtistItem>[];
        for (final MapEntry<String, List<Track>> group in groups.entries) {
          items.add(_AlbumGroupItem(album: group.key, tracks: group.value));
          for (int i = 0; i < group.value.length; i++) {
            final Track track = group.value[i];
            items.add(
              _TrackItem(
                track: track,
                index: track.trackNumber ?? i + 1,
                queue: group.value,
                startIndex: i,
              ),
            );
          }
        }

        // 拍平成一个惰性列表：艺术家可能有上千首曲目，不能一次性建出所有行。
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: items.length + 1,
          itemBuilder: (BuildContext context, int index) {
            if (index == 0) {
              return _ArtistHeader(
                artist: artist,
                songCount: list.length,
                albumCount: groups.length,
              );
            }
            return switch (items[index - 1]) {
              _AlbumGroupItem item => _AlbumGroupHeader(
                  artist: artist,
                  album: item.album,
                  tracks: item.tracks,
                ),
              _TrackItem item => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _ArtistTrackRow(
                    track: item.track,
                    index: item.index,
                    queue: item.queue,
                    startIndex: item.startIndex,
                  ),
                ),
            };
          },
        );
      },
    );
  }
}

/// 按专辑名分组；`List.sort` 不保证稳定，所以组内重新用 [sortForAlbum] 定序。
Map<String, List<Track>> _groupByAlbum(List<Track> tracks) {
  final List<Track> ordered = List<Track>.of(tracks)
    ..sort((Track a, Track b) => a.album.compareTo(b.album));

  final Map<String, List<Track>> groups = <String, List<Track>>{};
  for (final Track track in ordered) {
    (groups[track.album] ??= <Track>[]).add(track);
  }
  for (final List<Track> group in groups.values) {
    sortForAlbum(group);
  }
  return groups;
}

/// 拍平后的列表项：专辑分组头或一曲目行。
sealed class _ArtistItem {
  const _ArtistItem();
}

class _AlbumGroupItem extends _ArtistItem {
  const _AlbumGroupItem({required this.album, required this.tracks});

  final String album;

  final List<Track> tracks;
}

class _TrackItem extends _ArtistItem {
  const _TrackItem({
    required this.track,
    required this.index,
    required this.queue,
    required this.startIndex,
  });

  final Track track;

  final int index;

  final List<Track> queue;

  final int startIndex;
}

/// 艺术家头：头像 + 名字 + 「N 首歌曲 · M 张专辑」。
class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({
    required this.artist,
    required this.songCount,
    required this.albumCount,
  });

  final String artist;

  final int songCount;

  final int albumCount;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      child: Row(
        children: <Widget>[
          ArtistAvatar(artist: artist, size: 120),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '艺术家',
                  style: text.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  '$songCount 首歌曲 · $albumCount 张专辑',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 专辑分组头：专辑名 + 「播放这张专辑」/「打开专辑」。
class _AlbumGroupHeader extends ConsumerWidget {
  const _AlbumGroupHeader({
    required this.artist,
    required this.album,
    required this.tracks,
  });

  final String artist;

  final String album;

  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionHeader(
      title: album,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: '播放这张专辑',
            iconSize: 18,
            icon: const Icon(Icons.play_circle_outline),
            onPressed: () => ref.read(playbackProvider.notifier).playTracks(tracks),
          ),
          IconButton(
            tooltip: '打开专辑',
            iconSize: 18,
            icon: const Icon(Icons.album_outlined),
            onPressed: () => context.go(
              '/albums/${Uri.encodeComponent(artist)}/${Uri.encodeComponent(album)}',
            ),
          ),
        ],
      ),
    );
  }
}

/// 艺术家曲目行：点击从该行开始播放所在专辑。
class _ArtistTrackRow extends ConsumerWidget {
  const _ArtistTrackRow({
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
    final List<String> playingIds = ref.watch(playbackProvider.notifier).trackIds;
    final int playingIndex = ref.watch(playbackProvider).index;
    final bool isPlaying = playingIndex >= 0 &&
        playingIndex < playingIds.length &&
        playingIds[playingIndex] == track.id;

    return TrackRow(
      track: track,
      index: index,
      showAlbum: false,
      isPlaying: isPlaying,
      onTap: () => ref.read(playbackProvider.notifier).playTracks(queue, startIndex: startIndex),
    );
  }
}
