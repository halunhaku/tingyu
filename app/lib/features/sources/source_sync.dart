import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/source_adapters.dart';
import '../../data/db/database.dart';
import '../../data/models/library_summaries.dart';
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

  double? get progress => total > 0 ? (done / total).clamp(0, 1).toDouble() : null;
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
    _set(
      source.id,
      const SourceSyncState(running: true, message: '正在准备…'),
    );
    try {
      final SourceAdapter adapter = await buildSourceAdapter(ref, source);
      final SourceScanResult scan = await adapter.scan(
        onProgress: (int done, String name) => _set(
          source.id,
          SourceSyncState(running: true, message: name, done: done, total: done),
        ),
      );

      final MergeResult merge = await ref.read(trackRepositoryProvider).mergeScan(
            sourceId: source.id,
            scanned: scan.tracks,
          );

      final String status = scan.cancelled
          ? '已取消（已入库 ${merge.added} 首）'
          : '已同步（新增 ${merge.added} / 更新 ${merge.updated} / 移除 ${merge.removed}）';
      await ref.read(sourceRepositoryProvider).updateSyncStatus(
            source.id,
            status: status,
            syncedAt: DateTime.now().toUtc(),
            trackCount: scan.tracks.length,
          );
      _set(source.id, SourceSyncState(message: status, done: scan.tracks.length));
      return merge;
    } on Object catch (error) {
      final String message = _describe(error);
      await ref.read(sourceRepositoryProvider).updateSyncStatus(source.id, status: message);
      _set(source.id, SourceSyncState(message: message, error: message));
      return null;
    }
  }

  /// 把某个来源里缺元数据的曲目过一遍抓取管道（QQ 音乐 / LRCLIB / 网易云 / iTunes）。
  Future<void> enrichSource(String sourceId, {int limit = 50}) async {
    if (stateOf(sourceId).running) {
      return;
    }
    final List<Track> tracks = await ref.read(trackRepositoryProvider).bySource(sourceId);
    final List<Track> pending = tracks
        .where((Track track) =>
            track.coverArtPath == null ||
            (track.lyrics == null || track.lyrics!.isEmpty) ||
            track.artist == '未知艺术家' ||
            isPlaceholderAlbum(track.album))
        .take(limit)
        .toList(growable: false);
    if (pending.isEmpty) {
      _set(sourceId, const SourceSyncState(message: '没有需要补全的曲目'));
      return;
    }

    _set(sourceId, SourceSyncState(running: true, message: '正在补全元数据…', total: pending.length));
    int done = 0;
    int changed = 0;
    for (final Track track in pending) {
      final outcome = await ref.read(enrichmentServiceProvider).enrichTrack(track);
      if (outcome.changed) {
        changed++;
      }
      done++;
      _set(
        sourceId,
        SourceSyncState(running: true, message: track.title, done: done, total: pending.length),
      );
    }
    _set(
      sourceId,
      SourceSyncState(message: '元数据补全完成：$changed/${pending.length} 首有更新', done: done, total: done),
    );
  }

  static String _describe(Object error) {
    // 来源异常自带中文文案（WebDavException / QuarkException）。
    return error.toString().replaceFirst('Exception: ', '');
  }
}

/// 便于 UI 判断是否为本地来源。
bool isLocalSource(MusicSource source) => source.kind == 'local';

/// 目录是否存在（本地来源的可用性提示）。
bool localFolderExists(MusicSource source) {
  final String? path = source.localFolderPath;
  return path != null && path.isNotEmpty && Directory(path).existsSync();
}

final NotifierProvider<SourceSyncController, Map<String, SourceSyncState>> sourceSyncProvider =
    NotifierProvider<SourceSyncController, Map<String, SourceSyncState>>(SourceSyncController.new);
