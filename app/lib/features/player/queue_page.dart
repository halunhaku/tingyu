import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/database.dart';
import '../../design/components/buttons.dart';
import '../../design/components/structure.dart';
import '../../design/layout/form_factor.dart';
import '../../design/theme.dart';
import '../../design/tokens/metrics.dart';
import '../shared/current_track.dart';
import 'queue_panel.dart';

/// `/queue`：compact 下的整页队列（`docs/UX_REDESIGN.md` §3.3）。
///
/// 桌面把同一份 `QueuePanel` 放进检查器，移动端给它一个独立页——
/// 两处共用同一个组件，不做第二份实现。队列能力边界见 §4.1：
/// 只支持读、跳转与末尾追加（引擎没有插入/移除/重排接口）。
class QueuePage extends ConsumerWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track = ref.watch(currentTrackProvider);
    return Scaffold(
      backgroundColor: context.ty.colors.canvas,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.metrics.pagePadding,
                TySpace.x12,
                context.metrics.pagePadding,
                TySpace.x8,
              ),
              child: Row(
                children: <Widget>[
                  TyIconAction(
                    icon: Icons.arrow_back,
                    semanticLabel: '返回',
                    onPressed: () => context.canPop()
                        ? context.pop()
                        : context.go('/library/songs'),
                  ),
                  const SizedBox(width: TySpace.x8),
                  Expanded(
                    child: TyPageHeader(title: '播放队列', subtitle: track?.title),
                  ),
                ],
              ),
            ),
            const Expanded(child: QueuePanel()),
          ],
        ),
      ),
    );
  }
}
