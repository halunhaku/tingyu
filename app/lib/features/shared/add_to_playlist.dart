import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';

/// 「添加到播放列表…」：列出已有播放列表，或就地新建一个。
///
/// 曲目批量加入时保持传入顺序（追加到列表末尾）。
Future<void> showAddToPlaylistDialog(BuildContext context, WidgetRef ref, List<Track> tracks) async {
  if (tracks.isEmpty) {
    return;
  }
  final List<Playlist> playlists = await ref.read(playlistRepositoryProvider).all();
  if (!context.mounted) {
    return;
  }

  final String? chosen = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) {
      return SimpleDialog(
        title: Text('将 ${tracks.length} 首加入播放列表'),
        children: <Widget>[
          for (final Playlist playlist in playlists)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, playlist.id),
              child: Text(playlist.name),
            ),
          const Divider(height: 1),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, _createNewSentinel),
            child: const Text('新建播放列表…'),
          ),
        ],
      );
    },
  );
  if (chosen == null) {
    return;
  }

  final playlistRepository = ref.read(playlistRepositoryProvider);
  String playlistId = chosen;
  if (chosen == _createNewSentinel) {
    if (!context.mounted) {
      return;
    }
    final String name = await promptPlaylistName(context, title: '新建播放列表', confirmLabel: '创建') ?? '';
    if (name.trim().isEmpty) {
      return;
    }
    playlistId = 'pl-${DateTime.now().microsecondsSinceEpoch}';
    await playlistRepository.create(id: playlistId, name: name.trim());
  }

  for (final Track track in tracks) {
    await playlistRepository.addTrack(playlistId, track.id);
  }
  ref.invalidate(playlistTracksProvider(playlistId));
}

const String _createNewSentinel = '__create_new__';

/// 播放列表命名/改名弹窗；取消返回 null。
Future<String?> promptPlaylistName(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initial = '',
}) async {
  final TextEditingController controller = TextEditingController(text: initial);
  final String? result = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
          onSubmitted: (String value) => Navigator.pop(dialogContext, value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  controller.dispose();
  return result;
}
