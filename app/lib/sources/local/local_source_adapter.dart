import 'dart:io';

import '../../playback/playback_item.dart';
import '../source_adapter.dart';
import 'local_library_scanner.dart';

/// 本地目录来源：扫描交给 [LocalLibraryScanner]，播放直接用文件路径。
class LocalSourceAdapter implements SourceAdapter {
  LocalSourceAdapter({
    required this.sourceId,
    required this.folderPath,
    LocalLibraryScanner? scanner,
  }) : _scanner = scanner ?? LocalLibraryScanner();

  @override
  final String sourceId;

  /// 用户选择的目录绝对路径。
  final String folderPath;

  final LocalLibraryScanner _scanner;

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
    );
    return SourceScanResult(
      tracks: result.tracks,
      skipped: result.unreadableFiles,
      cancelled: result.cancelled,
    );
  }

  @override
  Future<PlaybackItem> open(String filePathOrUrl) async {
    final Uri parsed = Uri.tryParse(filePathOrUrl) ?? Uri.file(filePathOrUrl);
    return PlaybackItem.fromUri(parsed.scheme.isEmpty ? Uri.file(filePathOrUrl) : parsed);
  }
}
