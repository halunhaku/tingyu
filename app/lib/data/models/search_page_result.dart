import 'package:flutter/foundation.dart';

/// 分页查询结果：`items` 是当前页，`total` 是真实 COUNT（不是本页长度）。
///
/// 分开两个字段而不是让调用方拿 `items.length` 当总数：列表滚动条、"共 N 条"
/// 这类界面需要的是过滤后的全量，而分页查询永远只读回一页。
@immutable
class SearchPageResult<T> {
  const SearchPageResult({required this.items, required this.total});

  final List<T> items;

  final int total;

  bool get isEmpty => items.isEmpty;
}
