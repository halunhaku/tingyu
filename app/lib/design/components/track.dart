import 'package:flutter/material.dart';

import '../../data/db/database.dart';
import '../format.dart';
import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'cover.dart';
import 'highlight.dart';
import 'interactive.dart';

/// 曲目行：曲库、专辑、艺术家、歌单、搜索、队列共用。
///
/// 只负责展示与单曲级操作；「点击后播放哪个队列」由宿主通过 [onTap] 注入
/// （整库播放 vs 专辑内播放 vs 搜索结果播放）。
class TyTrackRow extends StatelessWidget {
  const TyTrackRow({
    super.key,
    required this.track,
    this.index,
    this.isPlaying = false,
    this.playing = false,
    this.selected = false,
    this.onTap,
    this.onDoubleTap,
    this.onToggleFavorite,
    this.onMore,
    this.onSecondaryTapDown,
    this.onSelectChanged,
    this.showAlbum = true,
    this.showCover = true,
    this.tableMode = false,
    this.trailing,
    this.highlightQuery,
  });

  final Track track;

  /// 1 起的展示序号（表格/列表左侧）。
  final int? index;

  /// 当前曲目（左侧音柱 + 标题强调）。
  final bool isPlaying;

  /// 当前曲目是否正在出声（暂停时音柱静止）。
  final bool playing;

  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onMore;
  final void Function(TapDownDetails details)? onSecondaryTapDown;
  final ValueChanged<bool>? onSelectChanged;
  final bool showAlbum;
  final bool showCover;

  /// 表格形态（列宽与行高按表格令牌）。
  final bool tableMode;
  final Widget? trailing;

  /// 搜索命中词：给了就把标题里的命中子串点亮（`TyHighlightedText`）。
  final String? highlightQuery;

