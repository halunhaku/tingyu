import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/mini_player.dart';
import '../../design/theme.dart';
import '../../design/tokens/tokens.dart';
import '../../playback/playback_item.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/current_track.dart';
import '../shared/track_actions.dart';

/// 迷你播放条（`DESIGN.md` §6.3）：紧贴底部 Tab 栏上方的一行当前曲目。
///
/// 元数据优先取曲库里的曲目行（抓取富化后会即时更新），队列由外部设置
/// （调试入口 / 系统恢复）时回退到播放条目自身。
///
/// 这一层只订阅「当前是哪一首」与队列判空；播放/暂停与进度各自订阅自己那一项，
/// 进度 tick 不会重建封面。
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  /// 行高由上下文里的 `metrics.miniPlayerHeight` 决定。

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CurrentTrackRef current = ref.watch(currentTrackRefProvider);
    final Track? track = ref.watch(currentTrackProvider);
    final PlaybackItem? item = current.item;
    final bool hasQueue = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot snapshot) =>
            snapshot.processing != PlaybackProcessing.idle,
      ),
    );
    final bool playing = ref.watch(
      playbackProvider.select((PlaybackSnapshot snapshot) => snapshot.playing),
    );

    final Uri? artUri = item?.artUri;
    final String? remoteArt =
        (artUri != null &&
            (artUri.scheme == 'http' || artUri.scheme == 'https'))
        ? artUri.toString()
        : null;

    return TyMiniPlayer(
      visible: hasQueue,
      coverPath: track?.coverArtPath,
      coverUrl: track?.coverArtUrl ?? remoteArt,
      coverSeed: track?.album ?? item?.title ?? 'tingyu',
      title: track?.title ?? item?.title ?? '',
      artist: track?.artist ?? item?.artist ?? '',
      favorite: track?.isFavorite ?? false,
      onToggleFavorite: track == null
          ? null
          : () => toggleTrackFavorite(ref, track),
      playing: playing,
      progressLine: hasQueue ? const _MiniProgressLine() : null,
      onPlayPause: hasQueue
          ? () => ref.read(playbackProvider.notifier).togglePlayPause()
          : null,
      onNext: hasQueue
          ? () => ref.read(playbackProvider.notifier).next()
          : null,
      onOpenStage: () => context.push('/stage'),
      onLongPress: hasQueue ? () => _showQueueSheet(context, ref) : null,
    );
  }

  /// 长按：给「现在这一首」的常用动作（队列能力边界见 §4.1，不做移除/重排）。
  Future<void> _showQueueSheet(BuildContext context, WidgetRef ref) async {
    final Track? track = ref.read(currentTrackProvider);
    if (track == null) {
      await context.push('/queue');
      return;
    }
    await showTrackMenu(
      context,
      ref,
      track,
      onPlay: () => ref.read(playbackProvider.notifier).togglePlayPause(),
    );
  }
}

/// 迷你条顶部进度线：**只有它**跟着进度 tick 重建（封面与标题不动）。
class _MiniProgressLine extends ConsumerWidget {
  const _MiniProgressLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyTokens ty = context.ty;
    final ({Duration position, Duration duration}) progress = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot snapshot) =>
            (position: snapshot.position, duration: snapshot.duration),
      ),
    );
    final double fraction = progress.duration > Duration.zero
        ? (progress.position.inMilliseconds / progress.duration.inMilliseconds)
              .clamp(0.0, 1.0)
        : 0;
    return SizedBox(
      height: TyMiniPlayerSize.progressLine,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ColoredBox(color: ty.colors.border),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: fraction,
            child: ColoredBox(color: ty.colors.accent),
          ),
        ],
      ),
    );
  }
}
