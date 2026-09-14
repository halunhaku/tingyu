import 'cover_store.dart';
import 'db/database.dart';
import 'repositories/track_repository.dart';
import '../sources/scraper/metadata_enricher.dart';

/// 一次富化的结果（用于同步状态与统计）。
class EnrichmentOutcome {
  const EnrichmentOutcome({
    required this.changed,
    required this.coverSaved,
    required this.lyricsSaved,
    required this.isSkipped,
  });

  static const EnrichmentOutcome skipped = EnrichmentOutcome(
    changed: false,
    coverSaved: false,
    lyricsSaved: false,
    isSkipped: true,
  );

  static final EnrichmentOutcome unchanged = const EnrichmentOutcome(
    changed: false,
    coverSaved: false,
    lyricsSaved: false,
    isSkipped: false,
  );

  final bool changed;

  final bool coverSaved;

  final bool lyricsSaved;

  final bool isSkipped;
}

/// 把 [MetadataEnricher] 的纯结果落到库里。
///
/// 分层原因：`sources/scraper` 只负责"取到数据"，写库与封面落盘属于数据层，
/// 这样抓取管道可以脱离数据库单测。
class LibraryEnrichmentService {
  LibraryEnrichmentService({
    required this.tracks,
    required this.covers,
    required this.enricher,
  });

  final TrackRepository tracks;

  final CoverStore covers;

  final MetadataEnricher enricher;

  final Map<String, Future<EnrichmentOutcome>> _inFlight =
      <String, Future<EnrichmentOutcome>>{};

  /// 同一首歌的自动补全、播放触发与手动触发共用一个在途任务，避免重复请求上游。
  Future<EnrichmentOutcome> enrichTrack(Track track) {
    final Future<EnrichmentOutcome>? existing = _inFlight[track.id];
    if (existing != null) {
      return existing;
    }
    final Future<EnrichmentOutcome> future = _enrichTrack(track);
    _inFlight[track.id] = future;
    return future.whenComplete(() {
      if (identical(_inFlight[track.id], future)) {
        _inFlight.remove(track.id);
      }
    });
  }

  Future<EnrichmentOutcome> _enrichTrack(Track track) async {
    final EnrichmentResult result = await enricher.enrich(
      EnrichmentInput(
        title: track.title,
        artist: track.artist,
        album: track.album,
        lyrics: track.lyrics,
        hasCover: track.coverArtPath != null || track.coverArtUrl != null,
        duration: Duration(milliseconds: (track.duration * 1000).round()),
      ),
    );

    if (result.isSkipped || !result.hasChanges) {
      return result.isSkipped
          ? EnrichmentOutcome.skipped
          : EnrichmentOutcome.unchanged;
    }

    String? coverArtPath;
    if (result.coverBytes != null) {
      coverArtPath = await covers.save(track.id, result.coverBytes!);
    }

    await tracks.applyEnrichment(
      id: track.id,
      title: result.title,
      artist: result.artist,
      album: result.album,
      lyrics: result.lyrics,
      coverArtPath: coverArtPath,
      coverArtUrl: result.coverUrl,
    );

    return EnrichmentOutcome(
      changed: true,
      coverSaved: coverArtPath != null,
      lyricsSaved: result.lyrics != null,
      isSkipped: false,
    );
  }
}
