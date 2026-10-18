import 'package:flutter/foundation.dart';

import '../../data/models/track_sort.dart';
import '../../design/components/track.dart' show TySortField;

/// 曲库根页的排序 / 来源过滤视图状态。
///
/// 这里是 URL query、表格列头与排序菜单三者的**唯一映射处**：raw slug 只在这一层
/// 与 [TrackSortField] 互转，页面与组件不各自解析字符串。
@immutable
class LibraryViewState {
  const LibraryViewState({
    this.sort = TrackSortField.title,
    this.ascending = true,
    this.sourceId,
  });

  /// 默认视图：标题升序、全部来源。
  static const LibraryViewState initial = LibraryViewState();

  final TrackSortField sort;
  final bool ascending;
  final String? sourceId;

  /// URL query → 视图状态。未知 `sort` 回落标题升序（深链容错）。
  ///
  /// [fallback] 给「最近添加」这类默认排序不是标题的入口用：query 里没写 `sort`
  /// 时用它，而不是一律回落标题。
  factory LibraryViewState.fromQuery(
    Map<String, String> query, {
    LibraryViewState fallback = LibraryViewState.initial,
  }) {
    final String? source = query['source']?.trim();
    final String? sort = query['sort']?.trim();
    return LibraryViewState(
      sort: (sort == null || sort.isEmpty)
          ? fallback.sort
          : TrackSortField.fromSlug(sort),
      ascending: query['dir'] == null
          ? fallback.ascending
          : query['dir'] != 'desc',
      sourceId: (source == null || source.isEmpty) ? null : source,
    );
  }

  /// 视图状态 → URL query；默认值不写进 URL，链接短且稳定。
  Map<String, String> toQuery([LibraryViewState? defaults]) {
    final LibraryViewState base = defaults ?? LibraryViewState.initial;
    return <String, String>{
      if (sort != base.sort) 'sort': sort.slug,
      if (ascending != base.ascending) 'dir': ascending ? 'asc' : 'desc',
      'source': ?sourceId,
    };
  }

  LibraryViewState copyWith({
    TrackSortField? sort,
    bool? ascending,
    String? sourceId,
    bool clearSourceId = false,
  }) {
    return LibraryViewState(
      sort: sort ?? this.sort,
      ascending: ascending ?? this.ascending,
      sourceId: clearSourceId ? null : (sourceId ?? this.sourceId),
    );
  }

  /// 点击表格列头：同一列反向；换列用该列的默认方向（入库时间默认最新在前）。
  LibraryViewState toggle(TrackSortField next) {
    if (next == sort) {
      return copyWith(ascending: !ascending);
    }
    return copyWith(sort: next, ascending: next != TrackSortField.addedAt);
  }

  /// 表格列头 ↔ 排序字段（组件层的枚举只在 UI 里流动）。
  TySortField get tableField => switch (sort) {
    TrackSortField.title => TySortField.title,
    TrackSortField.artist => TySortField.artist,
    TrackSortField.album => TySortField.album,
    TrackSortField.duration => TySortField.duration,
    TrackSortField.addedAt => TySortField.addedAt,
  };

  static TrackSortField fromTableField(TySortField field) => switch (field) {
    TySortField.title => TrackSortField.title,
    TySortField.artist => TrackSortField.artist,
    TySortField.album => TrackSortField.album,
    TySortField.duration => TrackSortField.duration,
    TySortField.addedAt => TrackSortField.addedAt,
  };

  // 值相等：路由 query 没变时 `didUpdateWidget` 必须判定「没变」，
  // 否则每次父级重建都会把分页打回第一页。
  @override
  bool operator ==(Object other) {
    return other is LibraryViewState &&
        other.sort == sort &&
        other.ascending == ascending &&
        other.sourceId == sourceId;
  }

  @override
  int get hashCode => Object.hash(sort, ascending, sourceId);

  @override
  String toString() =>
      'LibraryViewState(sort: $sort, ascending: $ascending, sourceId: $sourceId)';
}
