import '../../playback/playback_snapshot.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/playback_controller.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/models/library_query.dart';
import '../../data/models/search_page_result.dart';
import '../../design/components/command_palette.dart';
import '../../design/theme.dart';
import '../shared/add_to_playlist.dart';

/// `⌘K` 命令面板（`docs/UX_REDESIGN.md` §4.2）。
///
/// 与搜索页共用同一批只读查询（`searchSongsPageProvider` 一族），但**不写**
/// `searchQueryProvider`：侧栏输入框与搜索页共享那份状态，面板改了它就会出现
/// 「输入框里的字与结果对不上」。面板只在自己的弹层里打字。
Future<void> showSearchPalette(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: context.ty.colors.scrim,
    builder: (BuildContext dialogContext) => const _SearchPaletteDialog(),
  );
}

class _SearchPaletteDialog extends ConsumerStatefulWidget {
  const _SearchPaletteDialog();

  @override
  ConsumerState<_SearchPaletteDialog> createState() =>
      _SearchPaletteDialogState();
}

class _SearchPaletteDialogState extends ConsumerState<_SearchPaletteDialog> {
  String _text = '';
  String _debounced = '';
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _text = value);
    _timer?.cancel();
    _timer = Timer(searchDebounce, () {
      if (mounted) {
        setState(() => _debounced = value.trim());
      }
    });
  }

  void _close() => Navigator.of(context).maybePop();

  Future<void> _activate(TyPaletteEntry entry) async {
    final String? key = entry.key;
    if (key == null) {
      return;
    }
    if (key.startsWith('route:')) {
      final String route = key.substring('route:'.length);
      _close();
      if (route.startsWith('/playlist/') ||
          route.startsWith('/album/') ||
          route.startsWith('/artist/')) {
        context.push(route);
      } else {
        context.go(route);
      }
      return;
    }
    if (key.startsWith('track:')) {
      final String id = key.substring('track:'.length);
      final SearchPageResult<Track>? page = ref
          .read(
            searchSongsPageProvider(
              SearchPageRequest(text: _debounced, limit: paletteHitLimit),
            ),
          )
          .value;
      final List<Track> hits = page?.items ?? const <Track>[];
      final int index = hits.indexWhere((Track track) => track.id == id);
      if (index >= 0) {
        _close();
        await ref
            .read(playbackProvider.notifier)
            .playTracks(hits, startIndex: index);
      }
      return;
    }
    final PlaybackController controller = ref.read(playbackProvider.notifier);
    switch (key) {
      case 'media:playPause':
        _close();
        await controller.togglePlayPause();
      case 'media:next':
        _close();
        await controller.next();
      case 'media:previous':
        _close();
        await controller.previous();
      case 'media:stage':
        _close();
        context.push('/stage');
      case 'action:newPlaylist':
        _close();
        final String? name = await promptPlaylistName(
          context,
          title: '新建播放列表',
          confirmLabel: '创建',
        );
        if (name == null || name.trim().isEmpty || !mounted) {
          return;
        }
        final String id = 'pl-${DateTime.now().microsecondsSinceEpoch}';
        await ref
            .read(playlistRepositoryProvider)
            .create(id: id, name: name.trim());
        if (mounted) {
          context.push('/playlist/$id');
        }
    }
  }

  List<TyPaletteEntry> _entries() {
    final List<TyPaletteEntry> entries = <TyPaletteEntry>[];
    if (_debounced.isNotEmpty) {
      final SearchPageRequest request = SearchPageRequest(
        text: _debounced,
        limit: paletteHitLimit,
      );
      final List<Track> songs =
          ref.watch(searchSongsPageProvider(request)).value?.items ??
          const <Track>[];
      for (final Track track in songs) {
        entries.add(
          TyPaletteEntry(
            group: '歌曲',
            label: track.title,
            subtitle: track.artist,
            icon: Icons.music_note,
            key: 'track:${track.id}',
          ),
        );
      }
      final List<Playlist> playlists =
          ref.watch(searchPlaylistsPageProvider(request)).value?.items ??
          const <Playlist>[];
      for (final Playlist playlist in playlists) {
        entries.add(
          TyPaletteEntry(
            group: '歌单',
            label: playlist.name,
            icon: Icons.queue_music,
            key: 'route:/playlist/${playlist.id}',
          ),
        );
      }
    } else {
      final List<Track> recent =
          ref.watch(paletteRecentProvider).value ?? const <Track>[];
      for (final Track track in recent.take(paletteHitLimit)) {
        entries.add(
          TyPaletteEntry(
            group: '最近播放',
            label: track.title,
            subtitle: track.artist,
            icon: Icons.history,
            key: 'track:${track.id}',
          ),
        );
      }
    }
    final bool playing = ref.watch(
      playbackProvider.select((PlaybackSnapshot snapshot) => snapshot.playing),
    );
    entries.addAll(<TyPaletteEntry>[
      TyPaletteEntry(
        group: '快捷入口',
        label: playing ? '暂停' : '播放',
        icon: playing ? Icons.pause : Icons.play_arrow,
        hint: 'Space',
        key: 'media:playPause',
      ),
      const TyPaletteEntry(
        group: '快捷入口',
        label: '下一首',
        icon: Icons.skip_next,
        hint: '⌘→',
        key: 'media:next',
      ),
      const TyPaletteEntry(
        group: '快捷入口',
        label: '上一首',
        icon: Icons.skip_previous,
        hint: '⌘←',
        key: 'media:previous',
      ),
      const TyPaletteEntry(
        group: '快捷入口',
        label: '打开播放舞台',
        icon: Icons.album,
        hint: '⌘⇧P',
        key: 'media:stage',
      ),
      const TyPaletteEntry(
        group: '快捷入口',
        label: '曲库',
        icon: Icons.library_music_outlined,
        hint: '⌘1',
        key: 'route:/library/songs',
      ),
      const TyPaletteEntry(
        group: '快捷入口',
        label: '收藏',
        icon: Icons.favorite_border,
        hint: '⌘3',
        key: 'route:/favorites',
      ),
      const TyPaletteEntry(
        group: '快捷入口',
        label: '来源',
        icon: Icons.cloud_outlined,
        key: 'route:/sources',
      ),
      const TyPaletteEntry(
        group: '快捷入口',
        label: '设置',
        icon: Icons.settings_outlined,
        hint: '⌘,',
        key: 'route:/settings',
      ),
      const TyPaletteEntry(
        group: '快捷入口',
        label: '新建歌单',
        icon: Icons.add,
        hint: '⌘N',
        key: 'action:newPlaylist',
      ),
    ]);
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final List<TyPaletteEntry> entries = _entries();
    final bool loading = _text.trim() != _debounced;
    return TyCommandPalette(
      entries: entries,
      loading: loading,
      onQueryChanged: _onQueryChanged,
      onSelected: _activate,
      onClosed: _close,
    );
  }
}

/// 面板每组最多几条（规范：每组最多 5 条，页内「查看全部」到搜索页）。
const int paletteHitLimit = 5;
