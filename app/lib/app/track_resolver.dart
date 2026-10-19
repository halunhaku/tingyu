import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../playback/playback_item.dart';
import '../sources/source_adapter.dart';
import 'providers.dart';
import 'source_adapters.dart';

/// 把库里的曲目解析成播放引擎能直接消费的条目。
///
/// 三种来源的差异都收敛在 [buildSourceAdapter]：本地是文件路径，
/// WebDAV 带 Basic 鉴权头，Quark 先换直链再带播放头。
/// 这里另外补齐标题/艺术家/专辑/封面/时长，让系统媒体会话与播放界面无需再查库。
class TrackResolver {
  TrackResolver(this._ref);

  final Ref _ref;

  Future<PlaybackItem> resolve(Track track) async {
    final MusicSource? source = await _ref.read(sourceRepositoryProvider).byId(track.sourceId);
    final Uri? artUri = await _resolveCover(track);

    PlaybackItem base = PlaybackItem.fromUri(initialUri(track.filePathOrUrl));
    if (source != null) {
      try {
        // 走缓存：夸克每首歌都要换直链，重建适配器会把 5400s 的直链缓存清零。
        final SourceAdapter adapter = await _ref
            .read(sourceAdapterCacheProvider)
            .of(source);
        base = await adapter.open(track.filePathOrUrl);
      } on Object catch (error) {
        debugPrint('[resolver] 解析来源「${source.name}」失败: $error');
        rethrow;
      }
    }

    return PlaybackItem.fromUri(
      base.uri,
      httpHeaders: base.httpHeaders,
      title: track.title,
      artist: track.artist,
      album: track.album,
      artUri: artUri,
      duration: Duration(milliseconds: (track.duration * 1000).round()),
    );
  }

  /// resolver 入口的占位 URI：来源存在时随后会被 `adapter.open()` 覆盖，
  /// 只有来源行已删除的孤儿曲目才会真正用它播放。
  ///
  /// 不能无脑 `Uri.file()`：Windows 上它遇到 `quark://<fid>` /
  /// `https://...` 直接抛 `Invalid argument(s): Illegal character in path`，
  /// 而 `Uri.tryParse()` 又会把 `F:\...` 误解析出 scheme `f` —— 两边分流。
  static Uri initialUri(String filePathOrUrl) {
    if (_looksLikeWindowsDrivePath(filePathOrUrl)) {
      // 盘符路径必须显式按 Windows 规则解析；否则在 Linux/macOS 上
      // `Uri.file()` 会把 `D:/...` 当成相对路径并生成空 scheme。
      return Uri.file(filePathOrUrl, windows: true);
    }
    final Uri? parsed = Uri.tryParse(filePathOrUrl);
    if (parsed != null && parsed.scheme.isNotEmpty) {
      return parsed;
    }
    return Uri.file(filePathOrUrl);
  }

  /// `C:\...` / `D:/...` 盘符路径：tryParse 会误读出单字母 scheme。
  static bool _looksLikeWindowsDrivePath(String raw) {
    if (raw.length < 3) {
      return false;
    }
    final int drive = raw.codeUnitAt(0);
    final bool isLetter =
        (drive >= 65 && drive <= 90) || (drive >= 97 && drive <= 122);
    if (!isLetter || raw.codeUnitAt(1) != 58) {
      return false;
    }
    final int sep = raw.codeUnitAt(2);
    return sep == 47 || sep == 92; // '/' or '\'
  }

  Future<Uri?> _resolveCover(Track track) async {
    try {
      final File? cover = await _ref.read(coverStoreProvider).resolve(track.coverArtPath);
      if (cover != null) {
        return cover.uri;
      }
    } on Object catch (error) {
      debugPrint('[resolver] 读取封面缓存失败: $error');
    }
    final String? url = track.coverArtUrl;
    return (url == null || url.isEmpty) ? null : Uri.tryParse(url);
  }
}
