import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;

import '../../data/cover_store.dart';
import '../../data/models/scanned_track.dart';

/// 一次目录扫描的结果。
class LocalScanResult {
  const LocalScanResult({
    required this.tracks,
    required this.unreadableFiles,
    required this.unreadableDirectories,
    required this.cancelled,
    required this.truncated,
  });

  final List<ScannedTrack> tracks;

  /// 统计/读取失败、未能生成任何事实的文件数（不影响其余文件入库）。
  final int unreadableFiles;

  /// 无法枚举的目录数；根目录不存在也计为一个。
  final int unreadableDirectories;

  final bool cancelled;

  final bool truncated;

  bool get isAuthoritative =>
      !cancelled &&
      !truncated &&
      unreadableFiles == 0 &&
      unreadableDirectories == 0;
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

  static bool isSupported(String path) => supportedExtensions.contains(
    p.extension(path).toLowerCase().replaceFirst('.', ''),
  );

  /// 扫描目录。
  ///
  /// [known] 是库里已经记下的文件事实（大小 + 修改时间）。两者都没变的文件直接按
  /// "文件事实已知"处理，跳过标签解析与封面落盘 —— 曲库越大，重复扫描的收益越明显
  /// （几千个文件原本每次同步都要把每个文件的标签与内嵌封面重新读一遍、写一遍）。
  /// 合并层只覆盖"文件事实"，不会用这份稀疏结果覆盖已有的标题/封面/歌词。
  Future<LocalScanResult> scan(
    Directory root, {
    void Function(int done, int total, String path)? onProgress,
    bool Function()? isCancelled,
    KnownFileFacts known = noKnownFileFacts,
    int batchSize = 64,
  }) async {
    final _CollectedFiles collected = _collectFiles(root);
    if (collected.files.isEmpty) {
      return LocalScanResult(
        tracks: const <ScannedTrack>[],
        unreadableFiles: 0,
        unreadableDirectories: collected.unreadableDirectories,
        cancelled: isCancelled?.call() ?? false,
        truncated: collected.truncated,
      );
    }
    final String coversDirectory = (await _coverStore.coversDirectory()).path;

    final List<ScannedTrack> tracks = <ScannedTrack>[];
    int unreadable = 0;

    for (int start = 0; start < collected.files.length; start += batchSize) {
      if (isCancelled?.call() ?? false) {
        return LocalScanResult(
          tracks: tracks,
          unreadableFiles: unreadable,
          unreadableDirectories: collected.unreadableDirectories,
          cancelled: true,
          truncated: collected.truncated,
        );
      }
      final List<String> batch = collected.files.sublist(
        start,
        math.min(start + batchSize, collected.files.length),
      );
      final _BatchResult result = await Isolate.run(
        () => _scanBatch(batch, coversDirectory, known),
      );
      tracks.addAll(result.tracks);
      unreadable += result.unreadable;
      onProgress?.call(
        math.min(start + batch.length, collected.files.length),
        collected.files.length,
        batch.last,
      );
    }

    return LocalScanResult(
      tracks: tracks,
      unreadableFiles: unreadable,
      unreadableDirectories: collected.unreadableDirectories,
      cancelled: false,
      truncated: collected.truncated,
    );
  }

  _CollectedFiles _collectFiles(Directory root) {
    final List<String> files = <String>[];
    if (!root.existsSync()) {
      return const _CollectedFiles(
        files: <String>[],
        unreadableDirectories: 1,
        truncated: false,
      );
    }
    int unreadableDirectories = 0;
    final List<Directory> pending = <Directory>[root];
    while (pending.isNotEmpty) {
      final Directory dir = pending.removeLast();
      final List<FileSystemEntity> entries;
      try {
        // 不跟随符号链接，避免自引用目录导致无限递归。
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        unreadableDirectories++;
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
            return _CollectedFiles(
              files: files,
              unreadableDirectories: unreadableDirectories,
              truncated: true,
            );
          }
        }
      }
    }
    files.sort();
    return _CollectedFiles(
      files: files,
      unreadableDirectories: unreadableDirectories,
      truncated: false,
    );
  }
}

class _CollectedFiles {
  const _CollectedFiles({
    required this.files,
    required this.unreadableDirectories,
    required this.truncated,
  });

  final List<String> files;

  final int unreadableDirectories;

  final bool truncated;
}

