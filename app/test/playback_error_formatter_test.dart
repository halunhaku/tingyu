import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:tingyu/playback/playback_error_formatter.dart';
import 'package:tingyu/sources/local/folder_permission.dart';
import 'package:tingyu/sources/quark/quark_drive_client.dart';
import 'package:tingyu/sources/webdav/webdav_client.dart';

void main() {
  group('PlaybackErrorFormatter 播放失败文案中文化归类', () {
    test('明文 HTTP 请求被系统拦截（Android cleartext 策略）', () {
      final PlatformException ex = PlatformException(
        code: '1',
        message: 'Cleartext HTTP traffic to dl.example.com not permitted',
      );
      expect(PlaybackErrorFormatter.format(ex), '系统已阻止明文 HTTP 请求，请使用 HTTPS 链接');
      expect(
        PlaybackErrorFormatter.format('Cleartext HTTP traffic not permitted'),
        '系统已阻止明文 HTTP 请求，请使用 HTTPS 链接',
      );
    });

    test('文件不存在、路径失效或 404', () {
      const FileSystemException fsEx = FileSystemException(
        'Cannot open file',
        '/music/deleted.flac',
        OSError('No such file or directory', 2),
      );
      expect(PlaybackErrorFormatter.format(fsEx), '音频文件不存在或已被移动');

      final ja.PlayerException ja404 = ja.PlayerException(
        0,
        'Response code: 404',
        0,
      );
      expect(PlaybackErrorFormatter.format(ja404), '音频文件不存在或已被移动');

      expect(
        PlaybackErrorFormatter.format(
          'Failed to open /path/a.mp3: No such file',
        ),
        '音频文件不存在或已被移动',
      );
      expect(
        PlaybackErrorFormatter.format('HTTP error: 404 Not Found'),
        '音频文件不存在或已被移动',
      );
    });

    test('网络不可达、连接超时与 TLS 握手异常', () {
      const SocketException socketEx = SocketException(
        'OS Error: Network is unreachable, errno = 101',
      );
      expect(PlaybackErrorFormatter.format(socketEx), '网络连接失败，请检查网络设置');

      const HandshakeException tlsEx = HandshakeException(
        'Connection terminated during handshake',
      );
      expect(PlaybackErrorFormatter.format(tlsEx), '网络连接失败，请检查网络设置');

      expect(
        PlaybackErrorFormatter.format('Could not resolve hostname dl.quark.cn'),
        '网络连接失败，请检查网络设置',
      );
      expect(
        PlaybackErrorFormatter.format('Connection refused'),
        '网络连接失败，请检查网络设置',
      );
    });

    test('目录授权失效与各来源认证/权限异常', () {
      const FolderPermissionLostException folderEx =
          FolderPermissionLostException();
      expect(PlaybackErrorFormatter.format(folderEx), '本地目录授权已失效，请重新选择音乐文件夹');

      const QuarkUnauthenticated quarkAuth = QuarkUnauthenticated();
      expect(PlaybackErrorFormatter.format(quarkAuth), '夸克网盘登录凭据已失效，请重新登录');

      const WebDavUnauthorized webdavAuth = WebDavUnauthorized();
      expect(
        PlaybackErrorFormatter.format(webdavAuth),
        'WebDAV 认证失败，请检查账号和应用专用密码',
      );

      const WebDavForbidden webdavForbidden = WebDavForbidden();
      expect(
        PlaybackErrorFormatter.format(webdavForbidden),
        'WebDAV 拒绝访问该目录 (403 Forbidden)',
      );

      final ja.PlayerException ja403 = ja.PlayerException(
        0,
        'Response code: 403',
        0,
      );
      expect(PlaybackErrorFormatter.format(ja403), '服务器拒绝访问，可能无权限或链接已过期');
    });

    test('流控与频控限流', () {
      const QuarkRateLimited quarkRate = QuarkRateLimited();
      expect(PlaybackErrorFormatter.format(quarkRate), '夸克网盘请求过于频繁，请稍候再试');

      const WebDavRateLimited webdavRate =
          WebDavRateLimited.temporaryFlowControl();
      expect(PlaybackErrorFormatter.format(webdavRate), contains('503 临时流控'));

      final ja.PlayerException ja429 = ja.PlayerException(
        0,
        'Response code: 429',
        0,
      );
      expect(PlaybackErrorFormatter.format(ja429), '请求过于频繁或服务器维护中，请稍候再试');

      final ja.PlayerException ja503 = ja.PlayerException(
        0,
        'Response code: 503',
        0,
      );
      expect(PlaybackErrorFormatter.format(ja503), '请求过于频繁或服务器维护中，请稍候再试');
    });

    test('Java IllegalArgumentException 与非法参数/URL', () {
      final PlatformException ex = PlatformException(
        code: 'Error',
        message: 'java.lang.IllegalArgumentException: Invalid uri path segment',
      );
      expect(PlaybackErrorFormatter.format(ex), '音频地址或参数非法，无法播放');

      const FormatException uriEx = FormatException('Invalid URI');
      expect(PlaybackErrorFormatter.format(uriEx), '音频地址或参数非法，无法播放');
    });

    test('音频格式不受支持或文件损坏', () {
      final ja.PlayerException formatEx = ja.PlayerException(
        0,
        'UnrecognizedInputFormatException: None of the available extractors could read the stream',
        0,
      );
      expect(PlaybackErrorFormatter.format(formatEx), '音频格式不受支持或文件已损坏');

      expect(
        PlaybackErrorFormatter.format('Demuxer error: no stream found'),
        '音频格式不受支持或文件已损坏',
      );
    });

    test('ExoPlayer 原生通用 Source error', () {
      final ja.PlayerException srcEx = ja.PlayerException(0, 'Source error', 0);
      expect(PlaybackErrorFormatter.format(srcEx), '音频资源读取失败');

      expect(PlaybackErrorFormatter.format('Source error'), '音频资源读取失败');
    });

    test('已有中文说明保留，并剥离 PlatformException 外壳', () {
      final PlatformException wrapped = PlatformException(
        code: '1',
        message: '夸克网络连接异常: Connection reset',
      );
      expect(
        PlaybackErrorFormatter.format(wrapped),
        '夸克网络连接异常: Connection reset',
      );

      expect(
        PlaybackErrorFormatter.format('自定义错误：无法连接私人服务器'),
        '自定义错误：无法连接私人服务器',
      );
    });
  });
}
