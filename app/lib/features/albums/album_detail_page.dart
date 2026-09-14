import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../shared/add_to_playlist.dart';
import '../shared/cover_art.dart';
import '../shared/empty_state.dart';
import '../shared/format.dart';
import '../shared/track_row.dart';

/// 专辑详情：大封面 + 元数据 + 「播放全部 / 添加到播放列表」，下方是曲目表。
///
/// 曲目顺序由 [albumTracksProvider] 给定（碟号 → 曲序 → 标题），点击第 i 首
/// 从该首开始播放整张专辑。
class AlbumDetailPage extends ConsumerWidget {
  const AlbumDetailPage({super.key, required this.albumKey});

  final AlbumKey albumKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Track>> tracks = ref.watch(albumTracksProvider(albumKey));

    return tracks.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace stack) => EmptyState(
        icon: Icons.error_outline,
        title: '专辑读取失败',
        message: '$error',
      ),
      data: (List<Track> list) {
        if (list.isEmpty) {
          return EmptyState(
            icon: Icons.album_outlined,
            title: '没有可播放的曲目',
            message: '${albumKey.album} · ${albumKey.artist}',
            action: TextButton(
              onPressed: () => context.go('/albums'),
              child: const Text('返回专辑列表'),
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: list.length + 1,
          itemBuilder: (BuildContext context, int index) {
            if (index == 0) {
              return _AlbumHeader(albumKey: albumKey, tracks: list);
            }
            final int trackIndex = index - 1;
            final Track track = list[trackIndex];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _AlbumTrackRow(
                track: track,
                index: track.trackNumber ?? trackIndex + 1,
                queue: list,
                startIndex: trackIndex,
              ),
            );
          },
        );
      },
    );
  }
}

/// 专辑头：封面 + 专辑名/艺术家/年份/曲目数/总时长 + 播放与加列表按钮。
class _AlbumHeader extends ConsumerWidget {
  const _AlbumHeader({required this.albumKey, required this.tracks});

  final AlbumKey albumKey;

  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Track? cover = _firstWithCover(tracks);
    final int? year = _firstYear(tracks);
    final double totalSeconds =
        tracks.fold<double>(0, (double sum, Track track) => sum + track.duration);

    final String stats = <String>[
      if (year != null) '$year年',
      '${tracks.length} 首歌曲',
      if (totalSeconds > 0) formatSeconds(totalSeconds),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              CoverArt(
                coverArtPath: cover?.coverArtPath,
                coverArtUrl: cover?.coverArtUrl,
                size: 180,
                radius: 8,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      albumKey.album,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      albumKey.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      stats,
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton.icon(
                          onPressed: () =>
                              ref.read(playbackProvider.notifier).playTracks(tracks),
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('播放全部'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => showAddToPlaylistDialog(context, ref, tracks),
                          icon: const Icon(Icons.playlist_add, size: 18),
                          label: const Text('添加到播放列表'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

/// 专辑曲目行：点击从该行开始播放整张专辑。
class _AlbumTrackRow extends ConsumerWidget {
  const _AlbumTrackRow({
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

/// 取第一条带封面的曲目（本地缓存优先，其次远端 URL）。
Track? _firstWithCover(List<Track> tracks) {
  for (final Track track in tracks) {
    if (track.coverArtPath != null || track.coverArtUrl != null) {
      return track;
    }
  }
  return null;
}

/// 专辑年份取第一条有年份的曲目。
int? _firstYear(List<Track> tracks) {
  for (final Track track in tracks) {
    if (track.year != null) {
      return track.year;
    }
  }
  return null;
}
