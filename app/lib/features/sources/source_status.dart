import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/db/database.dart';
import '../../design/components/feedback.dart';
import '../../design/components/source_card.dart' show TySourceStatusTone;
import '../../design/format.dart';
import 'source_sync.dart';

/// 失败后可行的恢复动作（`docs/UX_REDESIGN.md` §4.5：错误必须有恢复路径）。
enum SourceRemediation {
  /// 配置或数据正常，无需恢复。
  none,

  /// 重新同步（扫描失败、网络抖动）。
  retry,

  /// 夸克凭据失效 → 重新登录。
  relogin,

  /// 库内配置不完整（缺目录 / 地址）→ 删除后重新添加。
  reconfigure,
}

/// 来源在 UI 上的完整状态（列表卡片与详情页共用同一份翻译）。
///
/// 状态机（`docs/UX_REDESIGN.md` §4.5 §5.6）：
/// 未配置 → [SourceRemediation.reconfigure]；已连接 → [TySourceStatusTone.connected]；
/// 同步中 → [busy] + [progressLabel]；失败 → [TySourceStatusTone.failed] + [remediation]。
/// 「登录中」由登录页自身呈现（`QuarkQrLoginPage` / `QuarkWebLoginPage`）。
@immutable
class SourceStatusView {
  const SourceStatusView({
    required this.typeLabel,
    required this.typeIcon,
    required this.statusLabel,
    required this.tone,
    required this.primaryLabel,
    required this.primaryIcon,
    this.detail,
    this.progressLabel,
    this.busy = false,
    this.remediation = SourceRemediation.none,
  });

  final String typeLabel;
  final IconData typeIcon;

  /// 状态行文案。
  final String statusLabel;
  final TySourceStatusTone tone;

  /// 第二行元数据：目录 / 地址 / 失败原因。
  final String? detail;

  /// 进度文案，例：`已扫描 128 / 540`（同时是读屏 `liveRegion` 的值）。
  final String? progressLabel;

  /// 主操作（同步 / 重试 / 同步中）。
  final String primaryLabel;
  final IconData primaryIcon;
  final bool busy;

  final SourceRemediation remediation;
}

/// 把 provider 里的来源 + 同步态翻译成展示状态（纯函数，不读 provider）。
SourceStatusView describeSourceStatus(
  MusicSource source,
  SourceSyncState sync,
) {
  final (String typeLabel, IconData typeIcon) = _typeOf(source);
  if (sync.running) {
    return SourceStatusView(
      typeLabel: typeLabel,
      typeIcon: typeIcon,
      statusLabel: sync.message.isEmpty ? '正在同步…' : sync.message,
      // 进行中用中性点：不伪装成功，也不当成失败；进度条承载全部信息。
      tone: TySourceStatusTone.idle,
      detail: _detailOf(source),
      progressLabel: sync.total > 0
          ? '已扫描 ${sync.done} / ${sync.total}'
          : '已扫描 ${sync.done}',
      primaryLabel: '同步中',
      primaryIcon: Icons.sync,
      busy: true,
    );
  }
  final String? failure =
      sync.error ??
      (isFailureStatus(source.syncStatus) ? source.syncStatus : null);
  if (failure != null) {
    return SourceStatusView(
      typeLabel: typeLabel,
      typeIcon: typeIcon,
      statusLabel: '同步失败',
      tone: TySourceStatusTone.failed,
      detail: failure,
      primaryLabel: '重试',
      primaryIcon: Icons.refresh,
      remediation: source.kind == 'quark'
          ? SourceRemediation.relogin
          : SourceRemediation.retry,
    );
  }
  if (!isConfigured(source)) {
    return SourceStatusView(
      typeLabel: typeLabel,
      typeIcon: typeIcon,
      statusLabel: '未配置 · 没有可扫描的内容',
      tone: TySourceStatusTone.warning,
      detail: '这条来源没有目录或地址，请删除后重新添加',
      primaryLabel: '删除',
      primaryIcon: Icons.delete_outline,
      remediation: SourceRemediation.reconfigure,
    );
  }
  final DateTime? syncedAt = source.lastSyncedAt;
  final String synced = syncedAt == null
      ? '尚未同步'
      : '上次同步 ${formatRelativeTime(syncedAt)}';
  return SourceStatusView(
    typeLabel: typeLabel,
    typeIcon: typeIcon,
    statusLabel: '已连接 · ${source.trackCount} 首 · $synced',
    tone: syncedAt == null && source.trackCount == 0
        ? TySourceStatusTone.idle
        : TySourceStatusTone.connected,
    detail: _detailOf(source),
    primaryLabel: '同步',
    primaryIcon: Icons.sync,
  );
}

