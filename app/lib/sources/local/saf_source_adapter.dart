import 'package:path/path.dart' as p;
import 'package:tingyu_saf/tingyu_saf.dart';

import '../../data/models/scanned_track.dart';
import '../../playback/playback_item.dart';
import '../source_adapter.dart';
import '../scraper/smart_title_parser.dart';
import 'local_library_scanner.dart';

/// Android 本地目录来源（SAF 授权目录）。
///
/// 与 [LocalSourceAdapter] 的区别只在"怎么拿到文件"：
/// 这里所有的读写都通过 `content://` URI 走系统 DocumentProvider，
/// 因此不受分区存储限制，也不需要 `READ_MEDIA_AUDIO`。
/// 文件名解析、扩展名过滤、批量上限与取消语义与本地扫描器保持一致。
class SafSourceAdapter implements SourceAdapter {
  SafSourceAdapter({
    required this.sourceId,
    required this.treeUri,
    this.maxDepth = 8,
    this.maxFiles = 5000,
  });

  /// 用户在系统选择器里授权的目录（持久化授权，存于 `music_sources.local_bookmark`）。
  final String treeUri;

  final int maxDepth;

  final int maxFiles;

  @override
  final String sourceId;

  @override
  Future<SourceScanResult> scan({
    void Function(int done, String name)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!await TingyuSaf.hasPermission(treeUri)) {
      throw const SafPermissionLostException();
    }

    final List<ScannedTrack> tracks = <ScannedTrack>[];
    int skipped = 0;
    bool cancelled = false;

    final List<_SafDirectory> queue = <_SafDirectory>[
      const _SafDirectory(depth: 0),
    ];
    while (queue.isNotEmpty && tracks.length < maxFiles && !cancelled) {
      final _SafDirectory directory = queue.removeAt(0);
      if (directory.depth > maxDepth) {
        continue;
      }
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }

      final List<SafEntry> children;
      try {
        children = await TingyuSaf.listChildren(treeUri, parentDocumentId: directory.documentId);
      } on Object {
        // 单个目录读不到（权限被撤销 / 提供方异常）不阻断整体扫描。
        skipped++;
        continue;
      }

      for (final SafEntry entry in children) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        if (entry.name.startsWith('.')) {
          continue;
        }
        if (entry.isDirectory) {
          queue.add(_SafDirectory(documentId: entry.documentId, depth: directory.depth + 1));
          continue;
        }
        if (!LocalLibraryScanner.isSupported(entry.name)) {
          continue;
        }

        final ScannedTrack track = _toTrack(entry);
        tracks.add(track);
        onProgress?.call(tracks.length, track.title);
        if (tracks.length >= maxFiles) {
          break;
        }
      }
    }

    return SourceScanResult(tracks: tracks, skipped: skipped, cancelled: cancelled);
  }

  @override
  Future<PlaybackItem> open(String filePathOrUrl) async {
    // SAF 曲目的 filePathOrUrl 本身就是 content:// URI，ExoPlayer 可直接播放。
    return PlaybackItem.fromUri(Uri.parse(filePathOrUrl));
  }

  ScannedTrack _toTrack(SafEntry entry) {
    final String stem = p.basenameWithoutExtension(entry.name);
    final ParsedSongInfo parsed = SmartTitleParser.parse(stem);
    final String extension = p.extension(entry.name).toLowerCase().replaceFirst('.', '');
    return ScannedTrack(
      filePathOrUrl: entry.uri,
      title: parsed.title.isEmpty ? stem : parsed.title,
      artist: parsed.artist,
      album: parsed.album,
      fileFormat: extension.isEmpty ? 'mp3' : extension,
      fileSize: entry.size,
      lastModified: entry.lastModified,
    );
  }
}

class _SafDirectory {
  const _SafDirectory({required this.depth, this.documentId});

  /// 为空表示授权目录本身。
  final String? documentId;

  final int depth;
}

/// 授权已失效（用户在系统设置里撤销，或换了设备）。
class SafPermissionLostException implements Exception {
  const SafPermissionLostException();

  @override
  String toString() => '本地目录授权已失效，请重新选择音乐文件夹';
}
