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

    PlaybackItem base = PlaybackItem.fromUri(Uri.file(track.filePathOrUrl));
    if (source != null) {
      try {
        final SourceAdapter adapter = await buildSourceAdapter(_ref, source);
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