/// 库内状态文案里这些前缀是「正常收尾」，其余一律按失败呈现（同步进度写回的状态）。
const List<String> _healthyStatusPrefixes = <String>[
  '已同步',
  '部分同步',
  '已取消',
  '登录已更新',
  '元数据补全',
  '没有需要补全',
  '尚未同步',
  '未同步',
];

bool isFailureStatus(String status) =>
    status.isNotEmpty &&
    !_healthyStatusPrefixes.any(
      (String prefix) => status.startsWith(prefix),
    );

/// 配置完整性：读不到目录 / 地址的来源无法扫描，必须显式说明而不是显示「0 首」。
bool isConfigured(MusicSource source) => switch (source.kind) {
  'webdav' => (source.webdavUrl ?? '').isNotEmpty,
  // 夸克凭据在系统安全存储里，库内配置（账号名可以为空）判断不了；凭据失效由
  // 同步失败态呈现（认证失败会写回状态文案）。
  'quark' => true,
  _ =>
    (source.localFolderPath ?? '').isNotEmpty ||
        (source.localBookmark ?? '').isNotEmpty,
};

/// 类型徽标：SAF / 安全书签目录与普通目录要能一眼分开。
(String, IconData) _typeOf(MusicSource source) {
  switch (source.kind) {
    case 'webdav':
      return ('WebDAV', Icons.cloud_outlined);
    case 'quark':
      return ('夸克网盘', Icons.cloud_queue);
  }
  final String token = source.localBookmark ?? '';
  if (token.startsWith('content://')) {
    return ('本地目录 · SAF', Icons.folder_outlined);
  }
  if (token.isNotEmpty) {
    return ('本地目录 · 书签', Icons.folder_outlined);
  }
  return ('本地目录', Icons.folder_outlined);
}

String? _detailOf(MusicSource source) {
  switch (source.kind) {
    case 'webdav':
      final String url = source.webdavUrl ?? '';
      if (url.isEmpty) {
        return null;
      }
      final String user = source.webdavUsername ?? '';
      return user.isEmpty ? url : '$url（$user）';
    case 'quark':
      final String account = source.quarkAccountName ?? '';
      return account.isEmpty ? null : '账号：$account';
  }
  final String path = source.localFolderPath ?? '';
  if (path.isNotEmpty) {
    return path;
  }
  return (source.localBookmark ?? '').isEmpty ? null : '系统授权的音乐目录';
}

/// 复制诊断信息：出问题时把可粘贴的一段话带走（错误详情展示走 `TyErrorView`）。
void copySourceDiagnostics(
  BuildContext context,
  MusicSource source,
  SourceSyncState sync,
) {
  Clipboard.setData(ClipboardData(text: sourceDiagnostics(source, sync)));
  TySnack.show(context, '诊断信息已复制');
}

/// 复制诊断信息用的结构化文本（诊断入口的唯一实现处）。
String sourceDiagnostics(MusicSource source, SourceSyncState sync) {
  return <String>[
    '来源：${source.name}',
    '类型：${source.kind}',
    '状态：${source.syncStatus.isEmpty ? '尚未同步' : source.syncStatus}',
    '曲目数：${source.trackCount}',
    '上次同步：${source.lastSyncedAt?.toLocal().toIso8601String() ?? '从未'}',
    if (sync.error != null) '本次错误：${sync.error}',
  ].join('\n');
}
