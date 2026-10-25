import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/components/buttons.dart';
import '../../design/layout/form_factor.dart';
import '../../design/tokens/tokens.dart';
import '../../design/components/structure.dart';
import '../../design/theme.dart';
import '../../design/tokens/metrics.dart';

/// 首次引导（`docs/UX_REDESIGN.md` §3.3 的 `/onboarding`）。
///
/// 只在「库已加载 ∧ 无来源 ∧ 无曲目」时由外壳送进来一次；不做假动画、不做轮播，
/// 只把「你的音乐放哪儿都行」这件事说清楚，并把用户送到真正能加来源的地方。
/// 三种来源的添加流程都在 `/sources` 里（那里能选文件夹、填 WebDAV、扫码登录夸克），
/// 所以这里的按钮就是导航，而不是把表单复制一遍。
class OnboardingPage extends ConsumerWidget {
  const OnboardingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TyTokens ty = context.ty;
    final TyMetrics metrics = context.metrics;
    return Scaffold(
      backgroundColor: ty.colors.canvas,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: metrics.maxContentWidth),
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: metrics.pagePadding,
                vertical: TySpace.x40,
              ),
              children: <Widget>[
                Text(
                  '听屿',
                  style: ty.typography.displayL.copyWith(
                    color: ty.colors.textPrimary,
                  ),
                ),
                const SizedBox(height: TySpace.x8),
                Text(
                  'A beautiful home for your personal music.',
                  style: ty.typography.titleM.copyWith(
                    color: ty.colors.textSecondary,
                  ),
                ),
                const SizedBox(height: TySpace.x12),
                Text(
                  '先把音乐放进来：本地文件夹、私人云盘、网盘都行。'
                  '扫描完成后，曲库、封面、歌词与播放队列都会自动整理好。',
                  style: ty.typography.bodyM.copyWith(
                    color: ty.colors.textSecondary,
                  ),
                ),
                const SizedBox(height: TySpace.x24),
                TyPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const _SourceHint(
                        icon: Icons.folder_outlined,
                        title: '本地文件夹',
                        description: '选择一个音乐目录，扫描后自动入库',
                      ),
                      const SizedBox(height: TySpace.x16),
                      const _SourceHint(
                        icon: Icons.cloud_outlined,
                        title: 'WebDAV',
                        description: '私有云盘（Nextcloud、坚果云等）填地址与账号即可',
                      ),
                      const SizedBox(height: TySpace.x16),
                      const _SourceHint(
                        icon: Icons.cloud_queue,
                        title: '夸克网盘',
                        description: '扫码或网页登录后直接读取网盘里的音乐',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: TySpace.x24),
                Row(
                  children: <Widget>[
                    TyButton(
                      label: '添加音乐来源',
                      icon: Icons.add,
                      onPressed: () => context.go('/sources'),
                    ),
                    const SizedBox(width: TySpace.x12),
                    TyButton(
                      label: '先去设置看看',
                      variant: TyButtonVariant.ghost,
                      onPressed: () => context.go('/settings'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceHint extends StatelessWidget {
  const _SourceHint({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: TyIconSize.inline, color: ty.colors.textSecondary),
        const SizedBox(width: TySpace.x12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: ty.typography.titleM.copyWith(
                  color: ty.colors.textPrimary,
                ),
              ),
              const SizedBox(height: TySpace.x4),
              Text(
                description,
                style: ty.typography.bodyS.copyWith(
                  color: ty.colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
