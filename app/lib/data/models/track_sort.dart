/// 歌曲列表排序字段：URL `sort=` 的 slug 与 UI 文案的唯一来源（data 层不依赖 UI）。
///
/// 排序落到 SQL 的哪一列由仓储按 [slug] 之外的枚举分支决定，不在这里暴露列名：
/// 列名属于库表细节，元素名才是对外的稳定标识。
enum TrackSortField {
  title('title', '标题'),
  artist('artist', '艺术家'),
  album('album', '专辑'),
  duration('duration', '时长'),
  addedAt('added', '最近添加');

  const TrackSortField(this.slug, this.label);

  /// URL/query 参数里的稳定标识。
  final String slug;

  /// 排序菜单/列头文案。
  final String label;

  /// 未知或缺失一律回落到 [title]（深链容错）。
  static TrackSortField fromSlug(String? value) => values.firstWhere(
    (TrackSortField field) => field.slug == value,
    orElse: () => title,
  );
}
