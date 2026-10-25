import 'package:flutter/foundation.dart';

import 'track_sort.dart';

/// 曲库（或搜索分组）列表的查询参数：值相等即同一查询，可直接当 `family` 的缓存键。
@immutable
class LibraryQuery {
  const LibraryQuery({
    this.text = '',
    this.favoritesOnly = false,
    this.sourceId,
    this.sort = TrackSortField.title,
    this.ascending = true,
  });

  /// 文本过滤；空串表示**不过滤**（列全库），与搜索页「没输入就没结果」不同。
  final String text;

  /// 只看收藏。
  final bool favoritesOnly;

  /// 限定来源；null 表示全部来源。
  final String? sourceId;

  final TrackSortField sort;

  /// 升序（`false` = 降序）。
  final bool ascending;

  bool get hasText => text.trim().isNotEmpty;

  LibraryQuery copyWith({
    String? text,
    bool? favoritesOnly,
    String? sourceId,
    bool clearSourceId = false,
    TrackSortField? sort,
    bool? ascending,
  }) {
    return LibraryQuery(
      text: text ?? this.text,
      favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      sourceId: clearSourceId ? null : (sourceId ?? this.sourceId),
      sort: sort ?? this.sort,
      ascending: ascending ?? this.ascending,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is LibraryQuery &&
        other.text == text &&
        other.favoritesOnly == favoritesOnly &&
        other.sourceId == sourceId &&
        other.sort == sort &&
        other.ascending == ascending;
  }

  @override
  int get hashCode => Object.hash(text, favoritesOnly, sourceId, sort, ascending);

  @override
  String toString() =>
      'LibraryQuery(text: "$text", favoritesOnly: $favoritesOnly, '
      'source: $sourceId, ${sort.slug} ${ascending ? 'asc' : 'desc'})';
}

/// 单页请求：查询参数 + 偏移量。页面自己决定加载到第几页，
/// provider 只负责「这一页取回来」，避免把滚动状态塞进 provider。
@immutable
class LibraryPageRequest {
  const LibraryPageRequest({
    required this.query,
    this.offset = 0,
    this.limit = 40,
  });

  final LibraryQuery query;
  final int offset;
  final int limit;

  LibraryPageRequest nextPage() =>
      LibraryPageRequest(query: query, offset: offset + limit, limit: limit);

  @override
  bool operator ==(Object other) {
    return other is LibraryPageRequest &&
        other.query == query &&
        other.offset == offset &&
        other.limit == limit;
  }

  @override
  int get hashCode => Object.hash(query, offset, limit);

  @override
  String toString() => 'LibraryPageRequest($query, offset: $offset, limit: $limit)';
}

/// 搜索分组单页请求（歌曲 / 专辑 / 艺人 / 歌单四组共用的缓存键）。
@immutable
class SearchPageRequest {
  const SearchPageRequest({required this.text, this.offset = 0, this.limit = 40});

  final String text;
  final int offset;
  final int limit;

  SearchPageRequest nextPage() =>
      SearchPageRequest(text: text, offset: offset + limit, limit: limit);

  @override
  bool operator ==(Object other) {
    return other is SearchPageRequest &&
        other.text == text &&
        other.offset == offset &&
        other.limit == limit;
  }

  @override
  int get hashCode => Object.hash(text, offset, limit);

  @override
  String toString() => 'SearchPageRequest("$text", offset: $offset, limit: $limit)';
}
