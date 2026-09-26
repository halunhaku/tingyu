import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/source_adapters.dart';
import '../../data/db/database.dart';
import '../../data/models/library_summaries.dart';
import '../../data/repositories/source_repository.dart';
import '../../sources/source_adapter.dart';

/// 单个来源的同步状态（驱动来源页与侧栏的进度展示）。
class SourceSyncState {
  const SourceSyncState({
    this.running = false,
    this.message = '',
    this.done = 0,
    this.total = 0,
    this.error,
  });

  final bool running;

  final String message;

  final int done;

  final int total;

  final String? error;

  double? get progress =>
      total > 0 ? (done / total).clamp(0, 1).toDouble() : null;
}

/// 来源同步：扫描 → 合并入库 → 更新来源状态。
///
/// 与旧版一致：扫描只负责产出事实，合并（保留封面/歌词/收藏）由
/// `TrackRepository.mergeScan` 完成；被删除的曲目会连同播放列表引用一起清理。
class SourceSyncController extends Notifier<Map<String, SourceSyncState>> {
  @override
  Map<String, SourceSyncState> build() => const <String, SourceSyncState>{};

  SourceSyncState stateOf(String sourceId) =>
      state[sourceId] ?? const SourceSyncState();

  void _set(String sourceId, SourceSyncState value) {
    state = <String, SourceSyncState>{...state, sourceId: value};
  }

  /// 同步一个来源；重复调用会被忽略（同一来源串行）。
  Future<MergeResult?> sync(MusicSource source) async {
    if (stateOf(source.id).running) {
      return null;
    }
    _set(source.id, const SourceSyncState(running: true, message: '正在准备…'));
    try {
      final SourceAdapter adapter = await ref
          .read(sourceAdapterCacheProvider)
          .of(source);
      final SourceScanResult scan = await adapter.scan(
        // 扫描阶段拿不到"总数"：来源要么边翻页边发现条目（夸克/WebDAV），要么只知道
        // 已读到的文件数。这里如实只报进度数（total 留 0 → 进度条走不确定态），
        // 而不是把 done 同时当成 total —— 那会让进度条自始至终停在 100%。
        onProgress: (int done, String name) => _set(
          source.id,
          SourceSyncState(running: true, message: '已扫描 $done 首 · $name', done: done),
        ),
      );

      final MergeResult merge = await ref
          .read(trackRepositoryProvider)
          .mergeScan(
            sourceId: source.id,
            scanned: scan.tracks,
            removeMissing: scan.isAuthoritative,
          );

      final SourceRepository sources = ref.read(sourceRepositoryProvider);
      final int trackCount = await sources.trackCount(source.id);
      final String status = _syncStatus(scan, merge);
      await sources.updateSyncStatus(
        source.id,
        status: status,
        syncedAt: DateTime.now().toUtc(),
        trackCount: trackCount,
      );
      _set(
        source.id,
        SourceSyncState(message: status, done: scan.tracks.length),
      );
      // 与原生 macOS 一致：新入库曲目在后台自动补齐，不要求用户再点一次按钮。
      unawaited(enrichSource(source.id));
      if (scan.isAuthoritative) {
        // 完整同步是清理封面缓存的好时机：内容寻址后换封面会留下旧图，
        // 历史上的重复副本也只有这种"权威快照"时刻才能确定没人再引用。
        unawaited(_pruneCovers());
      }
      return merge;
    } on Object catch (error) {
      final String message = _describe(error);
      await ref
          .read(sourceRepositoryProvider)
          .updateSyncStatus(source.id, status: message);
      _set(source.id, SourceSyncState(message: message, error: message));
      return null;
    }
  }

  /// 把某个来源里缺元数据的曲目过一遍抓取管道（QQ 音乐 / LRCLIB / 网易云 / iTunes）。
  Future<void> enrichSource(String sourceId, {int? limit}) async {
    if (stateOf(sourceId).running) {
      return;
    }
    final List<Track> tracks = await ref
        .read(trackRepositoryProvider)
        .bySource(sourceId);
    final Iterable<Track> missing = tracks.where(trackNeedsEnrichment);
    final List<Track> pending = (limit == null ? missing : missing.take(limit))
        .toList(growable: false);
    if (pending.isEmpty) {
      _set(sourceId, const SourceSyncState(message: '没有需要补全的曲目'));
      return;
    }

    _set(
      sourceId,
      SourceSyncState(
        running: true,
        message: '正在补全元数据…',
        total: pending.length,
      ),
    );
    int done = 0;
    int changed = 0;
    for (final Track track in pending) {
      final outcome = await ref
          .read(enrichmentServiceProvider)
          .enrichTrack(track);
      if (outcome.changed) {
        changed++;
      }
      done++;
      _set(
        sourceId,
        SourceSyncState(
          running: true,
          message: track.title,
          done: done,
          total: pending.length,
        ),
      );
    }
    _set(
      sourceId,
      SourceSyncState(
        message: '元数据补全完成：$changed/${pending.length} 首有更新',
        done: done,
        total: done,
      ),
    );
  }

  /// 清理不再被任何曲目引用的封面文件。
  ///
  /// 只删"确实没人引用"的文件：任何一次完整同步之后调用它，会自动清掉换封面、
  /// 换来源留下的孤儿图，以及历史上按 key 命名时代留下的重复副本。
  Future<void> _pruneCovers() async {
    try {
      final Set<String> keep = await ref
          .read(trackRepositoryProvider)
          .coverNamesInUse();
      final int removed = await ref
          .read(coverStoreProvider)
          .pruneUnreferenced(keep);
      if (removed > 0) {
        debugPrint('[sources] 清理无引用封面 $removed 个');
      }
    } on Object catch (error) {
      // 清理是尽力而为：删不掉封面不该让一次成功的同步变成失败。
      debugPrint('[sources] 清理封面缓存失败: $error');
    }
  }

  static String _syncStatus(SourceScanResult scan, MergeResult merge) {
    if (scan.isAuthoritative) {
      return '已同步（新增 ${merge.added} / 更新 ${merge.updated} / 移除 ${merge.removed}）';
    }
    if (scan.cancelled) {
      return '已取消（保留未扫描曲目；新增 ${merge.added} / 更新 ${merge.updated}）';
    }
    // 截断的原因由各来源自己给（数量上限 / 层级上限 / 响应无法解析）：笼统写成
    // "达到数量上限"会把"目录层级超过上限"这类原因盖掉，用户对着提示也改不对设置。
    if (scan.truncated) {
      final String reason = scan.truncationReason ?? '来源内容未枚举完';
      return '部分同步（$reason；保留未扫描曲目；'
          '新增 ${merge.added} / 更新 ${merge.updated}）';
    }
    return '部分同步（跳过 ${scan.skipped} 项；保留未扫描曲目；'
        '新增 ${merge.added} / 更新 ${merge.updated}）';
  }

  static String _describe(Object error) {
    // 来源异常自带中文文案（WebDavException / QuarkException）。
    return error.toString().replaceFirst('Exception: ', '');
  }
}

final NotifierProvider<SourceSyncController, Map<String, SourceSyncState>>
sourceSyncProvider =
    NotifierProvider<SourceSyncController, Map<String, SourceSyncState>>(
      SourceSyncController.new,
    );
