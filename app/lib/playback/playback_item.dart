import 'package:flutter/foundation.dart';

/// 平台无关的可播放条目。
///
/// [uri] 支持 `file` / `http(s)` 方案。WebDAV、Quark 等需要鉴权的来源通过
/// [httpHeaders] 传递 Cookie / Referer：移动端由 ExoPlayer 直连，桌面端由流代理注入。
@immutable
class PlaybackItem {
  const PlaybackItem({
    required this.id,
    required this.uri,
    this.httpHeaders = const <String, String>{},
    this.title,
    this.artist,
    this.album,
    this.artUri,
    this.duration,
  });

  /// 用 URI 构造条目：`id` 取 URI 本身，标题缺省回退为路径末段。
  factory PlaybackItem.fromUri(
    Uri uri, {
    String? title,
    String? artist,
    String? album,
    Uri? artUri,
    Duration? duration,
    Map<String, String> httpHeaders = const <String, String>{},
  }) {
    final List<String> segments = uri.pathSegments;
    return PlaybackItem(
      id: uri.toString(),
      uri: uri,
      httpHeaders: httpHeaders,
      title: title ?? (segments.isEmpty ? uri.toString() : segments.last),
      artist: artist,
      album: album,
      artUri: artUri,
      duration: duration,
    );
  }

  /// 曲目稳定标识，用于队列与元数据对齐。
  final String id;

  final Uri uri;

  final Map<String, String> httpHeaders;

  final String? title;

  final String? artist;

  final String? album;

  final Uri? artUri;

  final Duration? duration;
}
