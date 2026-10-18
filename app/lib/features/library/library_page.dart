import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/models/library_query.dart';
import '../../data/models/track_sort.dart';
import '../../data/models/search_page_result.dart';
import '../../design/components/album_card.dart';
import '../../design/components/buttons.dart';
import '../../design/components/chips.dart';
import '../../design/components/context_menu.dart';
import '../../design/components/dialogs.dart';
import '../../design/components/feedback.dart';
import '../../design/components/inputs.dart';
import '../../design/components/interactive.dart';
import '../../design/components/sort_menu.dart';
import '../../design/components/structure.dart';
import '../../design/components/track.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/metrics.dart';
import '../../design/tokens/tokens.dart';
import '../../design/tokens/voice_archive.dart';
import '../../design/theme.dart';
import '../shared/add_to_playlist.dart';
import '../shared/playback_track_row.dart';
import '../shared/track_actions.dart';
import 'library_table_columns.dart';
import 'library_view_state.dart';

/// 曲库歌曲列表：曲库根页与收藏页共用「分页 + 排序 + 来源过滤 + 表格/列表」。
///
/// 排序与来源过滤放在 URL query（[view]），所以「按艺术家排序、只看某个来源」的链接
/// 可以直接分享/收藏；收藏页没有 query，就退化成页面自持状态。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({
    super.key,
    this.favoritesOnly = false,
    this.view,
    this.routePath = '/library/songs',
    this.defaultView = LibraryViewState.initial,
  });

  /// 收藏页：只看收藏，并多一个「专辑」分段。
  final bool favoritesOnly;

  /// 路由注入的排序/来源状态；null 表示页面自持（收藏页）。
  final LibraryViewState? view;

  /// 排序/来源变化时回写的路由，保持链接可分享。
  final String routePath;

  /// 该路由的默认视图：URL 里只写与默认值不同的项，链接短且稳定。
  final LibraryViewState defaultView;

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  late LibraryViewState _view = widget.view ?? LibraryViewState.initial;
  final ScrollController _scroll = ScrollController();
  final Set<String> _selected = <String>{};
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode(debugLabel: '曲库搜索');

  /// 已加载的页数；每页 [libraryPageSize] 条。
  int _pages = 1;

  /// 收藏页的 0 = 歌曲 / 1 = 专辑。
  int _favoritesSection = 0;

  bool _selectionMode = false;
  bool _busy = false;
  bool _preparingPlaybackAll = false;
  int _playAllGeneration = 0;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(searchQueryProvider),
    );
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 路由 query 变了（返回/前进/深链）→ 跟着回到第一页，别把两个排序的数据拼在一起。
    if (widget.view != null && widget.view != oldWidget.view) {
      setState(() {
        _view = widget.view!;
        _pages = 1;
        _selected.clear();
        _playAllGeneration++;
        _preparingPlaybackAll = false;
      });
    }
  }

  LibraryQuery get _query => LibraryQuery(
    favoritesOnly: widget.favoritesOnly,
    sourceId: _view.sourceId,
    sort: _view.sort,
    ascending: _view.ascending,
  );

  void _applyView(LibraryViewState next) {
    _selected.clear();
    _playAllGeneration++;
    _preparingPlaybackAll = false;
    if (widget.view != null) {
      final Map<String, String> params = next.toQuery(widget.defaultView);
      final String query = Uri(queryParameters: params.isEmpty ? null : params)
          .query;
      context.go(
        query.isEmpty ? widget.routePath : '${widget.routePath}?$query',
      );
      return;
    }
    setState(() {
      _view = next;
      _pages = 1;
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) {
      return;
    }
    final ScrollPosition position = _scroll.position;
    if (position.maxScrollExtent - position.pixels > 600) {
      return;
    }
    _loadMore();
  }

  void _loadMore() {
    setState(() => _pages++);
  }

  Future<void> _play(List<Track> tracks, int index) async {
    await ref
        .read(playbackProvider.notifier)
        .playTracks(tracks, startIndex: index);
  }

  /// 「播放全部」不能只播放当前滚动加载到的几页；按同一个 provider 补齐所有页。
  Future<void> _playAll({
    required LibraryQuery query,
    required List<Track> loadedTracks,
    required int total,
  }) async {
    if (_preparingPlaybackAll || total == 0) {
      return;
    }
    if (loadedTracks.length >= total) {
      await _play(loadedTracks, 0);
      return;
    }

    final int generation = ++_playAllGeneration;
    setState(() => _preparingPlaybackAll = true);
    String? failure;
    LibraryPageRequest request = LibraryPageRequest(
      query: query,
      limit: libraryPageSize,
    );
    final List<Track> allTracks = <Track>[];
    try {
      while (true) {
        final SearchPageResult<Track> page = await ref.read(
          libraryTracksPageProvider(request).future,
        );
        if (!mounted || generation != _playAllGeneration || query != _query) {
          return;
        }
        allTracks.addAll(page.items);
        if (page.items.isEmpty || allTracks.length >= page.total) {
          break;
        }
        request = request.nextPage();
      }
      if (allTracks.isNotEmpty) {
        await _play(allTracks, 0);
      }
    } catch (error) {
      // 失败页下次读取时重新取数，用户关闭提示后可直接再点“播放全部”。
      ref.invalidate(libraryTracksPageProvider(request));
      failure = error.toString();
    } finally {
      if (mounted && generation == _playAllGeneration) {
        setState(() => _preparingPlaybackAll = false);
      }
    }

    if (failure != null && mounted && generation == _playAllGeneration) {
      await _showPlayAllFailure(failure);
    }
  }

  Future<void> _showPlayAllFailure(String detail) {
    return showTyDialog<void>(
      context,
      child: TyDialog(
        title: '无法播放全部',
        subtitle: '曲库分页没有完整读取，播放尚未开始。',
        actions: <Widget>[
          TyButton(
            label: '知道了',
            variant: TyButtonVariant.secondary,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
        child: SelectableText(
          detail,
          maxLines: 6,
          style: context.ty.typography.bodyS.copyWith(
            color: context.ty.colors.textSecondary,
          ),
        ),
      ),
    );
  }

  bool get _primaryLibrary =>
      !widget.favoritesOnly && widget.routePath == '/library/songs';

  void _onSearchChanged(String value) {
    ref.read(searchQueryProvider.notifier).set(value);
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return;
    }
    context.go('/search?q=${Uri.encodeQueryComponent(trimmed)}');
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(searchQueryProvider.notifier).clear();
  }

  Future<void> _showMenu(Track track, Offset position, List<Track> tracks) {
    return showTrackMenu(
      context,
      ref,
      track,
      position: position,
      onPlay: () => _play(tracks, tracks.indexOf(track)),
    );
  }

  Future<void> _favoriteSelected(List<Track> tracks) async {
    final List<Track> chosen = tracks
        .where((Track track) => _selected.contains(track.id))
        .toList();
    setState(() => _busy = true);
    try {
      await Future.wait(
        chosen.map(
          (Track track) => ref
              .read(trackRepositoryProvider)
              .setFavorite(track.id, value: true),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _selectionMode = false;
          _selected.clear();
        });
      }
    }
  }

  Future<void> _addSelectedToPlaylist(List<Track> tracks) async {
    final List<Track> chosen = tracks
        .where((Track track) => _selected.contains(track.id))
        .toList();
    await showAddToPlaylistDialog(context, ref, chosen);
    if (mounted) {
      setState(() {
        _selectionMode = false;
        _selected.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 曲库出现时后台补全缺失元数据（原行为，别丢）。
    ref.watch(autoLibraryEnrichmentProvider);
    final LibraryQuery query = _query;
    final List<AsyncValue<SearchPageResult<Track>>> pages =
        <AsyncValue<SearchPageResult<Track>>>[
          for (int i = 0; i < _pages; i++)
            ref.watch(
              libraryTracksPageProvider(
                LibraryPageRequest(
                  query: query,
                  offset: i * libraryPageSize,
                  limit: libraryPageSize,
                ),
              ),
            ),
        ];
    final AsyncValue<SearchPageResult<Track>> first = pages.first;
    final List<Track> tracks = <Track>[
      for (final AsyncValue<SearchPageResult<Track>> page in pages)
        ...?page.value?.items,
    ];
    final bool loadingMore = _pages > 1 && pages.last.isLoading;
    final AsyncValue<List<MusicSource>> sourceValue = ref.watch(
      sourcesProvider,
    );
    final Map<String, String> sourceNames = <String, String>{
      for (final MusicSource source
          in sourceValue.value ?? const <MusicSource>[])
        source.id: source.name,
    };

    Widget page(BuildContext pageContext) {
      final TyMetrics pageMetrics = pageContext.metrics;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              pageMetrics.pagePadding,
              TySpace.x20,
              pageMetrics.pagePadding,
              TySpace.x12,
            ),
            child: _selectionMode
                ? _selectionBar(pageContext, tracks)
                : (_primaryLibrary
                      ? _primaryHeader(pageContext, first, tracks)
                      : _header(pageContext, first)),
          ),
          if (widget.favoritesOnly && _favoritesSection == 1)
            Expanded(child: _favoriteAlbums(pageContext, pageMetrics))
          else
            Expanded(
              child: TyAsyncView<SearchPageResult<Track>>(
                value: first,
                loading: (BuildContext context) => _skeleton(context),
                error:
                    (BuildContext context, Object error, StackTrace? stack) =>
                        TyErrorView(
                          title: '曲库读取失败',
                          detail: _errorDetail(error),
                          onRetry: () => ref.invalidate(
                            libraryTracksPageProvider(
                              LibraryPageRequest(
                                query: query,
                                limit: libraryPageSize,
                              ),
                            ),
                          ),
                        ),
                data: (BuildContext context, SearchPageResult<Track> page) {
                  if (page.total == 0) {
                    return _emptyState(context);
                  }
                  return _content(
                    context,
                    pageMetrics,
                    tracks: tracks,
                    total: page.total,
                    pages: pages,
                    loadingMore: loadingMore,
                    query: query,
                    sourceNames: sourceNames,
                  );
                },
              ),
            ),
        ],
      );
    }

    if (!_primaryLibrary) {
      return page(context);
    }
    final TyTokens inherited = context.ty;
    return Theme(
      data: TyTheme.build(
        brightness: inherited.brightness,
        density: inherited.density,
        colors: VoiceArchiveColors.of(inherited.brightness),
      ),
      child: Builder(builder: page),
    );
  }

  Widget _primaryHeader(
    BuildContext context,
    AsyncValue<SearchPageResult<Track>> first,
    List<Track> tracks,
  ) {
    final TyTokens ty = context.ty;
    final int? total = first.value?.total;
    final String libraryStatus = first.hasError
        ? '无法读取曲库'
        : total == null
        ? '正在读取曲库'
        : '$total 首歌曲';
    final Widget search = TySearchField(
      controller: _searchController,
      focusNode: _searchFocus,
      hint: '搜索曲库',
      onChanged: _onSearchChanged,
      onClear: _clearSearch,
    );
    final Widget playAll = TyButton(
      label: _preparingPlaybackAll ? '正在准备…' : '播放全部',
      icon: Icons.play_arrow_rounded,
      dense: context.formFactor.isCompact,
      onPressed: tracks.isEmpty || total == null || _preparingPlaybackAll
          ? null
          : () => _playAll(query: _query, loadedTracks: tracks, total: total),
    );
    final Widget sort = TySortMenu<TrackSortField>(
      value: _view.sort,
      options: <TySortOption<TrackSortField>>[
        for (final TrackSortField field in TrackSortField.values)
          TySortOption<TrackSortField>(value: field, label: field.label),
      ],
      direction: _view.ascending
          ? TySortDirection.ascending
          : TySortDirection.descending,
      onChanged: (TrackSortField field) => _applyView(
        _view.copyWith(sort: field, ascending: field != TrackSortField.addedAt),
      ),
      onDirectionChanged: (TySortDirection direction) => _applyView(
        _view.copyWith(ascending: direction == TySortDirection.ascending),
      ),
    );
    final Widget sourceFilter = _sourceFilter(context);
    final TyIconAction select = TyIconAction(
      icon: Icons.checklist_outlined,
      semanticLabel: '多选',
      tooltip: '多选',
      onPressed: total == null || total == 0
          ? null
          : () => setState(() => _selectionMode = true),
    );
    final List<Widget> actions = <Widget>[playAll, sort, sourceFilter, select];

    if (context.formFactor.isCompact) {
      final bool enlargedText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '曲库',
                  style: ty.typography.titleXL.copyWith(
                    color: ty.colors.textPrimary,
                  ),
                ),
              ),
              TyButton(
                label: '来源',
                icon: Icons.storage_outlined,
                variant: TyButtonVariant.ghost,
                dense: true,
                onPressed: () => context.go('/sources'),
              ),
            ],
          ),
          const SizedBox(height: TySpace.x12),
          search,
          const SizedBox(height: TySpace.x12),
          TySegmentedControl(
            maxWidth: null,
            segments: const <String>['歌曲', '专辑', '艺术家', '歌单'],
            index: 0,
            onChanged: (int index) {
              const List<String> routes = <String>[
                '/library/songs',
                '/library/albums',
                '/library/artists',
                '/library/playlists',
              ];
              context.go(routes[index]);
            },
          ),
          const SizedBox(height: TySpace.x12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  libraryStatus,
                  style: ty.typography.bodyS.copyWith(
                    color: ty.colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: TySpace.x8),
              playAll,
            ],
          ),
          const SizedBox(height: TySpace.x8),
          if (enlargedText)
            Row(
              children: <Widget>[
                Expanded(
                  child: _compactFilterSortButton(
                    context,
                    canSelect: total != null && total > 0,
                  ),
                ),
                const SizedBox(width: TySpace.x8),
                select,
              ],
            )
          else
            Row(
              children: <Widget>[
                sort,
                const SizedBox(width: TySpace.x8),
                sourceFilter,
                const Spacer(),
                select,
              ],
            ),
        ],
      );
    }

    final Widget title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '曲库',
          style: ty.typography.titleXL.copyWith(color: ty.colors.textPrimary),
        ),
        const SizedBox(height: TySpace.x4),
        Text(
          libraryStatus,
          style: ty.typography.bodyS.copyWith(color: ty.colors.textSecondary),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        search,
        const SizedBox(height: TySpace.x20),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Widget actionWrap = Wrap(
              spacing: TySpace.x8,
              runSpacing: TySpace.x8,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            );
            if (constraints.maxWidth < 720) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  title,
                  const SizedBox(height: TySpace.x12),
                  actionWrap,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                title,
                const Spacer(),
                Flexible(child: actionWrap),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _compactFilterSortButton(
    BuildContext context, {
    required bool canSelect,
  }) {
    return Builder(
      builder: (BuildContext buttonContext) => TyButton(
        label: '筛选与排序',
        icon: Icons.tune_rounded,
        variant: TyButtonVariant.secondary,
        dense: true,
        expand: true,
        onPressed: () {
          final RenderObject? box = buttonContext.findRenderObject();
          final Offset origin = box is RenderBox && box.hasSize
              ? box.localToGlobal(Offset(0, box.size.height))
              : Offset.zero;
          _showCompactFilterSortMenu(context, origin, canSelect: canSelect);
        },
      ),
    );
  }

  Future<void> _showCompactFilterSortMenu(
    BuildContext context,
    Offset position, {
    required bool canSelect,
  }) {
    final List<MusicSource> sources =
        ref.read(sourcesProvider).value ?? const <MusicSource>[];
    return TyContextMenu.show(
      context,
      position: position,
      actions: <TyMenuAction>[
        for (final TrackSortField field in TrackSortField.values)
          TyMenuAction(
            label: '按${field.label}排序',
            icon: identical(field, _view.sort) ? Icons.check : null,
            onSelected: () => _applyView(
              _view.copyWith(
                sort: field,
                ascending: field != TrackSortField.addedAt,
              ),
            ),
          ),
        TyMenuAction(
          label: '升序',
          icon: _view.ascending ? Icons.check : null,
          onSelected: () => _applyView(_view.copyWith(ascending: true)),
        ),
        TyMenuAction(
          label: '降序',
          icon: _view.ascending ? null : Icons.check,
          onSelected: () => _applyView(_view.copyWith(ascending: false)),
        ),
        if (sources.length > 1) ...<TyMenuAction>[
          TyMenuAction(
            label: '全部来源',
            icon: _view.sourceId == null ? Icons.check : Icons.folder_outlined,
            onSelected: () => _applyView(_view.copyWith(clearSourceId: true)),
          ),
          for (final MusicSource source in sources)
            TyMenuAction(
              label: '来源：${source.name}',
              icon: _view.sourceId == source.id
                  ? Icons.check
                  : Icons.folder_open_outlined,
              onSelected: () => _applyView(_view.copyWith(sourceId: source.id)),
            ),
        ],
        TyMenuAction(
          label: '多选',
          icon: Icons.checklist_outlined,
          enabled: canSelect,
          onSelected: canSelect
              ? () => setState(() => _selectionMode = true)
              : null,
        ),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    AsyncValue<SearchPageResult<Track>> first,
  ) {
    final int? total = first.value?.total;
    final bool songsSection = !widget.favoritesOnly || _favoritesSection == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TyPageHeader(
          title: widget.favoritesOnly ? '收藏' : '歌曲',
          subtitle: total == null ? null : '共 $total 首',
          actions: <Widget>[
            if (songsSection)
              TySortMenu<TrackSortField>(
                value: _view.sort,
                options: <TySortOption<TrackSortField>>[
                  for (final TrackSortField field in TrackSortField.values)
                    TySortOption<TrackSortField>(
                      value: field,
                      label: field.label,
                    ),
                ],
                direction: _view.ascending
                    ? TySortDirection.ascending
                    : TySortDirection.descending,
                onChanged: (TrackSortField field) => _applyView(
                  _view.copyWith(
                    sort: field,
                    ascending: field != TrackSortField.addedAt,
                  ),
                ),
                onDirectionChanged: (TySortDirection direction) => _applyView(
                  _view.copyWith(
                    ascending: direction == TySortDirection.ascending,
                  ),
                ),
              ),
            _sourceFilter(context),
            TyIconAction(
              icon: Icons.checklist_outlined,
              semanticLabel: '多选',
              tooltip: '多选',
              onPressed: () => setState(() => _selectionMode = true),
            ),
          ],
        ),
        if (widget.favoritesOnly) ...<Widget>[
          const SizedBox(height: TySpace.x12),
          Align(
            alignment: Alignment.centerLeft,
            child: TySegmentedControl(
              segments: const <String>['歌曲', '专辑'],
              index: _favoritesSection,
              onChanged: (int index) =>
                  setState(() => _favoritesSection = index),
            ),
          ),
        ],
      ],
    );
  }

  /// 来源过滤：只有真的存在多个来源时才出现，避免单来源用户多一个永远无效的控件。
  Widget _sourceFilter(BuildContext context) {
    final List<MusicSource> sources =
        ref.watch(sourcesProvider).value ?? const <MusicSource>[];
    if (sources.length <= 1) {
      return const SizedBox.shrink();
    }
    String label = _view.sourceId == null ? '全部来源' : '未知来源';
    if (_view.sourceId != null) {
      for (final MusicSource source in sources) {
        if (source.id == _view.sourceId) {
          label = source.name;
          break;
        }
      }
    }
    return Builder(
      builder: (BuildContext buttonContext) => TyButton(
        label: label,
        icon: Icons.folder_outlined,
        variant: TyButtonVariant.secondary,
        dense: true,
        onPressed: () {
          final RenderObject? box = buttonContext.findRenderObject();
          final Offset origin = box is RenderBox && box.hasSize
              ? box.localToGlobal(box.size.center(Offset.zero))
              : Offset.zero;
          TyContextMenu.show(
            context,
            position: origin,
            actions: <TyMenuAction>[
              TyMenuAction(
                label: '全部来源',
                icon: Icons.folder_outlined,
                onSelected: () =>
                    _applyView(_view.copyWith(clearSourceId: true)),
              ),
              for (final MusicSource source in sources)
                TyMenuAction(
                  label: source.name,
                  icon: Icons.folder_open_outlined,
                  onSelected: () =>
                      _applyView(_view.copyWith(sourceId: source.id)),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _selectionBar(BuildContext context, List<Track> tracks) {
    final TyTokens ty = context.ty;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          Text(
            '已选 ${_selected.length} 首',
            style: ty.typography.bodyM.copyWith(color: ty.colors.textPrimary),
          ),
          const SizedBox(width: TySpace.x24),
          TyButton(
            label: '收藏',
            icon: Icons.favorite_border,
            variant: TyButtonVariant.secondary,
            onPressed: _busy || _selected.isEmpty
                ? null
                : () => _favoriteSelected(tracks),
          ),
          const SizedBox(width: TySpace.x8),
          TyButton(
            label: '加入歌单',
            icon: Icons.playlist_add,
            variant: TyButtonVariant.secondary,
            onPressed: _selected.isEmpty
                ? null
                : () => _addSelectedToPlaylist(tracks),
          ),
          const SizedBox(width: TySpace.x8),
          TyButton(
            label: '取消',
            variant: TyButtonVariant.ghost,
            onPressed: () => setState(() {
              _selectionMode = false;
              _selected.clear();
            }),
          ),
        ],
      ),
    );
  }

  Widget _content(
    BuildContext context,
    TyMetrics metrics, {
    required List<Track> tracks,
    required int total,
    required List<AsyncValue<SearchPageResult<Track>>> pages,
    required bool loadingMore,
    required LibraryQuery query,
    required Map<String, String> sourceNames,
  }) {
    final Widget footer = _footer(
      context,
      shown: tracks.length,
      total: total,
      loadingMore: loadingMore,
      lastPage: pages.last,
      query: query,
    );

    if (context.formFactor == FormFactor.compact) {
      final double? rowExtent = _primaryLibrary
          ? _compactLibraryRowExtent(context)
          : null;
      return TyTrackList(
        tracks: tracks,
        playingTrackId: null,
        playing: false,
        scrollController: _scroll,
        selectedIds: _selected,
        onSelectChanged: _toggleSelected,
        rowBuilder: (BuildContext context, int index, Track track) =>
            PlaybackTrackRow(
              key: ValueKey<String>('library-${track.id}'),
              track: track,
              index: index + 1,
              // P2：手机默认只显示艺术家；来源筛选后才补上来源上下文。
              showAlbum: false,
              showSource: _primaryLibrary && _view.sourceId != null,
              sourceLabel: _primaryLibrary && _view.sourceId != null
                  ? _sourceLabel(track, sourceNames)
                  : null,
              coverSize: _primaryLibrary ? 56 : null,
              titleMaxLines: _primaryLibrary ? 2 : 1,
              rowHeight: rowExtent,
              onTap: () => _play(tracks, index),
              // 手机曲库按批准稿只保留“更多”入口；收藏仍在同一菜单中，
              // 避免不可见列挤占双行标题。
              onToggleFavorite: _primaryLibrary
                  ? null
                  : () => toggleTrackFavorite(ref, track),
              onMore: () => _showMenu(track, rowOrigin(context), tracks),
              onSecondaryTapDown: (TapDownDetails details) =>
                  _showMenu(track, details.globalPosition, tracks),
              selected: _selected.contains(track.id),
              onSelectChanged: (bool value) => _toggleSelected(track, value),
            ),
        padding: EdgeInsets.symmetric(horizontal: metrics.pagePadding),
        footer: footer,
        itemExtent: rowExtent,
      );
    }
    if (!_primaryLibrary) {
      return TyTrackTable(
        tracks: tracks,
        playingTrackId: null,
        playing: false,
        scrollController: _scroll,
        selectedIds: _selected,
        onSelectChanged: _toggleSelected,
        sortField: _view.tableField,
        sortAscending: _view.ascending,
        onSort: (TySortField field) =>
            _applyView(_view.toggle(LibraryViewState.fromTableField(field))),
        rowBuilder: (BuildContext context, int index, Track track) =>
            PlaybackTrackRow(
              key: ValueKey<String>('library-${track.id}'),
              track: track,
              index: index + 1,
              tableMode: true,
              showAlbum: context.formFactor == FormFactor.expanded,
              onTap: () => _play(tracks, index),
              onToggleFavorite: () => toggleTrackFavorite(ref, track),
              onMore: () => _showMenu(track, rowOrigin(context), tracks),
              onSecondaryTapDown: (TapDownDetails details) =>
                  _showMenu(track, details.globalPosition, tracks),
              selected: _selected.contains(track.id),
              onSelectChanged: (bool value) => _toggleSelected(track, value),
            ),
        footer: footer,
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final LibraryTableColumns columns = LibraryTableColumns.forContentWidth(
          constraints.maxWidth - 2 * metrics.pagePadding,
        );
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: metrics.pagePadding),
          child: TyTrackTable(
            tracks: tracks,
            playingTrackId: null,
            playing: false,
            scrollController: _scroll,
            selectedIds: _selected,
            onSelectChanged: _toggleSelected,
            sortField: _view.tableField,
            sortAscending: _view.ascending,
            onSort: (TySortField field) => _applyView(
              _view.toggle(LibraryViewState.fromTableField(field)),
            ),
            showHeader: false,
            header: _LibraryTrackHeader(
              columns: columns,
              sortField: _view.tableField,
              ascending: _view.ascending,
              onSort: (TySortField field) => _applyView(
                _view.toggle(LibraryViewState.fromTableField(field)),
              ),
            ),
            rowBuilder: (BuildContext context, int index, Track track) =>
                PlaybackTrackRow(
                  key: ValueKey<String>('library-${track.id}'),
                  track: track,
                  index: columns.showIndex ? index + 1 : null,
                  tableMode: true,
                  showAlbum: columns.showAlbum,
                  showSource: columns.showSource,
                  sourceLabel: _sourceLabel(track, sourceNames),
                  separateArtistColumn: columns.showArtist,
                  reserveSelectionColumn: true,
                  onTap: () => _play(tracks, index),
                  onToggleFavorite: () => toggleTrackFavorite(ref, track),
                  onMore: () => _showMenu(track, rowOrigin(context), tracks),
                  onSecondaryTapDown: (TapDownDetails details) =>
                      _showMenu(track, details.globalPosition, tracks),
                  selected: _selected.contains(track.id),
                  onSelectChanged: (bool value) =>
                      _toggleSelected(track, value),
                ),
            footer: footer,
          ),
        );
      },
    );
  }

  String _sourceLabel(Track track, Map<String, String> sourceNames) {
    final String? known = sourceNames[track.sourceId];
    if (known != null && known.trim().isNotEmpty) {
      return known;
    }
    return '未知来源';
  }

  String _errorDetail(Object error) =>
      error is StateError ? error.message : error.toString();

  double _compactLibraryRowExtent(BuildContext context) {
    final TyTokens ty = context.ty;
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    double line(TextStyle style) =>
        scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.4);
    return math.max(
      88,
      line(ty.typography.bodyM) * 2 + line(ty.typography.bodyS) + TySpace.x32,
    );
  }

  void _toggleSelected(Track track, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(track.id);
      } else {
        _selected.remove(track.id);
      }
    });
  }

  /// 分页脚注：默认给出真实计数，接近底部时自动取下一页。
  Widget _footer(
    BuildContext context, {
    required int shown,
    required int total,
    required bool loadingMore,
    required AsyncValue<SearchPageResult<Track>> lastPage,
    required LibraryQuery query,
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
              onPressed: () => ref.invalidate(
                libraryTracksPageProvider(
                  LibraryPageRequest(
                    query: query,
                    offset: (shown ~/ libraryPageSize) * libraryPageSize,
                    limit: libraryPageSize,
                  ),
                ),
              ),
            )
          else
            TyButton(
              label: '加载更多',
              variant: TyButtonVariant.secondary,
              dense: true,
              onPressed: _loadMore,
            ),
        ],
      ),
    );
  }

  Widget _skeleton(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.metrics.pagePadding,
        vertical: TySpace.x8,
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TySkeleton(height: 16, width: 220),
          SizedBox(height: TySpace.x16),
          TySkeleton.line(),
          TySkeleton.line(),
          TySkeleton.line(),
          TySkeleton.line(),
          TySkeleton.line(),
          TySkeleton.line(),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    if (widget.favoritesOnly) {
      return TyEmptyState(
        icon: Icons.favorite_border,
        title: '还没有收藏的歌曲',
        description: '在歌曲行上点 ♥ 就会出现在这里',
        actionLabel: '去曲库',
        onAction: () => context.go('/library/songs'),
      );
    }
    return TyEmptyState(
      icon: Icons.library_music_outlined,
      title: '曲库是空的',
      description: '添加本地目录、WebDAV 或夸克来源后同步一次',
      actionLabel: '添加来源',
      onAction: () => context.go('/sources'),
    );
  }

  /// 收藏页的「专辑」分段：按 `artist + album` 归并收藏里的歌，点进专辑详情。
  Widget _favoriteAlbums(BuildContext context, TyMetrics metrics) {
    final AsyncValue<List<Track>> favorites = ref.watch(favoritesProvider);
    return TyAsyncView<List<Track>>(
      value: favorites,
      data: (BuildContext context, List<Track> list) {
        final Map<AlbumKey, List<Track>> grouped = <AlbumKey, List<Track>>{};
        for (final Track track in list) {
          grouped
              .putIfAbsent(
                AlbumKey(artist: track.artist, album: track.album),
                () => <Track>[],
              )
              .add(track);
        }
        if (grouped.isEmpty) {
          return TyEmptyState(
            icon: Icons.album_outlined,
            title: '还没有收藏的专辑',
            description: '收藏任意一首歌后，它的专辑会出现在这里',
          );
        }
        final List<MapEntry<AlbumKey, List<Track>>> entries =
            grouped.entries.toList()..sort(
              (
                MapEntry<AlbumKey, List<Track>> a,
                MapEntry<AlbumKey, List<Track>> b,
              ) => a.key.album.compareTo(b.key.album),
            );
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final int columns = tyGridColumns(constraints.maxWidth, metrics);
            final double tile =
                (constraints.maxWidth -
                    (columns - 1) * metrics.gridGap -
                    2 * metrics.pagePadding) /
                columns;
            return GridView.builder(
              padding: EdgeInsets.symmetric(
                horizontal: metrics.pagePadding,
                vertical: TySpace.x8,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: metrics.gridGap,
                mainAxisSpacing: metrics.gridGap,
                mainAxisExtent: tyTileExtent(context, tile),
              ),
              itemCount: entries.length,
              itemBuilder: (BuildContext context, int index) {
                final AlbumKey key = entries[index].key;
                final List<Track> albumTracks = entries[index].value;
                return TyAlbumCard(
                  width: tile,
                  title: key.album,
                  subtitle: '${key.artist} · ${albumTracks.length} 首',
                  coverPath: albumTracks
                      .map((Track track) => track.coverArtPath)
                      .firstWhere(
                        (String? path) => path != null && path.isNotEmpty,
                        orElse: () => null,
                      ),
                  coverUrl: albumTracks
                      .map((Track track) => track.coverArtUrl)
                      .firstWhere(
                        (String? url) => url != null && url.isNotEmpty,
                        orElse: () => null,
                      ),
                  coverSeed: '${key.artist} · ${key.album}',
                  onTap: () => context.push(
                    '/album/${Uri.encodeComponent(key.album)}'
                    '?artist=${Uri.encodeQueryComponent(key.artist)}',
                  ),
                  onPlay: () => _play(albumTracks, 0),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _LibraryTrackHeader extends StatelessWidget {
  const _LibraryTrackHeader({
    required this.columns,
    required this.sortField,
    required this.ascending,
    required this.onSort,
  });

  final LibraryTableColumns columns;
  final TySortField sortField;
  final bool ascending;
  final ValueChanged<TySortField> onSort;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Column(
      children: <Widget>[
        SizedBox(
          height: TySpace.x32,
          child: Padding(
            padding: const EdgeInsets.only(right: TySpace.x8),
            child: Row(
              children: <Widget>[
                const SizedBox(width: TySize.trackLeading),
                const SizedBox(width: TySize.tableCheckboxColumn),
                const SizedBox(width: TySize.tableCoverColumn + TySpace.x12),
                _LibrarySortHeader(
                  label: '曲名',
                  field: TySortField.title,
                  active: sortField,
                  ascending: ascending,
                  onSort: onSort,
                  flex: 5,
                ),
                if (columns.showArtist)
                  _LibrarySortHeader(
                    label: '艺术家',
                    field: TySortField.artist,
                    active: sortField,
                    ascending: ascending,
                    onSort: onSort,
                    flex: 3,
                  ),
                if (columns.showAlbum)
                  _LibrarySortHeader(
                    label: '专辑',
                    field: TySortField.album,
                    active: sortField,
                    ascending: ascending,
                    onSort: onSort,
                    flex: 3,
                  ),
                if (columns.showSource)
                  Expanded(
                    flex: 2,
                    child: Text(
                      '来源',
                      style: ty.typography.labelS.copyWith(
                        color: ty.colors.textTertiary,
                      ),
                    ),
                  ),
                SizedBox(
                  width: TySize.tableDurationColumn,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _LibrarySortHeaderContent(
                      label: '时长',
                      field: TySortField.duration,
                      active: sortField,
                      ascending: ascending,
                      onTap: () => onSort(TySortField.duration),
                    ),
                  ),
                ),
                const SizedBox(width: TySize.tableHeaderTrailing),
              ],
            ),
          ),
        ),
        const TyDividerThin(),
      ],
    );
  }
}

class _LibrarySortHeader extends StatelessWidget {
  const _LibrarySortHeader({
    required this.label,
    required this.field,
    required this.active,
    required this.ascending,
    required this.onSort,
    required this.flex,
  });

  final String label;
  final TySortField field;
  final TySortField active;
  final bool ascending;
  final ValueChanged<TySortField> onSort;
  final int flex;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Align(
        alignment: Alignment.centerLeft,
        child: _LibrarySortHeaderContent(
          label: label,
          field: field,
          active: active,
          ascending: ascending,
          onTap: () => onSort(field),
        ),
      ),
    );
  }
}

class _LibrarySortHeaderContent extends StatelessWidget {
  const _LibrarySortHeaderContent({
    required this.label,
    required this.field,
    required this.active,
    required this.ascending,
    required this.onTap,
  });

  final String label;
  final TySortField field;
  final TySortField active;
  final bool ascending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool selected = field == active;
    return TyInteractive(
      onTap: onTap,
      semanticLabel: '$label 排序',
      semanticButton: true,
      builder: (BuildContext context, TyInteractionState state) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: ty.typography.labelS.copyWith(
                color: selected
                    ? ty.colors.textPrimary
                    : ty.colors.textTertiary,
              ),
            ),
            if (selected)
              Icon(
                ascending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                size: 12,
                color: ty.colors.textPrimary,
              ),
          ],
        );
      },
    );
  }
}
