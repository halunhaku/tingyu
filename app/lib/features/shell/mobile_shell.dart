import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../player/mini_player.dart';

/// 移动端外壳：内容区 + 悬浮在底部 Tab 栏之上的迷你播放条。
///
/// 对应旧版 `Sources/UI/iOS/IOSContentView.swift` 的 `TabView`：曲库 / 收藏 /
/// 歌单 / 音乐源 四个分区，迷你条固定在 Tab 栏正上方。选中态由当前路由路径推导，
/// 因此二级页面（专辑、艺术家、来源详情…）仍保留 Tab 栏。
class MobileShell extends ConsumerWidget {
  const MobileShell({super.key, required this.child});

  final Widget child;

  static const List<_MobileTab> _tabs = <_MobileTab>[
    _MobileTab(path: '/library', label: '曲库', icon: Icons.library_music),
    _MobileTab(path: '/favorites', label: '收藏', icon: Icons.favorite),
    _MobileTab(path: '/playlists', label: '歌单', icon: Icons.queue_music),
    _MobileTab(path: '/sources', label: '音乐源', icon: Icons.cloud),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String path = GoRouterState.of(context).uri.path;

    return Scaffold(
      body: SafeArea(bottom: false, child: child),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: _selectedIndex(path),
            onDestinationSelected: (int index) => context.go(_tabs[index].path),
            destinations: <Widget>[
              for (final _MobileTab tab in _tabs)
                NavigationDestination(icon: Icon(tab.icon), label: tab.label),
            ],
          ),
        ],
      ),
    );
  }

  /// 当前路径对应的 Tab 下标。
  ///
  /// `/playlist/:id` 与 Tab 路径 `/playlists` 不同名，归入「歌单」分区；
  /// 专辑 / 艺术家 / 正在播放 / 设置 / 来源详情等页面不匹配任何 Tab，
  /// 退回曲库（0），Tab 栏保持可见。
  static int _selectedIndex(String path) {
    final String normalized = path.startsWith('/playlist/') ? '/playlists' : path;
    for (int i = 0; i < _tabs.length; i++) {
      final String tabPath = _tabs[i].path;
      if (normalized == tabPath || normalized.startsWith('$tabPath/')) {
        return i;
      }
    }
    return 0;
  }
}

class _MobileTab {
  const _MobileTab({required this.path, required this.label, required this.icon});

  final String path;

  final String label;

  final IconData icon;
}
