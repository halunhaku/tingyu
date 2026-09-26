import 'dart:io';

import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../sources/local/folder_permission.dart';
import '../sources/quark/quark_drive_client.dart';
import '../sources/webdav/webdav_client.dart';

/// 播放失败原因的中文化归纳与格式化。
///
/// 抹平 Android (ExoPlayer)、iOS (AVPlayer)、桌面 (libmpv) 以及上游直链解析器
/// 的原始堆栈和底层英文错误，归纳为用户看得懂的中文提示，同时保留已有业务异常的明确说明。
abstract final class PlaybackErrorFormatter {
  static const String _cleartextBlocked = '系统已阻止明文 HTTP 请求，请使用 HTTPS 链接';
  static const String _notFound = '音频文件不存在或已被移动';
  static const String _networkError = '网络连接失败，请检查网络设置';
  static const String _permissionDenied = '没有文件或目录的访问权限';
  static const String _unauthorized = '认证失败，请检查账号密码';
  static const String _forbidden = '服务器拒绝访问，可能无权限或链接已过期';
  static const String _rateLimited = '请求过于频繁或服务器维护中，请稍候再试';
  static const String _invalidArgs = '音频地址或参数非法，无法播放';
  static const String _unsupportedFormat = '音频格式不受支持或文件已损坏';
  static const String _sourceError = '音频资源读取失败';
  static const String _defaultError = '无法加载曲目';

  /// 将各种异常对象或错误文本归纳为简明的中文提示。
  static String format(Object? error) {
    if (error == null) {
      return _defaultError;
    }

    // 1. 已有成熟中文文案的领域业务异常，直接优先保留其描述
    if (error is FolderPermissionLostException) {
      return error.toString();
    }
    if (error is QuarkException) {
      return error.message;
    }
    if (error is WebDavException) {
      return error.message;
    }

    // 2. 强类型系统/网络异常
    if (error is FileSystemException) {
      final int? code = error.osError?.errorCode;
      if (code == 2 ||
          error.message.contains('No such file') ||
          (error.osError?.message.contains('No such file') ?? false)) {
        return _notFound;
      }
      if (code == 13 ||
          error.message.contains('Permission denied') ||
          (error.osError?.message.contains('Permission denied') ?? false)) {
        return _permissionDenied;
      }
      return _notFound;
    }

    if (error is SocketException ||
        error is HandshakeException ||
        error is HttpException) {
      return _networkError;
    }

    if (error is FormatException) {
      return _invalidArgs;
    }

    // 3. 提取原始文本载荷并剥离技术封装外壳（如 PlatformException / Exception:）
    final String raw = _extractRawMessage(error);
    final String clean = _cleanTechnicalPrefix(raw);

    // 4. 归一化后的文本载荷
    final String lower = clean.toLowerCase();

    // libmpv 的报错常是「英文句式 + 本地化 errno 尾巴」，例如
    // `Cannot open file '/x.mp3': 没有那个文件或目录` —— 整体含中文，若先走下面的
    // 「已含中文则直接展示」就会原样透出，读起来中英混杂。这里按前缀先行归一。
    if (lower.contains('cannot open file') ||
        lower.contains('failed to open')) {
      if (lower.contains('no such file') || clean.contains('没有那个文件')) {
        return _notFound;
      }
      if (lower.contains('permission denied') || clean.contains('权限')) {
        return _permissionDenied;
      }
      return _sourceError;
    }

    // 自身已包含明确的中文描述，直接展示，避免覆盖上游业务语义。
    if (_containsChinese(clean)) {
      return clean;
    }

    // 5. 英文/底层技术错误分类映射

    // 明文 HTTP 拦截
    if (lower.contains('cleartext') && lower.contains('not permitted')) {
      return _cleartextBlocked;
    }

    // 文件不存在 / 404
    if (lower.contains('response code: 404') ||
        lower.contains('404 not found') ||
        lower.contains('http error: 404') ||
        lower.contains('no such file') ||
        lower.contains('filenotfoundexception') ||
        lower.contains('pathnotfoundexception')) {
      return _notFound;
    }

    // 认证 / 权限失败
    if (lower.contains('response code: 401') ||
        lower.contains('http error: 401') ||
        lower.contains('401 unauthorized')) {
      return _unauthorized;
    }
    if (lower.contains('response code: 403') ||
        lower.contains('http error: 403') ||
        lower.contains('403 forbidden')) {
      return _forbidden;
    }
    if (lower.contains('permission denied') ||
        lower.contains('securityexception')) {
      return _permissionDenied;
    }

    // 频控 / 维护
    if (lower.contains('response code: 429') ||
        lower.contains('response code: 503') ||
        lower.contains('http error: 429') ||
        lower.contains('http error: 503') ||
        lower.contains('503 service unavailable') ||
        lower.contains('ratelimited')) {
      return _rateLimited;
    }

    // 网络不可达 / 超时 / 握手失败
    if (lower.contains('network is unreachable') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('connection timed out') ||
        lower.contains('sockettimeoutexception') ||
        lower.contains('timeoutexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('could not resolve hostname') ||
        lower.contains('unknownhostexception') ||
        lower.contains('handshake') ||
        lower.contains('tls handshake failed') ||
        lower.contains('sslhandshakeexception') ||
        lower.contains('connectexception')) {
      return _networkError;
    }

    // 参数错误 / 非法 URI
    if (lower.contains('illegalargumentexception') ||
        lower.contains('invalid uri') ||
        lower.contains('malformedurlexception')) {
      return _invalidArgs;
    }

    // 格式不支持 / 解码失败
    if (lower.contains('unrecognizedinputformatexception') ||
        lower.contains('parserexception') ||
        lower.contains('demuxer error') ||
        lower.contains('no stream found') ||
        lower.contains('formatexception') ||
        lower.contains('cannot decode') ||
        lower.contains('codec error')) {
      return _unsupportedFormat;
    }

    // 原生通用 Source error
    if (clean.trim() == 'Source error' || lower.contains('source error')) {
      return _sourceError;
    }

    return clean.isEmpty ? _defaultError : clean;
  }

  static String _extractRawMessage(Object error) {
    if (error is ja.PlayerException) {
      return error.message ?? error.toString();
    }
    if (error is PlatformException) {
      return error.message ?? error.toString();
    }
    return error.toString();
  }

  static String _cleanTechnicalPrefix(String text) {
    var result = text.trim();
    if (result.startsWith('Exception: ')) {
      result = result.substring('Exception: '.length).trim();
    }
    if (result.startsWith('PlatformException(')) {
      final int firstComma = result.indexOf(',');
      if (firstComma != -1 && firstComma + 1 < result.length) {
        result = result.substring(firstComma + 1).trim();
        if (result.endsWith(')')) {
          result = result.substring(0, result.length - 1).trim();
        }
      }
    }
    return result;
  }

  static bool _containsChinese(String text) {
    for (final int rune in text.runes) {
      if (rune >= 0x4e00 && rune <= 0x9fff) {
        return true;
      }
    }
    return false;
  }
}
