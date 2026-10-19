import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/context_menu.dart';
import '../../design/components/feedback.dart';
import '../library/manual_match_dialog.dart';
import 'add_to_playlist.dart';

/// 曲目动作的唯一实现处。
///
/// 队列语义归宿主（只有它知道「这一列表是什么」），所以这里只收 `onPlay`；
/// 收藏、加入歌单、匹配元数据、在文件管理器中显示全应用一份，
/// 桌面右键与触控长按走同一份菜单，不各写一套。
Future<void> toggleTrackFavorite(WidgetRef ref, Track track) {
  ref
      .read(trackRepositoryProvider)
      .setFavorite(track.id, value: !track.isFavorite);
  return Future<void>.value();
}

/// 弹出曲目菜单；[position] 为空时用触发行的左上角（⋯ 按钮场景）。
Future<void> showTrackMenu(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  Offset? position,
  VoidCallback? onPlay,
  String? removeLabel,
  Future<void> Function()? onRemove,
}) async {
  final RenderBox? box = context.findRenderObject() as RenderBox?;
  final Offset origin =
      position ?? box?.localToGlobal(Offset.zero) ?? Offset.zero;
  await TyContextMenu.show(
    context,
    position: origin,
    actions: <TyMenuAction>[
      if (onPlay != null)
        TyMenuAction(
          label: '播放',
          icon: Icons.play_arrow_outlined,
          onSelected: onPlay,
        ),
      TyMenuAction(
        label: track.isFavorite ? '取消收藏' : '收藏',
        icon: track.isFavorite
            ? Icons.favorite_outline
            : Icons.favorite_border,
        onSelected: () => toggleTrackFavorite(ref, track),
      ),
      TyMenuAction(
        label: '添加到播放列表…',
        icon: Icons.playlist_add,
        onSelected: () => showAddToPlaylistDialog(context, ref, <Track>[track]),
      ),
      TyMenuAction(
        label: '匹配元数据…',
        icon: Icons.auto_fix_high_outlined,
        onSelected: () => showManualMatchDialog(context, ref, track),
      ),
      if (onRemove != null)
        TyMenuAction(
          label: removeLabel ?? '移除',
          icon: Icons.remove_circle_outline,
          destructive: true,
          onSelected: () => onRemove(),
        ),
      if (_isLocalFile(track))
        TyMenuAction(
          label: _revealLabel(),
          icon: Icons.folder_open,
          onSelected: () => _revealInFileManager(context, track),
        ),
    ],
  );
}

bool _isLocalFile(Track track) => track.filePathOrUrl.startsWith('/');

String _revealLabel() {
  if (Platform.isMacOS) {
    return '在访达中显示'; // guard-ok: 菜单文案按宿主平台命名文件管理器
  }
  if (Platform.isWindows) {
    return '在资源管理器中显示'; // guard-ok: 菜单文案按宿主平台命名文件管理器
  }
  return '在文件管理器中显示';
}

Future<void> _revealInFileManager(BuildContext context, Track track) async {
  final String path = track.filePathOrUrl;
  try {
    if (Platform.isMacOS) {
      // guard-ok: 只有宿主平台知道「在文件管理器中显示」对应哪个命令
      await Process.run('open', <String>['-R', path]);
    } else if (Platform.isWindows) {
      // guard-ok: 同上，explorer 的选中语义在不同平台完全不同
      await Process.run('explorer', <String>['/select,', path]);
    } else {
      // Linux 桌面没有 open -R；xdg-open 目录即文件管理器。
      await Process.run('xdg-open', <String>[File(path).parent.path]);
    }
  } on Object catch (error) {
    debugPrint('[library] 打开文件管理器失败: $error');
    if (context.mounted) {
      TySnack.show(context, '无法打开文件管理器');
    }
  }
}

/// 行左上角的全局坐标：右键/⋯ 菜单的锚点。
///
/// `TyTrackTable` / `TyTrackList` 的内置行与宿主自建的行（`PlaybackTrackRow`）
/// 都从这里取同一个算法，菜单落点不会因为「谁建的行」而变化。
Offset rowOrigin(BuildContext rowContext) {
  final RenderObject? box = rowContext.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    return box.localToGlobal(Offset.zero);
  }
  return Offset.zero;
}
