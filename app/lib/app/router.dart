import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../design/layout/app_shell.dart';
import '../features/albums/album_detail_page.dart';
import '../features/albums/albums_page.dart';
import '../features/artists/artist_detail_page.dart';
import '../features/artists/artists_page.dart';
import '../features/library/library_page.dart';
import '../features/library/library_view_state.dart';
import '../features/onboarding/onboarding_page.dart';
import '../features/player/lyrics_page.dart';
import '../features/player/now_playing_page.dart';
import '../features/player/queue_page.dart';
import '../features/playlists/playlist_page.dart';
import '../features/playlists/playlists_page.dart';
import '../features/search/search_page.dart';
import '../features/settings/ai_settings_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sources/source_page.dart';
import '../features/sources/sources_page.dart';
import 'providers.dart';

/// 应用路由（`docs/UX_REDESIGN.md` §3.3 的路由表）。
///
/// 唯一 `ShellRoute` 承载全部浏览页；`/stage`、`/queue`、`/lyrics`、`/onboarding`
/// 挂在它**之外**，因此天然覆盖外壳与播放条（不需要第二个外壳）。
///
/// 导航语义：根级目的地用 `go`（横切、不压栈），详情用 `push`，沉浸层 `push` 到根。
/// 旧路径（`/`、`/library`、`/recent`、`/albums`、`/artists`、`/playlists`、
/// `/now-playing`）**全部迁移、不保留别名**。
GoRouter createRouter({String initialLocation = '/library/songs'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            TyAppShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            path: '/library/songs',
            builder: (BuildContext context, GoRouterState state) => LibraryPage(
              routePath: '/library/songs',
              view: LibraryViewState.fromQuery(state.uri.queryParameters),
            ),
          ),
          GoRoute(
            path: '/library/albums',
            builder: (_, _) => const AlbumsPage(),
          ),
          GoRoute(
            path: '/library/artists',
            builder: (_, _) => const ArtistsPage(),
          ),
          GoRoute(
            path: '/library/playlists',
            builder: (_, _) => const PlaylistsPage(),
          ),
          GoRoute(
            path: '/favorites',
            builder: (BuildContext context, GoRouterState state) => LibraryPage(
              favoritesOnly: true,
              routePath: '/favorites',
              view: LibraryViewState.fromQuery(state.uri.queryParameters),
            ),
          ),
          GoRoute(path: '/search', builder: (_, _) => const SearchPage()),
          GoRoute(
            path: '/album/:name',
            // 专辑标识是 `artist + album`，所以专辑名走 path、艺术家走 query，
            // 数组以外的形态不做（沿用现有聚合键，不新增 id）。
            builder: (BuildContext context, GoRouterState state) =>
                AlbumDetailPage(
                  albumKey: AlbumKey(
                    album: state.pathParameters['name'] ?? '',
                    artist: state.uri.queryParameters['artist'] ?? '',
                  ),
                ),
          ),
          GoRoute(
            path: '/artist/:name',
            // go_router 18 已把 pathParameters 解码；再次 decodeComponent 会让中文名
            // 直接抛 Illegal percent encoding，表现为详情页空白。
            builder: (BuildContext context, GoRouterState state) =>
                ArtistDetailPage(artist: state.pathParameters['name'] ?? ''),
          ),
          GoRoute(
            path: '/playlist/:id',
            builder: (BuildContext context, GoRouterState state) =>
                PlaylistPage(playlistId: state.pathParameters['id'] ?? ''),
          ),
          GoRoute(
            path: '/source/:id',
            builder: (BuildContext context, GoRouterState state) =>
                SourcePage(sourceId: state.pathParameters['id'] ?? ''),
          ),
          GoRoute(path: '/sources', builder: (_, _) => const SourcesPage()),
          GoRoute(
            path: '/settings/:section',
            builder: (BuildContext context, GoRouterState state) =>
                SettingsPage(section: state.pathParameters['section']),
          ),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
          GoRoute(path: '/ai', builder: (_, _) => const AISettingsPage()),
        ],
      ),
      // ------------------------------------------------ 根 Navigator 的覆盖层
      GoRoute(path: '/stage', builder: (_, _) => const NowPlayingPage()),
      GoRoute(path: '/queue', builder: (_, _) => const QueuePage()),
      GoRoute(path: '/lyrics', builder: (_, _) => const LyricsPage()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingPage()),
    ],
    errorBuilder: (BuildContext context, GoRouterState state) =>
        Center(child: Text('页面不存在：${state.uri}')),
  );
}
