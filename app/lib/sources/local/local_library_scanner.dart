import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;

import '../../data/cover_store.dart';
import '../../data/models/scanned_track.dart';

/// 一次目录扫描的结果。
class LocalScanResult {
  const LocalScanResult({
    required this.tracks,
    required this.unreadableFiles,
    required this.cancelled,
  });

  final List<ScannedTrack> tracks;

  /// 统计/读取失败、未能生成任何事实的文件数（不影响其余文件入库）。
  final int unreadableFiles;

  final bool cancelled;
}

/// 本地音乐目录扫描，对齐旧版 `Sources/Services/Library/LocalLibraryScanner.swift`。
///
/// 遍历在主 isolate（很快），标签解析分批丢到后台 isolate：
/// 上千个文件时主线程不会被解析阻塞（M2 验收条件）。
class LocalLibraryScanner {
  LocalLibraryScanner({CoverStore? coverStore, this.maxFiles = 5000})
      : _coverStore = coverStore ?? CoverStore();

  /// 与旧版 Swift 的 `supportedExtensions` 保持一致。
  static const Set<String> supportedExtensions = <String>{
    'mp3',
    'flac',
    'm4a',
    'aac',
    'wav',
    'ogg',
    'opus',
    'aiff',
    'alac',
  };

  final CoverStore _coverStore;

  /// 单次扫描的文件数上限，防止误选根目录时把内存打满。
  final int maxFiles;

  static bool isSupported(String path) =>
      supportedExtensions.contains(p.extension(path).toLowerCase().replaceFirst('.', ''));

  Future<LocalScanResult> scan(
    Directory root, {
    void Function(int done, int total, String path)? onProgress,
    bool Function()? isCancelled,
    int batchSize = 64,
  }) async {
    final List<String> files = _collectFiles(root);
    final String coversDirectory = (await _coverStore.coversDirectory()).path;

    final List<ScannedTrack> tracks = <ScannedTrack>[];
    int unreadable = 0;

    for (int start = 0; start < files.length; start += batchSize) {
      if (isCancelled?.call() ?? false) {
        return LocalScanResult(tracks: tracks, unreadableFiles: unreadable, cancelled: true);
      }
      final List<String> batch = files.sublist(start, math.min(start + batchSize, files.length));
      final _BatchResult result = await Isolate.run(() => _scanBatch(batch, coversDirectory));
      tracks.addAll(result.tracks);
      unreadable += result.unreadable;
      onProgress?.call(math.min(start + batch.length, files.length), files.length, batch.last);
    }

    return LocalScanResult(tracks: tracks, unreadableFiles: unreadable, cancelled: false);
  }

  List<String> _collectFiles(Directory root) {
    final List<String> files = <String>[];
    if (!root.existsSync()) {
      return files;
    }
    final List<Directory> pending = <Directory>[root];
    while (pending.isNotEmpty) {
      final Directory dir = pending.removeLast();
      final List<FileSystemEntity> entries;
      try {
        // 不跟随符号链接，避免自引用目录导致无限递归。
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final FileSystemEntity entry in entries) {
        if (p.basename(entry.path).startsWith('.')) {
          continue;
        }
        if (entry is Directory) {
          pending.add(entry);
        } else if (entry is File && isSupported(entry.path)) {
          files.add(entry.path);
          if (files.length >= maxFiles) {
            files.sort();
            return files;
          }
        }
      }
    }
    files.sort();
    return files;
  }
}

class _BatchResult {
  const _BatchResult(this.tracks, this.unreadable);

  final List<ScannedTrack> tracks;

  final int unreadable;
}

/// 在子 isolate 中执行：只依赖路径与封面目录，不触碰数据库。
_BatchResult _scanBatch(List<String> paths, String coversDirectory) {
  final List<ScannedTrack> tracks = <ScannedTrack>[];
  int unreadable = 0;
  for (final String path in paths) {
    try {
      tracks.add(_scanFile(path, coversDirectory));
    } on FileSystemException {
      unreadable++;
    }
  }
  return _BatchResult(tracks, unreadable);
}

ScannedTrack _scanFile(String path, String coversDirectory) {
  final File file = File(path);
  final FileStat stat = file.statSync();
  final String extension = p.extension(path).toLowerCase().replaceFirst('.', '');

  String title = p.basenameWithoutExtension(path);
  String artist = ScannedTrack.unknownArtist;
  String album = ScannedTrack.unknownAlbum;
  double duration = 0;
  int? trackNumber;
  int? discNumber;
  int? year;
  int? bitrate;
  int? sampleRate;
  String? genre;
  String? lyrics;
  String? coverArtPath;

  try {
    final AudioMetadata metadata = readMetadata(file, getImage: true);
    title = _nonEmpty(metadata.title) ?? title;
    artist = _nonEmpty(metadata.artist) ?? artist;
    album = _nonEmpty(metadata.album) ?? album;
    final Duration? parsedDuration = metadata.duration;
    if (parsedDuration != null && parsedDuration > Duration.zero) {
      duration = parsedDuration.inMilliseconds / 1000;
    }
    trackNumber = metadata.trackNumber;
    discNumber = metadata.discNumber;
    year = metadata.year?.year;
    genre = metadata.genres.isEmpty ? null : metadata.genres.first;
    bitrate = metadata.bitrate;
    sampleRate = metadata.sampleRate;
    lyrics = _nonEmpty(metadata.lyrics);
    if (metadata.pictures.isNotEmpty) {
      coverArtPath = _writeCover(coversDirectory, path, metadata.pictures.first.bytes);
    }
  } on MetadataParserException {
    // 该容器/标签不被支持（如裸 AAC）：保留文件名与文件事实，其余留空由后续补全。
  } on UnsupportedError {
    // 同上，不同版本抛出的异常类型不一致。
  }

  return ScannedTrack(
    filePathOrUrl: path,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    trackNumber: trackNumber,
    discNumber: discNumber,
    year: year,
    genre: genre,
    bitrate: bitrate,
    sampleRate: sampleRate,
    fileFormat: extension.isEmpty ? 'mp3' : extension,
    fileSize: stat.size,
    lastModified: stat.modified,
    coverArtPath: coverArtPath,
    lyrics: lyrics,
  );
}

String? _writeCover(String coversDirectory, String path, List<int> bytes) {
  final String name = CoverStore.fileNameFor(path, extension: bytes.length >= 8 && bytes[0] == 0x89 ? '.png' : '.jpg');
  File(p.join(coversDirectory, name)).writeAsBytesSync(bytes, flush: false);
  return name;
}

String? _nonEmpty(String? value) {
  final String? trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
