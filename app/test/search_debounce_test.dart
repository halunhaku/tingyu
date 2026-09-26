import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/cover_store.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/enrichment_service.dart';
import 'package:tingyu/data/models/scanned_track.dart';
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
  test('搜索：敲键不查库，停顿后才查；命中被截断时记录上报 truncated', () async {
    final TingyuDatabase db = openTestDatabase();
    addTearDown(db.close);
    final TrackRepository repo = TrackRepository(db);
    await repo.mergeScan(
      sourceId: 's',
      scanned: <ScannedTrack>[
        // 250 首同名歌，必被 200 条上限截断。
        for (int i = 0; i < 250; i++) _scan('song$i'),
        _scan('needle'),
      ],
    );

    final ProviderContainer container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    AsyncValue<SearchResults>? latest;
    final ProviderSubscription<AsyncValue<SearchResults>> sub = container.listen(
      searchResultsProvider,
      (AsyncValue<SearchResults>? _, AsyncValue<SearchResults> next) =>
          latest = next,
      fireImmediately: true,
    );
    addTearDown(sub.close);
    await pumpEventQueue();

    expect(latest!.value!.tracks.length, 251, reason: '空查询给全库');
    expect(latest!.value!.limit, searchResultLimit);
    expect(latest!.value!.truncated, isFalse);

    // 输入框立刻反映（标题/清除按钮要用），但查询词还停在防抖之前。
    container.read(searchQueryProvider.notifier).set('needle');
    container.read(debouncedSearchQueryProvider.notifier).set('needle');
    expect(container.read(searchQueryProvider), 'needle');
    expect(container.read(debouncedSearchQueryProvider), isEmpty);
    await pumpEventQueue();
    expect(
      latest!.value!.tracks.length,
      251,
      reason: '防抖窗口内仍然是全库（没有发起搜索查询）',
    );

    await Future<void>.delayed(searchDebounce * 2);
    await pumpEventQueue();
    expect(container.read(debouncedSearchQueryProvider), 'needle');
    expect(latest!.value!.tracks.length, 1);
    expect(latest!.value!.truncated, isFalse);

    container.read(debouncedSearchQueryProvider.notifier).set('song');
    await Future<void>.delayed(searchDebounce * 2);
    await pumpEventQueue();
    expect(latest!.value!.tracks.length, searchResultLimit);
    expect(latest!.value!.truncated, isTrue, reason: '250 命中被截到 200，必须上报');

    // 清空（含只剩空白）立刻回到全库，不等防抖，也不会闪一下空结果。
    container.read(debouncedSearchQueryProvider.notifier).set('   ');
    expect(container.read(debouncedSearchQueryProvider), isEmpty);
    await pumpEventQueue();
    expect(latest!.value!.tracks.length, 251);
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

    await TrackRepository(db).mergeScan(
      sourceId: 's',
      scanned: <ScannedTrack>[_scan('a')],
    );
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
    await TrackRepository(db).mergeScan(
      sourceId: 's',
      scanned: <ScannedTrack>[_scan('a'), _scan('b')],
    );

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
      scanned: <ScannedTrack>[
        for (int i = 0; i < 100; i++) _scan('t$i'),
      ],
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
