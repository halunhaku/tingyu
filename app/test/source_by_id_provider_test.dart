import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/repositories/source_repository.dart';

import 'support/test_support.dart';

/// 来源详情页读的是 `sourceByIdProvider`。同步（可能从来源列表发起）写回统计后，
/// 正开着的详情页必须立刻反映新数字，而不是等到杀进程重进才更新。
void main() {
  test('同步写回统计后，来源详情页的数据会重新推送', () async {
    final TingyuDatabase database = openTestDatabase();
    addTearDown(database.close);
    final ProviderContainer container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    final SourceRepository sources = SourceRepository(database);
    await sources.upsert(
      MusicSourcesCompanion.insert(
        id: 's1',
        name: 'Music',
        kind: 'local',
        trackCount: const Value<int>(3),
        syncStatus: const Value<String>('已同步（新增 1 / 更新 0 / 移除 0）'),
      ),
    );

    final List<MusicSource?> seen = <MusicSource?>[];
    final ProviderSubscription<AsyncValue<MusicSource?>> subscription = container
        .listen(sourceByIdProvider('s1'), (
          AsyncValue<MusicSource?>? previous,
          AsyncValue<MusicSource?> next,
        ) {
          next.whenData(seen.add);
        }, fireImmediately: true);
    addTearDown(subscription.close);

    await pumpEventQueue();
    expect(seen.last?.trackCount, 3);

    await sources.updateSyncStatus(
      's1',
      status: '已同步（新增 0 / 更新 0 / 移除 1）',
      syncedAt: DateTime.utc(2026, 9, 14),
      trackCount: 2,
    );
    await pumpEventQueue();

    expect(seen.last?.trackCount, 2);
    expect(seen.last?.syncStatus, '已同步（新增 0 / 更新 0 / 移除 1）');
  });
}
