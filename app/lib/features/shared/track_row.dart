import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../library/manual_match_dialog.dart';
import 'add_to_playlist.dart';
import 'cover_art.dart';
import 'format.dart';

/// 曲目行：曲库、专辑、艺术家、播放列表、搜索结果共用。
///
/// 只负责展示与单曲操作；"点击后播放哪个队列"由调用方通过 [onTap] 决定，
/// 这样同一个 widget 能服务"整库播放"与"专辑内播放"两种语义。
class TrackRow extends ConsumerWidget {
  const TrackRow({
    super.key,
    required this.track,
    this.index,
    this.onTap,
    this.showAlbum = true,
    this.showIndex = true,
    this.isPlaying = false,
    this.trailing,
  });

  final Track track;

  /// 列表序号（从 1 开始展示）。
  final int? index;

  final VoidCallback? onTap;

  final bool showAlbum;

  final bool showIndex;

  final bool isPlaying;

  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      onSecondaryTapDown: (TapDownDetails details) =>
          _showMenu(context, ref, position: details.globalPosition),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: <Widget>[
            if (showIndex)
              SizedBox(
                width: 28,
                child: isPlaying
                    ? Icon(Icons.graphic_eq, size: 16, color: scheme.primary)
                    : Text(
                        index == null ? '' : '$index',
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
              ),
            if (showIndex) const SizedBox(width: 4),
            CoverArt(coverArtPath: track.coverArtPath, coverArtUrl: track.coverArtUrl, size: 40),
            const SizedBox(width: 12),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: isPlaying ? scheme.primary : null,
                      fontWeight: isPlaying ? FontWeight.w600 : null,
                    ),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (showAlbum)
              Expanded(
                flex: 4,
                child: Text(
                  track.album,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            if (track.isFavorite)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.favorite, size: 14, color: scheme.primary),
              ),
            SizedBox(
              width: 56,
              child: Text(
                formatSeconds(track.duration),
                textAlign: TextAlign.right,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            ?trailing,
            IconButton(
              tooltip: '更多',
              iconSize: 18,
              onPressed: () => _showMenu(context, ref),
              icon: const Icon(Icons.more_horiz),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context, WidgetRef ref, {Offset? position}) async {
    final RenderBox box = context.findRenderObject()! as RenderBox;
    final Offset origin = position ?? box.localToGlobal(Offset.zero);
    final String? selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(origin.dx, origin.dy, origin.dx, origin.dy),
      items: <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(value: 'play', child: Text('播放')),
        PopupMenuItem<String>(
          value: 'favorite',
          child: Text(track.isFavorite ? '取消收藏' : '收藏'),
        ),
        const PopupMenuItem<String>(value: 'playlist', child: Text('添加到播放列表…')),
        const PopupMenuItem<String>(value: 'match', child: Text('匹配元数据…')),
        if (track.filePathOrUrl.startsWith('/'))
          const PopupMenuItem<String>(value: 'reveal', child: Text('在访达中显示')),
      ],
    );
    if (selected == null || !context.mounted) {
      return;
    }
    switch (selected) {
      case 'play':
        onTap?.call();
      case 'favorite':
        await ref.read(trackRepositoryProvider).setFavorite(track.id, value: !track.isFavorite);
      case 'playlist':
        await showAddToPlaylistDialog(context, ref, <Track>[track]);
      case 'match':
        if (context.mounted) {
          await showManualMatchDialog(context, ref, track);
        }
      case 'reveal':
        await Process.run('open', <String>['-R', track.filePathOrUrl]);
    }
  }
}
