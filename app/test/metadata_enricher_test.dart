import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/sources/scraper/metadata_enricher.dart';
import 'package:tingyu/sources/scraper/metadata_provider.dart';

/// 记录调用并按预设返回的假来源。
final class _FakeSearcher implements MetadataSearcher {
  _FakeSearcher(this._candidate, {this.name = 'fake-search'});

  final MetadataCandidate? _candidate;

  @override
  final String name;

  int calls = 0;

  String? lastTitle;

  @override
  Future<MetadataCandidate?> search(String title, {String artist = ''}) async {
    calls++;
    lastTitle = title;
    return _candidate;
  }
}

final class _FakeLyricsProvider implements LyricsProvider {
  _FakeLyricsProvider(this._lyrics, {this.name = 'fake-lyrics'});

  final String? _lyrics;

  @override
  final String name;

  int calls = 0;

  LyricsQuery? lastQuery;

  @override
  Future<String?> fetchLyrics(LyricsQuery query, {MetadataCandidate? candidate}) async {
    calls++;
    lastQuery = query;
    return _lyrics;
  }
}

final class _FakeCoverLookup implements CoverLookup {
  _FakeCoverLookup(this._url);

  final String? _url;

  @override
  String get name => 'fake-cover';

  int calls = 0;

  @override
  Future<String?> coverUrl({required String album, String artist = ''}) async {
    calls++;
    return _url;
  }
}

/// 让 dio 返回固定字节，避免真联网。
final class _FakeHttpAdapter implements HttpClientAdapter {
  _FakeHttpAdapter(this.bytes, {this.statusCode = 200});

  final List<int> bytes;

  final int statusCode;

  final List<String> requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.toString());
    return ResponseBody.fromBytes(Uint8List.fromList(bytes), statusCode);
  }

  @override
  void close({bool force = false}) {}
}

ImageDownloader _downloaderReturning(_FakeHttpAdapter adapter) {
  final Dio dio = Dio()..httpClientAdapter = adapter;
  return ImageDownloader(dio: dio);
}

