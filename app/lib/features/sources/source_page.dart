import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../shared/empty_state.dart';
import '../shared/track_row.dart';
import 'source_sync.dart';

/// 单个来源页：同步状态 + 曲目列表 + 元数据补全入口。
class SourcePage extends ConsumerWidget {
  const SourcePage({super.key, required this.sourceId});

  final String sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<MusicSource?> source = ref.watch(sourceByIdProvider(sourceId));
    final AsyncValue<List<Track>> tracks = ref.watch(tracksOfSourceProvider(sourceId));
    final SourceSyncState sync = ref.watch(sourceSyncProvider)[sourceId] ?? const SourceSyncState();

    return source.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace stack) =>
          EmptyState(icon: Icons.error_outline, title: '来源读取失败', message: '$error'),
      data: (MusicSource? value) {
        if (value == null) {
          return const EmptyState(icon: Icons.help_outline, title: '来源不存在');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(value.name, style: Theme.of(context).textTheme.titleLarge),
                      ),
                      TextButton.icon(
                        onPressed: sync.running
                            ? null
                            : () => ref.read(sourceSyncProvider.notifier).sync(value),
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text('同步'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: sync.running
                            ? null
                            : () => ref.read(sourceSyncProvider.notifier).enrichSource(value.id),
                        icon: const Icon(Icons.auto_fix_high, size: 18),
                        label: const Text('补全元数据'),
                      ),
                    ],
                  ),
                  Text(
                    '${value.trackCount} 首 · ${value.syncStatus}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (value.localFolderPath != null)
                    Text(
                      value.localFolderPath!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if ((value.localBookmark ?? '').startsWith('content://'))
                    Text(
                      '系统授权的音乐目录（SAF）',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (value.webdavUrl != null)
                    Text(
                      '${value.webdavUrl}（${value.webdavUsername ?? ''}）',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (sync.running) ...<Widget>[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: sync.progress, minHeight: 3),
                    const SizedBox(height: 4),
                    Text(
                      sync.message,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ] else if (sync.message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        sync.message,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: sync.error != null
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      TextButton(
                        onPressed: () => context.go('/sources'),
                        child: const Text('管理来源'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: tracks.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (Object error, StackTrace stack) =>
                    EmptyState(icon: Icons.error_outline, title: '曲目读取失败', message: '$error'),
                data: (List<Track> list) {
                  if (list.isEmpty) {
                    return const EmptyState(
                      icon: Icons.cloud_off,
                      title: '该来源还没有曲目',
                      message: '点上方「同步」开始扫描',
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: list.length,
                    itemBuilder: (BuildContext context, int index) => TrackRow(
                      track: list[index],
                      index: index + 1,
                      onTap: () => ref
                          .read(playbackProvider.notifier)
                          .playTracks(list, startIndex: index),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
