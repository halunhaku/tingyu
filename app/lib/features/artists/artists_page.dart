import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/models/library_summaries.dart';
import '../../design/components/artist_row.dart';
import '../../design/components/buttons.dart';
import '../../design/components/context_menu.dart';
import '../../design/components/feedback.dart';
import '../../design/components/structure.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../shared/skeletons.dart';

/// 艺术家头像字节：按名字缓存（`ArtistAvatarStore` 自带内存 + 磁盘缓存与并发收敛）。
///
/// 头像来自网易云，`ArtistAvatarStore` 只给 bytes（内存 + 应用支持目录缓存），
/// 所以直接喂给 `TyArtistRow.avatarBytes`，不为展示再造一条文件路径。
///
/// 不显式标注 `FutureProviderFamily<Uint8List?, String>`：Riverpod 3 把该类型
/// 挪到了 `package:flutter_riverpod/misc.dart`，这里靠推断保持主入口 import。
final artistAvatarProvider = FutureProvider.family<Uint8List?, String>(
  (Ref ref, String artist) =>
      ref.watch(artistAvatarStoreProvider).avatar(artist),
);

/// 艺术家页：列表（头像 44 + 名称 + 曲目数 + chevron），可扫读性优于网格
/// （`docs/UX_REDESIGN.md` §5.2），点击进入艺术家详情。
class ArtistsPage extends ConsumerWidget {
  const ArtistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyMetrics metrics = context.metrics;
    final AsyncValue<List<ArtistSummary>> artists = ref.watch(artistsProvider);
    final int? count = artists.value?.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.pagePadding,
            TySpace.x20,
            metrics.pagePadding,
            TySpace.x12,
          ),
          child: TyPageHeader(
            title: '艺术家',
            subtitle: count == null ? null : '共 $count 位',
          ),
        ),
        Expanded(
          child: TyAsyncView<List<ArtistSummary>>(
            value: artists,
            loading: (BuildContext context) =>
                const TrackRowsSkeleton(rows: 8),
            error: (BuildContext context, Object error, StackTrace? stack) =>
                TyErrorView(
                  title: '艺术家列表读取失败',
                  detail: '$error',
                  onRetry: () => ref.invalidate(artistsProvider),
                ),
            isEmpty: (List<ArtistSummary> list) => list.isEmpty,
            empty: (BuildContext context) => TyEmptyState(
              icon: Icons.person_outline,
              title: '还没有艺术家',
              description: '添加来源并同步曲库后，这里会按艺术家聚合展示',
              actionLabel: '添加来源',
              onAction: () => context.go('/sources'),
            ),
            data: (BuildContext context, List<ArtistSummary> list) =>
                ListView.builder(
                  padding: EdgeInsets.symmetric(
                    horizontal: metrics.pagePadding,
                    vertical: TySpace.x8,
                  ),
                  itemCount: list.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _ArtistListRow(artist: list[index]),
                ),
          ),
        ),
      ],
    );
  }
}

/// 单行艺术家：头像拿到前先画首字占位，不阻塞列表。
class _ArtistListRow extends ConsumerWidget {
  const _ArtistListRow({required this.artist});

  final ArtistSummary artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TyArtistRow(
      name: artist.name,
      subtitle: '${artist.trackCount} 首',
      avatarBytes: ref.watch(artistAvatarProvider(artist.name)).value,
      onTap: () => context.push('/artist/${Uri.encodeComponent(artist.name)}'),
      onSecondaryTapDown: (TapDownDetails details) =>
          _showMenu(context, ref, details.globalPosition),
      trailing: Builder(
        builder: (BuildContext buttonContext) => TyIconAction(
          icon: Icons.more_horiz,
          semanticLabel: '${artist.name}：更多操作',
          tooltip: '更多',
          size: TyIconSize.compact,
          onPressed: () => _showMenu(context, ref, _menuAnchor(buttonContext)),
        ),
      ),
    );
  }

  /// 艺术家行的上下文菜单：播放 / 随机 / 查看艺术家。
  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position,
  ) async {
    Future<void> play({required bool shuffle}) async {
      final List<Track> tracks = await ref.read(
        artistTracksProvider(artist.name).future,
      );
      if (!context.mounted) {
        return;
      }
      if (tracks.isEmpty) {
        TySnack.show(context, '「${artist.name}」还没有曲目');
        return;
      }
      await ref
          .read(playbackProvider.notifier)
          .playTracks(tracks, shuffle: shuffle);
    }

    await TyContextMenu.show(
      context,
      position: position,
      actions: <TyMenuAction>[
        TyMenuAction(
          label: '播放',
          icon: Icons.play_arrow_outlined,
          onSelected: () => play(shuffle: false),
        ),
        TyMenuAction(
          label: '随机播放',
          icon: Icons.shuffle,
          onSelected: () => play(shuffle: true),
        ),
        TyMenuAction(
          label: '查看艺术家',
          icon: Icons.person_outline,
          onSelected: () =>
              context.push('/artist/${Uri.encodeComponent(artist.name)}'),
        ),
      ],
    );
  }
}

/// ⋯ 按钮的菜单锚点（全局坐标）。
Offset _menuAnchor(BuildContext buttonContext) {
  final RenderObject? box = buttonContext.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    return box.localToGlobal(box.size.center(Offset.zero));
  }
  return Offset.zero;
}
