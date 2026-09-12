import 'package:flutter/foundation.dart';

/// 一次扫描/列举产出的曲目事实。
///
/// 本地扫描与远端来源（WebDAV / Quark）共用同一结构：合并层只认它，
/// 不必知道数据来自文件系统还是网络。
@immutable
class ScannedTrack {
  const ScannedTrack({
    required this.filePathOrUrl,
    required this.title,
    this.artist = unknownArtist,
    this.album = unknownAlbum,
    this.duration = 0,
    this.trackNumber,
    this.discNumber,
    this.year,
    this.genre,
    this.bitrate,
    this.sampleRate,
    this.fileFormat = 'mp3',
    this.fileSize = 0,
    this.etag,
    this.lastModified,
    this.coverArtPath,
    this.coverArtUrl,
    this.lyrics,
  });

  /// 占位值：与旧版 Swift 实现保持一致，合并时据此判断"元数据是否还没补上"。
  static const String unknownArtist = '未知艺术家';

  static const String unknownAlbum = '未知专辑';

  /// 旧版用于标记远端来源的专辑占位值，合并时同样视为占位。
  static const Set<String> placeholderAlbums = <String>{
    unknownAlbum,
    '夸克曲库',
    'WebDAV 曲库',
  };

  /// 本地绝对路径或远端 URL；同一来源内唯一，是合并的匹配键。
  final String filePathOrUrl;

  final String title;

  final String artist;

  final String album;

  /// 秒。
  final double duration;

  final int? trackNumber;

  final int? discNumber;

  final int? year;

  final String? genre;

  final int? bitrate;

  final int? sampleRate;

  final String fileFormat;

  final int fileSize;

  final String? etag;

  final DateTime? lastModified;

  /// 已落盘的封面缓存文件名（由 `CoverStore` 管理）。
  final String? coverArtPath;

  final String? coverArtUrl;

  final String? lyrics;
}
