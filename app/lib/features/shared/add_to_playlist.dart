import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../design/components/buttons.dart';
import '../../design/components/dialogs.dart';
import '../../design/components/inputs.dart';
import '../../design/components/track.dart';
import '../../design/theme.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tokens/metrics.dart';

/// 「添加到播放列表…」：列出已有播放列表，或就地新建一个。
///
/// 曲目批量加入时保持传入顺序（追加到列表末尾）。
Future<void> showAddToPlaylistDialog(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks,
) async {
  if (tracks.isEmpty) {
    return;
  }
  final List<Playlist> playlists = await ref
      .read(playlistRepositoryProvider)
      .all();
  if (!context.mounted) {
    return;
  }

  final String? chosen = await showTyDialog<String>(
    context,
    child: TyDialog(
      title: '将 ${tracks.length} 首加入播放列表',
      actions: <Widget>[
        TyButton(
          label: '取消',
          variant: TyButtonVariant.secondary,
          dense: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
      child: Builder(
        builder: (BuildContext dialogContext) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final Playlist playlist in playlists)
              _OptionRow(
                label: playlist.name,
                icon: Icons.queue_music,
                onTap: () => Navigator.pop(dialogContext, playlist.id),
              ),
            const TyDividerThin(),
            _OptionRow(
              label: '新建播放列表…',
              icon: Icons.add,
              onTap: () => Navigator.pop(dialogContext, _createNewSentinel),
            ),
          ],
        ),
      ),
    ),
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
    final String name =
        await promptPlaylistName(
          context,
          title: '新建播放列表',
          confirmLabel: '创建',
        ) ??
        '';
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
  final TextEditingController controller = TextEditingController(
    text: initial,
  );
  final String? result = await showTyDialog<String>(
    context,
    child: _PlaylistNameDialog(
      title: title,
      confirmLabel: confirmLabel,
      controller: controller,
    ),
  );
  controller.dispose();
  return result;
}

/// 命名表单：宽度/圆角/字段错误样式全部来自 `TyDialog` + `TyTextField`。
class _PlaylistNameDialog extends StatelessWidget {
  const _PlaylistNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.controller,
  });

  final String title;
  final String confirmLabel;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TyDialog(
      title: title,
      form: true,
      actions: <Widget>[
        TyButton(
          label: '取消',
          variant: TyButtonVariant.secondary,
          dense: true,
          onPressed: () => Navigator.pop(context),
        ),
        TyButton(
          label: confirmLabel,
          dense: true,
          onPressed: () => Navigator.pop(context, controller.text),
        ),
      ],
      child: TyTextField(
        controller: controller,
        label: '名称',
        autofocus: true,
        onSubmitted: (String value) => Navigator.pop(context, value),
      ),
    );
  }
}

/// 弹窗里的可选项行：图标 + 名称 + 整行点击（不用 `SimpleDialogOption`，
/// 因为它用的是 Material 默认排版）。
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(TyRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: TySpace.x12,
            vertical: TySpace.x12,
          ),
          child: Row(
            children: <Widget>[
              Icon(icon, size: TyIconSize.compact, color: ty.colors.textSecondary),
              const SizedBox(width: TySpace.x12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ty.typography.bodyM.copyWith(
                    color: ty.colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
