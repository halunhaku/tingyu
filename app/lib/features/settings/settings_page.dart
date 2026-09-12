import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../data/models/library_summaries.dart';
import '../../data/db/database.dart';
import '../sources/source_sync.dart';

/// 设置页：库统计、数据位置、播放引擎信息，以及来源管理与批量维护入口。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Track>> tracks = ref.watch(allTracksProvider);
    final AsyncValue<List<MusicSource>> sources = ref.watch(sourcesProvider);
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);
    final AsyncValue<List<AlbumSummary>> albums = ref.watch(albumsProvider);
    final AsyncValue<List<ArtistSummary>> artists = ref.watch(artistsProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: <Widget>[
        Text('设置', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        _Section(
          title: '曲库',
          children: <Widget>[
            _InfoRow(label: '曲目', value: '${tracks.value?.length ?? 0}'),
            _InfoRow(label: '专辑', value: '${albums.value?.length ?? 0}'),
            _InfoRow(label: '艺术家', value: '${artists.value?.length ?? 0}'),
            _InfoRow(label: '播放列表', value: '${playlists.value?.length ?? 0}'),
            _InfoRow(label: '来源', value: '${sources.value?.length ?? 0}'),
          ],
        ),
        _Section(
          title: '来源',
          children: <Widget>[
            ListTile(
              dense: true,
              leading: const Icon(Icons.folder_open),
              title: const Text('来源管理'),
              subtitle: const Text('本地目录 / WebDAV / 夸克网盘'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/sources'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.sync),
              title: const Text('同步全部来源'),
              subtitle: const Text('逐个重新扫描并合并入库'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final List<MusicSource> list = sources.value ?? const <MusicSource>[];
                for (final MusicSource source in list) {
                  await ref.read(sourceSyncProvider.notifier).sync(source);
                }
              },
            ),
          ],
        ),
        _Section(
          title: '播放',
          children: <Widget>[
            _InfoRow(label: '播放引擎', value: ref.read(audioHandlerProvider).engineName),
            const _InfoRow(label: '系统媒体会话', value: 'Now Playing / 媒体键 / 锁屏（audio_service）'),
          ],
        ),
        _Section(
          title: '数据',
          children: <Widget>[
            FutureBuilder(
              future: getApplicationSupportDirectory(),
              builder: (BuildContext context, AsyncSnapshot<dynamic> snapshot) {
                final String path = snapshot.data?.path as String? ?? '…';
                return _InfoRow(label: '数据目录', value: path);
              },
            ),
            const _InfoRow(label: '曲库文件', value: 'library.sqlite（SQLite / drift）'),
            const _InfoRow(label: '封面缓存', value: 'covers/（只存文件名，二进制落盘）'),
          ],
        ),
        _Section(
          title: '关于',
          children: <Widget>[
            const _InfoRow(label: '版本', value: '0.1.0 (Flutter 预览版)'),
            // 构建戳：开发期用来确认"手机上装的到底是哪一次构建"。
            const _InfoRow(label: '构建', value: String.fromEnvironment('BUILD_STAMP', defaultValue: '本地构建')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(
                '这是纯 Swift 版的重写版本，桌面端（macOS / Windows / Linux）与移动端共用一套代码；'
                '旧版仍在维护期内，迁移方案见 docs/crossplatform-migration.md。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '未入库曲目提示：远端来源（WebDAV / 夸克）的曲目需要先同步；'
            '曲目缺少歌手/专辑/歌词时可在来源页点「补全元数据」。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;

  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(child: SelectableText(value, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
