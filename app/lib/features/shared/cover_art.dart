import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// 解码宽度 = 显示尺寸 × 设备像素比。
///
/// 封面动辄几千像素，按原图解一次就是几十 MB 内存，而这里最小只画到 36px；
/// 乘上像素比只为保住物理像素的清晰度。
int _decodeWidth(BuildContext context, double size) =>
    math.max(1, (size * MediaQuery.devicePixelRatioOf(context)).round());

/// 封面：优先本地缓存（扫描/抓取落盘的图片），其次远端 URL，最后占位图。
///
/// 本地封面走 [coverFileProvider]（`CoverStore` 只管文件名，路径解析是异步的）。
class CoverArt extends ConsumerWidget {
  const CoverArt({
    super.key,
    this.coverArtPath,
    this.coverArtUrl,
    this.size = 44,
    this.radius = 6,
  });

  final String? coverArtPath;

  final String? coverArtUrl;

  final double size;

  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? path = coverArtPath;
    if (path != null && path.isNotEmpty) {
      // 路径解析保持异步（`CoverStore` 只管文件名）；这里不做任何同步 IO。
      final AsyncValue<File?> file = ref.watch(coverFileProvider(path));
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: file.maybeWhen(
          data: (File? resolved) => resolved == null
              ? _RemoteOrPlaceholder(url: coverArtUrl, size: size, radius: radius)
              : Image.file(
                  resolved,
                  width: size,
                  height: size,
                  cacheWidth: _decodeWidth(context, size),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _Placeholder(size: size, radius: radius),
                ),
          orElse: () => _Placeholder(size: size, radius: radius),
        ),
      );
    }
    return _RemoteOrPlaceholder(url: coverArtUrl, size: size, radius: radius);
  }
}

class _RemoteOrPlaceholder extends StatelessWidget {
  const _RemoteOrPlaceholder({required this.url, required this.size, required this.radius});

  final String? url;

  final double size;

  final double radius;

  @override
  Widget build(BuildContext context) {
    final String? remote = url;
    if (remote == null || remote.isEmpty) {
      return _Placeholder(size: size, radius: radius);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: remote,
        width: size,
        height: size,
        // 解码与磁盘缓存都按显示尺寸存，别把原图整张读进内存。
        memCacheWidth: _decodeWidth(context, size),
        maxWidthDiskCache: _decodeWidth(context, size),
        fit: BoxFit.cover,
        placeholder: (_, _) => _Placeholder(size: size, radius: radius),
        errorWidget: (_, _, _) => _Placeholder(size: size, radius: radius),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.size, required this.radius});

  final double size;

  final double radius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.music_note, size: size * 0.5, color: scheme.onSurfaceVariant),
    );
  }
}
