import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/buttons.dart';
import '../../design/components/feedback.dart';
import '../../design/components/player_stage.dart';
import '../../design/components/transport.dart';
import '../../design/layout/form_factor.dart';
import '../../design/theme.dart';
import '../../design/tokens/metrics.dart';
import '../../playback/playback_item.dart';
import '../../playback/playback_snapshot.dart';
import '../shared/current_track.dart';
import '../shared/track_actions.dart';
import 'fluid_background.dart';
import 'lyrics_panel.dart';
import 'queue_panel.dart';

/// 播放舞台（`/stage`，`DESIGN.md` §6.3 / `docs/UX_REDESIGN.md` §5.4）。
///
/// - 背景：封面取色的极缓漂移（`FluidBackground`，容器里只有它重绘）；
/// - 结构交给 `TyPlayerStage`：封面 → 曲名 → 艺术家 → 专辑 → 进度 → 传输行 → 次级行；
/// - expanded 两栏：右侧 `?tab=lyrics|queue` 决定放歌词还是队列；
/// - 关闭：`Esc` / 顶部左箭头；compact 还能下拉收起。
class NowPlayingPage extends ConsumerStatefulWidget {
  const NowPlayingPage({super.key});

  @override
  ConsumerState<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends ConsumerState<NowPlayingPage> {
  /// 右侧栏当前放什么；`?tab=queue` 由传输条/快捷入口带进来。
  String _tab = 'lyrics';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final String? tab = GoRouterState.of(context).uri.queryParameters['tab'];
    if (tab == 'queue' || tab == 'lyrics') {
      _tab = tab!;
    }
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go('/library/songs');
  }

  @override
  Widget build(BuildContext context) {
    final bool compact = context.formFactor.isCompact;
    final CurrentTrackRef current = ref.watch(currentTrackRefProvider);
    final Track? track = ref.watch(currentTrackProvider);
    final PlaybackItem? item = current.item;
    final Uri? artUri = item?.artUri;
    final String? remoteArt =
        (artUri != null &&
            (artUri.scheme == 'http' || artUri.scheme == 'https'))
        ? artUri.toString()
        : null;
    final bool hasTrack = track != null || item != null;

    if (!hasTrack) {
      return Scaffold(
        backgroundColor: context.ty.colors.canvas,
        body: SafeArea(
          child: Stack(
            children: <Widget>[
              Positioned(
                left: TySpace.x8,
                top: TySpace.x8,
                child: TyIconAction(
                  icon: Icons.arrow_back,
                  semanticLabel: '返回',
                  tooltip: '返回',
                  onPressed: _close,
                ),
              ),
              const Center(
                child: TyEmptyState(
                  icon: Icons.headphones_outlined,
                  title: '未在播放',
                  description: '从曲库中选一首歌开始播放',
                ),
              ),
            ],
          ),
        ),
      );
    }

    return TyPlayerStage(
      background: FluidBackground(
        coverPath: track?.coverArtPath,
        child: const SizedBox.expand(),
      ),
      title: track?.title ?? item?.title ?? '',
      artist: track?.artist ?? item?.artist ?? '',
      album: track?.album,
      coverPath: track?.coverArtPath,
      coverUrl: track?.coverArtUrl ?? remoteArt,
      coverSeed: track?.album ?? item?.title ?? 'tingyu',
      favorite: track?.isFavorite ?? false,
      onToggleFavorite: track == null
          ? null
          : () => toggleTrackFavorite(ref, track),
      onArtistTap: track == null
          ? null
          : () => context.push('/artist/${Uri.encodeComponent(track.artist)}'),
      progress: const _StageProgress(),
      transport: const _StageTransport(),
      actions: <Widget>[
        TyIconAction(
          icon: Icons.lyrics_outlined,
          semanticLabel: '歌词',
          tooltip: '歌词',
          active: _tab == 'lyrics',
          onPressed: () => setState(() => _tab = 'lyrics'),
        ),
        TyIconAction(
          icon: Icons.queue_music_outlined,
          semanticLabel: '播放队列',
          tooltip: '播放队列',
          active: _tab == 'queue',
          onPressed: () => setState(() => _tab = 'queue'),
        ),
        if (!compact) const _StageVolume(),
      ],
      rightPane: _rightPane(compact),
      onClose: _close,
      onDismiss: _close,
    );
  }

  Widget? _rightPane(bool compact) {
    // compact 没有右栏：歌词/队列各自是整页（`/lyrics`、`/queue`）。
    if (compact) {
      return null;
    }
    return _tab == 'queue' ? const QueuePanel() : const LyricsPanel();
  }
}

/// 舞台进度：只订阅进度三项，tick 重建的也只有它。
class _StageProgress extends ConsumerWidget {
  const _StageProgress();

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
    return TySeekBar(
      position: progress.position,
      duration: progress.duration,
      buffered: progress.buffered,
      enabled: progress.duration > Duration.zero,
      onSeek: ref.read(playbackProvider.notifier).seek,
    );
  }
}

/// 舞台传输行：与传输条同一套键，尺寸取舞台档。
class _StageTransport extends ConsumerWidget {
  const _StageTransport();

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
    return TyTransportRow(
      playing: snapshot.playing,
      loading: snapshot.processing == PlaybackProcessing.loading,
      onPlayPause: () => ref.read(playbackProvider.notifier).togglePlayPause(),
      onPrevious: () => ref.read(playbackProvider.notifier).previous(),
      onNext: () => ref.read(playbackProvider.notifier).next(),
      shuffled: snapshot.playOrder == PlayOrder.shuffle,
      onToggleShuffle: () =>
          ref.read(playbackProvider.notifier).toggleShuffle(),
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
      onCycleRepeat: () =>
          ref.read(playbackProvider.notifier).cycleRepeatMode(),
    );
  }
}

/// 舞台音量：与传输条同一控件，尺寸按舞台放宽。
class _StageVolume extends ConsumerWidget {
  const _StageVolume();

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
