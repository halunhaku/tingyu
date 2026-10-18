import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens/color.dart';

/// 舞台背景配色：主色 → 次色（`DESIGN.md` §2.5）。
///
/// 只描述两个颜色：渐变角度、压平层、漂移都在绘制处（`FluidBackground`）完成。
@immutable
class StagePalette {
  const StagePalette({required this.primary, required this.secondary});

  final Color primary;
  final Color secondary;

  /// 中性渐变（`DESIGN.md` §2.5 第 8 条）：设置项关闭取色、没有本地封面、灰封面、
  /// 取色失败时都用它。文档给的两个色值取自配色表的相邻档位：
  /// 深色 `#101014 → #17171C`（`surfaceSunken` / 抬升层），浅色 `#F0F0F4 → #E7E7EC`
  /// （`surfaceSunken` / `coverPlaceholder`）。
  static StagePalette neutral(Brightness brightness) {
    final TyColors colors = TyColors.of(brightness);
    return brightness == Brightness.dark
        ? StagePalette(
            primary: colors.surfaceSunken,
            secondary: colors.surfaceRaised,
          )
        : StagePalette(
            primary: colors.surfaceSunken,
            secondary: colors.coverPlaceholder,
          );
  }

  StagePalette lerp(StagePalette other, double t) => StagePalette(
    primary: Color.lerp(primary, other.primary, t) ?? primary,
    secondary: Color.lerp(secondary, other.secondary, t) ?? secondary,
  );

  /// 取色结果的通道（`r1,g1,b1,r2,g2,b2`，0–255）→ 颜色。
  static StagePalette fromRgb(List<int> rgb) => StagePalette(
    // guard-ok: 封面取色得到的颜色来自图像像素，不是设计令牌色。
    primary: Color.fromARGB(255, rgb[0], rgb[1], rgb[2]),
    // guard-ok: 同上（次色）。
    secondary: Color.fromARGB(255, rgb[3], rgb[4], rgb[5]),
  );
}

/// 取色结果的键：本地封面绝对路径 + 主题亮度（mtime 在缓存键里，见 [_cacheKey]）。
typedef StagePaletteKey = ({String path, Brightness brightness});

/// 本地封面 → 舞台配色。
///
/// 键是「文件路径 + 亮度」：换曲、换封面文件都会换 provider 实例，
/// 快速切歌时旧结果落在旧实例上，不会涂到新封面上（`DESIGN.md` §2.5 第 7 条）；
/// 文件改了但路径没变的情况由缓存键里的 mtime 兜住。
final stagePaletteProvider = FutureProvider.autoDispose
    .family<StagePalette, StagePaletteKey>((Ref ref, StagePaletteKey key) async {
      final int modified = await _modifiedAt(key.path);
      if (modified < 0) {
        return StagePalette.neutral(key.brightness);
      }
      final TyColors colors = TyColors.of(key.brightness);
      final List<int>? rgb = await _extract(
        (path: key.path, modifiedMs: modified, brightness: key.brightness),
        colors,
      );
      return rgb == null
          ? StagePalette.neutral(key.brightness)
          : StagePalette.fromRgb(rgb);
    });

/// 缓存键：路径 + mtime + 亮度（`DESIGN.md` §2.5 第 7 条）。
typedef _CacheKey = ({String path, int modifiedMs, Brightness brightness});

/// LRU：最近 64 张封面。
final LinkedHashMap<_CacheKey, List<int>?> _cache =
    LinkedHashMap<_CacheKey, List<int>?>();

const int _cacheLimit = 64;

Future<int> _modifiedAt(String path) async {
  try {
    final FileStat stat = await File(path).stat();
    return stat.modified.millisecondsSinceEpoch;
  } on Object catch (error) {
    debugPrint('[stage-palette] 无法读取封面文件（回退中性渐变）: $error');
    return -1;
  }
}

Future<List<int>?> _extract(_CacheKey key, TyColors colors) async {
  final List<int>? cached = _cache.remove(key);
  if (cached != null) {
    _cache[key] = cached;
    return cached;
  }
  List<int>? result;
  try {
    result = await compute(
      _extractPalette,
      _PaletteRequest(
        path: key.path,
        dark: key.brightness == Brightness.dark,
        canvas: colors.canvas,
        textPrimary: colors.textPrimary,
      ),
      debugLabel: 'ty-stage-palette',
    );
  } on Object catch (error) {
    debugPrint('[stage-palette] 取色失败（回退中性渐变）: $error');
    result = null;
  }
  _cache[key] = result;
  while (_cache.length > _cacheLimit) {
    _cache.remove(_cache.keys.first);
  }
  return result;
}

