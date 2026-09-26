import 'dart:io';

import '../../data/models/scanned_track.dart';
import '../../playback/playback_item.dart';
import '../source_adapter.dart';
import 'local_library_scanner.dart';

/// 本地目录来源：扫描交给 [LocalLibraryScanner]，播放直接用文件路径。
class LocalSourceAdapter implements SourceAdapter {
  LocalSourceAdapter({
    required this.sourceId,
    required this.folderPath,
    LocalLibraryScanner? scanner,
    this.knownFacts,
  }) : _scanner = scanner ?? LocalLibraryScanner();

  @override
  final String sourceId;

  /// 用户选择的目录绝对路径。
  final String folderPath;

  final LocalLibraryScanner _scanner;

  /// 库里已记录的文件事实（由 app 层从曲库取）。为空则每次都完整解析。
  ///
  /// 用回调而不是直接依赖仓储：来源层只依赖 `data/` 的模型，不持有数据库句柄。
  final Future<KnownFileFacts> Function()? knownFacts;

  @override
  Future<SourceScanResult> scan({
    void Function(int done, String name)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final LocalScanResult result = await _scanner.scan(
      Directory(folderPath),
      onProgress: onProgress == null
          ? null
          : (int done, int total, String path) => onProgress(done, path),
      isCancelled: isCancelled,
      known: await knownFacts?.call() ?? noKnownFileFacts,
    );
    return SourceScanResult(
      tracks: result.tracks,
      skipped: result.unreadableFiles + result.unreadableDirectories,
      cancelled: result.cancelled,
      truncated: result.truncated,
    );
  }

  @override
  Future<PlaybackItem> open(String filePathOrUrl) async {
    final Uri parsed = Uri.tryParse(filePathOrUrl) ?? Uri.file(filePathOrUrl);
    return PlaybackItem.fromUri(
      parsed.scheme.isEmpty ? Uri.file(filePathOrUrl) : parsed,
    );
  }
}
