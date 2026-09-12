import '../data/models/scanned_track.dart';
import '../playback/playback_item.dart';

/// 一次来源扫描的结果。
class SourceScanResult {
  const SourceScanResult({
    required this.tracks,
    this.skipped = 0,
    this.cancelled = false,
  });

  final List<ScannedTrack> tracks;

  /// 因权限/网络/解析问题被跳过的条目数（不阻断整体扫描）。
  final int skipped;

  final bool cancelled;
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