/// 取色输入：全部字段都可跨 isolate 传递。
@immutable
class _PaletteRequest {
  const _PaletteRequest({
    required this.path,
    required this.dark,
    required this.canvas,
    required this.textPrimary,
  });

  final String path;
  final bool dark;
  final Color canvas;
  final Color textPrimary;
}

/// 取色参数（`DESIGN.md` §2.5）。
abstract final class _Palette {
  /// 解码目标宽度：只为了取色，不需要清晰度。
  static const int targetWidth = 24;

  /// 亮度 / 饱和度门限：太暗、太亮、太灰的像素不参与统计。
  static const double minLightness = 0.08;
  static const double maxLightness = 0.92;
  static const double minSaturation = 0.08;

  /// 有效像素低于这个比例就判定为「灰封面」。
  static const double minAcceptedRatio = 0.2;

  /// 近乎透明的像素直接跳过。
  static const int minAlpha = 20;

  /// 有效像素的上限，避免大图逐像素太慢（24px 宽一般远小于它）。
  static const int maxSamples = 4096;

  /// 色相直方图桶数与次色的最小色相差。
  static const int hueBuckets = 12;
  static const double secondaryHueGap = 24;
  static const double rotatedHue = 18;

  /// 钳制区间（`DESIGN.md` §2.5 第 4 条）。
  static const double minClampSaturation = 0.28;
  static const double maxClampSaturation = 0.46;
  static const double lightMin = 0.72;
  static const double lightMax = 0.84;
  static const double darkMin = 0.10;
  static const double darkMax = 0.18;

  /// 舞台背景上的正文对比度下限与下调步长（第 5 条）。
  static const double minContrast = 7;
  static const double lightnessStep = 0.05;

  /// 压平层：`canvas @ 35%`。
  static const double flattenOpacity = 0.35;
}

/// isolate 入口：读 24px 缩略图的像素并算出主 / 次色通道。
///
/// 返回 `r1,g1,b1,r2,g2,b2`；灰封面 / 无法读取 / 取色失败一律返回 null（调用方回退中性渐变）。
Future<List<int>?> _extractPalette(_PaletteRequest request) async {
  ui.ImmutableBuffer? buffer;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromFilePath(request.path);
    final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
      buffer,
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: _Palette.targetWidth,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    image = frame.image;
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (bytes == null) {
      return null;
    }
    return _paletteFromPixels(bytes.buffer.asUint8List(), request);
  } on Object catch (error) {
    debugPrint('[stage-palette] 解码封面失败: $error');
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    buffer?.dispose();
  }
}

List<int>? _paletteFromPixels(Uint8List rgba, _PaletteRequest request) {
  final int total = rgba.length ~/ 4;
  if (total == 0) {
    return null;
  }
  final List<double> hueSum = List<double>.filled(_Palette.hueBuckets, 0);
  final List<double> satSum = List<double>.filled(_Palette.hueBuckets, 0);
  final List<double> lightSum = List<double>.filled(_Palette.hueBuckets, 0);
  final List<int> counts = List<int>.filled(_Palette.hueBuckets, 0);

  int accepted = 0;
  final int step = math.max(1, total ~/ _Palette.maxSamples);
  for (int i = 0; i < total; i += step) {
    final int offset = i * 4;
    if (rgba[offset + 3] < _Palette.minAlpha) {
      continue;
    }
    final HSLColor hsl = HSLColor.fromColor(
      // guard-ok: 逐像素判色，不是界面配色。
      Color.fromARGB(255, rgba[offset], rgba[offset + 1], rgba[offset + 2]),
    );
    if (hsl.lightness < _Palette.minLightness ||
        hsl.lightness > _Palette.maxLightness ||
        hsl.saturation < _Palette.minSaturation) {
      continue;
    }
    accepted++;
    final int bucket =
        (hsl.hue / (360 / _Palette.hueBuckets)).floor() % _Palette.hueBuckets;
    hueSum[bucket] += hsl.hue;
    satSum[bucket] += hsl.saturation;
    lightSum[bucket] += hsl.lightness;
    counts[bucket]++;
  }

  // 有效像素太少 → 判定「灰封面」，回退中性渐变。
  if (accepted == 0 || accepted / (total / step) < _Palette.minAcceptedRatio) {
    return null;
  }

  final int primaryBucket = _peakBucket(counts);
  if (primaryBucket < 0) {
    return null;
  }
  final HSLColor primary = _bucketHsl(
    primaryBucket,
    counts,
    hueSum,
    satSum,
    lightSum,
    request.dark,
  );

  final int secondaryBucket = _secondaryBucket(primaryBucket, counts, primary);
  final HSLColor secondary = secondaryBucket >= 0
      ? _bucketHsl(
          secondaryBucket,
          counts,
          hueSum,
          satSum,
          lightSum,
          request.dark,
        )
      : primary.withHue((primary.hue + _Palette.rotatedHue) % 360);

  return <int>[
    ..._channels(_contrasted(primary, request)),
    ..._channels(_contrasted(secondary, request)),
  ];
}