  double _height(BuildContext context) => tableMode
      ? context.metrics.tableRowHeight
      : context.metrics.rowHeight;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool touch = context.traits.touchPrimary;
    return TyInteractive(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onSecondaryTapDown: onSecondaryTapDown,
      semanticLabel:
          '${track.title} · ${track.artist} · ${track.album}'
          '${isPlaying ? ' · 正在播放' : ''}',
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, TyInteractionState state) {
        final bool showActions = touch || state.hovered || state.focused || selected;
        final Color? background = selected
            ? ty.colors.surfaceSelected
            : (state.pressed
                  ? ty.colors.surfacePressed
                  : (state.hovered ? ty.colors.surfaceHover : null));
        return Container(
          height: _height(context),
          decoration: BoxDecoration(
            color: background,
            border: Border(
              left: BorderSide(
                color: isPlaying ? ty.colors.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          padding: const EdgeInsets.only(right: TySpace.x8),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: TySize.trackLeading,
                child: Center(
                  child: _LeadingCell(
                    index: index,
                    isPlaying: isPlaying,
                    playing: playing,
                    showPlay: state.hovered && !touch && onTap != null,
                    onPlay: onTap,
                  ),
                ),
              ),
              if (onSelectChanged != null && (selected || showActions))
                Padding(
                  padding: const EdgeInsets.only(right: TySpace.x4),
                  child: _CheckBox(
                    selected: selected,
                    onChanged: () => onSelectChanged!(!selected),
                  ),
                ),
              if (showCover) ...<Widget>[
                TyCover(
                  path: track.coverArtPath,
                  url: track.coverArtUrl,
                  seed: '${track.artist} · ${track.album}',
                  size: tableMode ? 32 : 40,
                  radius: TyRadius.xs,
                ),
                const SizedBox(width: TySpace.x12),
              ],
              Expanded(
                flex: 5,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // 搜索页要把命中子串点亮；其它场景原样 `Text`（少一层 span）。
                    if (highlightQuery == null || highlightQuery!.isEmpty)
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ty.typography.bodyM.copyWith(
                          color: isPlaying
                              ? ty.colors.accent
                              : ty.colors.textPrimary,
                          fontWeight: isPlaying
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      )
                    else
                      TyHighlightedText(
                        text: track.title,
                        query: highlightQuery!,
                        style: ty.typography.bodyM.copyWith(
                          color: isPlaying
                              ? ty.colors.accent
                              : ty.colors.textPrimary,
                          fontWeight: isPlaying
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    const SizedBox(height: 1),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ty.typography.bodyS.copyWith(
                        color: ty.colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (showAlbum && context.formFactor != FormFactor.compact)
                Expanded(
                  flex: 3,
                  child: Text(
                    track.album,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ty.typography.bodyS.copyWith(
                      color: ty.colors.textSecondary,
                    ),
                  ),
                ),
              SizedBox(
                width: TySize.tableDurationColumn,
                child: Text(
                  formatSeconds(track.duration),
                  textAlign: TextAlign.right,
                  style: ty.typography.numericS.copyWith(
                    color: ty.colors.textTertiary,
                  ),
                ),
              ),
              if (onToggleFavorite != null)
                SizedBox(
                  width: TySize.tableFavoriteColumn,
                  child: AnimatedOpacity(
                    duration: TyDuration.fast,
                    opacity: track.isFavorite || showActions ? 1 : 0,
                    child: IconButton(
                      onPressed: onToggleFavorite,
                      tooltip: track.isFavorite ? '取消收藏' : '收藏',
                      iconSize: TyIconSize.normal,
                      splashRadius: 18,
                      color: track.isFavorite
                          ? ty.colors.accent
                          : ty.colors.textTertiary,
                      icon: Icon(
                        track.isFavorite
                            ? Icons.favorite
                            : Icons.favorite_border,
                      ),
                    ),
                  ),
                ),
              ?trailing,
              if (onMore != null)
                SizedBox(
                  width: TySize.tableMoreColumn,
                  child: AnimatedOpacity(
                    duration: TyDuration.fast,
                    opacity: showActions ? 1 : 0,
                    child: IconButton(
                      onPressed: onMore,
                      tooltip: '更多操作',
                      iconSize: TyIconSize.normal,
                      splashRadius: 18,
                      color: ty.colors.textTertiary,
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _LeadingCell extends StatelessWidget {
  const _LeadingCell({
    required this.index,
    required this.isPlaying,
    required this.playing,
    required this.showPlay,
    required this.onPlay,
  });

  final int? index;
  final bool isPlaying;
  final bool playing;
  final bool showPlay;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    if (isPlaying) {
      return TyEqualizer(active: playing);
    }
    if (showPlay) {
      return GestureDetector(
        onTap: onPlay,
        child: Icon(
          Icons.play_arrow_rounded,
          size: TyIconSize.normal,
          color: ty.colors.textPrimary,
        ),
      );
    }
    return Text(
      index == null ? '' : '$index',
      textAlign: TextAlign.center,
      style: ty.typography.numericS.copyWith(color: ty.colors.textTertiary),
    );
  }
}

/// 播放中音柱：4 根柱子的轻动画；暂停静止；减少动态时完全静止。
class TyEqualizer extends StatefulWidget {
  const TyEqualizer({super.key, required this.active, this.size = 14});

  final bool active;
  final double size;

  @override
  State<TyEqualizer> createState() => _TyEqualizerState();
}

class _TyEqualizerState extends State<TyEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(TyEqualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = context.ty.colors.accent;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    const List<double> phases = <double>[0.2, 0.7, 0.45, 0.9];
    return Semantics(
      label: '正在播放',
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: reduceMotion
            ? _bars(accent, const <double>[0.4, 0.8, 0.55, 0.9])
            : AnimatedBuilder(
                animation: _controller,
                builder: (BuildContext context, Widget? child) {
                  final double t = _controller.value;
                  return _bars(accent, <double>[
                    for (final double phase in phases)
                      0.25 + 0.65 * ((t + phase) % 1.0),
                  ]);
                },
              ),
      ),
    );
  }

  Widget _bars(Color color, List<double> heights) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        for (final double h in heights)
          Container(
            width: 2,
            height: widget.size * h,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
      ],
    );
  }
}

class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.selected, required this.onChanged});

  final bool selected;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return TyInteractive(
      onTap: onChanged,
      semanticLabel: selected ? '取消选择' : '选择',
      builder: (BuildContext context, TyInteractionState state) {
        return Container(
          width: TySize.checkbox,
          height: TySize.checkbox,
          decoration: BoxDecoration(
            color: selected ? ty.colors.accent : Colors.transparent,
            borderRadius: TyRadius.xsAll,
            border: Border.all(
              color: selected ? ty.colors.accent : ty.colors.borderStrong,
            ),
          ),
          child: selected
              ? Icon(Icons.check, size: 12, color: ty.colors.onAccent)
              : null,
        );
      },
    );
  }
}

/// 表格排序字段。
enum TySortField { title, artist, album, duration, addedAt }

/// 桌面表格：列头 + 固定行高 + 可选行。
class TyTrackTable extends StatelessWidget {
  const TyTrackTable({
    super.key,
    required this.tracks,
    required this.playingTrackId,
    required this.playing,
    this.selectedIds = const <String>{},
    this.sortField = TySortField.addedAt,
    this.sortAscending = false,
    this.onSort,
    this.onTapTrack,
    this.onToggleFavorite,
    this.onMore,
    this.onSecondaryTapDown,
    this.onSelectChanged,
    this.header,
    this.emptyBuilder,
    this.showHeader = true,
    this.scrollController,
    this.footer,
    this.highlightQuery,
    this.rowBuilder,
  });

  final List<Track> tracks;
  final String? playingTrackId;
  final bool playing;
  final Set<String> selectedIds;
  final TySortField sortField;
  final bool sortAscending;
  final void Function(TySortField field)? onSort;
  final void Function(int index)? onTapTrack;
  final void Function(Track track)? onToggleFavorite;
  final void Function(Track track, Offset position)? onMore;
  final void Function(Track track, TapDownDetails details)? onSecondaryTapDown;
  final void Function(Track track, bool selected)? onSelectChanged;

  /// 列头上方/右侧的工具条，由宿主提供。
  final Widget? header;
  final WidgetBuilder? emptyBuilder;
  final bool showHeader;
  final ScrollController? scrollController;

  /// 表格下方的工具条（例如「已显示 40 / 共 201 首 + 加载更多」）。
  final Widget? footer;

  /// 搜索命中词：给了就把每行标题里的命中子串点亮。
  final String? highlightQuery;

  /// 自定义行构造器：宿主用它把「这一行是不是正在播放」的订阅放进**行自己**里。
  ///
  /// 默认行的播放态来自 `playingTrackId` / `playing`，那要求宿主订阅整份播放快照，
  /// 于是每次进度 tick 都会重建可见的每一行；换成只订阅自己那一行的组件后，
  /// 换曲只重建高亮翻转的行（`ui_rebuild_seek_test` 锁定的口径）。
  final Widget Function(BuildContext context, int index, Track track)? rowBuilder;

  @override
  Widget build(BuildContext context) {
    // 「专辑」列只在 expanded 出现（`DESIGN.md` §5.1）：medium 的窗口宽度里
    // 标题 + 专辑两列会互相挤压，用户更需要标题完整可读。
    final bool showAlbum = context.formFactor == FormFactor.expanded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ?header,
        if (showHeader)
          _TableHeader(
            sortField: sortField,
            ascending: sortAscending,
            onSort: onSort,
            showAlbum: showAlbum,
          ),
        if (showHeader)
          const TyDividerThin(),
        Expanded(
          child: tracks.isEmpty
              ? (emptyBuilder?.call(context) ?? const SizedBox.shrink())
              : ListView.builder(
                  controller: scrollController,
                  itemExtent: context.metrics.tableRowHeight,
                  itemCount: tracks.length,
                  itemBuilder: (BuildContext context, int i) {
                    final Track track = tracks[i];
                    if (rowBuilder != null) {
                      return rowBuilder!(context, i, track);
                    }
                    // 用行自己的 RenderBox 当菜单锚点：⋯ 与右键都落在这一行上，
                    // 而不是页面左上角（`Offset.zero` 会退化成那里）。
                    return Builder(
                      builder: (BuildContext rowContext) => TyTrackRow(
                      track: track,
                      index: i + 1,
                      tableMode: true,
                      showAlbum: showAlbum,
                      highlightQuery: highlightQuery,
                      isPlaying: track.id == playingTrackId,
                      playing: track.id == playingTrackId && playing,
                      selected: selectedIds.contains(track.id),
                      onTap: onTapTrack == null ? null : () => onTapTrack!(i),
                      onDoubleTap: onTapTrack == null
                          ? null
                          : () => onTapTrack!(i),
                      onToggleFavorite: onToggleFavorite == null
                          ? null
                          : () => onToggleFavorite!(track),
                      onMore: onMore == null
                          ? null
                          : () => onMore!(track, _rowOrigin(rowContext)),
                      onSecondaryTapDown: onSecondaryTapDown == null
                          ? null
                          : (TapDownDetails d) =>
                                onSecondaryTapDown!(track, d),
                      onSelectChanged: onSelectChanged == null
                          ? null
                          : (bool value) => onSelectChanged!(track, value),
                      ),
                    );
                  },
                ),
        ),
        ?footer,
      ],
    );
  }
}

class TyDividerThin extends StatelessWidget {
  const TyDividerThin({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    color: context.ty.colors.border,
  );
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({
    required this.sortField,
    required this.ascending,
    required this.onSort,
    required this.showAlbum,
  });

  final TySortField sortField;
  final bool ascending;
  final void Function(TySortField field)? onSort;
  final bool showAlbum;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return SizedBox(
      height: TySpace.x32,
      child: Padding(
        padding: const EdgeInsets.only(right: TySpace.x8),
        child: Row(
          children: <Widget>[
            const SizedBox(width: TySize.trackLeading),
            SizedBox(width: TySize.tableCheckboxColumn),
            const SizedBox(width: TySize.tableCoverColumn + TySpace.x12),
            _SortLabel(
              label: '标题',
              field: TySortField.title,
              active: sortField,
              ascending: ascending,
              onSort: onSort,
              flex: 5,
            ),
            if (showAlbum)
              _SortLabel(
                label: '专辑',
                field: TySortField.album,
                active: sortField,
                ascending: ascending,
                onSort: onSort,
                flex: 3,
              ),
            SizedBox(
              width: TySize.tableDurationColumn,
              child: Text(
                '时长',
                textAlign: TextAlign.right,
                style: ty.typography.labelS.copyWith(
                  color: ty.colors.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: TySize.tableHeaderTrailing),
          ],
        ),
      ),
    );
  }
}

class _SortLabel extends StatelessWidget {
  const _SortLabel({
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
  final void Function(TySortField field)? onSort;
  final int flex;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final bool isActive = active == field;
    return Expanded(
      flex: flex,
      child: TyInteractive(
        onTap: onSort == null ? null : () => onSort!(field),
        semanticLabel: '$label 排序',
        semanticButton: true,
        builder: (BuildContext context, TyInteractionState state) {
          return Container(
            color: state.overlay(ty.colors),
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: ty.typography.labelS.copyWith(
                    color: isActive
                        ? ty.colors.textPrimary
                        : ty.colors.textTertiary,
                  ),
                ),
                if (isActive)
                  Icon(
                    ascending
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_downward_rounded,
                    size: 12,
                    color: ty.colors.textPrimary,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 紧凑列表：固定行高，虚拟滚动。
class TyTrackList extends StatelessWidget {
  const TyTrackList({
    super.key,
    required this.tracks,
    required this.playingTrackId,
    required this.playing,
    this.onTapTrack,
    this.onToggleFavorite,
    this.onMore,
    this.onSecondaryTapDown,
    this.header,
    this.emptyBuilder,
    this.padding = EdgeInsets.zero,
    this.scrollController,
    this.selectedIds = const <String>{},
    this.onSelectChanged,
    this.showAlbum = false,
    this.footer,
    this.highlightQuery,
    this.rowBuilder,
  });

  final List<Track> tracks;
  final String? playingTrackId;
  final bool playing;
  final void Function(int index)? onTapTrack;
  final void Function(Track track)? onToggleFavorite;

  /// ⋯ 按钮：位置是行左上角的全局坐标（与 [TyTrackTable] 一致）。
  final void Function(Track track, Offset position)? onMore;
  final void Function(Track track, TapDownDetails details)? onSecondaryTapDown;
  final Widget? header;
  final WidgetBuilder? emptyBuilder;
  final EdgeInsets padding;
  final ScrollController? scrollController;
  final Set<String> selectedIds;
  final void Function(Track track, bool selected)? onSelectChanged;
  final bool showAlbum;

  /// 列表下方的工具条（例如「已显示 40 / 共 201 首 + 加载更多」）。
  final Widget? footer;

  /// 搜索命中词：给了就把每行标题里的命中子串点亮。
  final String? highlightQuery;

  /// 自定义行构造器；语义与 [TyTrackTable.rowBuilder] 相同。
  final Widget Function(BuildContext context, int index, Track track)? rowBuilder;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return emptyBuilder?.call(context) ?? const SizedBox.shrink();
    }
    return CustomScrollView(
      controller: scrollController,
      slivers: <Widget>[
        if (header != null) SliverToBoxAdapter(child: header),
        SliverPadding(
          padding: padding,
          sliver: SliverFixedExtentList(
            itemExtent: context.metrics.rowHeight,
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int i) {
                final Track track = tracks[i];
                if (rowBuilder != null) {
                  return rowBuilder!(context, i, track);
                }
                return Builder(
                  builder: (BuildContext rowContext) => TyTrackRow(
                  track: track,
                  index: i + 1,
                  showAlbum: showAlbum,
                  highlightQuery: highlightQuery,
                  isPlaying: track.id == playingTrackId,
                  playing: track.id == playingTrackId && playing,
                  selected: selectedIds.contains(track.id),
                  onTap: onTapTrack == null ? null : () => onTapTrack!(i),
                  onToggleFavorite: onToggleFavorite == null
                      ? null
                      : () => onToggleFavorite!(track),
                  onMore: onMore == null
                      ? null
                      : () => onMore!(track, _rowOrigin(rowContext)),
                  onSecondaryTapDown: onSecondaryTapDown == null
                      ? null
                      : (TapDownDetails d) =>
                            onSecondaryTapDown!(track, d),
                  onSelectChanged: onSelectChanged == null
                      ? null
                      : (bool value) => onSelectChanged!(track, value),
                  ),
                );
              },
              childCount: tracks.length,
            ),
          ),
        ),
        if (footer != null) SliverToBoxAdapter(child: footer),
      ],
    );
  }
}

/// 行左上角的全局坐标：右键/⋯ 菜单的锚点。
///
/// 行不知道自己被放在哪里，宿主也不该替它猜，所以由行自己上报一次坐标。
Offset _rowOrigin(BuildContext rowContext) {
  final RenderObject? box = rowContext.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    return box.localToGlobal(Offset.zero);
  }
  return Offset.zero;
}
