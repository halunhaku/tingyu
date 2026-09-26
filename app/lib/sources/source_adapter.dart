import '../data/models/scanned_track.dart';
import '../playback/playback_item.dart';

/// 一次来源扫描的结果。
class SourceScanResult {
  const SourceScanResult({
    required this.tracks,
    this.skipped = 0,
    this.cancelled = false,
    this.truncated = false,
    this.truncationReason,
  });

  final List<ScannedTrack> tracks;

  /// 因权限/网络/解析问题被跳过的条目数（不阻断整体扫描）。
  final int skipped;

  /// 调用方主动中止，结果只包含取消前已经发现的曲目。
  final bool cancelled;

  /// 本次结果**没有覆盖来源的全部内容**（达到数量上限、目录层级超限、服务端响应
  /// 无法解析等），因此不能据此判断"未出现的曲目已被删除"。
  final bool truncated;

  /// [truncated] 的具体原因，用于给用户一句能对上号的说明。
  final String? truncationReason;

  /// 只有完整快照才能证明“未出现的旧曲目确实已被删除”。
  bool get isAuthoritative => !cancelled && !truncated && skipped == 0;
}

/// 一个可扫描、可播放的来源（本地目录 / WebDAV / Quark）。
///
/// 契约：
/// - [scan] 只产出曲目事实（[ScannedTrack]），不写库；入库由 `TrackRepository.mergeScan` 负责。
/// - [open] 把库里的一条 `filePathOrUrl` 解析为可直接交给播放引擎的条目（含鉴权头）。
/// - 两个方法都不允许触碰 UI 或播放器实现，只依赖 `data/` 与 `playback/` 的模型。
abstract interface class SourceAdapter {
  /// 对应 `music_sources.id`。
  String get sourceId;

  /// 扫描整个来源。实现方需自行限流，并在耗时循环里检查 [isCancelled]。
  Future<SourceScanResult> scan({
    void Function(int done, String name)? onProgress,
    bool Function()? isCancelled,
  });

  /// 解析可播放条目；凭据失效等错误应抛来源专属异常。
  Future<PlaybackItem> open(String filePathOrUrl);
}
