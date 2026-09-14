import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/cover_store.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/enrichment_service.dart';
import 'package:tingyu/data/repositories/track_repository.dart';
import 'package:tingyu/sources/scraper/itunes_cover_provider.dart';
import 'package:tingyu/sources/scraper/lrclib_provider.dart';
import 'package:tingyu/sources/scraper/metadata_enricher.dart';
import 'package:tingyu/sources/scraper/metadata_provider.dart';
import 'package:tingyu/sources/scraper/netease_provider.dart';
import 'package:tingyu/sources/scraper/qq_music_provider.dart';

import 'support/test_support.dart';

/// 抓取是尽力而为：上游失败（离线时的 TLS 握手失败就是这种）不能变成未捕获异常，
/// 否则 `unawaited(enrichTrack(...))` 的调用点会把它漏到 zone 上（见 docs §23 复核）。
final class _OfflineEnricher extends MetadataEnricher {
  _OfflineEnricher()
    : super(
        searcher: QQMusicProvider(),
        lyricsProvider: LrclibProvider(),
        fallbackSearcher: NetEaseProvider(),
        fallbackLyricsProvider: NetEaseProvider(),
        coverLookup: ITunesCoverProvider(),
        downloader: ImageDownloader(),
      );

  @override
  Future<EnrichmentResult> enrich(EnrichmentInput input) async =>
      throw const SocketException('网络不可达');
}

Track _track() => Track(
  id: 't1',
  sourceId: 's1',
  title: '晴天',
  artist: '周杰伦',
  album: '叶惠美',
  duration: 269,
  fileFormat: 'mp3',
  filePathOrUrl: '/music/晴天.mp3',
  fileSize: 0,
  isFavorite: false,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

void main() {
  test('上游失败时 enrichTrack 返回"没有变化"，而不是抛出', () async {
    final TingyuDatabase database = openTestDatabase();
    addTearDown(database.close);
    final Directory covers = await createTempDirectory();
    addTearDown(() => covers.delete(recursive: true));

    final LibraryEnrichmentService service = LibraryEnrichmentService(
      tracks: TrackRepository(database),
      covers: CoverStore(rootDirectory: () async => covers),
      enricher: _OfflineEnricher(),
    );

    final EnrichmentOutcome outcome = await service.enrichTrack(_track());

    expect(outcome.changed, isFalse);
    expect(outcome.coverSaved, isFalse);
    expect(outcome.lyricsSaved, isFalse);
  });
}
