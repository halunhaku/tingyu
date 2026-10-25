import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/cover_store.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/enrichment_service.dart';
import 'package:tingyu/data/models/library_query.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/data/models/search_overview.dart';
import 'package:tingyu/data/models/search_page_result.dart';
import 'package:tingyu/data/repositories/track_repository.dart';
import 'package:tingyu/sources/scraper/metadata_enricher.dart';

import 'support/test_support.dart';

/// 只数调用次数、不发网络请求的补全服务。
class _CountingService implements LibraryEnrichmentService {
  _CountingService({required this.tracks});

  int calls = 0;

  @override
  final TrackRepository tracks;

  @override
  CoverStore get covers => throw UnimplementedError();

  @override
  MetadataEnricher get enricher => throw UnimplementedError();

  @override
  Future<EnrichmentOutcome> enrichTrack(Track track) async {
    calls++;
    return EnrichmentOutcome.unchanged;
  }
}

ScannedTrack _scan(String title) => ScannedTrack(
  filePathOrUrl: '/music/$title.flac',
  title: title,
  artist: '歌手',
  album: '专辑',
  duration: 180,
  fileSize: 1000,
  fileFormat: 'flac',
);

/// 第一首卡在闸门上，用来观察"调用方释放后还会不会继续请求下一首"。
class _GatedService extends _CountingService {
  _GatedService({required super.tracks});

  final Completer<void> gate = Completer<void>();

  @override
  Future<EnrichmentOutcome> enrichTrack(Track track) async {
    calls++;
    if (calls == 1) {
      await gate.future;
    }
    return EnrichmentOutcome.unchanged;
  }
}

void main() {
  test('搜索：敲键不查库，停顿后才查；分页查询给真实总数，不再静默截断', () async {
    final TingyuDatabase db = openTestDatabase();
    addTearDown(db.close);
    final TrackRepository repo = TrackRepository(db);
    await repo.mergeScan(
      sourceId: 's',
      scanned: <ScannedTrack>[
        for (int i = 0; i < 250; i++) _scan('song$i'),
        _scan('needle'),
      ],
    );

    final ProviderContainer container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    // 输入框立刻反映（标题/清除按钮要用），但查询词还停在防抖之前。
    container.read(searchQueryProvider.notifier).set('needle');
    expect(container.read(searchQueryProvider), 'needle');
    expect(container.read(debouncedSearchQueryProvider), isEmpty);

    await Future<void>.delayed(searchDebounce * 2);
    await pumpEventQueue();
    expect(container.read(debouncedSearchQueryProvider), 'needle');

    // 250 条命中：总数必须是真实 COUNT，而且不再有 200 条硬上限。
    const SearchPageRequest first = SearchPageRequest(text: 'song', limit: 40);
    final SearchPageResult<Track> firstPage = await container.read(
      searchSongsPageProvider(first).future,
    );
    expect(firstPage.total, 250, reason: '总数是过滤后的全量，不是本页长度');
    expect(firstPage.items.length, 40, reason: '一页只回 40 条');

    final SearchPageResult<Track> secondPage = await container.read(
      searchSongsPageProvider(first.nextPage()).future,
    );
    expect(secondPage.items.length, 40);
    expect(
      secondPage.items.first.id,
      isNot(firstPage.items.first.id),
      reason: '翻页必须给出不同的曲目',
    );

    // 「全部」视图同样给真实总数（四条只读查询，各自带 COUNT）。
    // 它读的是防抖后的查询词，所以先把词换成 'song' 并等过防抖窗口。
    container.read(debouncedSearchQueryProvider.notifier).set('song');
    await Future<void>.delayed(searchDebounce * 2);
    await pumpEventQueue();
    final SearchOverview overview = await container.read(
      searchOverviewProvider.future,
    );
    expect(overview.songs.total, 250);

    // 清空（含只剩空白）立刻生效，不等防抖，也不会闪一下旧结果。
    container.read(debouncedSearchQueryProvider.notifier).set('   ');
    expect(container.read(debouncedSearchQueryProvider), isEmpty);
    await pumpEventQueue();
  });

  test('自动补全：本会话只跑一次；没有缺失元数据的歌时一次都不跑', () async {
    final TingyuDatabase db = openTestDatabase();
    addTearDown(db.close);
    final _CountingService service = _CountingService(
      tracks: TrackRepository(db),
    );

    final ProviderContainer container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        enrichmentServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);

    // 空库：无事可做，连遍历都不该进。
    await container.read(autoLibraryEnrichmentProvider.future);
    expect(service.calls, 0, reason: '没有缺失元数据的歌时跳过整个遍历');

    await TrackRepository(db)
        .mergeScan(sourceId: 's', scanned: <ScannedTrack>[_scan('a')]);
    // 曲库页刷新会 invalidate；同一个会话内不得重跑整库网络遍历。
    container.invalidate(autoLibraryEnrichmentProvider);
    await container.read(autoLibraryEnrichmentProvider.future);
    expect(service.calls, 0, reason: '本会话已跑过一次，重挂载/刷新不再重跑');

    // 新容器 = 新会话：只有这时才真正遍历一次。
    final ProviderContainer nextSession = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        enrichmentServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(nextSession.dispose);
    await nextSession.read(autoLibraryEnrichmentProvider.future);
    expect(service.calls, 1);
  });

  test('自动补全：provider 释放后不再继续遍历剩下的歌', () async {
    final TingyuDatabase db = openTestDatabase();
    addTearDown(db.close);
    await TrackRepository(
      db,
    ).mergeScan(sourceId: 's', scanned: <ScannedTrack>[_scan('a'), _scan('b')]);

    final _GatedService service = _GatedService(tracks: TrackRepository(db));
    final ProviderContainer container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        enrichmentServiceProvider.overrideWithValue(service),
      ],
    );

    // 不 await：第一首会卡在闸门上，provider 的 Future 还没结束。
    container.read(autoLibraryEnrichmentProvider.future).ignore();
    await pumpEventQueue();
    expect(service.calls, 1);

    container.dispose(); // 页面离开/容器销毁 → ref.onDispose
    service.gate.complete();
    await pumpEventQueue();
    expect(service.calls, 1, reason: '释放后不该再发第二首的请求');
  });
  test('自动补全：一次最多补上限数量的曲目', () async {
    final TingyuDatabase db = openTestDatabase();
    addTearDown(db.close);
    final TrackRepository tracks = TrackRepository(db);
    // 100 首：封面、歌词、时长全缺（夸克整库就是这种状态）。
    await tracks.mergeScan(
      sourceId: 's',
      scanned: <ScannedTrack>[for (int i = 0; i < 100; i++) _scan('t$i')],
    );

    final _CountingService service = _CountingService(tracks: tracks);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        enrichmentServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);

    await container.read(autoLibraryEnrichmentProvider.future);

    expect(
      service.calls,
      autoEnrichmentLimit,
      reason: '一次会话最多补 $autoEnrichmentLimit 首，剩下的留给下次或手动补全',
    );
  });
}
