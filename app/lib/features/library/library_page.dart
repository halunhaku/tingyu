import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../shared/current_track.dart';
import '../shared/empty_state.dart';
import '../shared/track_row.dart';

/// 是否为"手机布局"（窄屏外壳 + 底部 Tab）。
///
/// 用 `Theme.of(context).platform` 而不是 `dart:io Platform`：前者在测试里可以用
/// `debugDefaultTargetPlatformOverride` 覆盖，后者只看宿主系统 —— 在 Linux 上跑
/// widget 测试时，手机布局的代码路径根本无法验证。
bool _isPhoneLayout(BuildContext context) {
  final TargetPlatform platform = Theme.of(context).platform;
  return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
}

/// 曲库页：整库、最近添加、收藏、搜索结果共用一套列表。
///
/// 与旧版一致：搜索框在侧栏，命中结果回到曲库列表展示。
/// 搜索结果被仓库层按上限硬截断时，标题下方给一行"仅显示前 N 首"的提示。
class LibraryPage extends ConsumerWidget {
  const LibraryPage({
    super.key,
    this.recentOnly = false,
    this.favoritesOnly = false,
  });

  final bool recentOnly;

  final bool favoritesOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 原生 macOS 在曲库出现时后台补全所有缺失元数据的歌曲。
    ref.watch(autoLibraryEnrichmentProvider);
    final String query = ref.watch(searchQueryProvider);
    final AsyncValue<List<Track>> tracks;
    final String title;
    if (favoritesOnly) {
      tracks = ref.watch(favoritesProvider);
      title = '收藏';
    } else if (recentOnly) {
      tracks = ref.watch(recentlyAddedProvider);
      title = '最近添加';
    } else {
      tracks = ref.watch(visibleTracksProvider);
      title = query.trim().isEmpty ? '曲库' : '搜索“${query.trim()}”';
    }
    // 真的在搜索时才订阅截断信号：仓库层把命中硬截到上限，不提示就像库里只有这么多。
    final SearchResults? searchResults =
        favoritesOnly || recentOnly || query.trim().isEmpty
        ? null
        : ref.watch(searchResultsProvider).value;
    final int? truncatedAt = (searchResults != null && searchResults.truncated)
        ? searchResults.limit
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 桌面侧栏有搜索框；手机没有侧栏，曲库页自己给一个，否则"搜索"这个功能
        // 在移动端根本没有入口（只能靠翻列表）。
        if (_isPhoneLayout(context) && !favoritesOnly && !recentOnly)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: _MobileSearchField(),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              tracks.maybeWhen(
                data: (List<Track> list) => Text(
                  '${list.length} 首',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                orElse: () => const SizedBox.shrink(),
              ),
              // 桌面侧栏左下角已有设置；只有移动端没有侧栏，才在标题栏放入口。
              if (_isPhoneLayout(context))
                IconButton(
                  tooltip: '设置',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => context.push('/settings'),
                ),
            ],
          ),
        ),
        if (truncatedAt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '命中超过 $truncatedAt 首，仅显示前 $truncatedAt 首',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_isPhoneLayout(context) &&
            favoritesOnly == false &&
            recentOnly == false &&
            query.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/artists'),
                    icon: const Icon(Icons.person_outline, size: 18),
                    label: const Text('艺术家'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/albums'),
                    icon: const Icon(Icons.album_outlined, size: 18),
                    label: const Text('专辑'),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: tracks.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, StackTrace stack) => EmptyState(
              icon: Icons.error_outline,
              title: '曲库读取失败',
              message: '$error',
            ),
            data: (List<Track> list) {
              if (list.isEmpty) {
                return EmptyState(
                  icon: Icons.library_music_outlined,
                  title: favoritesOnly ? '还没有收藏' : '曲库是空的',
                  message: '在设置里添加本地目录、WebDAV 或夸克来源后点击同步',
                  action: FilledButton(
                    onPressed: () => context.go('/sources'),
                    child: const Text('添加来源'),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: list.length,
                itemBuilder: (BuildContext context, int index) {
                  final Track track = list[index];
                  return _TrackRowWithPlayback(
                    track: track,
                    index: index + 1,
                    queue: list,
                    startIndex: index,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 移动端搜索框。
///
/// 自己持有 [TextEditingController]（父级重建不该丢输入），并在别处清空搜索条件时
/// （例如桌面端不留、但弹窗/深度链接可能改）跟着同步。输入即写 `searchQueryProvider`
/// 的"即时文本"，真正查库由它内部的防抖查询负责。
class _MobileSearchField extends ConsumerStatefulWidget {
  const _MobileSearchField();

  @override
  ConsumerState<_MobileSearchField> createState() => _MobileSearchFieldState();
}

class _MobileSearchFieldState extends ConsumerState<_MobileSearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: ref.read(searchQueryProvider),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 外部清空（例如返回曲库时重置）要反映到输入框里。
    ref.listen<String>(searchQueryProvider, (String? previous, String next) {
      if (next != _controller.text) {
        _controller.text = next;
      }
    });
    final bool hasQuery = ref.watch(searchQueryProvider).isNotEmpty;

    return TextField(
      controller: _controller,
      textInputAction: TextInputAction.search,
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索歌曲、艺术家或专辑',
        prefixIcon: const Icon(Icons.search, size: 18),
        suffixIcon: hasQuery
            ? IconButton(
                tooltip: '清除搜索',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _controller.clear();
                  ref.read(searchQueryProvider.notifier).clear();
                },
              )
            : null,
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: (String value) =>
          ref.read(searchQueryProvider.notifier).set(value),
    );
  }
}

/// 把"点击播放"的队列语义固定下来：播放当前列表并从该行开始。
class _TrackRowWithPlayback extends ConsumerWidget {
  const _TrackRowWithPlayback({
    required this.track,
    required this.index,
    required this.queue,
    required this.startIndex,
  });

  final Track track;

  final int index;

  final List<Track> queue;

  final int startIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 只订阅"这一行是不是正在播放的那一首"：进度 tick 不再重建整张列表。
    final bool isPlaying = ref.watch(isCurrentTrackProvider(track.id));

    return TrackRow(
      track: track,
      index: index,
      isPlaying: isPlaying,
      onTap: () => ref
          .read(playbackProvider.notifier)
          .playTracks(queue, startIndex: startIndex),
    );
  }
}
