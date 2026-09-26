import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/playback_controller.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/track_resolver.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/playback/playback_engine.dart';
import 'package:tingyu/playback/playback_item.dart';
import 'package:tingyu/playback/playback_snapshot.dart';
import 'package:tingyu/playback/tingyu_audio_handler.dart';

import 'dart:io';

import 'package:tingyu/sources/local/folder_permission.dart';

/// 取直链失败（离线时的夸克）发生在引擎之前，没有引擎事件可以依赖：
/// 以前它只进 logcat，界面"点了没反应"。现在控制器把同样的失败写进快照，
/// 由 `PlaybackFailureListener` 弹提示 —— 这个文件守住这条行为。
final class _IdleEngine extends PlaybackEngineBase {
  @override
  String get name => 'idle';

  @override
  List<PlaybackItem> get items => const <PlaybackItem>[];

  @override
  PlaybackItem? get currentItem => null;

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

  /// 模拟真实引擎照常推送进度事件（`emit` 为 protected）。
  void push(PlaybackSnapshot snapshot) => emit(snapshot);

  @override
  Future<void> dispose() async => closeSnapshotStream();
}

/// 任何曲目都解析不出来，错误文案与夸克离线时一致。
final class _UnreachableResolver extends TrackResolver {
  _UnreachableResolver(super.ref);

  @override
  Future<PlaybackItem> resolve(Track track) async => throw const _Offline();
}

final class _Offline implements Exception {
  const _Offline();

  @override
  String toString() => '夸克网络连接异常: unknown';
}

final class _NetworkErrorResolver extends TrackResolver {
  _NetworkErrorResolver(super.ref);

  @override
  Future<PlaybackItem> resolve(Track track) async =>
      throw const SocketException('OS Error: Network is unreachable');
}

final class _PermissionLostResolver extends TrackResolver {
  _PermissionLostResolver(super.ref);

  @override
  Future<PlaybackItem> resolve(Track track) async =>
      throw const FolderPermissionLostException();
}

Track _track(String id, String title) => Track(
  id: id,
  sourceId: 'quark-1',
  title: title,
  artist: '周杰伦',
  album: 'Jay',
  duration: 240,
  fileFormat: 'mp3',
  filePathOrUrl: 'quark://$id',
  fileSize: 0,
  isFavorite: false,
  dateAdded: DateTime.utc(2026, 9, 1),
  playCount: 0,
);

ProviderContainer _container() => _containerAndEngine(_UnreachableResolver.new).$1;

/// 同时拿到容器与其中的引擎：验证"引擎照常 tick 时失败仍在"需要手动推快照。
(ProviderContainer, _IdleEngine) _containerAndEngine(
  TrackResolver Function(Ref ref) resolver,
) {
  final _IdleEngine engine = _IdleEngine();
  final ProviderContainer container = ProviderContainer(
    overrides: [
      audioHandlerProvider.overrideWithValue(TingyuAudioHandler(engine)),
      trackResolverProvider.overrideWith((Ref ref) => resolver(ref)),
    ],
  );
  addTearDown(container.dispose);
  return (container, engine);
}

