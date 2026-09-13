import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'metadata_provider.dart';

/// 艺术家头像缓存（对齐 `Sources/Services/Scraper/ArtistAvatarStore.swift`）。
///
/// 头像来自网易云的艺术家搜索（`type=100`），命中后写盘缓存；
/// 与封面不同，头像不写进曲库，只是展示层缓存。
class ArtistAvatarStore {
  ArtistAvatarStore({
    required this.lookup,
    ImageDownloader? downloader,
    Future<Directory> Function()? rootDirectory,
  })  : _downloader = downloader ?? ImageDownloader(),
        _rootDirectory = rootDirectory ?? getApplicationSupportDirectory;

  static const String unknownArtist = '未知艺术家';

  final ArtistLookup lookup;

  final ImageDownloader _downloader;

  final Future<Directory> Function() _rootDirectory;

  final Map<String, Uint8List> _memoryCache = <String, Uint8List>{};

  /// 返回头像字节；查不到返回 null（调用方回落到占位图）。
  Future<Uint8List?> avatar(String artist) async {
    final String name = artist.trim();
    if (name.isEmpty || name == unknownArtist) {
      return null;
    }
    final Uint8List? cached = _memoryCache[name];
    if (cached != null) {
      return cached;
    }

    final File cacheFile = await _cacheFile(name);
    if (cacheFile.existsSync()) {
      final Uint8List bytes = await cacheFile.readAsBytes();
      if (bytes.isNotEmpty) {
        _memoryCache[name] = bytes;
        return bytes;
      }
    }

    final String? url;
    try {
      url = await lookup.avatarUrl(name);
    } on Object catch (error) {
      debugPrint('[avatar] 查找「$name」失败: $error');
      return null;
    }
    if (url == null || url.isEmpty) {
      debugPrint('[avatar] 没有「$name」的头像地址');
      return null;
    }
    final Uint8List? bytes = await _downloader.download(
      url,
      headers: const <String, String>{
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        'Referer': 'https://music.163.com',
      },
    );
    if (bytes == null) {
      debugPrint('[avatar] 下载「$name」头像失败 $url');
      return null;
    }
    _memoryCache[name] = bytes;
    await cacheFile.parent.create(recursive: true);
    await cacheFile.writeAsBytes(bytes, flush: false);
    return bytes;
  }

  /// 缓存文件路径；艺术家名可能含 `/`、`:` 等路径字符，先做百分号编码。
  Future<File> _cacheFile(String artist) async {
    final Directory root = await _rootDirectory();
    return File(p.join(root.path, 'avatars', '${Uri.encodeComponent(artist)}.jpg'));
  }
}