int _peakBucket(List<int> counts) {
  int best = -1;
  for (int i = 0; i < counts.length; i++) {
    if (counts[i] > 0 && (best < 0 || counts[i] > counts[best])) {
      best = i;
    }
  }
  return best;
}

/// 与主色色相差 ≥ 24° 的次峰；没有就返回 -1（调用方按主色旋转 +18°）。
int _secondaryBucket(int primaryBucket, List<int> counts, HSLColor primary) {
  int best = -1;
  for (int i = 0; i < counts.length; i++) {
    if (i == primaryBucket || counts[i] == 0) {
      continue;
    }
    final double hue = (i + 0.5) * (360 / _Palette.hueBuckets);
    if (_hueGap(primary.hue, hue) < _Palette.secondaryHueGap) {
      continue;
    }
    if (best < 0 || counts[i] > counts[best]) {
      best = i;
    }
  }
  return best;
}

double _hueGap(double a, double b) {
  final double raw = (a - b).abs() % 360;
  return raw > 180 ? 360 - raw : raw;
}

HSLColor _bucketHsl(
  int bucket,
  List<int> counts,
  List<double> hueSum,
  List<double> satSum,
  List<double> lightSum,
  bool dark,
) {
  final int count = counts[bucket];
  final double saturation = (satSum[bucket] / count)
      .clamp(_Palette.minClampSaturation, _Palette.maxClampSaturation)
      .toDouble();
  final double lightness = (lightSum[bucket] / count)
      .clamp(
        dark ? _Palette.darkMin : _Palette.lightMin,
        dark ? _Palette.darkMax : _Palette.lightMax,
      )
      .toDouble();
  return HSLColor.fromAHSL(1, (hueSum[bucket] / count) % 360, saturation, lightness);
}

/// 舞台背景必须让 `textPrimary` 最差点 ≥ 7:1（`DESIGN.md` §2.5 第 5 条）。
///
/// 深色主题文字是浅色：背景越暗对比越高，按 5% 下调亮度；
/// 浅色主题文字是深色，方向相反（上调亮度）。
Color _contrasted(HSLColor color, _PaletteRequest request) {
  Color flattened = _flatten(color.toColor(), request.canvas);
  double lightness = color.lightness;
  for (int i = 0; i < 20; i++) {
    if (_contrast(flattened, request.textPrimary) >= _Palette.minContrast) {
      break;
    }
    lightness += request.dark
        ? -_Palette.lightnessStep
        : _Palette.lightnessStep;
    flattened = _flatten(
      color.withLightness(lightness.clamp(0, 1).toDouble()).toColor(),
      request.canvas,
    );
  }
  return color.withLightness(lightness.clamp(0, 1).toDouble()).toColor();
}

/// 渐变上压一层 `canvas @ 35%` 之后的实际底色。
Color _flatten(Color color, Color canvas) => Color.alphaBlend(
  canvas.withValues(alpha: _Palette.flattenOpacity),
  color,
);

double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = math.max(la, lb);
  final double lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

List<int> _channels(Color color) {
  int channel(double value) => (value * 255).round().clamp(0, 255);
  return <int>[
    channel(color.r),
    channel(color.g),
    channel(color.b),
  ];
}
