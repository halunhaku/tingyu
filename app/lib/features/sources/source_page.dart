import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/buttons.dart';
import '../../design/components/context_menu.dart';
import '../../design/components/feedback.dart';
import '../../design/components/source_card.dart';
import '../../design/components/structure.dart';
import '../../design/components/track.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../../design/tokens/tokens.dart';
import '../../design/theme.dart';
import '../shared/current_track.dart';
import '../shared/track_actions.dart';
import 'source_status.dart';
import 'source_sync.dart';
import 'sources_page.dart';

/// 单个来源页：状态与恢复路径 + 曲目列表 + 元数据补全入口。
class SourcePage extends ConsumerWidget {
  const SourcePage({super.key, required this.sourceId});

  final String sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyMetrics metrics = context.metrics;
    final AsyncValue<MusicSource?> source = ref.watch(
      sourceByIdProvider(sourceId),
    );
    final SourceSyncState sync =
        ref.watch(sourceSyncProvider)[sourceId] ?? const SourceSyncState();
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
        child: source.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(TySpace.x24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TySkeleton(height: TySpace.x24, width: 220),
                SizedBox(height: TySpace.x12),
                TySkeleton.line(width: 320),
              ],
            ),
          ),
          error: (Object error, StackTrace stack) => TyErrorView(
            title: '来源读取失败',
            detail: '$error',
            onRetry: () => ref.invalidate(sourceByIdProvider(sourceId)),
          ),
          data: (MusicSource? value) {
            if (value == null) {
              return TyEmptyState(
                icon: Icons.help_outline,
                title: '来源不存在',
                description: '它可能已被删除',
                actionLabel: '返回来源管理',
                onAction: () => context.go('/sources'),
              );
            }
            return _body(context, ref, value, sync, metrics);
          },
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    MusicSource source,
    SourceSyncState sync,
    TyMetrics metrics,
  ) {
    final SourceStatusView view = describeSourceStatus(source, sync);
    final AsyncValue<List<Track>> tracks = ref.watch(
      tracksOfSourceProvider(source.id),
    );
    final CurrentTrackRef current = ref.watch(currentTrackRefProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.pagePadding,
            TySpace.x16,
            metrics.pagePadding,
            TySpace.x12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (context.canPop())
                Align(
                  alignment: Alignment.centerLeft,
                  child: TyButton(
                    label: '返回',
                    icon: Icons.chevron_left,
                    variant: TyButtonVariant.ghost,
                    dense: true,
                    onPressed: () => context.pop(),
                  ),
                ),
              TyPageHeader(
                title: source.name,
                // 来源名常与类型同名（用户把夸克来源就命名为「夸克网盘」），
                // 状态标签里也已经带了曲目数——这里只补类型与状态，避免同一行重复两遍。
                subtitle: <String>[
                  if (view.typeLabel != source.name) view.typeLabel,
                  view.statusLabel,
                ].join(' · '),
                actions: <Widget>[
                  TyButton(
                    label: view.primaryLabel,
                    icon: view.primaryIcon,
                    variant: TyButtonVariant.secondary,
                    onPressed: view.busy
                        ? null
                        : _primaryAction(context, ref, source, view),
                  ),
                  _OverflowMenu(source: source, sync: sync),
                ],
              ),
              _statusPanel(context, ref, source, sync, view),
            ],
          ),
        ),
        Expanded(
          child: tracks.when(
            loading: () => _trackSkeleton(metrics),
            error: (Object error, StackTrace stack) => TyErrorView(
              title: '曲目读取失败',
              detail: '$error',
              onRetry: () => ref.invalidate(tracksOfSourceProvider(source.id)),
            ),
            data: (List<Track> list) {
              if (list.isEmpty) {
                return TyEmptyState(
                  icon: Icons.cloud_off,
                  title: '该来源还没有曲目',
                  description: '点上方「${view.primaryLabel}」开始扫描',
                  actionLabel: view.primaryLabel,
                  onAction: view.busy
                      ? null
                      : () => ref
                            .read(sourceSyncProvider.notifier)
                            .sync(source),
                );
              }
              return TyTrackList(
                tracks: list,
                playingTrackId: current.trackId,
                playing: ref.watch(playbackProvider).playing,
                padding: EdgeInsets.symmetric(horizontal: metrics.pagePadding),
                onTapTrack: (int index) => ref
                    .read(playbackProvider.notifier)
                    .playTracks(list, startIndex: index),
                onToggleFavorite: (Track track) =>
                    toggleTrackFavorite(ref, track),
                onMore: (Track track, Offset position) => showTrackMenu(
                  context,
                  ref,
                  track,
                  position: position,
                  onPlay: () => ref
                      .read(playbackProvider.notifier)
                      .playTracks(list, startIndex: list.indexOf(track)),
                ),
                onSecondaryTapDown: (Track track, TapDownDetails details) =>
                    showTrackMenu(
                      context,
                      ref,
                      track,
                      position: details.globalPosition,
                      onPlay: () => ref
                          .read(playbackProvider.notifier)
                          .playTracks(list, startIndex: list.indexOf(track)),
                    ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _trackSkeleton(TyMetrics metrics) {
    return ListView.builder(
      padding: EdgeInsets.symmetric(horizontal: metrics.pagePadding),
      itemCount: 8,
      itemBuilder: (BuildContext context, int index) => const Padding(
        padding: EdgeInsets.symmetric(vertical: TySpace.x12),
        child: Row(
          children: <Widget>[
            TySkeleton(width: TySpace.x40, height: TySpace.x40),
            SizedBox(width: TySpace.x12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TySkeleton(height: TySpace.x16, width: 220),
                  SizedBox(height: TySpace.x6),
                  TySkeleton(height: TySpace.x12, width: 140),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  VoidCallback _primaryAction(
    BuildContext context,
    WidgetRef ref,
    MusicSource source,
    SourceStatusView view,
  ) {
    return switch (view.remediation) {
      SourceRemediation.relogin => () =>
        reloginQuarkSource(context, ref, source),
      SourceRemediation.reconfigure => () =>
        confirmDeleteSource(context, ref, source),
      _ => () => ref.read(sourceSyncProvider.notifier).sync(source),
    };
  }

  /// 状态行 + 进度（扫描 / 补全元数据均在此播报）+ 异常恢复路径。
  Widget _statusPanel(
    BuildContext context,
    WidgetRef ref,
    MusicSource source,
    SourceSyncState sync,
    SourceStatusView view,
  ) {
    final TyTokens ty = context.ty;
    final bool failed = view.tone == TySourceStatusTone.failed;
    final String? progressLabel = view.progressLabel;
    return TyPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              TySourceStatusDot(tone: view.tone),
              const SizedBox(width: TySpace.x8),
              Expanded(
                child: Text(
                  view.statusLabel,
                  style: ty.typography.bodyM.copyWith(
                    color: ty.colors.textPrimary,
                  ),
                ),
              ),
              if (sync.running) ...<Widget>[
                const SizedBox(width: TySpace.x12),
                Text(
                  sync.total > 0 ? '${sync.done}/${sync.total}' : '${sync.done}',
                  style: ty.typography.numericS.copyWith(
                    color: ty.colors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
          if (sync.running) ...<Widget>[
            const SizedBox(height: TySpace.x12),
            Semantics(
              liveRegion: true,
              value: progressLabel,
              child: TyProgressBar(
                value: sync.total > 0 ? sync.progress : null,
                semanticLabel: progressLabel,
              ),
            ),
            const SizedBox(height: TySpace.x6),
            Text(
              sync.message.isEmpty ? '正在同步…' : sync.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ty.typography.bodyS.copyWith(
                color: ty.colors.textSecondary,
              ),
            ),
          ],
          if (view.detail != null) ...<Widget>[
            const SizedBox(height: TySpace.x6),
            SelectableText(
              view.detail!,
              style: ty.typography.bodyS.copyWith(
                color: failed ? ty.colors.danger : ty.colors.textTertiary,
              ),
            ),
          ],
          if (failed) ...<Widget>[
            const SizedBox(height: TySpace.x12),
            TyErrorView(
              compact: true,
              title: '同步失败',
              detail: sync.error == null ? null : '可复制诊断信息发给开发者定位。',
              retryLabel: view.primaryLabel,
              onRetry: view.busy
                  ? null
                  : _primaryAction(context, ref, source, view),
            ),
          ],
          const SizedBox(height: TySpace.x12),
          Wrap(
            spacing: TySpace.x8,
            runSpacing: TySpace.x8,
            children: <Widget>[
              TyButton(
                label: '补全元数据',
                icon: Icons.auto_fix_high,
                variant: TyButtonVariant.ghost,
                dense: true,
                onPressed: sync.running
                    ? null
                    : () => ref
                          .read(sourceSyncProvider.notifier)
                          .enrichSource(source.id),
              ),
              if (source.kind == 'quark')
                TyButton(
                  label: '重新登录',
                  icon: Icons.login,
                  variant: TyButtonVariant.ghost,
                  dense: true,
                  onPressed: sync.running
                      ? null
                      : () => reloginQuarkSource(context, ref, source),
                ),
              TyButton(
                label: '复制诊断信息',
                icon: Icons.copy_all_outlined,
                variant: TyButtonVariant.ghost,
                dense: true,
                onPressed: () => copySourceDiagnostics(context, source, sync),
              ),
              TyButton(
                label: '管理来源',
                icon: Icons.folder_open,
                variant: TyButtonVariant.ghost,
                dense: true,
                onPressed: () => context.go('/sources'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ⋯ 菜单（详情页头部）：危险操作与其他动作隔开（`TyContextMenu` 负责分组）。
class _OverflowMenu extends ConsumerWidget {
  const _OverflowMenu({required this.source, required this.sync});

  final MusicSource source;
  final SourceSyncState sync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TyIconAction(
      icon: Icons.more_horiz,
      semanticLabel: '更多操作',
      tooltip: '更多操作',
      onPressed: () => _open(context, ref),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final RenderBox box = context.findRenderObject()! as RenderBox;
    final Offset origin = box.localToGlobal(Offset.zero);
    await TyContextMenu.show(
      context,
      position: origin + Offset(box.size.width, box.size.height),
      actions: <TyMenuAction>[
        TyMenuAction(
          label: '补全元数据',
          icon: Icons.auto_fix_high,
          enabled: !sync.running,
          onSelected: () =>
              ref.read(sourceSyncProvider.notifier).enrichSource(source.id),
        ),
        if (source.kind == 'quark')
          TyMenuAction(
            label: '重新登录',
            icon: Icons.login,
            enabled: !sync.running,
            onSelected: () => reloginQuarkSource(context, ref, source),
          ),
        TyMenuAction(
          label: '复制诊断信息',
          icon: Icons.copy_all_outlined,
          onSelected: () => copySourceDiagnostics(context, source, sync),
        ),
        TyMenuAction(
          label: '管理来源',
          icon: Icons.folder_open,
          onSelected: () => context.go('/sources'),
        ),
        TyMenuAction(
          label: '删除来源',
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () => confirmDeleteSource(context, ref, source),
        ),
      ],
    );
  }
}
