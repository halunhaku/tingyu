/// 搜索范围（`docs/UX_REDESIGN.md` §5.5 的分段）。
///
/// 来源不进搜索：数量少，而且「我的」里就能看到。
enum SearchScope {
  all('all', '全部'),
  songs('songs', '歌曲'),
  albums('albums', '专辑'),
  artists('artists', '艺术家'),
  playlists('playlists', '歌单');

  const SearchScope(this.slug, this.label);

  /// URL `?scope=` 的稳定标识。
  final String slug;

  /// 分段控件文案。
  final String label;

  /// 未知或缺失一律回落到 [all]（深链容错）。
  static SearchScope fromSlug(String? value) => values.firstWhere(
    (SearchScope scope) => scope.slug == value,
    orElse: () => SearchScope.all,
  );
}
