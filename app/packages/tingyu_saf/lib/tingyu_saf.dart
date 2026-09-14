import 'dart:async';

import 'package:flutter/services.dart';

/// SAF 目录里的一个条目。
class SafEntry {
  const SafEntry({
    required this.documentId,
    required this.uri,
    required this.name,
    required this.isDirectory,
    required this.size,
    this.lastModified,
  });

  final String documentId;

  /// 可直接读/播放的 `content://` URI。
  final String uri;

  final String name;

  final bool isDirectory;

  final int size;

  final DateTime? lastModified;
}

/// 用户在系统文档选择器里授权的目录（iOS）。
class PickedFolder {
  const PickedFolder({required this.bookmark, required this.path});

  /// 安全作用域书签（base64）：可持久化，重启应用后仍能解析。
  final String bookmark;

  /// 选择时的绝对路径 —— 只用于展示目录名；容器路径会随应用更新变化，不要落库。
  final String path;
}

/// 「系统授权目录」桥：Android 是 SAF（tree URI + 持久化权限），iOS 是安全作用域书签。
///
/// 两端解决的是同一个问题：沙盒不允许直接读用户任意目录，必须由用户在系统选择器里
/// 显式授权，并把这份授权持久化下来。
/// - Android（[pickDirectory] / [listChildren]）：授权是 tree URI，子项以 `content://`
///   形式直接交给 ExoPlayer，不需要 `READ_MEDIA_AUDIO`；
/// - iOS（[pickFolderBookmark] / [resolveBookmark]）：授权是安全作用域书签，解析出真实
///   路径后交给 `dart:io` 与 AVPlayer，插件负责在进程内保持安全作用域。
///
/// 其余方法（夸克跳转、拉回前台）是 Android 专属，Dart 侧按平台调用。
class TingyuSaf {
  TingyuSaf._();

  static const MethodChannel _channel = MethodChannel('tingyu/saf');

  /// 拉起系统目录选择器；用户取消返回 null。
  static Future<String?> pickDirectory() => _channel.invokeMethod<String>('pickDirectory');

  /// iOS：拉起系统文档选择器选一个目录；用户取消返回 null。
  ///
  /// 返回的书签可以持久化（落库），[PickedFolder.path] 只是当时的绝对路径。
  static Future<PickedFolder?> pickFolderBookmark() async {
    final Map<Object?, Object?>? raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'pickFolderBookmark',
    );
    final String? bookmark = raw?['bookmark'] as String?;
    if (bookmark == null || bookmark.isEmpty) {
      return null;
    }
    return PickedFolder(bookmark: bookmark, path: raw?['path'] as String? ?? '');
  }

  /// iOS：解析书签并开启安全作用域访问，返回目录绝对路径；书签失效返回 null。
  ///
  /// 安全作用域一直开到 [releaseBookmark]（或进程结束）：扫描与点播之间可能隔很久。
  static Future<String?> resolveBookmark(String bookmark) =>
      _channel.invokeMethod<String>('resolveBookmark', <String, Object?>{'bookmark': bookmark});

  /// iOS：关闭书签的安全作用域访问（删除来源时调用）。
  static Future<void> releaseBookmark(String bookmark) =>
      _channel.invokeMethod<bool>('releaseBookmark', <String, Object?>{'bookmark': bookmark});

  /// 该 tree URI 的读权限是否仍然有效（用户可能在系统设置里撤销）。
  static Future<bool> hasPermission(String treeUri) async {
    final bool? granted = await _channel.invokeMethod<bool>(
      'hasPermission',
      <String, Object?>{'treeUri': treeUri},
    );
    return granted ?? false;
  }

  /// 释放持久化授权（删除来源时调用）。
  static Future<void> releasePermission(String treeUri) =>
      _channel.invokeMethod<bool>('releasePermission', <String, Object?>{'treeUri': treeUri});

  /// 列出某个目录的子项；[parentDocumentId] 为空时列出授权目录本身的内容。
  static Future<List<SafEntry>> listChildren(
    String treeUri, {
    String? parentDocumentId,
  }) async {
    final List<Object?>? raw = await _channel.invokeMethod<List<Object?>>(
      'listChildren',
      <String, Object?>{
        'treeUri': treeUri,
        'parentDocumentId': parentDocumentId,
      },
    );
    if (raw == null) {
      return const <SafEntry>[];
    }
    return raw.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> item) {
      final int? modified = item['lastModified'] as int?;
      return SafEntry(
        documentId: item['documentId'] as String? ?? '',
        uri: item['uri'] as String? ?? '',
        name: item['name'] as String? ?? '',
        isDirectory: item['isDirectory'] as bool? ?? false,
        size: (item['size'] as int?) ?? 0,
        lastModified: modified == null ? null : DateTime.fromMillisecondsSinceEpoch(modified),
      );
    }).toList(growable: false);
  }

  /// 用夸克 App 打开确认登录链接。未安装夸克时走系统 VIEW（可能是浏览器）。
  static Future<bool> openInQuark(String url) async {
    final bool? opened = await _channel.invokeMethod<bool>(
      'openInQuark',
      <String, Object?>{'url': url},
    );
    return opened ?? false;
  }

  /// 把听屿从后台拉回前台（夸克 App 确认登录后）。
  static Future<bool> bringToForeground() async {
    final bool? ok = await _channel.invokeMethod<bool>('bringToForeground');
    return ok ?? false;
  }
}
