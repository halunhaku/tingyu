import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/buttons.dart';
import '../../design/components/transport.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../../playback/playback_item.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/current_track.dart';
import '../shared/track_actions.dart';

/// 底部传输条（`DESIGN.md` §6.3）。
///
/// - 队列为空时整条收起（不留「未在播放」占位）；
/// - 左：封面 56 + 曲名/艺术家（点击进舞台）+ ♥；中：传输键 + 进度行；
///   右：歌词 / 队列 / 音量；
/// - 失败时整条替换为 `TyErrorView` 内联形态，而不是静默停住。
///
/// 订阅口径：这一层只看「当前是哪一首」与「有没有队列」；进度 tick 由
/// `TySeekBar` 自己订阅，播放键、音量各自订阅自己那一项。
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CurrentTrackRef current = ref.watch(currentTrackRefProvider);
    final Track? track = ref.watch(currentTrackProvider);
    // 只订阅「有没有队列」与「有没有失败」：进度 tick 不该重建整条播放条
    // （重建一次封面就可能重解一次图片）。
    final ({bool hasQueue, String? error}) state = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot snapshot) => (
          hasQueue: snapshot.processing != PlaybackProcessing.idle,
          error: snapshot.failure?.message,
        ),
      ),
    );
    final bool hasQueue = state.hasQueue;
    final PlaybackItem? item = current.item;
    final bool hasTrack = track != null || item != null;

    // 队列由外部设置时没有曲库 id 映射，用引擎条目兜底。
    final Uri? artUri = item?.artUri;
    final String? remoteArt =
        (artUri != null &&
            (artUri.scheme == 'http' || artUri.scheme == 'https'))
        ? artUri.toString()
        : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(TySpace.x16, 0, TySpace.x16, TySpace.x12),
      child: TyTransportBar(
        visible: hasQueue && hasTrack,
        coverPath: track?.coverArtPath,
        coverUrl: track?.coverArtUrl ?? remoteArt,
        coverSeed: track?.album ?? item?.title ?? 'tingyu',
        title: track?.title ?? item?.title ?? '',
        artist: track?.artist ?? item?.artist ?? '',
        favorite: track?.isFavorite ?? false,
        onToggleFavorite: track == null
            ? null
            : () => toggleTrackFavorite(ref, track),
        onOpenStage: () => context.push('/stage'),
        error: state.error == null ? null : '播放失败',
        errorDetail: state.error,
        onRetry: () => ref.read(playbackProvider.notifier).togglePlayPause(),
        transport: const _TransportRow(),
        progress: const _Progress(),
        actions: <Widget>[
          const _StageAction(
            icon: Icons.lyrics_outlined,
            tooltip: '歌词',
            tab: 'lyrics',
          ),
          const _StageAction(
            icon: Icons.queue_music_outlined,
            tooltip: '播放队列',
            tab: 'queue',
          ),
          const _Volume(),
        ],
      ),
    );
  }
}

/// 传输键：单独订阅 `playing` 与随机/循环状态。
class _TransportRow extends ConsumerWidget {
  const _TransportRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ({
      bool playing,
      PlaybackProcessing processing,
      PlayOrder playOrder,
      PlaybackRepeatMode repeatMode,
    })
    snapshot = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot value) => (
          playing: value.playing,
          processing: value.processing,
          playOrder: value.playOrder,
          repeatMode: value.repeatMode,
        ),
      ),
    );
    final bool ready = snapshot.processing != PlaybackProcessing.idle;
    return TyTransportRow(
      playing: snapshot.playing,
      loading: snapshot.processing == PlaybackProcessing.loading,
      onPlayPause: ready
          ? () => ref.read(playbackProvider.notifier).togglePlayPause()
          : null,
      onPrevious: ready
          ? () => ref.read(playbackProvider.notifier).previous()
          : null,
      onNext: ready ? () => ref.read(playbackProvider.notifier).next() : null,
      shuffled: snapshot.playOrder == PlayOrder.shuffle,
      onToggleShuffle: ready
          ? () => ref.read(playbackProvider.notifier).toggleShuffle()
          : null,
      repeatActive: snapshot.repeatMode != PlaybackRepeatMode.off,
      repeatIcon: switch (snapshot.repeatMode) {
        PlaybackRepeatMode.one => Icons.repeat_one_rounded,
        _ => Icons.repeat_rounded,
      },
      repeatTooltip: switch (snapshot.repeatMode) {
        PlaybackRepeatMode.one => '单曲循环',
        PlaybackRepeatMode.off => '不循环',
        _ => '列表循环',
      },
      onCycleRepeat: ready
          ? () => ref.read(playbackProvider.notifier).cycleRepeatMode()
          : null,
      sideIconSize: TyPlayerSize.barSideIcon,
      keyIconSize: TyPlayerSize.barKeyIcon,
      playSize: TyPlayerSize.barPlay,
    );
  }
}

/// 进度行：单独订阅 position/duration/buffered（唯一随 tick 重建的部分）。
class _Progress extends ConsumerWidget {
  const _Progress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ({Duration position, Duration duration, Duration buffered}) progress =
        ref.watch(
          playbackProvider.select(
            (PlaybackSnapshot snapshot) => (
              position: snapshot.position,
              duration: snapshot.duration,
              buffered: snapshot.buffered,
            ),
          ),
        );
    final bool ready = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot snapshot) =>
            snapshot.processing != PlaybackProcessing.idle,
      ),
    );
    return TySeekBar(
      position: progress.position,
      duration: progress.duration,
      buffered: progress.buffered,
      // 时长未知时滑块没有可信的刻度。
      enabled: ready && progress.duration > Duration.zero,
      hitHeight: TyPlayerSize.barSeekHitHeight,
      onSeek: ref.read(playbackProvider.notifier).seek,
    );
  }
}

/// 音量：单独订阅 `volume`，与进度互不牵连。
class _Volume extends ConsumerWidget {
  const _Volume();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double volume = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot snapshot) => snapshot.volume.clamp(0, 1).toDouble(),
      ),
    );
    return TyVolumeControl(
      volume: volume,
      onChanged: ref.read(playbackProvider.notifier).setVolume,
    );
  }
}

/// 右侧「歌词 / 队列」：桌面打开检查器式面板，其余情况退回独立页。
class _StageAction extends StatelessWidget {
  const _StageAction({
    required this.icon,
    required this.tooltip,
    required this.tab,
  });

  final IconData icon;
  final String tooltip;

  /// `/stage?tab=lyrics` 或 `queue`。
  final String tab;

  @override
  Widget build(BuildContext context) {
    return TyIconAction(
      icon: icon,
      semanticLabel: tooltip,
      tooltip: tooltip,
      onPressed: () => context.push(
        context.formFactor.isCompact ? '/$tab' : '/stage?tab=$tab',
      ),
    );
  }
}