class _BatchResult {
  const _BatchResult(this.tracks, this.unreadable);

  final List<ScannedTrack> tracks;

  final int unreadable;
}

/// 在子 isolate 中执行：只依赖路径与封面目录，不触碰数据库。
_BatchResult _scanBatch(
  List<String> paths,
  String coversDirectory,
  KnownFileFacts known,
) {
  final List<ScannedTrack> tracks = <ScannedTrack>[];
  int unreadable = 0;
  for (final String path in paths) {
    try {
      final FileStat stat = File(path).statSync();
      final ({int size, DateTime? modified})? previous = known[path];
      if (previous != null &&
          previous.size == stat.size &&
          _sameInstant(previous.modified, stat.modified)) {
        // 文件没动过：标签、封面、时长都还是库里那一份，不必再解析一遍。
        tracks.add(_unchangedTrack(path, stat));
        continue;
      }
      tracks.add(_scanFile(path, coversDirectory, stat: stat));
    } on Object {
      // 单个文件无论如何都不该让整批（乃至整次扫描）失败：列目录与真正读取
      // 之间文件可能已被删除/改权限，任何异常都只记一次「读不了」。
      unreadable++;
    }
  }
  return _BatchResult(tracks, unreadable);
}

/// 两次 stat 的时间是否表示同一时刻。
///
/// `DateTime.==` 还比较 `isUtc`：库里那份经过 drift 往返可能变成 UTC，而
/// `FileStat.modified` 是本地时间，直接用 `==` 会让"没变过"永远判成"变了"。
bool _sameInstant(DateTime? a, DateTime b) =>
    a != null && a.isAtSameMomentAs(b);

/// 文件没变化时的稀疏结果：只有文件事实，标签留空。
///
/// 合并层（`TrackRepository._withFileFacts`）对空标签的处理是"保留库里已有的值"，
/// 所以这份稀疏结果不会把已解析的标题、时长、封面抹掉。
ScannedTrack _unchangedTrack(String path, FileStat stat) => ScannedTrack(
  filePathOrUrl: path,
  title: p.basenameWithoutExtension(path),
  fileFormat: p.extension(path).toLowerCase().replaceFirst('.', ''),
  fileSize: stat.size,
  lastModified: stat.modified,
);

ScannedTrack _scanFile(
  String path,
  String coversDirectory, {
  FileStat? stat,
}) {
  final File file = File(path);
  final FileStat fileStat = stat ?? file.statSync();
  final String extension = p
      .extension(path)
      .toLowerCase()
      .replaceFirst('.', '');

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
      coverArtPath = _writeCover(
        coversDirectory,
        path,
        metadata.pictures.first.bytes,
      );
    }
  } on MetadataParserException {
    // 该容器/标签不被支持（如裸 AAC）：保留文件名与文件事实，其余留空由后续补全。
  } on UnsupportedError {
    // 同上，不同版本抛出的异常类型不一致。
  } on Object {
    // audio_metadata_reader 在「扩展名受支持、内容却没有任何解析器认领」时抛的是
    // NoMetadataParserException —— 它 implements Exception，**不是**
    // MetadataParserException 的子类（见包的 utils/metadata_parser_exception.dart）。
    // 只捕获上面两种类型会让一个裸 ADTS 的 .aac / 改名后的垃圾 .mp3 直接把异常
    // 抛出 isolate，整次扫描一首都不入库。这里按类文档的契约兜住：
    // 该文件保留文件名与文件事实，其余留空交给后续补全。
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
    fileSize: fileStat.size,
    lastModified: fileStat.modified,
    coverArtPath: coverArtPath,
    lyrics: lyrics,
  );
}

String? _writeCover(String coversDirectory, String path, List<int> bytes) {
  // 与 CoverStore 用同一个内容寻址命名：同一张专辑封面在每首歌里都嵌了一份，
  // 按内容命名才能让整张专辑共用盘上的同一个文件。
  final String name = CoverStore.coverNameFor(
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
  );
  final File file = File(p.join(coversDirectory, name));
  // 扫描是重复发生的：内容没变就不要重写盘（5000 首的重复扫描会白写几百 MB）。
  if (!file.existsSync() || file.lengthSync() != bytes.length) {
    file.writeAsBytesSync(bytes, flush: false);
  }
  return name;
}

String? _nonEmpty(String? value) {
  final String? trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
