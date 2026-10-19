/// 曲库桌面表格按 P2 的实际内容宽度逐级收拢列。
///
/// 宽度阈值计算已经扣除页面左右留白；调用方传入的是可供表格使用的宽度。
enum LibraryTableColumns {
  full(showArtist: true, showAlbum: true, showSource: true, showIndex: true),
  withoutAlbum(
    showArtist: true,
    showAlbum: false,
    showSource: true,
    showIndex: true,
  ),
  withoutArtist(
    showArtist: false,
    showAlbum: false,
    showSource: true,
    showIndex: true,
  ),
  withoutSource(
    showArtist: false,
    showAlbum: false,
    showSource: false,
    showIndex: true,
  ),
  single(
    showArtist: false,
    showAlbum: false,
    showSource: false,
    showIndex: false,
  );

  const LibraryTableColumns({
    required this.showArtist,
    required this.showAlbum,
    required this.showSource,
    required this.showIndex,
  });

  final bool showArtist;
  final bool showAlbum;
  final bool showSource;
  final bool showIndex;

  static LibraryTableColumns forContentWidth(double width) {
    if (width >= 864) {
      return full;
    }
    if (width >= 708) {
      return withoutAlbum;
    }
    if (width >= 560) {
      return withoutArtist;
    }
    if (width >= 460) {
      return withoutSource;
    }
    return single;
  }
}
