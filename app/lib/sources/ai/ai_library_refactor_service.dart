import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/db/database.dart';
import '../../data/enrichment_service.dart';
import '../../data/repositories/track_repository.dart';
import '../scraper/smart_title_parser.dart';
import 'ai_client.dart';
import 'ai_metadata_parser.dart';

/// 整库 AI 清洗进度状态。
class RefactorProgress {
  const RefactorProgress({
    required this.processed,
    required this.total,
    required this.updated,
    this.currentTrackTitle,
    this.isCompleted = false,
  });

  final int processed;
  final int total;
  final int updated;
  final String? currentTrackTitle;
  final bool isCompleted;

  double get ratio => total > 0 ? (processed / total).clamp(0.0, 1.0) : 1.0;
}

/// AI 辅助曲库元数据全库清洗与纠偏服务。
class AILibraryRefactorService {
  AILibraryRefactorService({
    required this.tracks,
    required this.client,
    this.enrichmentService,
    this.batchSize = 25,
    this.throttle = const Duration(milliseconds: 300),
  });

  final TrackRepository tracks;
  final AIClient client;
  final LibraryEnrichmentService? enrichmentService;
  final int batchSize;
  final Duration throttle;

  /// 分批执行全库识别与写回。
  Future<RefactorProgress> refactorAll({
    void Function(RefactorProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final List<Track> all = await tracks.all();
    if (all.isEmpty) {
      const RefactorProgress emptyDone = RefactorProgress(
        processed: 0,
        total: 0,
        updated: 0,
        isCompleted: true,
      );
      onProgress?.call(emptyDone);
      return emptyDone;
    }

    int processed = 0;
    int updated = 0;

    for (int i = 0; i < all.length; i += batchSize) {
      if (isCancelled?.call() ?? false) {
        break;
      }
      final int end = (i + batchSize < all.length) ? i + batchSize : all.length;
      final List<Track> batch = all.sublist(i, end);

      onProgress?.call(
        RefactorProgress(
          processed: processed,
          total: all.length,
          updated: updated,
          currentTrackTitle: batch.first.title,
        ),
      );

      final List<AIInputItem> items = batch
          .map(
            (Track t) => AIInputItem(
              id: t.id,
              filename: '${t.title} ${t.filePathOrUrl}',
            ),
          )
          .toList(growable: false);

      Map<String, ParsedSongInfo> recognized = const <String, ParsedSongInfo>{};
      try {
        recognized = await AIMetadataParser.parseBatch(
          client: client,
          items: items,
        );
      } on Object catch (error) {
        debugPrint('[ai-refactor] 批次识别失败 (${batch.length} 首): $error');
      }

      for (final Track track in batch) {
        final ParsedSongInfo? info = recognized[track.id];
        if (info != null &&
            (info.title.isNotEmpty ||
                info.artist.isNotEmpty ||
                info.album.isNotEmpty)) {
          final String newTitle = info.title.trim().isNotEmpty
              ? info.title.trim()
              : track.title;
          final String newArtist = info.artist.trim().isNotEmpty
              ? info.artist.trim()
              : track.artist;
          final String newAlbum = info.album.trim().isNotEmpty
              ? info.album.trim()
              : track.album;

          if (newTitle != track.title ||
              newArtist != track.artist ||
              newAlbum != track.album) {
            await tracks.applyEnrichment(
              id: track.id,
              title: newTitle,
              artist: newArtist,
              album: newAlbum,
            );
            updated++;

            if (enrichmentService != null) {
              final Track updatedTrack = track.copyWith(
                title: newTitle,
                artist: newArtist,
                album: newAlbum,
              );
              unawaited(enrichmentService!.enrichTrack(updatedTrack));
            }
          }
        }
      }

      processed += batch.length;
      onProgress?.call(
        RefactorProgress(
          processed: processed,
          total: all.length,
          updated: updated,
        ),
      );

      if (processed < all.length && throttle > Duration.zero) {
        await Future<void>.delayed(throttle);
      }
    }

    final RefactorProgress finalState = RefactorProgress(
      processed: processed,
      total: all.length,
      updated: updated,
      isCompleted: true,
    );
    onProgress?.call(finalState);
    return finalState;
  }
}
