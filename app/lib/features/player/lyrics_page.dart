import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/database.dart';
import '../../design/components/buttons.dart';
import '../../design/layout/form_factor.dart';
import '../../design/components/structure.dart';
import '../../design/theme.dart';
import '../../design/tokens/metrics.dart';
import '../shared/current_track.dart';
import 'lyrics_panel.dart';

/// `/lyrics`：compact 下的整页歌词（`docs/UX_REDESIGN.md` §3.3）。
///
/// 桌面把同一个 `LyricsPanel` 放进检查器/舞台右栏；移动端给它独立一页。
class LyricsPage extends ConsumerWidget {
  const LyricsPage({super.key});

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
                    child: TyPageHeader(title: '歌词', subtitle: track?.title),
                  ),
                ],
              ),
            ),
            const Expanded(child: LyricsPanel()),
          ],
        ),
      ),
    );
  }
}
