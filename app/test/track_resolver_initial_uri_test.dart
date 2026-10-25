import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/track_resolver.dart';

/// Windows 真机回归：`Uri.file('quark://<fid>')` 在 Windows 上直接抛
/// `Invalid argument(s): Illegal character in path`（POSIX 上静默通过，
/// 所以 CI 一直没爆），导致 Windows 上所有夸克/WebDAV 曲目在进
/// `adapter.open()` 之前就解析失败 —— 界面提示"无法播放"。
///
/// 守住 [TrackResolver.initialUri] 的分流：非文件 scheme 原样保留，
/// 盘符路径（`tryParse` 会误读出单字母 scheme）走 `Uri.file`。
void main() {
  group('TrackResolver.initialUri', () {
    test('quark 来源占位符不抛且保留 scheme', () {
      final Uri uri = TrackResolver.initialUri(
        'quark://3e570e4c3a8e43fd8bfcd21067d223de',
      );
      expect(uri.scheme, 'quark');
    });

    test('带 query 的 https 直链不抛且保留 scheme', () {
      final Uri uri = TrackResolver.initialUri(
        'https://example.com/music/a.mp3?sign=xxx&x=1',
      );
      expect(uri.scheme, 'https');
      expect(uri.queryParameters['sign'], 'xxx');
    });

    test('Windows 反斜杠盘符路径走 file scheme', () {
      final Uri uri = TrackResolver.initialUri(
        r'F:\Music\周杰伦 - 不爱我就拉倒.mp3',
      );
      expect(uri.scheme, 'file');
      expect(
        uri.toFilePath(windows: true),
        r'F:\Music\周杰伦 - 不爱我就拉倒.mp3',
      );
    });

    test('Windows 正斜杠盘符路径走 file scheme', () {
      final Uri uri = TrackResolver.initialUri('D:/Music/星晴.mp3');
      expect(uri.scheme, 'file');
    });

    test('POSIX 绝对路径走 file scheme', () {
      final Uri uri = TrackResolver.initialUri('/Music/星晴.mp3');
      expect(uri.scheme, 'file');
    });

    test('中文括号文件名走 file scheme', () {
      final Uri uri = TrackResolver.initialUri(r'F:\Music\「不爱我就拉倒」.mp3');
      expect(uri.scheme, 'file');
    });
  });
}
