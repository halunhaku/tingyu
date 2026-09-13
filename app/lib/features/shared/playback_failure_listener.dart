import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../playback/playback_snapshot.dart';

/// 把播放失败（[PlaybackSnapshot.failure]）弹成 SnackBar。
///
/// 挂在 `MaterialApp.router` 的 `builder` 上（那个位置在 `ScaffoldMessenger` 之下、
/// 路由之上），桌面与移动两套外壳共用一份，不必在每个页面里各监听一次。
///
/// 引擎的进度事件会以很高频率反复推送同一份快照，所以这里按"失败对象是否换了实例"
/// 去重：同一次失败只提示一次，换一首歌再次失败会换新实例、重新提示。
class PlaybackFailureListener extends ConsumerWidget {
  const PlaybackFailureListener({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<PlaybackSnapshot>(playbackProvider, (
      PlaybackSnapshot? previous,
      PlaybackSnapshot next,
    ) {
      final PlaybackFailure? failure = next.failure;
      if (failure == null || identical(previous?.failure, failure)) {
        return;
      }
      final String title = failure.title ?? '';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              title.isEmpty ? failure.message : '「$title」${failure.message}',
            ),
          ),
        );
    });
    return child;
  }
}
