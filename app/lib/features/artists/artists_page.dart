import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/models/library_summaries.dart';
import '../shared/empty_state.dart';

/// 艺术家头像字节：按名字缓存（`ArtistAvatarStore` 自带内存 + 磁盘缓存与并发收敛）。
///
/// 不显式标注 `FutureProviderFamily<Uint8List?, String>`：Riverpod 3 把该类型
/// 挪到了 `package:flutter_riverpod/misc.dart`，这里靠推断保持主入口 import。
final artistAvatarProvider = FutureProvider.family<Uint8List?, String>(
  (Ref ref, String artist) => ref.watch(artistAvatarStoreProvider).avatar(artist),
);

/// 艺术家头像：命中头像缓存显示图片，否则回落到名字首字占位。
///
/// 列表与详情页共用，尺寸由调用方给（列表 44，详情 120 左右）。
class ArtistAvatar extends ConsumerWidget {
  const ArtistAvatar({super.key, required this.artist, this.size = 44});

  final String artist;

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Uint8List?> avatar = ref.watch(artistAvatarProvider(artist));

    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: avatar.maybeWhen(
          data: (Uint8List? bytes) => bytes == null || bytes.isEmpty
              ? _initial(context)
              : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
          // 拉取中或失败（离线、查不到）都先用首字占位，不再阻塞列表。
          orElse: () => _initial(context),
        ),
      ),
    );
  }

  Widget _initial(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String name = artist.trim();

    return ColoredBox(
      color: scheme.primaryContainer,
      child: Center(
        child: Text(
          name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
          style: TextStyle(
            fontSize: size * 0.4,
            fontWeight: FontWeight.w600,
            color: scheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}

/// 艺术家页：头像 + 名字 + 曲目数，点击进入艺术家详情。
class ArtistsPage extends ConsumerWidget {
  const ArtistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ArtistSummary>> artists = ref.watch(artistsProvider);
    final TextTheme text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: <Widget>[
              Expanded(child: Text('艺术家', style: text.titleLarge)),
              artists.maybeWhen(
                data: (List<ArtistSummary> list) =>
                    Text('${list.length} 位', style: text.bodySmall),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
        ),
        Expanded(
          child: artists.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, StackTrace stack) => EmptyState(
              icon: Icons.error_outline,
              title: '艺术家列表读取失败',
              message: '$error',
            ),
            data: (List<ArtistSummary> list) {
              if (list.isEmpty) {
                return const EmptyState(
                  icon: Icons.person_outline,
                  title: '还没有艺术家',
                  message: '添加来源并同步曲库后，这里会按艺术家聚合展示',
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                itemCount: list.length,
                itemBuilder: (BuildContext context, int index) {
                  final ArtistSummary artist = list[index];
                  return ListTile(
                    leading: ArtistAvatar(artist: artist.name),
                    title: Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${artist.trackCount} 首'),
                    onTap: () => context.go('/artists/${Uri.encodeComponent(artist.name)}'),
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
