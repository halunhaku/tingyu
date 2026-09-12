import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/sources/quark/quark_cookie_store.dart';
import 'package:tingyu/sources/quark/quark_drive_client.dart';
import 'package:tingyu/sources/quark/quark_source_adapter.dart';
import 'package:tingyu/sources/source_adapter.dart';

/// 用 dio 的自定义 [HttpClientAdapter] 拦下所有请求：测试不碰外网，也不需要真实账号。
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

/// 假凭据存储：只覆盖安全存储读写，不触碰平台通道。
class _FakeCookieStore extends QuarkCookieStore {
  _FakeCookieStore(this.cookie);

  String? cookie;

  final List<String> saved = <String>[];

  @override
  Future<String?> load(String sourceId) async => cookie;

  @override
  Future<void> save(String sourceId, String cookie) async {
    this.cookie = cookie;
    saved.add(cookie);
  }

  @override
  Future<void> delete(String sourceId) async {
    cookie = null;
  }
}

QuarkDriveClient _buildClient(
  _Handler handler, {
  List<RequestOptions>? requests,
  DateTime Function()? clock,
}) {
  final List<RequestOptions> log = requests ?? <RequestOptions>[];
  final Dio dio = Dio(BaseOptions(validateStatus: (int? status) => true));
  dio.httpClientAdapter = _FakeHttpAdapter(handler, log);
  return QuarkDriveClient(dio: dio, clock: clock, folderDelay: Duration.zero);
}

ResponseBody _jsonBody(
  Object payload, {
  int statusCode = 200,
  Map<String, List<String>>? headers,
}) =>
    ResponseBody.fromString(
      jsonEncode(payload),
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json;charset=UTF-8'],
        ...?headers,
      },
    );

const String _cookie = 'session=abc; __puus=stale';

