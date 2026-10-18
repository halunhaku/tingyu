import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/playback_controller.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/cover.dart';
import '../../design/components/feedback.dart';
import '../../design/components/interactive.dart';
import '../../design/components/structure.dart';
import '../../design/layout/form_factor.dart';
import '../../design/format.dart';
import '../../design/theme.dart';
import '../../design/tokens/metrics.dart';
import '../../design/tokens/tokens.dart';
import '../../playback/playback_item.dart';
import '../../playback/playback_snapshot.dart';

/// 「接下来播放」：当前播放会话的完整列表（`DESIGN.md` §6.2 / §6.3）。
///
/// 行数据按 id 从曲库取，抓取富化改过的元数据能即时反映到队列里；直链仍懒解析，
/// 这里展示的是 `PlaybackController.sourceQueue`，不是引擎里那两三首。
///
/// 能力边界（§4.1）：引擎只有 `setQueue` 与 `addToQueue`，没有插入 / 移除 / 重排，
/// 所以这里**不提供**这些控件——只做读、跳转。
class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyTokens ty = context.ty;
    final _QueueView view = ref.watch(_queueViewProvider);
    final Map<String, Track> tracksById = ref.watch(_tracksByIdProvider);
    // 播放/暂停单独订阅：进度 tick 既不进这里，也不重建任何一行。
    final bool playing = ref.watch(
      playbackProvider.select((PlaybackSnapshot state) => state.playing),
    );
    final List<Track> source = view.source;
    final List<String> ids = view.ids;
    final List<PlaybackItem> items = view.items;
    // 队列由外部设置时没有曲目 id：退化为直接展示引擎条目（无曲库详情）。
    final bool showSource = source.isNotEmpty;
    final bool showIds = ids.isNotEmpty;
    final int count = showSource
        ? source.length
        : (showIds ? ids.length : items.length);
    final int currentIndex = view.currentIndex;

    return ColoredBox(
      color: ty.colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              TySpace.x16,
              TySpace.x12,
              TySpace.x16,
              TySpace.x8,
            ),
            child: TySectionHeader(title: '接下来播放', count: count),
          ),
          const TyDivider(),
          Expanded(
            child: count == 0
                ? const TyEmptyState(
                    icon: Icons.queue_music_outlined,
                    title: '暂无待播歌曲',
                    description: '从曲库中选一首开始播放',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: TySpace.x4),
                    // 行高固定：队列可能上千条，`itemExtent` 省掉逐行布局测量。
                    itemExtent: context.metrics.rowHeight,
                    itemCount: count,
                    itemBuilder: (BuildContext context, int index) {
                      final String? trackId = showSource
                          ? source[index].id
                          : (showIds ? ids[index] : null);
                      return _QueueRow(
                        track: trackId == null ? null : tracksById[trackId],
                        item: showSource || showIds ? null : items[index],
                        number: index + 1,
                        isCurrent: index == currentIndex,
                        isPlaying: index == currentIndex && playing,
                        onTap: () =>
                            ref.read(playbackProvider.notifier).playAt(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 队列行要展示的东西：三份平行队列数据 + 正在播放的下标。
typedef _QueueView = ({
  List<Track> source,
  List<String> ids,
  List<PlaybackItem> items,

  /// 正在播放那一条的下标（相对 [source]；外部队列时就是引擎下标）。
  int currentIndex,
});

/// [_QueueView] 的 provider。
///
/// 队列只存在控制器里，快照里没有；所以这里跟着快照重算（只取引用，不拷贝），
/// 靠控制器「改动即换新列表对象」的特性，让进度 tick 不通知面板重建。
final _queueViewProvider = Provider<_QueueView>((Ref ref) {
  final PlaybackSnapshot snapshot = ref.watch(playbackProvider);
  final PlaybackController controller = ref.read(playbackProvider.notifier);
  final List<Track> source = controller.sourceQueue;
  return (
    source: source,
    ids: controller.trackIds,
    items: controller.items,
    currentIndex: source.isNotEmpty
        ? controller.queueDisplayIndex
        : snapshot.index,
  );
});

/// 曲库 id → 曲目，一次取全库。
///
/// 队列行原先各自 watch 一个 `trackByIdProvider`，N 个可见行就是 N 条常驻
/// drift 查询；这里只留一条流，行数再多也只查一次。
final _tracksByIdProvider = Provider<Map<String, Track>>((Ref ref) {
  final List<Track> tracks =
      ref.watch(allTracksProvider).value ?? const <Track>[];
  return <String, Track>{for (final Track track in tracks) track.id: track};
});

/// 队列行：序号 / 封面 / 标题 / 艺术家 / 时长；当前曲目用强调色与音柱标出。
class _QueueRow extends StatelessWidget {
  const _QueueRow({
    this.track,
    this.item,
    required this.number,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
  });

  /// 曲库曲目；队列由外部设置或曲目不在库里时为 null，此时靠 [item] 展示。
  final Track? track;

  /// 引擎条目兜底。
  final PlaybackItem? item;

  /// 队列序号（从 1 开始）。
  final int number;

  final bool isCurrent;

  final bool isPlaying;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    // 提成局部变量，下面的空判断才能提升类型（公共字段不做类型提升）。
    final Track? track = this.track;
    final Uri? artUri = item?.artUri;
    final String? remoteArt =
        (artUri != null &&
            (artUri.scheme == 'http' || artUri.scheme == 'https'))
        ? artUri.toString()
        : null;
    final String title = track?.title ?? item?.title ?? '加载中…';
    final String artist = track?.artist ?? item?.artist ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: TySpace.x8, vertical: 1),
      child: TyInteractive(
        onTap: onTap,
        semanticLabel: '$number · $title · $artist',
        semanticSelected: isCurrent,
        builder: (BuildContext context, TyInteractionState state) =>
            DecoratedBox(
              decoration: BoxDecoration(
                color: isCurrent
                    ? ty.colors.surfaceSelected
                    : state.overlay(ty.colors),
                borderRadius: BorderRadius.circular(TyRadius.sm),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: TySpace.x8,
                  vertical: TySpace.x4,
                ),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: TySpace.x20,
                      child: Text(
                        '$number',
                        style: ty.typography.numericS.copyWith(
                          color: ty.colors.textTertiary,
                        ),
                      ),
                    ),
                    TyCover(
                      path: track?.coverArtPath,
                      url: track?.coverArtUrl ?? remoteArt,
                      seed: title,
                      size: context.metrics.coverList,
                      radius: TyRadius.xs,
                    ),
                    const SizedBox(width: TySpace.x12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ty.typography.bodyM.copyWith(
                              color: isCurrent
                                  ? ty.colors.accent
                                  : ty.colors.textPrimary,
                              fontWeight: isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                          Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ty.typography.bodyS.copyWith(
                              color: ty.colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: TySpace.x8),
                    if (isPlaying) ...<Widget>[
                      Icon(
                        Icons.volume_up_rounded,
                        size: TyIconSize.compact,
                        color: ty.colors.accent,
                      ),
                      const SizedBox(width: TySpace.x4),
                    ],
                    Text(
                      track == null ? '--:--' : formatSeconds(track.duration),
                      style: ty.typography.numericS.copyWith(
                        color: ty.colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ),
    );
  }
}
