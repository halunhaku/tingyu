import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 封面缓存。
///
/// 封面二进制不写进 SQLite：上千条曲目的内嵌封面会让库文件膨胀、查询与备份变慢。
/// 数据库里只保存这里返回的**相对文件名**，读取时用 [resolve] 还原绝对路径。
class CoverStore {
  CoverStore({Future<Directory> Function()? rootDirectory})
      : _rootDirectory = rootDirectory ?? _applicationSupportDirectory;

  final Future<Directory> Function() _rootDirectory;

  static Future<Directory> _applicationSupportDirectory() => getApplicationSupportDirectory();

  /// 写入封面并返回相对文件名。
  ///
  /// 文件名由**内容**决定（FNV-1a 哈希 + 扩展名），不再由曲目 key 决定：
  /// 一张专辑的内嵌封面会原样重复出现在该专辑每一首歌里，按 key 命名就会写出
  /// 20 多份完全相同的图片 —— 实机曲库 353 个封面文件里 91% 的字节是重复的。
  /// 按内容命名后同一张图只落一份盘，重复扫描也不会反复写同样的字节。
  ///
  /// 换封面会在盘上留下旧图（新内容 → 新文件名），由 [pruneUnreferenced] 回收。
  Future<String> save(Uint8List bytes) async {
    final Directory dir = await coversDirectory();
    final String name = coverNameFor(bytes);
    final File file = File(p.join(dir.path, name));
    // 同样的内容已经在盘上：不必再写一次（扫描器每个文件都要过一遍这里）。
    if (file.existsSync() && await file.length() == bytes.length) {
      return name;
    }
    await file.writeAsBytes(bytes, flush: false);
    return name;
  }

  /// 删除不再被任何曲目引用的封面文件，返回删除数量。
  ///
  /// 只删"确实没人引用"的文件：任何一次完整同步之后调用它，会自动清掉换封面、
  /// 换来源留下的孤儿图，以及历史上按 key 命名时代留下的重复副本。
  Future<int> pruneUnreferenced(Set<String> keep) async {
    final Directory dir = await coversDirectory();
    int removed = 0;
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      if (keep.contains(p.basename(entity.path))) {
        continue;
      }
      try {
        await entity.delete();
        removed++;
      } on Object catch (error) {
        debugPrint('[cover-store] 清理封面失败 ${entity.path}: $error');
      }
    }
    if (removed > 0) {
      debugPrint('[cover-store] 清理无引用封面 $removed 个');
    }
    return removed;
  }

  /// 把相对文件名还原为绝对路径；文件不存在时返回 null。
  Future<File?> resolve(String? name) async {
    if (name == null || name.isEmpty) {
      return null;
    }
    final Directory dir = await coversDirectory();
    final File file = File(p.join(dir.path, name));
    return file.existsSync() ? file : null;
  }

  Future<void> delete(String? name) async {
    if (name == null || name.isEmpty) {
      return;
    }
    final Directory dir = await coversDirectory();
    final File file = File(p.join(dir.path, name));
    if (file.existsSync()) {
      await file.delete();
    }
  }

  Future<Directory> coversDirectory() async {
    final Directory root = await _rootDirectory();
    final Directory dir = Directory(p.join(root.path, 'covers'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 内容寻址的文件名：`<FNV-1a 64bit>.<png|jpg>`。
  ///
  /// 取 63 位是为了避开负数 → `toRadixString(16)` 会输出前导 `-` 的文件名；
  /// 按字节（而非 String）哈希，隔离扫描器与数据层都能用同一个函数算出同一个名字。
  static String coverNameFor(Uint8List bytes) =>
      '${(fnv1a64Bytes(bytes) & 0x7FFFFFFFFFFFFFFF).toRadixString(16).padLeft(16, '0')}'
      '${_extensionOf(bytes)}';

  /// FNV-1a 64 位哈希（字节流），用于生成稳定且短的文件名。
  static int fnv1a64Bytes(List<int> bytes) {
    const int offsetBasis = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    const int mask = 0xFFFFFFFFFFFFFFFF;
    int hash = offsetBasis;
    for (final int byte in bytes) {
      hash = (hash ^ byte) & mask;
      hash = (hash * prime) & mask;
    }
    return hash;
  }

  static String _extensionOf(Uint8List bytes) {
    if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50) {
      return '.png';
    }
    return '.jpg';
  }
}
