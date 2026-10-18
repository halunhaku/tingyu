// Visual fixture only. This entrypoint is not a playback smoke test and must never
// be used as the production app main; all playback commands below only change memory.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:go_router/go_router.dart';

import 'package:tingyu/app/playback_controller.dart';
import 'package:tingyu/app/preferences.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/data/cover_store.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/enrichment_service.dart';
import 'package:tingyu/data/repositories/track_repository.dart';
import 'package:tingyu/data/settings_store.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/design/tokens/voice_archive.dart';
import 'package:tingyu/features/player/now_playing_page.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';
import 'package:tingyu/sources/scraper/metadata_enricher.dart';
import 'package:tingyu/sources/scraper/metadata_provider.dart';

final DateTime _fixtureDate = DateTime.utc(2026, 10, 18);
const String _fixtureCoverName = 'voice-archive-cover.png';

final List<Track> _fixtureTracks = <Track>[
  _track(
    id: 'voice-archive-1',
    title: '海风经过',
    artist: '林间回声',
    album: '潮汐手记',
    duration: const Duration(minutes: 4, seconds: 12),
    fileName: 'voice-archive-1.mp3',
    cover: true,
  ),
  _track(
    id: 'voice-archive-2',
    title: '直到海岸线的最后一束光都熄灭',
    artist: '林间回声',
    album: '潮汐手记',
    duration: const Duration(minutes: 5, seconds: 8),
    fileName: 'voice-archive-2.mp3',
    cover: true,
  ),
  _track(
    id: 'voice-archive-3',
    title: 'Between the Islands and the Quiet Sea',
    artist: 'The Quiet Sea',
    album: 'Tidal Notes',
    duration: const Duration(minutes: 3, seconds: 46),
    fileName: 'voice-archive-3.mp3',
    cover: true,
  ),
  _track(
    id: 'voice-archive-4',
    title: '无封面的练习',
    artist: '听屿试录',
    album: '练习录音',
    duration: const Duration(minutes: 2, seconds: 51),
    fileName: 'voice-archive-4.mp3',
  ),
];

Track _track({
  required String id,
  required String title,
  required String artist,
  required String album,
  required Duration duration,
  required String fileName,
  bool cover = false,
}) => Track(
  id: id,
  sourceId: 'voice-archive-preview',
  title: title,
  artist: artist,
  album: album,
  duration: duration.inMilliseconds / Duration.millisecondsPerSecond,
  fileFormat: 'mp3',
  filePathOrUrl: '/voice-archive-preview/$fileName',
  fileSize: 0,
  coverArtPath: cover ? _fixtureCoverName : null,
  lyrics: null,
  isFavorite: false,
  dateAdded: _fixtureDate,
  playCount: 0,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final Map<String, String> environment = Platform.environment;
  runApp(_VoiceArchivePreviewApp(environment: environment));
}

class _VoiceArchivePreviewApp extends StatelessWidget {
  _VoiceArchivePreviewApp({required this.environment})
    : router = _previewRouter(environment['TINGYU_DEBUG_ROUTE']);

  final Map<String, String> environment;
  final GoRouter router;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = environment['TINGYU_DEBUG_THEME'] == 'dark'
        ? Brightness.dark
        : Brightness.light;
    final String coverPath = _coverPath(environment);
    final List<Track> tracks = _tracksForState(
      environment['TINGYU_PREVIEW_STATE'],
    );

