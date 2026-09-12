import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/albums/album_detail_page.dart';
import '../features/albums/albums_page.dart';
import '../features/artists/artist_detail_page.dart';
import '../features/artists/artists_page.dart';
import '../features/library/library_page.dart';
import '../features/player/now_playing_page.dart';
import '../features/playlists/playlist_page.dart';
import '../features/settings/settings_page.dart';
import '../features/shell/app_shell.dart';
import '../features/sources/source_page.dart';
import '../features/sources/sources_page.dart';
import 'providers.dart';

/// 应用路由。
///
/// 侧栏驱动的桌面外壳，路径同时承载"当前选中项"与未来的深链
/// （`tingyu://album/...` 这类由 App Intents 触发的跳转，M6 接）。
GoRouter createRouter({String initialLocation = '/library'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            AppShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            path: '/library',
            builder: (_, _) => const LibraryPage(),
          ),
          GoRoute(
            path: '/recent',
            builder: (_, _) => const LibraryPage(recentOnly: true),
          ),
          GoRoute(
            path: '/favorites',
            builder: (_, _) => const LibraryPage(favoritesOnly: true),
          ),
          GoRoute(
            path: '/artists',
            builder: (_, _) => const ArtistsPage(),
          ),
          GoRoute(
            path: '/artists/:name',
            builder: (_, GoRouterState state) => ArtistDetailPage(
              artist: Uri.decodeComponent(state.pathParameters['name'] ?? ''),
            ),
          ),
          GoRoute(
            path: '/albums',
            builder: (_, _) => const AlbumsPage(),
          ),
          GoRoute(
            path: '/albums/:artist/:album',
            builder: (_, GoRouterState state) => AlbumDetailPage(
              albumKey: AlbumKey(
                artist: Uri.decodeComponent(state.pathParameters['artist'] ?? ''),
                album: Uri.decodeComponent(state.pathParameters['album'] ?? ''),
              ),
            ),
          ),
          GoRoute(
            path: '/playlist/:id',
            builder: (_, GoRouterState state) => PlaylistPage(
              playlistId: state.pathParameters['id'] ?? '',
            ),
          ),
          GoRoute(
            path: '/source/:id',
            builder: (_, GoRouterState state) => SourcePage(
              sourceId: state.pathParameters['id'] ?? '',
            ),
          ),
          GoRoute(
            path: '/sources',
            builder: (_, _) => const SourcesPage(),
          ),
          GoRoute(
            path: '/settings',
            builder: (_, _) => const SettingsPage(),
          ),
          GoRoute(
            path: '/now-playing',
            builder: (_, _) => const NowPlayingPage(),
          ),
        ],
      ),
    ],
    errorBuilder: (BuildContext context, GoRouterState state) => Center(
      child: Text('页面不存在：${state.uri}'),
    ),
  );
}
