import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

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
