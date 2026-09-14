import 'package:flutter/foundation.dart';

/// 艺术家聚合行。
@immutable
class ArtistSummary {
  const ArtistSummary({required this.name, required this.trackCount});

  final String name;

  final int trackCount;
}

/// 专辑聚合行（按 `artist + album` 归并，与旧版 `LibraryGrouping.albums` 一致）。
@immutable
class AlbumSummary {
  const AlbumSummary({
    required this.artist,
    required this.album,
    required this.trackCount,
    this.year,
    this.coverArtPath,
  });

  final String artist;

  final String album;

  final int trackCount;

  final int? year;

  /// 该专辑任一曲目的封面缓存文件名。
  final String? coverArtPath;
}

/// 一次扫描合并的结果，用于同步状态展示。
@immutable
class MergeResult {
  const MergeResult({required this.added, required this.updated, required this.removed});

  static const MergeResult empty = MergeResult(added: 0, updated: 0, removed: 0);

  final int added;

  final int updated;

  final int removed;

  int get total => added + updated + removed;
}