    return ProviderScope(
      overrides: <Override>[
        audioHandlerProvider.overrideWithValue(
          TingyuAudioHandler(_PreviewSilentEngine()),
        ),
        playbackProvider.overrideWith(PreviewPlaybackController.new),
        autoLibraryEnrichmentProvider.overrideWith((Ref ref) async {}),
        allTracksProvider.overrideWith(
          (Ref ref) => Stream<List<Track>>.value(tracks),
        ),
        for (final Track track in _fixtureTracks)
          trackByIdProvider(track.id)
              .overrideWith((Ref ref) => Stream<Track?>.value(track)),
        sourcesProvider.overrideWith(
          (Ref ref) => Stream<List<MusicSource>>.value(const <MusicSource>[]),
        ),
        coverFileProvider.overrideWith((Ref ref, String name) async {
          if (name != _fixtureCoverName || coverPath.isEmpty) {
            return null;
          }
          final File file = File(coverPath);
          return await file.exists() ? file : null;
        }),
        trackRepositoryProvider.overrideWithValue(_PreviewTrackRepository()),
        enrichmentServiceProvider.overrideWithValue(
          _NoNetworkEnrichmentService(),
        ),
        preferencesProvider.overrideWith(PreviewPreferencesNotifier.new),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: TyTheme.build(
          brightness: brightness,
          colors: VoiceArchiveColors.of(brightness),
        ),
        routerConfig: router,
        builder: (BuildContext context, Widget? child) {
          final MediaQueryData media = MediaQuery.of(context);
          final String? scaleValue = environment['TINGYU_PREVIEW_SCALE'];
          final double scale = scaleValue == '2' ? 2 : 1;
          final Size size = media.size;
          final FormFactor factor = FormFactor.ofWidth(size.width);
          return MediaQuery(
            data: media.copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: ProviderScope(
              overrides: <Override>[
                formFactorProvider.overrideWithValue(factor),
              ],
              child: TyLayoutScope.forSize(
                size,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _coverPath(Map<String, String> environment) {
  final String? configured = environment['TINGYU_PREVIEW_COVER'];
  if (configured != null && configured.isNotEmpty) {
    return File(configured).absolute.path;
  }
  return File('tool/fixtures/voice-archive-cover.png').absolute.path;
}

List<Track> _tracksForState(String? state) => state == 'empty'
    ? const <Track>[]
    : List<Track>.unmodifiable(_fixtureTracks);

GoRouter _previewRouter(String? configuredRoute) {
  final String initialLocation = switch (configuredRoute) {
    '/stage?tab=queue' => '/stage?tab=queue',
    '/stage?tab=lyrics' => '/stage?tab=lyrics',
    _ => '/stage',
  };
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(path: '/stage', builder: (_, _) => const NowPlayingPage()),
      GoRoute(
        path: '/library/songs',
        builder: (_, _) => const _PreviewExitPage(),
      ),
    ],
    errorBuilder: (_, GoRouterState state) =>
        _PreviewExitPage(message: '预览入口不处理 ${state.uri.path}；返回播放舞台即可。'),
  );
}

class _PreviewExitPage extends StatelessWidget {
  const _PreviewExitPage({this.message = '已离开听屿声档视觉预览。'});

  final String message;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(message)));
}

class PreviewPlaybackController extends PlaybackController {
  List<Track> get _tracks =>
      _tracksForState(Platform.environment['TINGYU_PREVIEW_STATE']);

  int get _initialIndex =>
      Platform.environment['TINGYU_PREVIEW_STATE'] == 'long' ? 1 : 0;

  List<PlaybackItem> get _previewItems => _tracks
      .map(
        (Track track) => PlaybackItem.fromUri(
          Uri.file(track.filePathOrUrl),
          title: track.title,
          artist: track.artist,
          album: track.album,
          duration: Duration(milliseconds: (track.duration * 1000).round()),
        ),
      )
      .toList(growable: false);

  @override
  List<Track> get sourceQueue => _tracks;

  @override
  List<String> get trackIds => _tracks.map((Track track) => track.id).toList();

  @override
  PlaybackItem? get currentItem {
    final List<PlaybackItem> currentItems = _previewItems;
    return state.index >= 0 && state.index < currentItems.length
        ? currentItems[state.index]
        : null;
  }

  @override
  List<PlaybackItem> get items => _previewItems;

  @override
  PlaybackSnapshot build() {
    final String? previewState = Platform.environment['TINGYU_PREVIEW_STATE'];
    if (previewState == 'empty') {
      return PlaybackSnapshot.initial.copyWith(index: -1);
    }
    final int index = _initialIndex;
    final Duration duration = previewState == 'unknown'
        ? Duration.zero
        : Duration(milliseconds: (_tracks[index].duration * 1000).round());
    final bool failed = previewState == 'failure';
    return PlaybackSnapshot(
      processing: PlaybackProcessing.ready,
      playing: !failed,
      position: const Duration(seconds: 84),
      duration: duration,
      buffered: duration,
      index: index,
      rate: 1,
      volume: 0.72,
      playOrder: PlayOrder.sequential,
      repeatMode: PlaybackRepeatMode.all,
      failure: failed
          ? PlaybackFailure(
              message: '视觉预览中的模拟播放失败。',
              title: _tracks[index].title,
            )
          : null,
    );
  }

  @override
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _tracks.length) {
      return;
    }
    final Track track = _tracks[index];
    state = state.copyWith(
      index: index,
      playing: true,
      position: Duration.zero,
      duration: Duration(milliseconds: (track.duration * 1000).round()),
      processing: PlaybackProcessing.ready,
      clearFailure: true,
    );
  }

  @override
  Future<void> togglePlayPause() async {
    if (state.index < 0) {
      return;
    }
    state = state.copyWith(playing: !state.playing);
  }

  @override
  Future<void> seek(Duration position) async {
    if (state.duration > Duration.zero) {
      final Duration bounded = position < Duration.zero
          ? Duration.zero
          : position > state.duration
          ? state.duration
          : position;
      state = state.copyWith(position: bounded);
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume.clamp(0, 1).toDouble());
  }

  @override
  void toggleShuffle() {
    state = state.copyWith(
      playOrder: state.playOrder == PlayOrder.sequential
          ? PlayOrder.shuffle
          : PlayOrder.sequential,
    );
  }

  @override
  void cycleRepeatMode() {
    state = state.copyWith(
      repeatMode: switch (state.repeatMode) {
        PlaybackRepeatMode.all => PlaybackRepeatMode.one,
        PlaybackRepeatMode.one => PlaybackRepeatMode.off,
        PlaybackRepeatMode.off => PlaybackRepeatMode.all,
      },
    );
  }

  @override
  Future<void> next() async {
    if (_tracks.isNotEmpty) {
      await playAt((state.index + 1) % _tracks.length);
    }
  }

  @override
  Future<void> previous() async {
    if (_tracks.isNotEmpty) {
      await playAt((state.index - 1 + _tracks.length) % _tracks.length);
    }
  }
}

final class _PreviewSilentEngine extends PlaybackEngineBase {
  @override
  String get name => 'voice-archive-visual-fixture';

