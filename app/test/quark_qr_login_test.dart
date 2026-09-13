import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/sources/quark/quark_qr_login.dart';
import 'package:tingyu/sources/quark/quark_session.dart';

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

ResponseBody _json(
  Object payload, {
  int statusCode = 200,
  Map<String, List<String>> headers = const <String, List<String>>{},
}) => ResponseBody.fromString(
  jsonEncode(payload),
  statusCode,
  headers: <String, List<String>>{
    Headers.contentTypeHeader: <String>['application/json'],
    ...headers,
  },
);

void main() {
  test('扫码流使用 client_id 532，并贯穿 CAS 与重定向 Cookie', () async {
    final List<RequestOptions> requests = <RequestOptions>[];
    final Dio dio = Dio(BaseOptions(validateStatus: (_) => true));
    dio.httpClientAdapter = _FakeHttpAdapter((RequestOptions request) async {
      switch (request.uri.path) {
        case '/cas/ajax/getTokenForQrcodeLogin':
          return _json(
            <String, Object?>{
              'status': 2000000,
              'message': 'ok',
              'data': <String, Object?>{
                'members': <String, Object?>{'token': 'fresh-token'},
              },
            },
            headers: <String, List<String>>{
              'set-cookie': <String>['cas_token=alpha; Path=/; HttpOnly'],
            },
          );
        case '/cas/ajax/getServiceTicketByQrcodeToken':
          expect(request.headers['Cookie'], 'cas_token=alpha');
          return _json(
            <String, Object?>{
              'status': 2000000,
              'message': 'ok',
              'data': <String, Object?>{
                'members': <String, Object?>{'service_ticket': 'ticket-1'},
              },
            },
            headers: <String, List<String>>{
              'set-cookie': <String>['cas_refresh=beta; Path=/'],
            },
          );
        case '/account/info':
          expect(request.uri.queryParameters['lw'], 'scan');
          expect(request.uri.queryParameters['fr'], 'pc');
          expect(request.uri.queryParameters['platform'], 'pc');
          expect(request.headers['Cookie'], contains('cas_token=alpha'));
          expect(request.headers['Cookie'], contains('cas_refresh=beta'));
          return ResponseBody.fromString(
            '',
            302,
            headers: <String, List<String>>{
              'location': <String>['/landing'],
              'set-cookie': <String>['__pus=main; Domain=.quark.cn; Path=/'],
            },
          );
        case '/landing':
          expect(request.headers['Cookie'], contains('__pus=main'));
          return ResponseBody.fromString(
            '',
            200,
            headers: <String, List<String>>{
              'set-cookie': <String>['__uid=user-1; Domain=.quark.cn; Path=/'],
            },
          );
        case '/':
          return ResponseBody.fromString(
            '',
            200,
            headers: <String, List<String>>{
              'set-cookie': <String>[
                '__kps=session-key; Domain=.quark.cn; Path=/',
              ],
            },
          );
        case '/1/clouddrive/file/sort':
          return ResponseBody.fromString(
            '{}',
            200,
            headers: <String, List<String>>{
              'set-cookie': <String>[
                '__puus=refreshed; Domain=.quark.cn; Path=/',
              ],
            },
          );
      }
      return ResponseBody.fromString('', 404);
    }, requests);

    final QuarkQrLogin login = QuarkQrLogin(dio: dio);
    final QuarkQrSession session = await login.start();

    final RequestOptions tokenRequest = requests.first;
    expect(tokenRequest.uri.queryParameters['client_id'], '532');
    expect(tokenRequest.uri.queryParameters['v'], '1.2');
    expect(
      tokenRequest.uri.queryParameters['request_id'],
      matches(RegExp(r'^[a-f0-9]{32}$')),
    );
    expect(tokenRequest.uri.queryParameters.containsKey('ut'), isFalse);
    expect(tokenRequest.uri.queryParameters.containsKey('sch'), isFalse);

    final Uri qr = Uri.parse(session.qrContent);
    expect(qr.queryParameters['token'], 'fresh-token');
    expect(qr.queryParameters['client_id'], '532');
    expect(session.qrContent, contains('&uc_param_str=&uc_biz_str='));
    expect(session.qrContent, isNot(contains('&uc_param_str&')));
    expect(qr.queryParameters.containsKey('sch'), isFalse);
    expect(qr.queryParameters.containsKey('sve'), isFalse);

    final QuarkQrPollResult result = await login.poll(session);
    expect(result.phase, QuarkQrPhase.scanned);
    expect(result.cookie, contains('cas_token=alpha'));
    expect(result.cookie, contains('cas_refresh=beta'));
    expect(result.cookie, contains('__pus=main'));
    expect(result.cookie, contains('__uid=user-1'));
    expect(result.cookie, contains('__kps=session-key'));
    expect(result.cookie, contains('__puus=refreshed'));

    final RequestOptions pollRequest = requests.firstWhere(
      (RequestOptions request) =>
          request.uri.path.endsWith('getServiceTicketByQrcodeToken'),
    );
    expect(pollRequest.uri.queryParameters['client_id'], '532');
    expect(pollRequest.uri.queryParameters['token'], 'fresh-token');
  });

  test('换票未收到主会话 Cookie 时返回不含敏感值的诊断信息', () async {
    final Dio dio = Dio(BaseOptions(validateStatus: (_) => true));
    dio.httpClientAdapter = _FakeHttpAdapter((RequestOptions request) async {
      if (request.uri.path.endsWith('getServiceTicketByQrcodeToken')) {
        return _json(<String, Object?>{
          'status': 2000000,
          'data': <String, Object?>{
            'members': <String, Object?>{'service_ticket': 'secret-ticket'},
          },
        });
      }
      return ResponseBody.fromString('{}', 200);
    }, <RequestOptions>[]);

    final QuarkQrPollResult result = await QuarkQrLogin(dio: dio).poll(
      QuarkQrSession(
        token: 'secret-token',
        qrContent: 'https://example.test',
        cookieJar: QuarkCookieJar.parse('cas_only=secret-value'),
      ),
    );
    expect(result.phase, QuarkQrPhase.error);
    expect(result.message, contains('未收到 __pus'));
    expect(result.message, contains('cookies=cas_only'));
    expect(result.message, isNot(contains('secret-ticket')));
    expect(result.message, isNot(contains('secret-value')));
  });

  test('轮询明确映射等待、过期、失败与取消状态', () async {
    Future<QuarkQrPollResult> pollStatus(int status, String message) async {
      final Dio dio = Dio(BaseOptions(validateStatus: (_) => true));
      dio.httpClientAdapter = _FakeHttpAdapter(
        (_) async =>
            _json(<String, Object?>{'status': status, 'message': message}),
        <RequestOptions>[],
      );
      return QuarkQrLogin(dio: dio).poll(
        QuarkQrSession(
          token: 'token',
          qrContent: 'https://example.test',
          cookieJar: QuarkCookieJar.empty(),
        ),
      );
    }

    expect((await pollStatus(50004001, '')).phase, QuarkQrPhase.waitingScan);
    expect((await pollStatus(50004002, '')).phase, QuarkQrPhase.expired);
    expect((await pollStatus(50004003, '请求失败')).phase, QuarkQrPhase.error);
    expect((await pollStatus(50004004, '')).phase, QuarkQrPhase.error);
  });
}
