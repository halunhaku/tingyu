import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/track.dart';
import '../../playback/playback_snapshot.dart';
import 'current_track.dart';

/// 曲目行：**行自己**订阅「我是不是正在播放的那一首」。
///
/// 为什么不让宿主统一订阅再传 `isPlaying`：那样每次进度 tick（每秒 5-16 次）都会
/// 重建宿主，可见的每一行跟着重建（`ui_rebuild_seek_test` 会直接抓到）。
/// 这里订阅的是两个稳定值——`isCurrentTrackProvider(id)` 与 `playing` 布尔——
/// 所以换曲只重建高亮翻转的那两行，进度 tick 一行都不重建。
class PlaybackTrackRow extends ConsumerWidget {
  const PlaybackTrackRow({
    super.key,
    required this.track,
    required this.index,
    this.tableMode = false,
    this.showAlbum = true,
    this.showCover = true,
    this.highlightQuery,
    this.selected = false,
    this.onTap,
    this.onDoubleTap,
    this.onToggleFavorite,
    this.onMore,
    this.onSecondaryTapDown,
    this.onSelectChanged,
    this.trailing,
  });

  final Track track;

  /// 1 起的展示序号。
  final int index;
  final bool tableMode;
  final bool showAlbum;
  final bool showCover;
  final String? highlightQuery;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onMore;
  final void Function(TapDownDetails details)? onSecondaryTapDown;
  final ValueChanged<bool>? onSelectChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isCurrent = ref.watch(isCurrentTrackProvider(track.id));
    final bool playing = ref.watch(
      playbackProvider.select((PlaybackSnapshot snapshot) => snapshot.playing),
    );
    return TyTrackRow(
      track: track,
      index: index,
      tableMode: tableMode,
      showAlbum: showAlbum,
      showCover: showCover,
      highlightQuery: highlightQuery,
      selected: selected,
      isPlaying: isCurrent,
      playing: isCurrent && playing,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onToggleFavorite: onToggleFavorite,
      onMore: onMore,
      onSecondaryTapDown: onSecondaryTapDown,
      onSelectChanged: onSelectChanged,
      trailing: trailing,
    );
  }
}
