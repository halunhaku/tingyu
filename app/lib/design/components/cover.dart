import 'dart:typed_data';

import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../theme.dart';
import '../tokens/color.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';

/// 封面占位：确定性色块 + 音符，绝不用随机色（否则每次重建都在闪）。
abstract final class TyCoverPalette {
  /// 由种子（专辑 id / 路径 / 标题）推出一个低饱和度的柔和色块。
  static Color placeholder(String? seed, Brightness brightness) {
    final String key = seed ?? '';
    if (key.isEmpty) {
      return TyColors.of(brightness).coverPlaceholder;
    }
    int hash = 7;
    for (final int unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final double hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(
      1,
      hue,
      brightness == Brightness.dark ? 0.14 : 0.20,
      brightness == Brightness.dark ? 0.24 : 0.87,
    ).toColor();
  }
}

/// 解码宽度 = 显示尺寸 × 设备像素比。
///
/// 封面动辄几千像素，按原图解一次就是几十 MB 内存，而这里最小只画到 24px。
int _decodeWidth(BuildContext context, double size) =>
    math.max(1, (size * MediaQuery.devicePixelRatioOf(context)).round());

/// 全应用唯一的封面组件（`DESIGN.md` §6.5）。
///
/// 取图顺序：本地缓存（扫描/抓取落盘）→ 远端 URL → 确定性占位。
/// 本地路径只给文件名，真实路径解析是异步的（`CoverStore` 契约），因此这里不做同步 IO。
class TyCover extends ConsumerWidget {
  const TyCover({
    super.key,
    this.path,
    this.url,
    this.bytes,
    required this.size,
    this.radius,
    this.seed,
    this.fit = BoxFit.cover,
    this.border,
  });

  /// `CoverStore` 里的封面文件名。
  final String? path;

  /// 远端封面地址。
  final String? url;

  /// 内存里的原始图片数据（艺术家头像来自 `ArtistAvatarStore`，没有文件名）。
  ///
  /// 优先级：bytes → path → url → 占位。给了 bytes 就不再解码网络图，
  /// 避免同一张头像同时走两条取图路径。
  final Uint8List? bytes;

  final double size;

  /// 默认取 [TyRadius.sm]；大封面请传 8–12。
  final double? radius;

  /// 占位色种子：专辑/艺术家 id 或路径。
  final String? seed;
  final BoxFit fit;
  final BorderSide? border;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double r = radius ?? TyRadius.sm;
    final Widget content = _buildContent(context, ref);
    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          border: border == null ? null : Border.fromBorderSide(border!),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(r),
          child: content,
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref) {
    final Uint8List? memory = bytes;
    if (memory != null && memory.isNotEmpty) {
      return Image.memory(
        memory,
        width: size,
        height: size,
        cacheWidth: _decodeWidth(context, size),
        fit: fit,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _Placeholder(size: size, seed: seed),
      );
    }
    final String? localPath = path;
    if (localPath != null && localPath.isNotEmpty) {
      final AsyncValue<File?> file = ref.watch(coverFileProvider(localPath));
      return file.maybeWhen(
        data: (File? resolved) => resolved == null
            ? _RemoteOrPlaceholder(
                url: url,
                size: size,
                radius: radius,
                seed: seed,
                fit: fit,
              )
            : Image.file(
                resolved,
                width: size,
                height: size,
                cacheWidth: _decodeWidth(context, size),
                fit: fit,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _Placeholder(size: size, seed: seed),
              ),
        orElse: () => _Placeholder(size: size, seed: seed),
      );
    }
    return _RemoteOrPlaceholder(
      url: url,
      size: size,
      radius: radius,
      seed: seed,
      fit: fit,
    );
  }
}

class _RemoteOrPlaceholder extends StatelessWidget {
  const _RemoteOrPlaceholder({
    required this.url,
    required this.size,
    required this.radius,
    required this.seed,
    required this.fit,
  });

  final String? url;
  final double size;
  final double? radius;
  final String? seed;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final String? remote = url;
    if (remote == null || remote.isEmpty) {
      return _Placeholder(size: size, seed: seed);
    }
    return CachedNetworkImage(
      imageUrl: remote,
      width: size,
      height: size,
      // 解码与磁盘缓存都按显示尺寸存，别把原图整张读进内存。
      memCacheWidth: _decodeWidth(context, size),
      maxWidthDiskCache: _decodeWidth(context, size),
      fit: fit,
      fadeInDuration: TyDuration.fast,
      placeholder: (_, _) => _Placeholder(size: size, seed: seed),
      errorWidget: (_, _, _) => _Placeholder(size: size, seed: seed),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.size, required this.seed});

  final double size;
  final String? seed;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Container(
      width: size,
      height: size,
      color: seed == null || seed!.isEmpty
          ? ty.colors.coverPlaceholder
          : TyCoverPalette.placeholder(seed, ty.brightness),
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: math.max(12, size * 0.34),
        color: ty.colors.textTertiary,
      ),
    );
  }
}

/// 圆形封面 / 头像：艺术家、歌单、账号。
class TyAvatar extends StatelessWidget {
  const TyAvatar({
    super.key,
    required this.size,
    this.label,
    this.seed,
    this.child,
  });

  final double size;

  /// 无图时的首字母（中英文都取首字符）。
  final String? label;
  final String? seed;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final String? text = label?.trim();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: TyCoverPalette.placeholder(seed ?? text, ty.brightness),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child:
          child ??
          Text(
            (text == null || text.isEmpty) ? '♪' : text.characters.first,
            style: ty.typography.labelM.copyWith(
              color: ty.colors.textSecondary,
              fontSize: math.max(12, size * 0.4),
            ),
          ),
    );
  }
}
