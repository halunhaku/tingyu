import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/features/sources/source_sync.dart';

/// Fixed, fictional data for source-management visual checks.
///
/// This file is used by the desktop preview runner and widget tests only. It
/// never reads a database, secure storage, or a remote source.
enum SourcePreviewState {
  normal,
  syncing,
  empty,
  relogin,
  error;

  static SourcePreviewState parse(String? value) {
    return switch (value) {
      'syncing' => syncing,
      'empty' => empty,
      'relogin' => relogin,
      'error' => error,
      _ => normal,
    };
  }
}

final DateTime _localSyncedAt = DateTime.utc(2026, 10, 6, 0, 24);
final DateTime _webDavSyncedAt = DateTime.utc(2026, 10, 5, 13, 16);
final DateTime _quarkSyncedAt = DateTime.utc(2026, 10, 4, 15, 40);

List<MusicSource> sourcePreviewFixtures(SourcePreviewState state) {
  if (state == SourcePreviewState.empty || state == SourcePreviewState.error) {
    return const <MusicSource>[];
  }
  final List<MusicSource> sources = <MusicSource>[
    MusicSource(
      id: 'preview-source-local',
      kind: 'local',
      name: '潮汐唱片',
      trackCount: 128,
      syncStatus: '已同步（新增 4 / 更新 2 / 移除 0）',
      lastSyncedAt: _localSyncedAt,
      localFolderPath: '/music/archive',
    ),
    MusicSource(
      id: 'preview-source-webdav',
      kind: 'webdav',
      name: '海岸线备份',
      trackCount: 63,
      syncStatus: '已同步（新增 0 / 更新 1 / 移除 0）',
      lastSyncedAt: _webDavSyncedAt,
      webdavUrl: 'https://dav.example.test/music',
      webdavUsername: 'listener',
    ),
    MusicSource(
      id: 'preview-source-quark',
      kind: 'quark',
      name: '远航云盘',
      trackCount: 37,
      syncStatus: state == SourcePreviewState.relogin
          ? '登录状态已失效，请重新登录'
          : '已同步（新增 7 / 更新 0 / 移除 0）',
      lastSyncedAt: _quarkSyncedAt,
      quarkAccountName: '听屿测试',
    ),
  ];
  if (state == SourcePreviewState.relogin) {
    final MusicSource failed = sources.removeLast();
    sources.insert(0, failed);
  }
  return sources;
}

Map<String, SourceSyncState> sourcePreviewSyncStates(SourcePreviewState state) {
  return switch (state) {
    SourcePreviewState.syncing => <String, SourceSyncState>{
      'preview-source-webdav': const SourceSyncState(
        running: true,
        message: '海岸线备份 · 第 184 项',
        done: 184,
        total: 320,
      ),
    },
    SourcePreviewState.relogin => <String, SourceSyncState>{
      'preview-source-quark': const SourceSyncState(
        message: '登录状态已失效，请重新登录',
        error: '夸克会话已过期，需要重新登录后继续同步。',
      ),
    },
    _ => const <String, SourceSyncState>{},
  };
}

/// Fixed sync state for screenshots and widget tests. Mutating methods are not
/// exercised by the visual fixture.
class SourceSyncPreviewController extends SourceSyncController {
  SourceSyncPreviewController(this.fixedState);

  final Map<String, SourceSyncState> fixedState;

  @override
  Map<String, SourceSyncState> build() => fixedState;
}
