import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/sources/ai/ai_client.dart';
import 'package:tingyu/sources/ai/ai_config.dart';

typedef _Handler = Future<ResponseBody> Function(RequestOptions options);

class _FakeHttpAdapter implements HttpClientAdapter {
  _FakeHttpAdapter(this.handler, this.requests);

  final _Handler handler;
  final List<RequestOptions> requests;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(dynamic data, {int statusCode = 200}) {
  final String text = jsonEncode(data);
  return ResponseBody.fromString(
    text,
    statusCode,
    headers: <String, List<String>>{
      'content-type': <String>['application/json; charset=utf-8'],
    },
  );
}

void main() {
  group('AIProviderPreset 服务商预设', () {
    test('预设包含 DeepSeek, 通义千问, Kimi, OpenAI, 本地 Ollama 与自定义', () {
      expect(AIProviderPreset.deepseek.displayName, 'DeepSeek');
      expect(
        AIProviderPreset.deepseek.defaultBaseUrl,
        'https://api.deepseek.com/v1',
      );
      expect(AIProviderPreset.deepseek.defaultModel, 'deepseek-chat');

      expect(AIProviderPreset.qwen.displayName, '通义千问 (Qwen)');
      expect(
        AIProviderPreset.qwen.defaultBaseUrl,
        'https://dashscope.aliyuncs.com/compatible-mode/v1',
      );
      expect(AIProviderPreset.qwen.defaultModel, 'qwen-plus');

      expect(AIProviderPreset.kimi.displayName, 'Kimi (Moonshot)');
      expect(
        AIProviderPreset.kimi.defaultBaseUrl,
        'https://api.moonshot.cn/v1',
      );
      expect(AIProviderPreset.kimi.defaultModel, 'moonshot-v1-8k');

      expect(AIProviderPreset.openai.displayName, 'OpenAI');
      expect(
        AIProviderPreset.openai.defaultBaseUrl,
        'https://api.openai.com/v1',
      );
      expect(AIProviderPreset.openai.defaultModel, 'gpt-4o-mini');

      expect(AIProviderPreset.ollama.displayName, '本地 Ollama');
      expect(
        AIProviderPreset.ollama.defaultBaseUrl,
        'http://localhost:11434/v1',
      );
      expect(AIProviderPreset.ollama.defaultModel, 'qwen2.5:7b');

      expect(AIProviderPreset.custom.displayName, '自定义');
    });
  });

  group('AIClient 通信协议与响应解析', () {
    test('标准 OpenAI /chat/completions 请求格式与鉴权头', () async {
      final List<RequestOptions> requests = <RequestOptions>[];
      final Dio dio = Dio()
        ..httpClientAdapter = _FakeHttpAdapter((RequestOptions options) async {
          return _jsonResponse(<String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': '测试成功',
                },
              },
            ],
          });
        }, requests);

      final AIClient client = AIClient(
        dio: dio,
        baseUrl: 'https://api.example.com/v1/',
        model: 'test-model',
        apiKey: 'sk-test-secret-key',
      );

      final String result = await client.complete(<ChatMessage>[
        const ChatMessage(role: 'system', content: '你是助手'),
        const ChatMessage(role: 'user', content: '你好'),
      ], temperature: 0.2);

      expect(result, '测试成功');
      expect(requests, hasLength(1));

      final RequestOptions req = requests.single;
      expect(req.uri.toString(), 'https://api.example.com/v1/chat/completions');
      expect(req.method, 'POST');
      expect(req.headers['Authorization'], 'Bearer sk-test-secret-key');

      final Map<String, dynamic> body = req.data as Map<String, dynamic>;
      expect(body['model'], 'test-model');
      expect(body['temperature'], 0.2);
      final List<dynamic> messages = body['messages'] as List<dynamic>;
      expect(messages, hasLength(2));
      expect(messages[0], <String, dynamic>{
        'role': 'system',
        'content': '你是助手',
      });
      expect(messages[1], <String, dynamic>{'role': 'user', 'content': '你好'});
    });

    test('本地 Ollama 无 key 时不附加 Authorization 请求头', () async {
      final List<RequestOptions> requests = <RequestOptions>[];
      final Dio dio = Dio()
        ..httpClientAdapter = _FakeHttpAdapter((RequestOptions options) async {
          return _jsonResponse(<String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': 'ollama ok',
                },
              },
            ],
          });
        }, requests);

      final AIClient client = AIClient(
        dio: dio,
        baseUrl: 'http://localhost:11434/v1',
        model: 'qwen2.5:7b',
        apiKey: '',
      );

      final String res = await client.complete(<ChatMessage>[
        const ChatMessage(role: 'user', content: 'hi'),
      ]);

      expect(res, 'ollama ok');
      expect(requests.single.headers['Authorization'], isNull);
    });

    test('testConnection 发送探测消息并返回结果', () async {
      final List<RequestOptions> requests = <RequestOptions>[];
      final Dio dio = Dio()
        ..httpClientAdapter = _FakeHttpAdapter((RequestOptions options) async {
          return _jsonResponse(<String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': 'hello',
                },
              },
            ],
          });
        }, requests);

      final AIClient client = AIClient(
        dio: dio,
        baseUrl: 'https://api.example.com/v1',
        model: 'test-model',
        apiKey: 'key',
      );

      final bool ok = await client.testConnection();
      expect(ok, isTrue);
      expect(requests, hasLength(1));
    });

    test('HTTP 401 映射为 AIUnauthorizedException', () async {
      final Dio dio = Dio()
        ..httpClientAdapter = _FakeHttpAdapter((RequestOptions options) async {
          return _jsonResponse(<String, dynamic>{
            'error': 'invalid api key',
          }, statusCode: 401);
        }, <RequestOptions>[]);

      final AIClient client = AIClient(
        dio: dio,
        baseUrl: 'https://api.example.com/v1',
        model: 'test-model',
        apiKey: 'wrong-key',
      );

      await expectLater(
        client.complete(<ChatMessage>[
          const ChatMessage(role: 'user', content: 'hi'),
        ]),
        throwsA(isA<AIUnauthorizedException>()),
      );
    });

    test('HTTP 429 映射为 AIRateLimitedException', () async {
      final Dio dio = Dio()
        ..httpClientAdapter = _FakeHttpAdapter((RequestOptions options) async {
          return _jsonResponse(<String, dynamic>{
            'error': 'rate limit exceeded',
          }, statusCode: 429);
        }, <RequestOptions>[]);

      final AIClient client = AIClient(
        dio: dio,
        baseUrl: 'https://api.example.com/v1',
        model: 'test-model',
        apiKey: 'key',
      );

      await expectLater(
        client.complete(<ChatMessage>[
          const ChatMessage(role: 'user', content: 'hi'),
        ]),
        throwsA(isA<AIRateLimitedException>()),
      );
    });

    test('HTTP 500 / 503 映射为 AIServerException', () async {
      final Dio dio = Dio()
        ..httpClientAdapter = _FakeHttpAdapter((RequestOptions options) async {
          return _jsonResponse(<String, dynamic>{
            'error': 'server overloaded',
          }, statusCode: 503);
        }, <RequestOptions>[]);

      final AIClient client = AIClient(
        dio: dio,
        baseUrl: 'https://api.example.com/v1',
        model: 'test-model',
        apiKey: 'key',
      );

      await expectLater(
        client.complete(<ChatMessage>[
          const ChatMessage(role: 'user', content: 'hi'),
        ]),
        throwsA(isA<AIServerException>()),
      );
    });

    test('返回结构异常（无 choices）映射为 AIResponseParseException', () async {
      final Dio dio = Dio()
        ..httpClientAdapter = _FakeHttpAdapter((RequestOptions options) async {
          return _jsonResponse(<String, dynamic>{'choices': <dynamic>[]});
        }, <RequestOptions>[]);

      final AIClient client = AIClient(
        dio: dio,
        baseUrl: 'https://api.example.com/v1',
        model: 'test-model',
        apiKey: 'key',
      );

      await expectLater(
        client.complete(<ChatMessage>[
          const ChatMessage(role: 'user', content: 'hi'),
        ]),
        throwsA(isA<AIResponseParseException>()),
      );
    });
  });
}
