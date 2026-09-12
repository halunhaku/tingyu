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

/// Android 存储访问框架（SAF）桥。
///
/// Android 10+ 起应用无法直接读取 `/sdcard` 下的任意目录，必须由用户通过系统目录选择器
/// 授权一个目录（tree URI），并持久化该授权 —— 作用等价于 iOS 的安全作用域书签。
/// 拿到的子项以 `content://` 形式交给播放引擎（ExoPlayer 原生支持），
/// 不像"猜路径"那样受分区存储限制。
class TingyuSaf {
  TingyuSaf._();

  static const MethodChannel _channel = MethodChannel('tingyu/saf');

  /// 拉起系统目录选择器；用户取消返回 null。
  static Future<String?> pickDirectory() => _channel.invokeMethod<String>('pickDirectory');

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
}