void main() {
  test('verifyCookie：200 且 status=200 才有效，昵称固定为「夸克用户」', () async {
    final List<RequestOptions> requests = <RequestOptions>[];
    final QuarkDriveClient client = _buildClient(
      (RequestOptions options) async => _jsonBody(<String, Object?>{'status': 200, 'data': <String, Object?>{}}),
      requests: requests,
    );

    expect(await client.verifyCookie(_cookie), (isValid: true, nickname: '夸克用户'));
    final RequestOptions request = requests.single;
    expect(request.method, 'GET');
    expect(request.uri.host, 'drive-pc.quark.cn');
    expect(request.uri.path, '/1/clouddrive/file/sort');
    expect(request.uri.queryParameters['pdir_fid'], '0');
    expect(request.uri.queryParameters['_page'], '1');
    expect(request.uri.queryParameters['_size'], '1');

    expect(
      await _buildClient((_) async => _jsonBody(<String, Object?>{'status': 400})).verifyCookie(_cookie),
      (isValid: false, nickname: ''),
    );
    expect(
      await _buildClient((_) async => _jsonBody(<String, Object?>{}, statusCode: 403)).verifyCookie(_cookie),
      (isValid: false, nickname: ''),
    );
    expect(
      await _buildClient((_) async => ResponseBody.fromString('<html>', 200)).verifyCookie(_cookie),
      (isValid: false, nickname: ''),
    );
  });

  test('listFolder：解析目录/文件、size 为整数或缺失时的回退', () async {
    final List<RequestOptions> requests = <RequestOptions>[];
    final QuarkDriveClient client = _buildClient(
      (RequestOptions options) async => _jsonBody(<String, Object?>{
        'status': 200,
        'data': <String, Object?>{
          'list': <Object?>[
            <String, Object?>{'fid': 'dir-1', 'file_name': '专辑', 'file_type': 0},
            <String, Object?>{
              'fid': 'file-1',
              'file_name': '晴天.flac',
              'file_type': 1,
              'size': 54641611,
              'format_type': 'flac',
            },
            <String, Object?>{'fid': 'file-2', 'file_name': '园游会.mp3', 'file_type': 1},
            <String, Object?>{'fid': 'file-3', 'file_name': '带小数.mp3', 'file_type': 1, 'size': 1024.0},
            <String, Object?>{'file_name': '没有 fid.mp3', 'file_type': 1},
          ],
        },
      }),
      requests: requests,
    );

    final List<QuarkItem> items = await client.listFolder(fid: 'root-fid', cookie: _cookie);

    expect(items.map((QuarkItem i) => i.id).toList(), <String>['dir-1', 'file-1', 'file-2', 'file-3']);
    expect(items[0].name, '专辑');
    expect(items[0].isFolder, isTrue);
    expect(items[0].formatType, 'dir');
    expect(items[0].size, 0);
    expect(items[1].isFolder, isFalse);
    expect(items[1].formatType, 'flac');
    expect(items[1].size, 54641611);
    expect(items[2].formatType, 'file');
    expect(items[2].size, 0);
    expect(items[3].size, 1024);

    // 请求头与 URL 必须与 Swift 的 applyAPIHeaders / listFolder 一致。
    final RequestOptions request = requests.single;
    expect(request.method, 'GET');
    expect(request.uri.host, 'drive-pc.quark.cn');
    expect(request.uri.path, '/1/clouddrive/file/sort');
    expect(request.uri.queryParameters['pr'], 'ucpro');
    expect(request.uri.queryParameters['fr'], 'pc');
    expect(request.uri.queryParameters['pdir_fid'], 'root-fid');
    expect(request.uri.queryParameters['_page'], '1');
    expect(request.uri.queryParameters['_size'], '100');
    expect(request.uri.queryParameters['_fetch_total'], '1');
    expect(request.uri.queryParameters['_sort'], 'file_type:asc,file_name:asc');
    expect(request.headers['Cookie'], _cookie);
    expect(request.headers['User-Agent'], QuarkDriveClient.userAgent);
    expect(request.headers['Referer'], 'https://pan.quark.cn/');
    expect(request.headers['Origin'], 'https://pan.quark.cn');
    expect(request.headers['Accept'], 'application/json, text/plain, */*');
    expect(request.headers.containsKey('Content-Type'), isFalse);

    // 结构不符（缺 data.list / 非 JSON / 非 2xx 由调用方另测）时返回空列表。
    expect(await _buildClient((_) async => _jsonBody(<String, Object?>{'status': 200})).listFolder(cookie: _cookie), isEmpty);
    expect(await _buildClient((_) async => ResponseBody.fromString('not json', 200)).listFolder(cookie: _cookie), isEmpty);
  });

  test('extractDownloadURL：三种响应形状 + 字段回退', () {
    expect(
      QuarkDriveClient.extractDownloadURL(<String, dynamic>{
        'data': <Object?>[
          <String, dynamic>{'download_url': 'https://cdn.example/a.mp3'},
        ],
      }).toString(),
      'https://cdn.example/a.mp3',
    );
    expect(
      QuarkDriveClient.extractDownloadURL(<String, dynamic>{
        'data': <String, dynamic>{'download_url_https': 'https://cdn.example/b.mp3'},
      }).toString(),
      'https://cdn.example/b.mp3',
    );
    expect(
      QuarkDriveClient.extractDownloadURL(<String, dynamic>{
        'data': <String, dynamic>{
          'list': <Object?>[
            <String, dynamic>{'downloadUrl': 'https://cdn.example/c.mp3'},
          ],
        },
      }).toString(),
      'https://cdn.example/c.mp3',
    );
    expect(
      QuarkDriveClient.extractDownloadURL(<String, dynamic>{
        'data': <String, dynamic>{
          'list': <Object?>[
            <String, dynamic>{'url': 'https://cdn.example/d.mp3'},
          ],
        },
      }).toString(),
      'https://cdn.example/d.mp3',
    );

    // 字段优先级：download_url > download_url_https > downloadUrl > url。
    expect(
      QuarkDriveClient.extractDownloadURL(<String, dynamic>{
        'data': <String, dynamic>{
          'url': 'https://cdn.example/low.mp3',
          'downloadUrl': 'https://cdn.example/mid.mp3',
          'download_url': 'https://cdn.example/high.mp3',
        },
      }).toString(),
      'https://cdn.example/high.mp3',
    );

    // data[] 里第一条不可用时继续找下一条；全部不可用则 null。
    expect(
      QuarkDriveClient.extractDownloadURL(<String, dynamic>{
        'data': <Object?>[
          <String, dynamic>{'nope': 1},
          <String, dynamic>{'download_url': 'https://cdn.example/e.mp3'},
        ],
      }).toString(),
      'https://cdn.example/e.mp3',
    );
    expect(QuarkDriveClient.extractDownloadURL(<String, dynamic>{'data': <String, dynamic>{'download_url': '不是地址'}}), isNull);
    expect(QuarkDriveClient.extractDownloadURL(<String, dynamic>{'data': <String, dynamic>{}}), isNull);
    expect(QuarkDriveClient.extractDownloadURL(<String, dynamic>{}), isNull);
  });

  test('getDownloadUrl：直链缓存 5400s，__puus 刷新后合并回 Cookie 串', () async {
    final List<RequestOptions> requests = <RequestOptions>[];
    int calls = 0;
    DateTime now = DateTime(2026, 9, 11, 12);
    final QuarkDriveClient client = _buildClient(
      (RequestOptions options) async {
        calls += 1;
        return _jsonBody(
          <String, Object?>{
            'status': 200,
            'data': <Object?>[
              <String, Object?>{'download_url': 'https://cdn.example/a.mp3?calls=$calls'},
            ],
          },
          headers: <String, List<String>>{
            'set-cookie': <String>['__puus=fresh-value; Path=/; HttpOnly'],
          },
        );
      },
      requests: requests,
      clock: () => now,
    );

    final Uri first = await client.getDownloadUrl('fid-1', _cookie);
    expect(first.toString(), 'https://cdn.example/a.mp3?calls=1');
    expect(calls, 1);
    expect(requests.single.uri.host, 'drive-pc.quark.cn');

    // 同一 fid 第二次命中缓存，不再发请求。
    final Uri second = await client.getDownloadUrl('fid-1', _cookie);
    expect(second, first);
    expect(calls, 1);

    // 刷新出来的 __puus 覆盖原 Cookie 串里的旧值。
    expect(client.latestCookie(_cookie), 'session=abc; __puus=fresh-value');
    expect(client.latestCookie('session=abc'), 'session=abc; __puus=fresh-value');

    // 超过 5400s 后缓存失效，重新取直链（仍会先试 pc 端点）。
    now = now.add(const Duration(seconds: 5401));
    final Uri third = await client.getDownloadUrl('fid-1', _cookie);
    expect(third.toString(), 'https://cdn.example/a.mp3?calls=2');
    expect(calls, 2);
    expect(requests.length, 2);

    // 没抓到 __puus 时原样返回。
    final QuarkDriveClient plain = _buildClient(
      (_) async => _jsonBody(<String, Object?>{
        'status': 200,
        'data': <String, dynamic>{'download_url': 'https://cdn.example/x.mp3'},
      }),
    );
    await plain.getDownloadUrl('fid-2', _cookie);
    expect(plain.latestCookie(_cookie), _cookie);
  });

  test('getDownloadUrl：错误映射（401 / 31001 / login / 429 / 非 2xx / 非 200 status）', () async {
    Future<Object> failure(Object payload, {int statusCode = 200}) async {
      final QuarkDriveClient client = _buildClient((_) async => _jsonBody(payload, statusCode: statusCode));
      try {
        await client.getDownloadUrl('fid-1', _cookie);
      } catch (error) {
        return error;
      }
      fail('应当抛出异常');
    }

    expect(await failure(<String, Object?>{}, statusCode: 401), isA<QuarkUnauthenticated>());
    expect(
      await failure(<String, Object?>{'status': 200, 'code': 31001, 'message': 'require_login'}),
      isA<QuarkUnauthenticated>(),
    );
    expect(
      await failure(<String, Object?>{'status': 200, 'message': 'please login first'}),
      isA<QuarkUnauthenticated>(),
    );
    expect(await failure(<String, Object?>{'status': 200, 'message': 'login required'}), isA<QuarkUnauthenticated>());
    // 大小写敏感：Swift 的 `contains("login")` 不认 "Login"，这里必须同样落回解析错误。
    expect(await failure(<String, Object?>{'status': 200, 'message': 'Login required'}), isA<QuarkParseError>());
    expect(await failure(<String, Object?>{'status': 429}), isA<QuarkRateLimited>());
    expect(await failure(<String, Object?>{}, statusCode: 429), isA<QuarkRateLimited>());

    final Object serverError = await failure(<String, Object?>{'message': '服务开小差'}, statusCode: 503);
    expect(serverError, isA<QuarkNetworkError>());
    expect((serverError as QuarkException).message, '夸克网络连接异常: 直链失败 HTTP 503 服务开小差');

    final Object bareError = await failure(<String, Object?>{'status': 500, 'message': ''});
    expect(bareError, isA<QuarkNetworkError>());
    expect((bareError as QuarkException).message, '夸克网络连接异常: 接口 status 500');

    final Object parseError = await failure(<String, Object?>{'status': 200, 'data': <String, Object?>{}});
    expect(parseError, isA<QuarkParseError>());
    expect((parseError as QuarkException).message, contains('响应中没有 download_url'));

    // 两个端点都失败时抛出最后一个错误：说明回退顺序是 pc → cdn。
    final QuarkDriveClient fallback = _buildClient(
      (RequestOptions options) async =>
          _jsonBody(<String, Object?>{}, statusCode: options.uri.host == 'drive-pc.quark.cn' ? 500 : 503),
    );
    final Object last = await () async {
      try {
        await fallback.getDownloadUrl('fid-1', _cookie);
      } catch (error) {
        return error;
      }
      fail('应当抛出异常');
    }();
    expect((last as QuarkException).message, '夸克网络连接异常: 直链失败 HTTP 503');

    // 空 Cookie 直接判定未认证，且不发请求。
    final List<RequestOptions> requests = <RequestOptions>[];
    final QuarkDriveClient empty = _buildClient((_) async => _jsonBody(<String, Object?>{'status': 200}), requests: requests);
    await expectLater(empty.getDownloadUrl('fid-1', '   '), throwsA(isA<QuarkUnauthenticated>()));
    expect(requests, isEmpty);

    // 目录接口非 2xx 是网络错误，文案与 Swift 一致。
    final QuarkDriveClient brokenList = _buildClient((_) async => _jsonBody(<String, Object?>{}, statusCode: 500));
    final Object listError = await () async {
      try {
        await brokenList.listFolder(cookie: _cookie);
      } catch (error) {
        return error;
      }
      fail('应当抛出异常');
    }();
    expect((listError as QuarkException).message, '夸克网络连接异常: 读取夸克文件列表失败 (HTTP 500)');
  });

  group('scan()', () {
    // 目录树：0 → f1(dir) / f2(dir) / 音频 / 图片；f1 → f11(dir) + 音频；f11 → 音频。
    final Map<String, List<Map<String, Object?>>> tree = <String, List<Map<String, Object?>>>{
      '0': <Map<String, Object?>>[
        <String, Object?>{'fid': 'f1', 'file_name': '专辑一', 'file_type': 0},
        <String, Object?>{'fid': 'f2', 'file_name': '空目录', 'file_type': 0},
        <String, Object?>{
          'fid': 'file-root',
          'file_name': '周杰伦 - 晴天.mp3',
          'file_type': 1,
          'size': 54641611,
          'format_type': 'mp3',
        },
        <String, Object?>{'fid': 'file-cover', 'file_name': 'cover.jpg', 'file_type': 1, 'size': 1024},
      ],
      'f1': <Map<String, Object?>>[
        <String, Object?>{'fid': 'f11', 'file_name': '深层', 'file_type': 0},
        <String, Object?>{
          'fid': 'file-nested',
          'file_name': '园游会 - 周杰伦 - 叶惠美.flac',
          'file_type': 1,
          'size': 2048,
          'format_type': 'flac',
        },
      ],
      'f11': <Map<String, Object?>>[
        <String, Object?>{'fid': 'file-deep', 'file_name': '深藏.wav', 'file_type': 1, 'size': 4096},
        <String, Object?>{'fid': 'file-noext', 'file_name': '没有扩展名', 'file_type': 1},
        <String, Object?>{'fid': 'file-dot', 'file_name': '句尾.', 'file_type': 1},
      ],
      'f2': <Map<String, Object?>>[],
    };

    Future<ResponseBody> handler(RequestOptions options) async {
      final String fid = options.uri.queryParameters['pdir_fid']!;
      return _jsonBody(<String, Object?>{
        'status': 200,
        'data': <String, Object?>{'list': tree[fid] ?? <Map<String, Object?>>[]},
      });
    }

    QuarkSourceAdapter adapterWith(
      List<RequestOptions> requests, {
      String? cookie = _cookie,
      int maxDepth = 5,
      int maxFiles = 5000,
    }) =>
        QuarkSourceAdapter(
          sourceId: 'src-1',
          folderFid: '0',
          client: _buildClient(handler, requests: requests),
          cookieStore: _FakeCookieStore(cookie),
          maxDepth: maxDepth,
          maxFiles: maxFiles,
        );

    test('BFS 深度受限：maxDepth=1 只扫根目录与一层子目录', () async {
      final List<RequestOptions> requests = <RequestOptions>[];
      final List<String> progress = <String>[];
      final QuarkSourceAdapter adapter = adapterWith(requests, maxDepth: 1);

      final SourceScanResult result = await adapter.scan(onProgress: (int done, String name) => progress.add('$done:$name'));

      expect(result.cancelled, isFalse);
      expect(result.skipped, 0);
      expect(
        result.tracks.map((ScannedTrack t) => t.filePathOrUrl).toList(),
        <String>['quark://file-root', 'quark://file-nested'],
      );
      // 目录请求：根目录 → f1 → f2（f11 是第 2 层，不再进队列）。
      expect(
        requests.map((RequestOptions r) => r.uri.queryParameters['pdir_fid']).toList(),
        <String>['0', 'f1', 'f2'],
      );

      final ScannedTrack root = result.tracks.first;
      expect(root.title, '晴天');
      expect(root.artist, '周杰伦');
      expect(root.album, '夸克曲库'); // 解析出的占位专辑被替换
      expect(root.duration, 0);
      expect(root.fileFormat, 'mp3');
      expect(root.fileSize, 54641611);
      expect(progress, <String>['1:晴天', '2:园游会']);
    });

    test('BFS 深度允许时扫到更深一层，并保留非占位专辑', () async {
      final List<RequestOptions> requests = <RequestOptions>[];
      final QuarkSourceAdapter adapter = adapterWith(requests, maxDepth: 2);

      final SourceScanResult result = await adapter.scan();

      expect(
        result.tracks.map((ScannedTrack t) => t.filePathOrUrl).toList(),
        <String>['quark://file-root', 'quark://file-nested', 'quark://file-deep'],
      );
      // 无扩展名 / 结尾点号 / 非音频一律跳过。
      expect(result.tracks.map((ScannedTrack t) => t.fileFormat).toList(), <String>['mp3', 'flac', 'wav']);
      expect(result.tracks[1].artist, '周杰伦');
      expect(result.tracks[1].album, '叶惠美');
      expect(result.tracks[1].title, '园游会');
      expect(result.tracks[2].title, '深藏');
      expect(requests.map((RequestOptions r) => r.uri.queryParameters['pdir_fid']).toList(), <String>['0', 'f1', 'f2', 'f11']);
    });

    test('maxFiles 截断：达到上限立即停止并停止请求后续目录', () async {
      final List<RequestOptions> requests = <RequestOptions>[];
      final QuarkSourceAdapter adapter = adapterWith(requests, maxFiles: 2);

      final SourceScanResult result = await adapter.scan();

      expect(result.tracks.map((ScannedTrack t) => t.filePathOrUrl).toList(), <String>['quark://file-root', 'quark://file-nested']);
      expect(requests.map((RequestOptions r) => r.uri.queryParameters['pdir_fid']).toList(), <String>['0', 'f1']);
    });

    test('取消：isCancelled 命中时立刻返回已扫到的结果', () async {
      final List<RequestOptions> requests = <RequestOptions>[];
      final QuarkSourceAdapter adapter = adapterWith(requests);

      final SourceScanResult result = await adapter.scan(isCancelled: () => true);

      expect(result.cancelled, isTrue);
      expect(result.tracks, isEmpty);
      expect(requests, isEmpty);
    });

    test('缺凭据时抛出未认证异常', () async {
      final List<RequestOptions> requests = <RequestOptions>[];
      final QuarkSourceAdapter adapter = adapterWith(requests, cookie: null);

      await expectLater(adapter.scan(), throwsA(isA<QuarkUnauthenticated>()));
      expect(requests, isEmpty);
    });
  });

  test('open()：解析 quark://fid、返回带鉴权头的直链并把刷新后的 Cookie 写回', () async {
    final List<RequestOptions> requests = <RequestOptions>[];
    final QuarkDriveClient client = _buildClient(
      (RequestOptions options) async => _jsonBody(
        <String, Object?>{
          'status': 200,
          'data': <String, dynamic>{'download_url': 'https://cdn.example/audio.mp3'},
        },
        headers: <String, List<String>>{
          'set-cookie': <String>['__puus=fresh', 'other=1'],
        },
      ),
      requests: requests,
    );
    final _FakeCookieStore store = _FakeCookieStore(_cookie);
    final QuarkSourceAdapter adapter = QuarkSourceAdapter(
      sourceId: 'src-1',
      folderFid: '0',
      client: client,
      cookieStore: store,
    );

    final PlaybackItem item = await adapter.open('quark://fid-9');

    expect(item.uri.toString(), 'https://cdn.example/audio.mp3');
    expect(item.httpHeaders, <String, String>{
      'Cookie': 'session=abc; __puus=fresh',
      'User-Agent': QuarkDriveClient.userAgent,
      'Referer': 'https://pan.quark.cn/',
      'Origin': 'https://pan.quark.cn',
      'Accept': '*/*',
    });

    final RequestOptions request = requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/1/clouddrive/file/download');
    expect(request.uri.host, 'drive-pc.quark.cn');
    expect(request.data, <String, Object?>{
      'fids': <String>['fid-9'],
    });
    expect(request.headers['Content-Type'], 'application/json;charset=UTF-8');
    expect(request.headers['Cookie'], _cookie);

    // 刷新出来的 __puus 写回凭据存储，下次播放用的是新 Cookie。
    expect(store.saved, <String>['session=abc; __puus=fresh']);
    expect(await store.load('src-1'), 'session=abc; __puus=fresh');

    // 非 quark:// 地址与空 fid 都是解析错误。
    await expectLater(adapter.open('https://example.com/a.mp3'), throwsA(isA<QuarkParseError>()));
    await expectLater(adapter.open('quark://  '), throwsA(isA<QuarkParseError>()));

    // 缺凭据时未认证，且不发请求。
    final QuarkSourceAdapter anonymous = QuarkSourceAdapter(
      sourceId: 'src-2',
      folderFid: '0',
      client: client,
      cookieStore: _FakeCookieStore(null),
    );
    await expectLater(anonymous.open('quark://fid-9'), throwsA(isA<QuarkUnauthenticated>()));
    expect(adapter.sourceId, 'src-1');
  });
}
