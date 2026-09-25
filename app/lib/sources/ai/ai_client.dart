import 'dart:async';

import 'package:dio/dio.dart';

sealed class AIException implements Exception {
  const AIException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AIUnauthorizedException extends AIException {
  const AIUnauthorizedException([super.message = 'AI 服务认证失败，请检查 API 密钥']);
}

class AIRateLimitedException extends AIException {
  const AIRateLimitedException([super.message = 'AI 请求过于频繁，已被限流']);
}

class AIServerException extends AIException {
  const AIServerException(this.statusCode, String detail)
    : super('AI 服务返回错误 ($statusCode): $detail');
  final int statusCode;
}

class AINetworkException extends AIException {
  const AINetworkException(String detail) : super('AI 网络连接失败: $detail');
}

class AIResponseParseException extends AIException {
  const AIResponseParseException([super.message = '未获取到有效的 AI 回复']);
}

class ChatMessage {
  const ChatMessage({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'role': role,
    'content': content,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    role: json['role'] as String? ?? 'user',
    content: json['content'] as String? ?? '',
  );
}

class AIClient {
  AIClient({
    Dio? dio,
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
  }) : _dio = dio ?? _defaultDio();

  final Dio _dio;
  final String baseUrl;
  final String model;
  final String apiKey;

  static Dio _defaultDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  String get _normalizedUrl {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return '$base/chat/completions';
  }

  Future<String> complete(
    List<ChatMessage> messages, {
    double temperature = 0.1,
  }) async {
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };
    final String cleanKey = apiKey.trim();
    if (cleanKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $cleanKey';
    }

    final Map<String, dynamic> body = <String, dynamic>{
      'model': model,
      'messages': messages
          .map((ChatMessage m) => m.toJson())
          .toList(growable: false),
      'temperature': temperature,
    };

    Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        _normalizedUrl,
        data: body,
        options: Options(headers: headers),
      );
    } on DioException catch (dioError) {
      final int? status = dioError.response?.statusCode;
      if (status == 401) {
        throw const AIUnauthorizedException();
      }
      if (status == 429) {
        throw const AIRateLimitedException();
      }
      if (status != null && status >= 500) {
        final Object? data = dioError.response?.data;
        throw AIServerException(
          status,
          data?.toString() ?? dioError.message ?? 'Server error',
        );
      }
      throw AINetworkException(dioError.message ?? dioError.toString());
    } on Object catch (error) {
      throw AINetworkException(error.toString());
    }

    final dynamic data = response.data;
    if (data is! Map) {
      throw const AIResponseParseException();
    }

    final dynamic choices = data['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AIResponseParseException();
    }

    final dynamic firstChoice = choices.first;
    if (firstChoice is! Map) {
      throw const AIResponseParseException();
    }

    final dynamic message = firstChoice['message'];
    if (message is! Map) {
      throw const AIResponseParseException();
    }

    final dynamic content = message['content'];
    if (content is! String) {
      throw const AIResponseParseException();
    }

    return content;
  }

  Future<bool> testConnection() async {
    try {
      final String result = await complete(const <ChatMessage>[
        ChatMessage(role: 'user', content: 'hi'),
      ], temperature: 0.1);
      return result.trim().isNotEmpty;
    } on Object {
      return false;
    }
  }
}
