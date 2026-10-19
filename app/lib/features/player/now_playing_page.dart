import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/buttons.dart';
import '../../design/components/feedback.dart';
import '../../design/components/interactive.dart';
import '../../design/components/player_stage.dart';
import '../../design/components/transport.dart';
import '../../design/layout/form_factor.dart';
import '../../design/theme.dart';
import '../../design/tokens/metrics.dart';
import '../../design/tokens/voice_archive.dart';
import '../../design/format.dart';
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
  String _tab = 'queue';
  String? _routeTab;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final String? tab = GoRouterState.of(context).uri.queryParameters['tab'];
    if ((tab == 'queue' || tab == 'lyrics') && tab != _routeTab) {
      _tab = tab!;
      _routeTab = tab;
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
    final inherited = context.ty;
    return Theme(
      data: TyTheme.build(
        brightness: inherited.brightness,
        density: inherited.density,
        colors: VoiceArchiveColors.of(inherited.brightness),
      ),
      child: Builder(builder: _buildStage),
    );
  }

  Widget _buildStage(BuildContext context) {
    final bool compact = context.formFactor.isCompact;
    final bool expanded = context.formFactor.isExpanded;
    final bool inlinePane =
        compact &&
        MediaQuery.sizeOf(context).height >=
            TyPlayerStageSize.compactPaneMinWindowHeight &&
        MediaQuery.textScalerOf(context).scale(1) <= 1.3;
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
    final PlaybackFailure? failure = ref.watch(
      playbackProvider.select((PlaybackSnapshot snapshot) => snapshot.failure),
    );

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
              Center(
                child: failure != null
                    ? TyErrorView(
                        title: '播放失败',
                        detail: failure.message,
                        onRetry: _canRetry(ref) ? () => _retryStage(ref) : null,
                      )
                    : const TyEmptyState(
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

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: TyPlayerStage(
        headerActions: const <Widget>[_StageStatus()],
        background: FluidBackground(
          coverPath: track?.coverArtPath,
          animate: false,
          child: const SizedBox.expand(),
        ),
        title: track?.title ?? item?.title ?? '',
        artist: track?.artist ?? item?.artist ?? '',
        album: track?.album,
        coverPath: track?.coverArtPath,
        coverUrl: track?.coverArtUrl ?? remoteArt,
        coverSeed: null,
        favorite: track?.isFavorite ?? false,
        onToggleFavorite: track == null
            ? null
            : () => toggleTrackFavorite(ref, track),
        onArtistTap: track == null
            ? null
            : () =>
                  context.push('/artist/${Uri.encodeComponent(track.artist)}'),
        progress: const _StageProgress(),
        transport: const _StageTransport(),
        actions: <Widget>[
          if (!expanded && !inlinePane)
            TyIconAction(
              icon: Icons.lyrics_outlined,
              semanticLabel: '歌词',
              tooltip: '歌词',
              active: _tab == 'lyrics',
              onPressed: () => _openPane(context, 'lyrics'),
            ),
          if (!expanded && !inlinePane)
            TyIconAction(
              icon: Icons.queue_music_outlined,
              semanticLabel: '播放队列',
              tooltip: '播放队列',
              active: _tab == 'queue',
              onPressed: () => _openPane(context, 'queue'),
            ),
          if (!compact) const _StageVolume(),
        ],
        compactPane: inlinePane ? _pane(preview: true) : null,
        rightPane: expanded ? _pane() : null,
        onClose: _close,
        onDismiss: _close,
      ),
    );
  }

  Widget _pane({bool preview = false}) => _StagePane(
    tab: _tab,
    preview: preview,
    onChanged: (String tab) => setState(() => _tab = tab),
  );

  void _openPane(BuildContext context, String tab) {
    setState(() => _tab = tab);
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => Theme(
        data: theme,
        child: SizedBox(
          height:
              MediaQuery.sizeOf(sheetContext).height *
              TyPlayerStageSize.sheetHeightFactor,
          child: _StagePane(tab: tab),
        ),
      ),
    );
  }
}

/// 舞台内唯一的歌词/队列分段；弹层只显示所请求的面板。
class _StagePane extends StatelessWidget {
  const _StagePane({required this.tab, this.preview = false, this.onChanged});