  @override
  PlaybackItem? get currentItem => null;

  @override
  List<PlaybackItem> get items => const <PlaybackItem>[];

  @override
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0}) async {}

  @override
  Future<void> addToQueue(PlaybackItem item) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> dispose() async => closeSnapshotStream();
}

class PreviewPreferencesNotifier extends PreferencesNotifier {
  @override
  Future<PreferencesState> build() async =>
      const PreferencesState(preferences: AppPreferences.defaults);
}

class _PreviewTrackRepository implements TrackRepository {
  @override
  Future<void> setFavorite(String id, {required bool value}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoNetworkEnrichmentService extends LibraryEnrichmentService {
  _NoNetworkEnrichmentService()
    : super(
        tracks: _PreviewTrackRepository(),
        covers: CoverStore(rootDirectory: () async => Directory.systemTemp),
        enricher: MetadataEnricher(
          searcher: _UnusedMetadataSearcher(),
          lyricsProvider: _UnusedLyricsProvider(),
          downloader: ImageDownloader(),
        ),
      );

  @override
  Future<EnrichmentOutcome> enrichTrack(Track track) async =>
      EnrichmentOutcome.skipped;
}

class _UnusedMetadataSearcher implements MetadataSearcher {
  const _UnusedMetadataSearcher();

  @override
  String get name => 'disabled';

  @override
  Future<MetadataCandidate?> search(String title, {String artist = ''}) async =>
      null;
}

class _UnusedLyricsProvider implements LyricsProvider {
  const _UnusedLyricsProvider();

  @override
  String get name => 'disabled';

  @override
  Future<String?> fetchLyrics(
    LyricsQuery query, {
    MetadataCandidate? candidate,
  }) async => null;
}
