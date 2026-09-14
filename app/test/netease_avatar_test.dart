import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/sources/scraper/netease_provider.dart';

class _FakeHttpAdapter implements HttpClientAdapter {
  _FakeHttpAdapter(this.body);

  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('img1v1Url 为空时用 picUrl，并升到 https', () async {
    final Dio dio = Dio();
    dio.httpClientAdapter = _FakeHttpAdapter(<String, dynamic>{
      'result': <String, dynamic>{
        'artists': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': '周杰伦',
            'img1v1Url': '',
            'picUrl': 'http://p1.music.126.net/cover.jpg',
          },
        ],
      },
    });
    final String? url = await NetEaseProvider(dio: dio).avatarUrl('周杰伦');
    expect(url, 'https://p1.music.126.net/cover.jpg?param=500y500');
  });
}