void main() {
  test('整队列都取不到直链时，快照里留下带曲名的失败（而不是静默）', () async {
    final ProviderContainer container = _container();

    await container.read(playbackProvider.notifier).playTracks(<Track>[
      _track('t1', '伊斯坦堡'),
    ]);

    final PlaybackFailure? failure = container.read(playbackProvider).failure;
    expect(failure, isNotNull);
    expect(failure!.title, '伊斯坦堡');
    expect(failure.message, contains('夸克网络连接异常'));
  });

  test('再次失败是新实例：提示才会重新弹', () async {
    final ProviderContainer container = _container();
    final PlaybackController controller = container.read(
      playbackProvider.notifier,
    );

    await controller.playTracks(<Track>[_track('t1', '伊斯坦堡')]);
    final PlaybackFailure first = container.read(playbackProvider).failure!;

    await controller.playTracks(<Track>[_track('t2', '晴天')]);
    final PlaybackFailure second = container.read(playbackProvider).failure!;

    expect(identical(first, second), isFalse);
    expect(second.title, '晴天');
  });

  test('整队列都解析不出来时也只在点击那一首上报一次，不逐首刷屏', () async {
    final ProviderContainer container = _container();
    final List<PlaybackFailure> failures = <PlaybackFailure>[];
    container.listen<PlaybackSnapshot>(playbackProvider, (
      PlaybackSnapshot? previous,
      PlaybackSnapshot next,
    ) {
      final PlaybackFailure? failure = next.failure;
      if (failure != null) {
        failures.add(failure);
      }
    }, fireImmediately: true);

    await container.read(playbackProvider.notifier).playTracks(<Track>[
      _track('t1', '伊斯坦布尔'),
      _track('t2', '晴天'),
      _track('t3', '可爱女人'),
    ]);

    expect(failures, hasLength(1));
    expect(failures.single.title, '伊斯坦布尔');
  });

  test('整队列都解析不出来时，不会把失败写成"正在播放"', () async {
    final ProviderContainer container = _container();

    await container.read(playbackProvider.notifier).playTracks(<Track>[
      _track('t1', '伊斯坦堡'),
      _track('t2', '晴天'),
    ]);

    final PlaybackSnapshot snapshot = container.read(playbackProvider);
    expect(snapshot.playing, isFalse);
    expect(snapshot.failure?.title, '伊斯坦堡');
  });

  test('解析遭遇网络异常时，快照文案被归纳为中文网络提示', () async {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        audioHandlerProvider.overrideWithValue(
          TingyuAudioHandler(_IdleEngine()),
        ),
        trackResolverProvider.overrideWith(
          (Ref ref) => _NetworkErrorResolver(ref),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(playbackProvider.notifier).playTracks(<Track>[
      _track('t1', '晴天'),
    ]);

    final PlaybackFailure? failure = container.read(playbackProvider).failure;
    expect(failure, isNotNull);
    expect(failure!.title, '晴天');
    expect(failure.message, '无法播放：网络连接失败，请检查网络设置');
  });

  test('解析遭遇本地目录授权失效时，快照文案保留明确指引', () async {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        audioHandlerProvider.overrideWithValue(
          TingyuAudioHandler(_IdleEngine()),
        ),
        trackResolverProvider.overrideWith(
          (Ref ref) => _PermissionLostResolver(ref),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(playbackProvider.notifier).playTracks(<Track>[
      _track('t1', '晴天'),
    ]);

    final PlaybackFailure? failure = container.read(playbackProvider).failure;
    expect(failure, isNotNull);
    expect(failure!.title, '晴天');
    expect(failure.message, '无法播放：本地目录授权已失效，请重新选择音乐文件夹');
  });

  test('引擎随后推的快照不会把解析失败擦掉（旧会话仍在 tick）', () async {
    final (ProviderContainer container, _IdleEngine engine) =
        _containerAndEngine(_UnreachableResolver.new);

    await container.read(playbackProvider.notifier).playTracks(<Track>[
      _track('t1', '伊斯坦堡'),
    ]);
    expect(container.read(playbackProvider).failure?.title, '伊斯坦堡');
    // 等控制器的订阅真的挂上引擎的快照流（`snapshots` 是 async* 包装的广播流，
    // 广播事件不会为还没订阅的监听者补发）。
    await pumpEventQueue();

    // 真实引擎不会因为"解析失败"就停下：旧会话仍在 playing=true 地推事件。
    // 引擎快照里的 failure 是 null，控制器的失败必须自己留着。
    engine.push(
      const PlaybackSnapshot(
        processing: PlaybackProcessing.ready,
        playing: true,
        position: Duration(milliseconds: 60),
        duration: Duration(seconds: 240),
        buffered: Duration(milliseconds: 60),
        index: 0,
        rate: 1,
        volume: 1,
      ),
    );
    // 引擎的 snapshots 是 async* 包装的广播流，事件要等事件循环真的转起来才到。
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      container.read(playbackProvider).failure?.title,
      '伊斯坦堡',
      reason: '引擎的 failure 为 null，不能把控制器侧记下的失败覆盖掉',
    );
    expect(container.read(playbackProvider).failure?.message, contains('夸克网络连接异常'));
  });
}
