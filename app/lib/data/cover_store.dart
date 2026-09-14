import 'dart:io';
import 'dart:typed_data';

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

  /// 写入封面并返回相对文件名；同一个 [key] 重复写入会覆盖旧文件。
  Future<String> save(String key, Uint8List bytes) async {
    final Directory dir = await coversDirectory();
    final String name = fileNameFor(key, extension: _extensionOf(bytes));
    await File(p.join(dir.path, name)).writeAsBytes(bytes, flush: false);
    return name;
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

  /// 文件名 = 稳定哈希 + 扩展名。
  ///
  /// 曲目 key 可能是 UUID，也可能是"来源::很长/的/路径"，直接清洗会撞上 255 字节的
  /// 文件名上限；FNV-1a 64 位既短又跨进程稳定（`String.hashCode` 不保证跨运行一致）。
  /// 取 63 位是为了避开负数 → `toRadixString(16)` 会输出前导 `-` 的文件名。
  static String fileNameFor(String key, {String extension = '.img'}) =>
      '${(fnv1a64(key) & 0x7FFFFFFFFFFFFFFF).toRadixString(16).padLeft(16, '0')}$extension';

  /// FNV-1a 64 位哈希，用于生成稳定且短的文件名。
  static int fnv1a64(String input) {
    const int offsetBasis = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    const int mask = 0xFFFFFFFFFFFFFFFF;
    int hash = offsetBasis;
    for (final int unit in input.codeUnits) {
      hash = (hash ^ unit) & mask;
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
