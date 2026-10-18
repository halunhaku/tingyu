import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../playback/playback_snapshot.dart';
import '../../features/player/mini_player.dart';
import '../../features/player/player_bar.dart';
import '../../features/search/search_palette.dart';
import '../../features/shared/add_to_playlist.dart';
import '../components/buttons.dart';
import '../components/feedback.dart';
import '../components/chips.dart';
import '../components/navigation.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/tokens.dart';
import 'form_factor.dart';

/// 唯一应用外壳（`DESIGN.md` §5）。
///
/// - expanded：展开侧栏 + 内容 + 桌面播放条；
/// - medium：图标 rail + 内容 + 桌面播放条；
/// - compact：内容 + 迷你播放条 + 底部 Tab。
///
/// 结构只由窗口宽度决定；平台只影响交互能力（hover/右键/快捷键）。
class TyAppShell extends ConsumerStatefulWidget {
  const TyAppShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TyAppShell> createState() => _TyAppShellState();
}

class _TyAppShellState extends ConsumerState<TyAppShell> {
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode(debugLabel: '侧栏搜索');

  /// 首次引导只判一次：库已加载 ∧ 无来源 ∧ 无曲目 → `/onboarding`。
  bool _onboardingEvaluated = false;
  ProviderSubscription<AsyncValue<List<MusicSource>>>? _sourcesSub;
  ProviderSubscription<AsyncValue<List<Track>>>? _tracksSub;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(searchQueryProvider),
    );
    // 只在「库与来源都读完、且都为空」时引导一次；用 listenManual 是为了不把
    // 整个外壳挂到全库曲目流上（那样每次入库都会重建外壳）。
    _sourcesSub = ref.listenManual<AsyncValue<List<MusicSource>>>(
      sourcesProvider,
      (_, _) => _evaluateOnboarding(),
    );
    _tracksSub = ref.listenManual<AsyncValue<List<Track>>>(
      allTracksProvider,
      (_, _) => _evaluateOnboarding(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _evaluateOnboarding());
  }

  /// 空库且无来源 → 送到首次引导（`docs/UX_REDESIGN.md` §3.3）。
  ///
  /// 判过一次就结束：用户从引导页回到曲库、或刻意清空来源，都不该被反复弹回。
  void _evaluateOnboarding() {
    if (!mounted || _onboardingEvaluated) {
      return;
    }
    final AsyncValue<List<MusicSource>> sources = ref.read(sourcesProvider);
    final AsyncValue<List<Track>> tracks = ref.read(allTracksProvider);
    if (!sources.hasValue || !tracks.hasValue) {
      return;
    }
    _onboardingEvaluated = true;
    if (sources.value!.isNotEmpty || tracks.value!.isNotEmpty) {
      return;
    }
    final GoRouterState state = GoRouterState.of(context);
    if (state.uri.path != '/library/songs' ||
        state.uri.queryParameters.isNotEmpty) {
      return;
    }
    context.go('/onboarding');
  }

  static const List<TyNavDestination> _primary = <TyNavDestination>[
    TyNavDestination(
      label: '歌曲',
      icon: Icons.music_note_outlined,
      selectedIcon: Icons.music_note,
      route: '/library/songs',
    ),
    TyNavDestination(
      label: '专辑',
      icon: Icons.album_outlined,
      selectedIcon: Icons.album,
      route: '/library/albums',
    ),
    TyNavDestination(
      label: '艺术家',
      icon: Icons.person_outline,
      selectedIcon: Icons.person,
      route: '/library/artists',
    ),
    TyNavDestination(
      label: '歌单',
      icon: Icons.queue_music_outlined,
      selectedIcon: Icons.queue_music,
      route: '/library/playlists',
    ),
  ];

  /// rail（medium）的底部固定入口：收藏与设置。
  ///
  /// rail 很窄，放不下「曲库」之外的所有目的地；把收藏钉在底部（与设置同一组）
  /// 比让它排在列表里更稳，也更像「一级目的地 + 常用入口」。
  /// 「最近添加」按规范是排序而不是目的地，入口留在歌曲页的排序菜单里。
  static const List<TyNavDestination> _railFooter = <TyNavDestination>[
    TyNavDestination(
      label: '收藏',
      icon: Icons.favorite_border,
      selectedIcon: Icons.favorite,
      route: '/favorites',
    ),
    TyNavDestination(
      label: '设置',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      route: '/settings',
    ),
  ];

  /// compact 的四个根 Tab（`docs/UX_REDESIGN.md` §3.2）：曲库 / 搜索 / 收藏 / 我的。
  static const List<TyNavDestination> _tabs = <TyNavDestination>[
    TyNavDestination(
      label: '曲库',
      icon: Icons.library_music_outlined,
      selectedIcon: Icons.library_music,
      route: '/library/songs',
    ),
    TyNavDestination(
      label: '搜索',
      icon: Icons.search,
      selectedIcon: Icons.search,
      route: '/search',
    ),
    TyNavDestination(
      label: '收藏',
      icon: Icons.favorite_border,
      selectedIcon: Icons.favorite,
      route: '/favorites',
    ),
    TyNavDestination(
      label: '我的',
      icon: Icons.account_circle_outlined,
      selectedIcon: Icons.account_circle,
      route: '/settings',
    ),
  ];

  /// 曲库四段的 slug 与顺序（compact 顶部分段控件用）。
  static const List<(String, String)> _librarySections = <(String, String)>[
    ('songs', '歌曲'),
    ('albums', '专辑'),
    ('artists', '艺术家'),
    ('playlists', '歌单'),
  ];

  /// 这些路径在 compact 下保留底部 Tab（都是 Tab 的根或根的下一层）。
  static const Set<String> _tabRoots = <String>{
    '/library/songs',
    '/library/albums',
    '/library/artists',
    '/library/playlists',
    '/search',
    '/favorites',
    '/settings',
    '/sources',
  };

  static const TyNavDestination _settings = TyNavDestination(
    label: '设置',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    route: '/settings',
  );

  @override
  void dispose() {
    _sourcesSub?.close();
    _tracksSub?.close();
    _searchFocus.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _navigate(String route) => context.go(route);

  void _openPalette() => showSearchPalette(context);

  /// `⌘F`：compact 跳到搜索 Tab（本页自带输入框），桌面聚焦侧栏搜索框。
  void _focusSearch() {
    if (context.formFactor == FormFactor.compact) {
      _navigate('/search');
      return;
    }
    _searchFocus.requestFocus();
  }

  /// 快捷键绑定的动作表（`docs/UX_REDESIGN.md` §6）。
  ///
  /// 输入态判断放在动作里而不是绑定里：`Space` 在输入框里必须是空格，
  /// 不能变成播放/暂停（修 I2 的同类问题）。
  /// macOS 用 `⌘`、Windows/Linux 用 `Ctrl`，两边都绑（平台只影响映射，不影响结构）。
  Map<ShortcutActivator, VoidCallback> _shortcuts() {
    final Map<ShortcutActivator, VoidCallback> bindings =
        <ShortcutActivator, VoidCallback>{};
    void both(
      LogicalKeyboardKey key,
      VoidCallback action, {
      bool shift = false,
    }) {
      bindings[SingleActivator(key, meta: true, shift: shift)] = action;
      bindings[SingleActivator(key, control: true, shift: shift)] = action;
    }

    both(LogicalKeyboardKey.keyK, _openPalette);
    both(LogicalKeyboardKey.keyF, _focusSearch);
    both(LogicalKeyboardKey.comma, () => _navigate('/settings'));
    both(LogicalKeyboardKey.digit1, () => _navigate('/library/songs'));
    both(LogicalKeyboardKey.digit2, () => _navigate('/search'));
    both(LogicalKeyboardKey.digit3, () => _navigate('/favorites'));
    both(LogicalKeyboardKey.digit4, () => _navigate('/sources'));
    both(LogicalKeyboardKey.keyN, _createPlaylist);
    both(LogicalKeyboardKey.keyP, () => context.push('/stage'), shift: true);
    both(LogicalKeyboardKey.keyL, () => context.push('/lyrics'));
    both(LogicalKeyboardKey.keyU, () => context.push('/queue'));
    both(LogicalKeyboardKey.arrowRight, _nextTrack);
    both(LogicalKeyboardKey.arrowLeft, _previousTrack);
    both(
      LogicalKeyboardKey.arrowRight,
      () => _seekBy(const Duration(seconds: 10)),
      shift: true,
    );
    both(
      LogicalKeyboardKey.arrowLeft,
      () => _seekBy(const Duration(seconds: -10)),
      shift: true,
    );
    both(LogicalKeyboardKey.arrowUp, _volumeUp);
    both(LogicalKeyboardKey.arrowDown, _volumeDown);
    bindings[const SingleActivator(LogicalKeyboardKey.space)] = _togglePlayback;
    return bindings;
  }

  /// 焦点是否在文本输入里：在输入框里按 `Space`/方向键必须是「打字」。
  bool get _typingHere {
    final BuildContext? focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null) {
      return false;
    }
    return focus.widget is EditableText ||
        focus.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _togglePlayback() {
    if (_typingHere) {
      return;
    }
    ref.read(playbackProvider.notifier).togglePlayPause();
  }

  void _nextTrack() {
    if (_typingHere) {
      return;
    }
    ref.read(playbackProvider.notifier).next();
  }

  void _previousTrack() {
    if (_typingHere) {
      return;
    }
    ref.read(playbackProvider.notifier).previous();
  }

  void _seekBy(Duration delta) {
    if (_typingHere) {
      return;
    }
    final PlaybackSnapshot snapshot = ref.read(playbackProvider);
    final Duration target = snapshot.position + delta;
    final Duration clamped = target < Duration.zero
        ? Duration.zero
        : (snapshot.duration > Duration.zero && target > snapshot.duration
              ? snapshot.duration
              : target);
    ref.read(playbackProvider.notifier).seek(clamped);
  }

  void _volumeUp() => _setVolume(ref.read(playbackProvider).volume + 0.05);

  void _volumeDown() => _setVolume(ref.read(playbackProvider).volume - 0.05);

  void _setVolume(double value) {
    if (_typingHere) {
      return;
    }
    ref.read(playbackProvider.notifier).setVolume(value.clamp(0, 1));
  }

  void _onSearchChanged(String value) {
    ref.read(searchQueryProvider.notifier).set(value);
    final String path = GoRouterState.of(context).uri.path;
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      if (path == '/search') {
        context.go('/library/songs');
      }
      return;
    }
    if (path != '/search') {
      context.go('/search?q=${Uri.encodeQueryComponent(trimmed)}');
    }
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(searchQueryProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    final TyTokens ty = context.ty;
    if (size.width < TyLayoutScope.minWindowSize.width ||
        size.height < TyLayoutScope.minWindowSize.height) {
      return Scaffold(
        backgroundColor: ty.colors.canvas,
        body: TyErrorView(
          title: '窗口过小',
          detail:
              '请将窗口放大到至少 '
              '${TyLayoutScope.minWindowSize.width.toInt()} × '
              '${TyLayoutScope.minWindowSize.height.toInt()}。',
        ),
      );
    }

    final String path = GoRouterState.of(context).uri.path;
    final Widget shell = switch (context.formFactor) {
      FormFactor.compact => _buildCompact(path),
      FormFactor.medium || FormFactor.expanded => _buildDesktop(path),
    };
    // `CallbackShortcuts` 只在「焦点在它子树里」时收到按键，而列表滚动后焦点可能
    // 落回根 scope；所以外面套一个 autofocus 的 `Focus` 兜底（它不参与 Tab 遍历，
    // 输入框一旦聚焦就能正常抢走按键）。
    return CallbackShortcuts(
      bindings: _shortcuts(),
      child: Focus(autofocus: true, skipTraversal: true, child: shell),
    );
  }

  Widget _buildCompact(String path) {
    final TyTokens ty = context.ty;
    // 舞台位于根 Navigator，compact 下不会经过这里；保留判断是为了
    // 「外壳里嵌了播放页」这种半屏分栏形态也不出错。
    final bool fullBleed = path == '/stage';
    // 详情页（专辑/艺人/歌单/来源详情…）只留迷你播放条：底 Tab 让位给返回路径。
    final bool showTabs = _tabRoots.contains(path);
    final int section = _librarySections.indexWhere(
      ((String, String) entry) => entry.$1 == path.split('/').last,
    );
    return Scaffold(
      backgroundColor: ty.colors.canvas,
      body: SafeArea(
        top: !fullBleed,
        bottom: false,
        child: Column(
          children: <Widget>[
            // 曲库四段在 compact 合成一页：分段控件取代侧栏的「曲库」分组。
            if (path.startsWith('/library/') && section >= 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  TySpace.x16,
                  TySpace.x12,
                  TySpace.x16,
                  0,
                ),
                child: TySegmentedControl(
                  // 窄屏的分段切换铺满：它就是这一层的导航，留白反而像漏画。
                  maxWidth: null,
                  segments: <String>[
                    for (final (String, String) entry in _librarySections)
                      entry.$2,
                  ],
                  index: section,
                  onChanged: (int index) =>
                      _navigate('/library/${_librarySections[index].$1}'),
                ),
              ),
            Expanded(child: widget.child),
          ],
        ),
      ),
      bottomNavigationBar: fullBleed
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const MiniPlayer(),
                if (showTabs)
                  TyBottomNav(
                    destinations: _tabs,
                    selectedIndex: _selectedTab(path),
                    onSelected: (int index) => _navigate(_tabs[index].route),
                  ),
              ],
            ),
    );
  }

  Widget _buildDesktop(String path) {
    final TyTokens ty = context.ty;
    final bool expanded = context.formFactor == FormFactor.expanded;
    final Widget navigation = expanded
        ? TySidebar(
            width: context.metrics.sidebarWidth,
            searchController: _searchController,
            searchFocusNode: _searchFocus,
            searchHint: '搜索歌曲、专辑、艺术家',
            onSearchChanged: _onSearchChanged,
            onClearSearch: _clearSearch,
            sections: _sidebarSections(path),
            selectedRoute: path,
            onNavigate: _navigate,
            footer: const <TyNavDestination>[_settings],
          )
        : TyNavRail(
            destinations: _primary,
            selectedRoute: path,
            onNavigate: _navigate,
            footer: _railFooter,
          );
    return Scaffold(
      backgroundColor: ty.colors.canvas,
      body: Row(
        children: <Widget>[
          navigation,
          VerticalDivider(width: 1, thickness: 1, color: ty.colors.border),
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Padding(
                    // 给悬浮播放条让出空间（它自己还带 12 的底边距）。
                    padding: EdgeInsets.only(
                      bottom: context.metrics.transportHeight + TySpace.x8,
                    ),
                    child: widget.child,
                  ),
                ),
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: PlayerBar(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<TySidebarSection> _sidebarSections(String path) {
    final AsyncValue<List<MusicSource>> sources = ref.watch(sourcesProvider);
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);
    return <TySidebarSection>[
      const TySidebarSection(destinations: _primary),
      TySidebarSection(
        title: '来源',
        destinations: <TyNavDestination>[
          for (final MusicSource source
              in sources.value ?? const <MusicSource>[])
            TyNavDestination(
              label: source.name,
              icon: switch (source.kind) {
                'webdav' => Icons.cloud_outlined,
                'quark' => Icons.cloud_queue,
                _ => Icons.folder_outlined,
              },
              route: '/source/${source.id}',
              detail: '${source.trackCount}',
            ),
        ],
        hint: switch (sources) {
          AsyncLoading<List<MusicSource>>() => '正在读取来源…',
          AsyncError<List<MusicSource>>() => '来源读取失败',
          _ =>
            (sources.value ?? const <MusicSource>[]).isEmpty ? '尚未添加来源' : null,
        },
        action: sources.hasError
            ? TyIconAction(
                icon: Icons.refresh,
                semanticLabel: '重试读取来源',
                tooltip: '重试',
                size: TyIconSize.inline,
                onPressed: () => ref.invalidate(sourcesProvider),
              )
            : null,
      ),
      TySidebarSection(
        title: '播放列表',
        destinations: <TyNavDestination>[
          for (final Playlist playlist in playlists.value ?? const <Playlist>[])
            TyNavDestination(
              label: playlist.name,
              icon: Icons.queue_music,
              route: '/playlist/${playlist.id}',
            ),
        ],
        hint: switch (playlists) {
          AsyncLoading<List<Playlist>>() => '正在读取播放列表…',
          AsyncError<List<Playlist>>() => '播放列表读取失败',
          _ =>
            (playlists.value ?? const <Playlist>[]).isEmpty ? '尚未创建播放列表' : null,
        },
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (playlists.hasError)
              TyIconAction(
                icon: Icons.refresh,
                semanticLabel: '重试读取播放列表',
                tooltip: '重试',
                size: TyIconSize.inline,
                onPressed: () => ref.invalidate(playlistsProvider),
              ),
            TyIconAction(
              icon: Icons.add,
              semanticLabel: '新建播放列表',
              tooltip: '新建播放列表',
              size: TyIconSize.inline,
              onPressed: _createPlaylist,
            ),
          ],
        ),
      ),
    ];
  }

  Future<void> _createPlaylist() async {
    final String? name = await promptPlaylistName(
      context,
      title: '新建播放列表',
      confirmLabel: '创建',
    );
    if (name == null || name.trim().isEmpty) {
      return;
    }
    final String id = 'pl-${DateTime.now().microsecondsSinceEpoch}';
    await ref
        .read(playlistRepositoryProvider)
        .create(id: id, name: name.trim());
    if (mounted) {
      _navigate('/playlist/$id');
    }
  }

  static int _selectedTab(String path) {
    if (path.startsWith('/library/')) {
      return 0;
    }
    if (path.startsWith('/playlist')) {
      return 0;
    }
    if (path.startsWith('/search')) {
      return 1;
    }
    if (path.startsWith('/favorites')) {
      return 2;
    }
    if (path.startsWith('/settings') ||
        path.startsWith('/sources') ||
        path.startsWith('/ai')) {
      return 3;
    }
    return 0;
  }
}