  final String tab;
  final bool preview;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ty = context.ty;
    return ColoredBox(
      color: ty.colors.surface,
      child: Column(
        children: <Widget>[
          if (onChanged != null)
            SizedBox(
              height: TySpace.x48,
              child: Row(
                children: <Widget>[
                  for (final entry in const <String, String>{
                    'lyrics': '歌词',
                    'queue': '队列',
                  }.entries)
                    Expanded(
                      child: TyInteractive(
                        semanticLabel: entry.value,
                        semanticSelected: tab == entry.key,
                        onTap: () => onChanged!(entry.key),
                        builder:
                            (BuildContext context, TyInteractionState state) =>
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: state.overlay(ty.colors),
                                    border: Border(
                                      bottom: BorderSide(
                                        color: tab == entry.key
                                            ? ty.colors.accent
                                            : ty.colors.border,
                                        width: tab == entry.key
                                            ? TySpace.x2
                                            : 1,
                                      ),
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      entry.value,
                                      style: ty.typography.labelL.copyWith(
                                        color: tab == entry.key
                                            ? ty.colors.accent
                                            : ty.colors.textSecondary,
                                      ),
                                    ),
                                  ),
                                ),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: tab == 'queue'
                ? QueuePanel(grouped: true, preview: preview)
                : LyricsPanel(compact: preview),
          ),
        ],
      ),
    );
  }
}

bool _canRetry(WidgetRef ref) {
  final controller = ref.read(playbackProvider.notifier);
  return controller.sourceQueue.isNotEmpty || controller.queue.isNotEmpty;
}

Future<void> _retryStage(WidgetRef ref) async {
  final controller = ref.read(playbackProvider.notifier);
  if (controller.sourceQueue.isNotEmpty) {
    await controller.playAt(
      controller.queueDisplayIndex.clamp(0, controller.sourceQueue.length - 1),
    );
  } else if (controller.queue.isNotEmpty) {
    await controller.playAt(
      ref.read(playbackProvider).index.clamp(0, controller.queue.length - 1),
    );
  }
}

class _StageStatus extends ConsumerWidget {
  const _StageStatus();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot value) =>
            (processing: value.processing, failed: value.failure != null),
      ),
    );
    final String label = status.failed
        ? '播放失败'
        : status.processing == PlaybackProcessing.buffering
        ? '正在缓冲'
        : status.processing == PlaybackProcessing.loading
        ? '正在加载'
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: TySpace.x12),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.ty.typography.bodyS.copyWith(
          color: status.failed
              ? context.ty.colors.danger
              : context.ty.colors.textSecondary,
        ),
      ),
    );
  }
}

/// 舞台进度：只订阅进度三项和错误，tick不重建封面或队列。
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
    final PlaybackFailure? failure = ref.watch(
      playbackProvider.select((PlaybackSnapshot value) => value.failure),
    );
    final bool known = progress.duration > Duration.zero;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (failure != null) ...<Widget>[
          Semantics(
            liveRegion: true,
            child: Text(
              '播放失败：${failure.message}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.ty.typography.bodyS.copyWith(
                color: context.ty.colors.danger,
              ),
            ),
          ),
          if (_canRetry(ref))
            TextButton(
              onPressed: () => _retryStage(ref),
              child: const Text('重试此曲'),
            ),
          const SizedBox(height: TySpace.x8),
        ],
        TySeekBar(
          position: progress.position,
          duration: progress.duration,
          buffered: progress.buffered,
          enabled: known && failure == null,
          hitHeight: TySpace.x40 + TySpace.x4,
          showTimes: known,
          semanticLabel: known ? '播放进度' : '播放进度，总时长未知',
          onSeek: ref.read(playbackProvider.notifier).seek,
        ),
        if (!known)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                progress.position > Duration.zero
                    ? formatDuration(progress.position)
                    : '0:00',
                style: context.ty.typography.numericM.copyWith(
                  color: context.ty.colors.textTertiary,
                ),
              ),
              Text(
                '--:--',
                style: context.ty.typography.numericM.copyWith(
                  color: context.ty.colors.textTertiary,
                ),
              ),
            ],
          ),
      ],
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
      bool failed,
    })
    snapshot = ref.watch(
      playbackProvider.select(
        (PlaybackSnapshot value) => (
          playing: value.playing,
          processing: value.processing,
          playOrder: value.playOrder,
          repeatMode: value.repeatMode,
          failed: value.failure != null,
        ),
      ),
    );
    return TyTransportRow(
      playing: snapshot.playing && !snapshot.failed,
      loading:
          snapshot.processing == PlaybackProcessing.loading ||
          snapshot.processing == PlaybackProcessing.buffering,
      onPlayPause: snapshot.failed
          ? (_canRetry(ref) ? () => _retryStage(ref) : null)
          : () => ref.read(playbackProvider.notifier).togglePlayPause(),
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
