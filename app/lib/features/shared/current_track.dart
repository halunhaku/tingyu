import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/playback_controller.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../playback/playback_item.dart';
import '../../playback/playback_snapshot.dart';

/// "正在播的是哪一首"的身份：曲库 id（有的话）与引擎条目。
///
/// 进度 tick 每秒 5-16 次，而这两个值整首歌只变一次。把它们单独拿出来订阅，
/// 曲库列表、迷你条、播放条的封面与标题才不必跟着进度重建。
typedef CurrentTrackRef = ({String? trackId, PlaybackItem? item});

/// [CurrentTrackRef] 的 provider。
///
/// 每收到一次快照就重算（只是一次查表，不做拷贝），但暴露的值按 `==` 比较，
/// 所以只有换曲/换队列才通知订阅方，进度 tick 不会。
///
/// 之所以要跟着 tick 重算，是因为队列只存在控制器里、快照本身不带队列身份：
/// 新队列的下标可能与旧的一样（比如都从第 0 首起播），只有重算才能读到新的 id。
final Provider<CurrentTrackRef> currentTrackRefProvider =
    Provider<CurrentTrackRef>((Ref ref) {
      final PlaybackSnapshot snapshot = ref.watch(playbackProvider);
      final PlaybackController controller = ref.read(playbackProvider.notifier);
      final List<String> ids = controller.trackIds;
      final int index = snapshot.index;
      return (
        trackId: (index >= 0 && index < ids.length) ? ids[index] : null,
        item: controller.currentItem,
      );
    });

/// 当前播放的曲库曲目；队列由外部设置（没有曲库 id）或曲目行还没读到时为 null。
final Provider<Track?> currentTrackProvider = Provider<Track?>((Ref ref) {
  final String? id = ref.watch(currentTrackRefProvider).trackId;
  // 没有曲库 id 时不要订阅曲库：空播放不该为一条 drift 流买单。
  return id == null ? null : ref.watch(trackByIdProvider(id)).value;
});

/// 某个曲库 id 是不是正在播放的那一首：列表高亮用。
///
/// 取值是布尔而不是 id/快照，所以换曲时只有高亮真的翻转的那两行会重建。
final isCurrentTrackProvider = Provider.family<bool, String>(
  (Ref ref, String trackId) =>
      ref.watch(currentTrackRefProvider).trackId == trackId,
);