void main() {
  final List<int> coverBytes = List<int>.generate(32, (int index) => index);

  test('元数据齐备时完全不出网', () async {
    final _FakeSearcher searcher = _FakeSearcher(null);
    final _FakeLyricsProvider lyrics = _FakeLyricsProvider('x');
    final _FakeHttpAdapter adapter = _FakeHttpAdapter(coverBytes);

    final MetadataEnricher enricher = MetadataEnricher(
      searcher: searcher,
      lyricsProvider: lyrics,
      downloader: _downloaderReturning(adapter),
    );

    final EnrichmentResult result = await enricher.enrich(
      const EnrichmentInput(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        lyrics: '[00:01.00]故事的小黄花',
        hasCover: true,
      ),
    );

    expect(result.hasChanges, isFalse);
    expect(searcher.calls, 0);
    expect(lyrics.calls, 0);
    expect(adapter.requested, isEmpty);
  });

  test('脏文件名 + 占位元数据：主来源补齐歌手/专辑/封面，歌词走主来源', () async {
    final _FakeSearcher searcher = _FakeSearcher(
      const MetadataCandidate(
        provider: 'qqmusic',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        coverUrl: 'https://example.com/cover.jpg',
      ),
    );
    final _FakeLyricsProvider lyrics = _FakeLyricsProvider('[00:01.00]歌词');
    final _FakeHttpAdapter adapter = _FakeHttpAdapter(coverBytes);

    final MetadataEnricher enricher = MetadataEnricher(
      searcher: searcher,
      lyricsProvider: lyrics,
      downloader: _downloaderReturning(adapter),
    );

    final EnrichmentResult result = await enricher.enrich(
      const EnrichmentInput(title: '周杰伦 - 晴天', duration: Duration(seconds: 269)),
    );

    expect(searcher.lastTitle, '晴天', reason: '查询词应是解析后的干净标题');
    expect(result.title, '晴天');
    expect(result.artist, '周杰伦');
    expect(result.album, '叶惠美');
    expect(result.lyrics, '[00:01.00]歌词');
    expect(result.coverBytes, isNotNull);
    expect(result.coverUrl, 'https://example.com/cover.jpg');
    expect(adapter.requested, <String>['https://example.com/cover.jpg']);
    expect(lyrics.lastQuery?.duration, const Duration(seconds: 269));
  });

  test('主来源标题不匹配时不改写元数据，歌词/封面交给兜底来源', () async {
    final _FakeSearcher primary = _FakeSearcher(
      const MetadataCandidate(provider: 'qqmusic', title: '完全不同的歌', artist: '别人', album: '别的专辑'),
    );
    final _FakeSearcher fallback = _FakeSearcher(
      const MetadataCandidate(
        provider: 'netease',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        coverUrl: 'https://example.com/netease.jpg',
        sourceId: '186016',
      ),
      name: 'netease',
    );
    final _FakeLyricsProvider primaryLyrics = _FakeLyricsProvider(null);
    final _FakeLyricsProvider fallbackLyrics = _FakeLyricsProvider('[00:02.00]网易云歌词', name: 'netease');
    final _FakeHttpAdapter adapter = _FakeHttpAdapter(coverBytes);

    final MetadataEnricher enricher = MetadataEnricher(
      searcher: primary,
      lyricsProvider: primaryLyrics,
      fallbackSearcher: fallback,
      fallbackLyricsProvider: fallbackLyrics,
      downloader: _downloaderReturning(adapter),
    );

    final EnrichmentResult result = await enricher.enrich(
      const EnrichmentInput(title: '晴天', artist: '未知艺术家', album: '夸克曲库'),
    );

    expect(result.artist, isNull, reason: '不匹配的候选不得污染艺术家');
    expect(result.album, isNull);
    expect(result.lyrics, '[00:02.00]网易云歌词');
    expect(result.coverBytes, isNotNull);
    expect(adapter.requested, <String>['https://example.com/netease.jpg']);
  });

  test('歌词主来源命中时不再请求兜底歌词（封面仍会走兜底搜索）', () async {
    final _FakeSearcher fallback = _FakeSearcher(null, name: 'netease');
    final _FakeLyricsProvider primaryLyrics = _FakeLyricsProvider('[00:01.00]主来源歌词');
    final _FakeLyricsProvider fallbackLyrics = _FakeLyricsProvider('兜底歌词', name: 'netease');

    final MetadataEnricher enricher = MetadataEnricher(
      searcher: _FakeSearcher(null),
      lyricsProvider: primaryLyrics,
      fallbackSearcher: fallback,
      fallbackLyricsProvider: fallbackLyrics,
      downloader: _downloaderReturning(_FakeHttpAdapter(coverBytes)),
    );

    final EnrichmentResult result = await enricher.enrich(
      const EnrichmentInput(title: '晴天', artist: '周杰伦', album: '叶惠美'),
    );

    expect(result.lyrics, '[00:01.00]主来源歌词');
    expect(fallbackLyrics.calls, 0, reason: '歌词已拿到，不该再打兜底歌词');
    expect(fallback.calls, 1, reason: '仍缺封面，兜底搜索用于找封面');
  });

  test('封面缺失时按专辑查 iTunes，且已有封面时不再查', () async {
    final _FakeCoverLookup lookup = _FakeCoverLookup('https://example.com/itunes.jpg');
    final _FakeHttpAdapter adapter = _FakeHttpAdapter(coverBytes);

    final MetadataEnricher enricher = MetadataEnricher(
      searcher: _FakeSearcher(null),
      lyricsProvider: _FakeLyricsProvider('歌词'),
      coverLookup: lookup,
      downloader: _downloaderReturning(adapter),
    );

    final EnrichmentResult withCover = await enricher.enrich(
      const EnrichmentInput(title: '晴天', artist: '周杰伦', album: '叶惠美', hasCover: true),
    );
    expect(withCover.coverBytes, isNull);
    expect(lookup.calls, 0);

    final EnrichmentResult withoutCover = await enricher.enrich(
      const EnrichmentInput(title: '晴天', artist: '周杰伦', album: '叶惠美'),
    );
    expect(withoutCover.coverBytes, isNotNull);
    expect(lookup.calls, 1);
  });

  test('标题可疑（疑似把艺术家当歌名）时跳过，不出网', () async {
    final _FakeSearcher searcher = _FakeSearcher(null);
    final MetadataEnricher enricher = MetadataEnricher(
      searcher: searcher,
      lyricsProvider: _FakeLyricsProvider(null),
      downloader: _downloaderReturning(_FakeHttpAdapter(coverBytes)),
    );

    final EnrichmentResult result = await enricher.enrich(
      const EnrichmentInput(title: '周杰伦', artist: '周杰伦'),
    );

    expect(result.isSkipped, isTrue);
    expect(searcher.calls, 0);
  });

  test('封面下载失败时不影响元数据与歌词写回', () async {
    final _FakeSearcher searcher = _FakeSearcher(
      const MetadataCandidate(
        provider: 'qqmusic',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        coverUrl: 'https://example.com/cover.jpg',
      ),
    );
    final MetadataEnricher enricher = MetadataEnricher(
      searcher: searcher,
      lyricsProvider: _FakeLyricsProvider('[00:01.00]歌词'),
      downloader: _downloaderReturning(_FakeHttpAdapter(coverBytes, statusCode: 404)),
    );

    final EnrichmentResult result = await enricher.enrich(
      const EnrichmentInput(title: '晴天', artist: '未知艺术家', album: '夸克曲库'),
    );

    expect(result.coverBytes, isNull);
    expect(result.artist, '周杰伦');
    expect(result.lyrics, '[00:01.00]歌词');
  });
}
