import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/playback_controller.dart';
import '../../app/providers.dart';
import '../../playback/playback_item.dart';
import '../../data/db/database.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/cover_art.dart';
import '../shared/empty_state.dart';
import '../shared/format.dart';

/// "接下来播放"：当前播放队列（对齐旧版 `UpNextQueueView` 的信息架构）。
///
/// 高亮正在播放的那一行；点击任意一行从该行开始播放（`playAt`）。
/// 队列条数由 `PlaybackController.trackIds` 给出，行数据按 id 从曲库取，
/// 这样抓取富化改过的元数据能即时反映到队列里。
class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlaybackSnapshot snapshot = ref.watch(playbackProvider);
    final PlaybackController controller = ref.read(playbackProvider.notifier);
    final List<String> ids = controller.trackIds;
    // 队列由外部设置时没有曲目 id：退化为直接展示引擎条目（无曲库详情）。
    final List<PlaybackItem> items = controller.items;
    final bool showIds = ids.isNotEmpty;
    final int count = showIds ? ids.length : items.length;
    final ThemeData theme = Theme.of(context);

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text('接下来播放', style: theme.textTheme.titleSmall),
                ),
                if (count > 0)
                  Text(
                    '$count 首',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: count == 0
                ? const EmptyState(
                    icon: Icons.queue_music_outlined,
                    title: '暂无待播歌曲',
                    message: '从曲库中选一首开始播放',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: count,
                    itemBuilder: (BuildContext context, int index) => _QueueRow(
                      trackId: showIds ? ids[index] : null,
                      item: showIds ? null : items[index],
                      number: index + 1,
                      isCurrent: index == snapshot.index,
                      isPlaying: index == snapshot.index && snapshot.playing,
                      onTap: () => ref.read(playbackProvider.notifier).playAt(index),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 队列行：封面 / 标题 / 艺术家 / 时长；当前曲目用主题色与喇叭图标标出。
class _QueueRow extends ConsumerWidget {
  const _QueueRow({
    this.trackId,
    this.item,
    required this.number,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
  });

  /// 曲库 id；队列由外部设置时为 null，此时靠 [item] 展示。
  final String? trackId;

  /// 引擎条目兜底。
  final PlaybackItem? item;

  /// 队列序号（从 1 开始）。
  final int number;

  final bool isCurrent;

  final bool isPlaying;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? id = trackId;
    final Track? track = id == null ? null : ref.watch(trackByIdProvider(id)).value;
    final Uri? artUri = item?.artUri;
    final String? remoteArt = (artUri != null && (artUri.scheme == 'http' || artUri.scheme == 'https'))
        ? artUri.toString()
        : null;

    final TextStyle? subtitle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: isCurrent
            ? scheme.primaryContainer.withValues(alpha: 0.45)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 20,
                  child: Text(number.toString(), style: subtitle),
                ),
                CoverArt(
                  coverArtPath: track?.coverArtPath,
                  coverArtUrl: track?.coverArtUrl ?? remoteArt,
                  size: 36,
                  radius: 4,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        track?.title ?? item?.title ?? '加载中…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                          color: isCurrent ? scheme.primary : null,
                        ),
                      ),
                      Text(
                        track?.artist ?? item?.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: subtitle,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isPlaying) ...<Widget>[
                  Icon(Icons.volume_up_rounded, size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                ],
                Text(
                  track == null ? '--:--' : formatSeconds(track.duration),
                  style: subtitle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
