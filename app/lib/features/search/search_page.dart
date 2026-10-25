import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/models/library_query.dart';
import '../../data/models/library_summaries.dart';
import '../../data/models/search_overview.dart';
import '../../data/models/search_page_result.dart';
import '../../design/components/album_card.dart';
import '../../design/components/artist_row.dart';
import '../../design/components/buttons.dart';
import '../../design/components/chips.dart';
import '../../design/components/feedback.dart';
import '../../design/components/inputs.dart';
import '../../design/components/playlist_card.dart';
import '../../design/components/structure.dart';
import '../../design/components/track.dart';
import '../../design/layout/form_factor.dart';
import '../../design/theme.dart';
import '../../design/tokens/metrics.dart';
import '../../design/tokens/tokens.dart';
import '../shared/playback_track_row.dart';
import '../shared/track_actions.dart';
import 'search_scope.dart';

/// 全局搜索（`docs/UX_REDESIGN.md` §5.5）。
///
/// - 桌面入口是侧栏搜索框与 `⌘K`；compact 由搜索 Tab 进入，页面自带输入框并自动聚焦。
/// - 本页只读 `debouncedSearchQueryProvider`；输入框与 URL 的 `?q=` 同步，
///   深链（`tingyu://search?q=…`）与刷新都能复原同一次搜索。
/// - 分段 `?scope=`：全部 / 歌曲 / 专辑 / 艺术家 / 歌单。「全部」按组露出前 5 条，
///   每组给真实总数与「查看全部」；分范围视图按 40 条一页继续取。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _fieldFocus = FocusNode(debugLabel: '搜索输入');

  /// 当前范围的分页页数；换词/换范围时归 1。
  int _pages = 1;
  String _pagingKey = '';

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(searchQueryProvider);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // URL → provider：只有深链/前进后退才会不一致，正常输入两者恒等。
    final String fromUrl =
        GoRouterState.of(context).uri.queryParameters['q']?.trim() ?? '';
    if (fromUrl != ref.read(searchQueryProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        ref.read(searchQueryProvider.notifier).set(fromUrl);
        _controller.text = fromUrl;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _writeUrl({required String query, required SearchScope scope}) {
    final String trimmed = query.trim();
    final Map<String, String> params = <String, String>{
      'q': ?(trimmed.isEmpty ? null : trimmed),
      if (scope != SearchScope.all) 'scope': scope.slug,
    };
    final String encoded = Uri(queryParameters: params).query;
    context.go(encoded.isEmpty ? '/search' : '/search?$encoded');
  }

  void _onQueryChanged(String value) {
    ref.read(searchQueryProvider.notifier).set(value);
    _writeUrl(query: value, scope: _scope);
  }

  void _onSubmitted(String value) {
    if (value.trim().isEmpty) {
      return;
    }
    ref.read(recentSearchesProvider.notifier).remember(value);
    _playBestHit();
  }

  void _clear() {
    _controller.clear();
    ref.read(searchQueryProvider.notifier).clear();
    _writeUrl(query: '', scope: _scope);
  }

  SearchScope get _scope => SearchScope.fromSlug(
    GoRouterState.of(context).uri.queryParameters['scope'],
  );

  /// 回车 = 播放最佳命中（`docs/UX_REDESIGN.md` §4.1）。
  Future<void> _playBestHit() async {
    final SearchOverview overview = await ref.read(
      searchOverviewProvider.future,
    );
    final List<Track> hits = overview.songs.items;
    if (hits.isEmpty) {
      return;
    }
    await ref.read(playbackProvider.notifier).playTracks(hits, startIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    final TyMetrics metrics = context.metrics;
    final SearchScope scope = _scope;
    final String immediate = ref.watch(searchQueryProvider);
    final String query = ref.watch(debouncedSearchQueryProvider).trim();

    // 换词或换范围 → 分页回到第一页。
    final String pagingKey = '$query|${scope.slug}';
    if (pagingKey != _pagingKey) {
      _pagingKey = pagingKey;
      _pages = 1;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.pagePadding,
            TySpace.x20,
            metrics.pagePadding,
            TySpace.x12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TyPageHeader(
                title: '搜索',
                subtitle: immediate.trim().isEmpty
                    ? null
                    : '“${immediate.trim()}”',
                actions: <Widget>[
                  if (immediate.trim().isNotEmpty)
                    TyIconAction(
                      icon: Icons.close,
                      semanticLabel: '清除搜索',
                      tooltip: '清除',
                      onPressed: _clear,
                    ),
                ],
              ),
              // compact 没有侧栏搜索框：本页自带，进入即聚焦（单手一步到位）。
              if (context.formFactor.isCompact) ...<Widget>[
                const SizedBox(height: TySpace.x12),
                TySearchField(
                  controller: _controller,
                  focusNode: _fieldFocus,
                  autofocus: true,
                  onChanged: _onQueryChanged,
                  onSubmitted: _onSubmitted,
                  onClear: _clear,
                ),
              ],
              const SizedBox(height: TySpace.x12),
              // 宽度上限由 `TySegmentedControl.maxWidth` 统一给（窄屏会铺满）。
              TySegmentedControl(
                segments: <String>[
                  for (final SearchScope item in SearchScope.values) item.label,
                ],
                index: scope.index,
                onChanged: (int index) => _writeUrl(
                  query: immediate,
                  scope: SearchScope.values[index],
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _body(context, scope, immediate, query)),
      ],
    );
  }

  Widget _body(
    BuildContext context,
    SearchScope scope,
    String immediate,
    String query,
  ) {
    if (query.isEmpty) {
      return _idle(context);
    }
    if (query != immediate.trim()) {
      return _skeleton(context);
    }
    return scope == SearchScope.all
        ? _overview(context, query)
        : _scopeResults(context, scope, query);
  }

  /// 未输入：最近搜索 + 一句提示（不留空白页）。
  Widget _idle(BuildContext context) {
    final List<String> recent = ref.watch(recentSearchesProvider);
    if (recent.isEmpty) {
      return TyEmptyState(
        icon: Icons.search,
        title: '搜索你的音乐库',
        description: '歌曲、专辑、艺术家、歌单都能找到',
      );
    }
    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: context.metrics.pagePadding,
        vertical: TySpace.x8,
      ),
      children: <Widget>[
        TySectionHeader(
          title: '最近搜索',
          trailing: TyButton(
            label: '清除',
            variant: TyButtonVariant.ghost,
            dense: true,
            onPressed: () => ref.read(recentSearchesProvider.notifier).clear(),
          ),
        ),
        const SizedBox(height: TySpace.x8),
        Wrap(
          spacing: TySpace.x8,
          runSpacing: TySpace.x8,
          children: <Widget>[
            for (final String item in recent)
              TyChip(
                label: item,
                onTap: () {
                  _controller.text = item;
                  _onQueryChanged(item);
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _skeleton(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: TySpace.x20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TySkeleton(height: 16, width: 160),
          SizedBox(height: TySpace.x12),
          TySkeleton.line(),
          TySkeleton.line(),
          TySkeleton.line(),
          TySkeleton.line(),
        ],
      ),
    );
  }

  Widget _overview(BuildContext context, String query) {
    final AsyncValue<SearchOverview> overview = ref.watch(
      searchOverviewProvider,
    );
    return TyAsyncView<SearchOverview>(
      value: overview,
      loading: _skeleton,
      error: (BuildContext context, Object error, StackTrace? stack) =>
          TyErrorView(
            title: '搜索失败',
            detail: '$error',
            onRetry: () => ref.invalidate(searchOverviewProvider),
          ),
      data: (BuildContext context, SearchOverview data) {
        if (data.isEmpty) {
          return _noResults(context);
        }
        return ListView(
          padding: EdgeInsets.fromLTRB(
            context.metrics.pagePadding,
            0,
            context.metrics.pagePadding,
            TySpace.x24,
          ),
          children: <Widget>[
            if (data.songs.items.isNotEmpty)
              _songGroup(context, data.songs, query),
            if (data.albums.items.isNotEmpty)
              _albumGroup(context, data.albums, query),
            if (data.artists.items.isNotEmpty)
              _artistGroup(context, data.artists, query),
            if (data.playlists.items.isNotEmpty)
              _playlistGroup(context, data.playlists, query),
          ],
        );
      },
    );
  }

  Widget _songGroup(
    BuildContext context,
    SearchGroup<Track> group,
    String query,
  ) {
    final List<Track> hits = group.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TySectionHeader(
          title: '歌曲',
          count: group.total,
          actionLabel: group.total > hits.length ? '查看全部' : null,
          onAction: () => _writeUrl(query: query, scope: SearchScope.songs),
        ),
        TyPanel(
          padding: const EdgeInsets.symmetric(vertical: TySpace.x4),
          child: Column(
            children: <Widget>[
              for (final Track track in hits)
                PlaybackTrackRow(
                  key: ValueKey<String>('search-song-${track.id}'),
                  track: track,
                  index: hits.indexOf(track) + 1,
                  highlightQuery: query,
                  onTap: () => ref
                      .read(playbackProvider.notifier)
                      .playTracks(hits, startIndex: hits.indexOf(track)),
                  onToggleFavorite: () => toggleTrackFavorite(ref, track),
                ),
            ],
          ),
        ),
        const SizedBox(height: TySpace.x24),
      ],
    );
  }

  Widget _albumGroup(
    BuildContext context,
    SearchGroup<AlbumSummary> group,
    String query,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TySectionHeader(
          title: '专辑',
          count: group.total,
          actionLabel: group.total > group.items.length ? '查看全部' : null,
          onAction: () => _writeUrl(query: query, scope: SearchScope.albums),
        ),
        _horizontalTiles(
          context,
          count: group.items.length,
          builder: (BuildContext context, int index, double tile) {
            final AlbumSummary album = group.items[index];
            return TyAlbumCard(
              key: ValueKey<String>(
                'search-album-${album.artist}-${album.album}',
              ),
              width: tile,
              title: album.album,
              subtitle: album.artist,
              coverSeed: '${album.artist} · ${album.album}',
              highlightQuery: query,
              onTap: () => context.push(
                '/album/${Uri.encodeComponent(album.album)}'
                '?artist=${Uri.encodeQueryComponent(album.artist)}',
              ),
            );
          },
        ),
        const SizedBox(height: TySpace.x24),
      ],
    );
  }

  Widget _artistGroup(
    BuildContext context,
    SearchGroup<ArtistSummary> group,
    String query,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TySectionHeader(
          title: '艺术家',
          count: group.total,
          actionLabel: group.total > group.items.length ? '查看全部' : null,
          onAction: () => _writeUrl(query: query, scope: SearchScope.artists),
        ),
        TyPanel(
          padding: const EdgeInsets.symmetric(vertical: TySpace.x4),
          child: Column(
            children: <Widget>[
              for (final ArtistSummary artist in group.items)
                TyArtistRow(
                  key: ValueKey<String>('search-artist-${artist.name}'),
                  name: artist.name,
                  subtitle: _artistSubtitle(artist),
                  highlightQuery: query,
                  onTap: () => context.push(
                    '/artist/${Uri.encodeComponent(artist.name)}',
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: TySpace.x24),
      ],
    );
  }

  Widget _playlistGroup(
    BuildContext context,
    SearchGroup<Playlist> group,
    String query,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TySectionHeader(
          title: '歌单',
          count: group.total,
          actionLabel: group.total > group.items.length ? '查看全部' : null,
          onAction: () => _writeUrl(query: query, scope: SearchScope.playlists),
        ),
        _horizontalTiles(
          context,
          count: group.items.length,
          builder: (BuildContext context, int index, double tile) {
            final Playlist playlist = group.items[index];
            final int? count = ref
                .watch(playlistTrackCountsProvider)
                .value?[playlist.id];
            return TyPlaylistCard(
              key: ValueKey<String>('search-playlist-${playlist.id}'),
              width: tile,
              title: playlist.name,
              subtitle: count == null ? null : '$count 首',
              highlightQuery: query,
              onTap: () => context.push('/playlist/${playlist.id}'),
            );
          },
        ),
        const SizedBox(height: TySpace.x24),
      ],
    );
  }

  /// 横向瓦片带：高度由 `tyTileExtent` 推出，与「专辑」页的网格同一套尺寸。
  Widget _horizontalTiles(
    BuildContext context, {
    required int count,
    required Widget Function(BuildContext context, int index, double tile)
    builder,
  }) {
    final TyMetrics metrics = context.metrics;
    final double tile = metrics.gridMinTile;
    return SizedBox(
      height: tyTileExtent(context, tile),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: count,
        separatorBuilder: (_, _) => SizedBox(width: metrics.gridGap),
        itemBuilder: (BuildContext context, int index) =>
            builder(context, index, tile),
      ),
    );
  }

  String _artistSubtitle(ArtistSummary artist) {
    if (artist.trackCount <= 0) {
      return '暂无曲目';
    }
    return '${artist.trackCount} 首';
  }

  Widget _noResults(BuildContext context) {
    return TyEmptyState(
      icon: Icons.search_off,
      title: '没有找到匹配的结果',
      description: '换个更短的关键词，或检查是否写错了字',
      actionLabel: '清除搜索',
      onAction: _clear,
    );
  }

  Widget _scopeResults(BuildContext context, SearchScope scope, String query) {
    final SearchPageRequest request = SearchPageRequest(
      text: query,
      limit: libraryPageSize,
    );
    final List<AsyncValue<SearchPageResult<Track>>> songPages =
        scope == SearchScope.songs
        ? <AsyncValue<SearchPageResult<Track>>>[
            for (int i = 0; i < _pages; i++)
              ref.watch(
                searchSongsPageProvider(
                  SearchPageRequest(
                    text: query,
                    offset: i * libraryPageSize,
                    limit: libraryPageSize,
                  ),
                ),
              ),
          ]
        : const <AsyncValue<SearchPageResult<Track>>>[];
    final AsyncValue<SearchPageResult<AlbumSummary>> albums =
        scope == SearchScope.albums
        ? ref.watch(searchAlbumsPageProvider(request))
        : const AsyncData<SearchPageResult<AlbumSummary>>(
            SearchPageResult<AlbumSummary>(items: <AlbumSummary>[], total: 0),
          );
    final AsyncValue<SearchPageResult<ArtistSummary>> artists =
        scope == SearchScope.artists
        ? ref.watch(searchArtistsPageProvider(request))
        : const AsyncData<SearchPageResult<ArtistSummary>>(
            SearchPageResult<ArtistSummary>(items: <ArtistSummary>[], total: 0),
          );
    final AsyncValue<SearchPageResult<Playlist>> playlists =
        scope == SearchScope.playlists
        ? ref.watch(searchPlaylistsPageProvider(request))
        : const AsyncData<SearchPageResult<Playlist>>(
            SearchPageResult<Playlist>(items: <Playlist>[], total: 0),
          );

    if (scope == SearchScope.songs) {
      final AsyncValue<SearchPageResult<Track>> first = songPages.first;
      final List<Track> tracks = <Track>[
        for (final AsyncValue<SearchPageResult<Track>> page in songPages)
          ...?page.value?.items,
      ];
      final bool loadingMore = _pages > 1 && songPages.last.isLoading;
      return TyAsyncView<SearchPageResult<Track>>(
        value: first,
        loading: _skeleton,
        error: (BuildContext context, Object error, StackTrace? stack) =>
            TyErrorView(
              title: '搜索失败',
              detail: '$error',
              onRetry: () => ref.invalidate(searchSongsPageProvider(request)),
            ),
        data: (BuildContext context, SearchPageResult<Track> page) {
          if (page.total == 0) {
            return _noResults(context);
          }
          final Widget footer = _footer(
            context,
            shown: tracks.length,
            total: page.total,
            loadingMore: loadingMore,
            lastPage: songPages.last,
            onRetry: () => ref.invalidate(
              searchSongsPageProvider(
                SearchPageRequest(
                  text: query,
                  offset: (tracks.length ~/ libraryPageSize) * libraryPageSize,
                  limit: libraryPageSize,
                ),
              ),
            ),
          );
          void play(int index) => ref
              .read(playbackProvider.notifier)
              .playTracks(tracks, startIndex: index);
          Widget row(BuildContext context, int index, Track track) =>
              PlaybackTrackRow(
                key: ValueKey<String>('search-${track.id}'),
                track: track,
                index: index + 1,
                tableMode: !context.formFactor.isCompact,
                showAlbum:
                    !context.formFactor.isCompact &&
                    context.formFactor == FormFactor.expanded,
                highlightQuery: query,
                onTap: () => play(index),
                onToggleFavorite: () => toggleTrackFavorite(ref, track),
              );
          if (context.formFactor.isCompact) {
            return TyTrackList(
              tracks: tracks,
              playingTrackId: null,
              playing: false,
              highlightQuery: query,
              rowBuilder: row,
              padding: EdgeInsets.symmetric(
                horizontal: context.metrics.pagePadding,
              ),
              footer: footer,
            );
          }
          return TyTrackTable(
            tracks: tracks,
            playingTrackId: null,
            playing: false,
            highlightQuery: query,
            rowBuilder: row,
            footer: footer,
          );
        },
      );
    }

    final AsyncValue<Object> value = switch (scope) {
      SearchScope.albums => albums,
      SearchScope.artists => artists,
      SearchScope.playlists => playlists,
      SearchScope.all || SearchScope.songs => albums,
    };
    final int total = switch (scope) {
      SearchScope.albums => albums.value?.total ?? 0,
      SearchScope.artists => artists.value?.total ?? 0,
      SearchScope.playlists => playlists.value?.total ?? 0,
      SearchScope.all || SearchScope.songs => albums.value?.total ?? 0,
    };
    return TyAsyncView<Object>(
      value: value,
      loading: _skeleton,
      error: (BuildContext context, Object error, StackTrace? stack) =>
          TyErrorView(
            title: '搜索失败',
            detail: '$error',
            onRetry: () {
              switch (scope) {
                case SearchScope.albums:
                  ref.invalidate(searchAlbumsPageProvider(request));
                case SearchScope.artists:
                  ref.invalidate(searchArtistsPageProvider(request));
                case SearchScope.playlists:
                  ref.invalidate(searchPlaylistsPageProvider(request));
                case SearchScope.all || SearchScope.songs:
                  ref.invalidate(searchSongsPageProvider(request));
              }
            },
          ),
      data: (BuildContext context, Object _) {
        if (total == 0) {
          return _noResults(context);
        }
        return ListView(
          padding: EdgeInsets.fromLTRB(
            context.metrics.pagePadding,
            0,
            context.metrics.pagePadding,
            TySpace.x24,
          ),
          children: <Widget>[
            TySectionHeader(title: scope.label, count: total),
            switch (scope) {
              SearchScope.albums => _albumGrid(
                context,
                albums.value!.items,
                query,
              ),
              SearchScope.artists => TyPanel(
                padding: const EdgeInsets.symmetric(vertical: TySpace.x4),
                child: Column(
                  children: <Widget>[
                    for (final ArtistSummary artist in artists.value!.items)
                      TyArtistRow(
                        key: ValueKey<String>('scope-artist-${artist.name}'),
                        name: artist.name,
                        subtitle: _artistSubtitle(artist),
                        highlightQuery: query,
                        onTap: () => context.push(
                          '/artist/${Uri.encodeComponent(artist.name)}',
                        ),
                      ),
                  ],
                ),
              ),
              SearchScope.playlists => _playlistGrid(
                context,
                playlists.value!.items,
                query,
              ),
              SearchScope.all || SearchScope.songs => const SizedBox.shrink(),
            },
            if (total > _pagedCount(scope, albums, artists, playlists))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: TySpace.x16),
                child: Center(
                  child: TyButton(
                    label: '加载更多',
                    variant: TyButtonVariant.secondary,
                    onPressed: () => setState(() => _pages++),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  int _pagedCount(
    SearchScope scope,
    AsyncValue<SearchPageResult<AlbumSummary>> albums,
    AsyncValue<SearchPageResult<ArtistSummary>> artists,
    AsyncValue<SearchPageResult<Playlist>> playlists,
  ) {
    return switch (scope) {
      SearchScope.albums => albums.value?.items.length ?? 0,
      SearchScope.artists => artists.value?.items.length ?? 0,
      SearchScope.playlists => playlists.value?.items.length ?? 0,
      SearchScope.all || SearchScope.songs => 0,
    };
  }

  Widget _albumGrid(
    BuildContext context,
    List<AlbumSummary> albums,
    String query,
  ) {
    final TyMetrics metrics = context.metrics;
    final double available = MediaQuery.sizeOf(context).width;
    final int columns = tyGridColumns(available, metrics);
    final double tile = (available - (columns - 1) * metrics.gridGap) / columns;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: metrics.gridGap,
        mainAxisSpacing: metrics.gridGap,
        mainAxisExtent: tyTileExtent(context, tile),
      ),
      itemCount: albums.length,
      itemBuilder: (BuildContext context, int index) {
        final AlbumSummary album = albums[index];
        return TyAlbumCard(
          key: ValueKey<String>('scope-album-${album.artist}-${album.album}'),
          width: tile,
          title: album.album,
          subtitle: album.artist,
          coverSeed: '${album.artist} · ${album.album}',
          highlightQuery: query,
          onTap: () => context.push(
            '/album/${Uri.encodeComponent(album.album)}'
            '?artist=${Uri.encodeQueryComponent(album.artist)}',
          ),
        );
      },
    );
  }

  Widget _playlistGrid(
    BuildContext context,
    List<Playlist> playlists,
    String query,
  ) {
    final TyMetrics metrics = context.metrics;
    final double available = MediaQuery.sizeOf(context).width;
    final int columns = tyGridColumns(available, metrics);
    final double tile = (available - (columns - 1) * metrics.gridGap) / columns;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: metrics.gridGap,
        mainAxisSpacing: metrics.gridGap,
        mainAxisExtent: tyTileExtent(context, tile),
      ),
      itemCount: playlists.length,
      itemBuilder: (BuildContext context, int index) {
        final Playlist playlist = playlists[index];
        final int? count = ref
            .watch(playlistTrackCountsProvider)
            .value?[playlist.id];
        return TyPlaylistCard(
          key: ValueKey<String>('scope-playlist-${playlist.id}'),
          width: tile,
          title: playlist.name,
          subtitle: count == null ? null : '$count 首',
          highlightQuery: query,
          onTap: () => context.push('/playlist/${playlist.id}'),
        );
      },
    );
  }

  /// 分页脚注：给出真实计数，滚动不到底也有明确出口。
  Widget _footer(
    BuildContext context, {
    required int shown,
    required int total,
    required bool loadingMore,
    required AsyncValue<SearchPageResult<Track>> lastPage,
    required VoidCallback onRetry,
  }) {
    final TyTokens ty = context.ty;
    if (shown >= total) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: TySpace.x16),
        child: Text(
          '已全部加载 · 共 $total 首',
          textAlign: TextAlign.center,
          style: ty.typography.bodyS.copyWith(color: ty.colors.textTertiary),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TySpace.x12,
        vertical: TySpace.x12,
      ),
      child: Row(
        children: <Widget>[
          Text(
            '已显示 $shown / 共 $total 首',
            style: ty.typography.bodyS.copyWith(color: ty.colors.textSecondary),
          ),
          const Spacer(),
          if (loadingMore)
            const TySkeleton(height: 32, width: 96)
          else if (lastPage.hasError)
            TyButton(
              label: '重试',
              variant: TyButtonVariant.secondary,
              dense: true,
              onPressed: onRetry,
            )
          else
            TyButton(
              label: '加载更多',
              variant: TyButtonVariant.secondary,
              dense: true,
              onPressed: () => setState(() => _pages++),
            ),
        ],
      ),
    );
  }
}
