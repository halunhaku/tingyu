import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tingyu_saf/tingyu_saf.dart';

import '../../data/models/scanned_track.dart';
import '../../playback/playback_item.dart';
import '../source_adapter.dart';
import 'folder_permission.dart';
import 'local_library_scanner.dart';

/// iOS 本地目录来源（安全作用域书签授权的目录）。
///
/// 与 [LocalSourceAdapter] 的区别只有一处，但很关键：库里的 `filePathOrUrl` 是
/// **相对授权目录**的路径，而不是绝对路径。
///
/// 绝对路径在 iOS 上不可持久：目录可能位于别的应用或文件提供者的容器里，容器 UUID
/// 会随应用更新变化 —— 存绝对路径会让每次重装都把整个曲库判成"全部新增 + 全部移除"，
/// 收藏与播放列表随之丢失。相对路径才是稳定的合并键，播放时用当前解析出的根目录拼回来。
///
/// 标签解析、扩展名过滤、批量上限与取消语义全部复用 [LocalLibraryScanner]：
/// 安全作用域一旦开启，授权目录就是一个普通路径，不需要 Android 那样的原生枚举桥。
class LocalBookmarkSourceAdapter implements SourceAdapter {
  LocalBookmarkSourceAdapter({
    required this.sourceId,
    required this.bookmark,
    LocalLibraryScanner? scanner,
  }) : _scanner = scanner ?? LocalLibraryScanner();

  /// 系统文档选择器授权的安全作用域书签（base64，存于 `music_sources.local_bookmark`）。
  final String bookmark;

  final LocalLibraryScanner _scanner;

  @override
  final String sourceId;

  @override
  Future<SourceScanResult> scan({
    void Function(int done, String name)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final Directory root = await _root();
    final LocalScanResult result = await _scanner.scan(
      root,
      onProgress: onProgress == null
          ? null
          : (int done, int total, String path) => onProgress(done, path),
      isCancelled: isCancelled,
    );
    return SourceScanResult(
      tracks: result.tracks
          .map(
            (ScannedTrack track) => track.withPath(
              p.relative(track.filePathOrUrl, from: root.path),
            ),
          )
          .toList(growable: false),
      skipped: result.unreadableFiles + result.unreadableDirectories,
      cancelled: result.cancelled,
      truncated: result.truncated,
    );
  }

  @override
  Future<PlaybackItem> open(String filePathOrUrl) async {
    final Directory root = await _root();
    return PlaybackItem.fromUri(Uri.file(p.join(root.path, filePathOrUrl)));
  }

  /// 解析书签，拿到当前进程里有效的授权目录；书签失效时抛出。
  Future<Directory> _root() async {
    final String? path = await TingyuSaf.resolveBookmark(bookmark);
    if (path == null || path.isEmpty) {
      throw const FolderPermissionLostException();
    }
    return Directory(path);
  }
}
