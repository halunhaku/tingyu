import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../layout/form_factor.dart';
import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'buttons.dart';
import 'cover.dart';
import 'interactive.dart';

/// 共享元素标签：迷你条封面 ↔ 舞台封面（`stageExpand` 320ms）。
abstract final class TyHeroTags {
  /// 正在播放封面：迷你条与舞台用同一个 tag，路由推入时自动做共享元素动画。
  static const String nowPlayingCover = 'ty-now-playing-cover';
}

/// 舞台几何档位（`DESIGN.md` §3.3 / §6.3 / §7.2）。
abstract final class TyPlayerStageSize {
  /// 右侧 `secondary` 槽宽度（歌词 / 队列）。
  static const double rightPaneWidth = 380;

  /// 舞台封面上限 / 下限与高度占比（compact 与桌面各一档）。
  static const double coverMax = 420;
  static const double coverMin = 120;
  static const double compactCoverHeightRatio = 0.42;
  static const double coverHeightRatio = 0.5;

  /// 左侧内容列最大宽度（封面 + 控制）。
  static const double contentMaxWidth = 420;

  /// 顶部条高与抓手。
  static const double topBarHeight = TySpace.x48;
  static const double dragHandleWidth = TySpace.x32;
  static const double dragHandleHeight = TySpace.x4;

  /// 下拉收起：手势 1:1 跟随，越过 35% 或速度足够即收起（`DESIGN.md` §7.2）。
  static const double collapseThreshold = 0.35;
  static const double collapseVelocity = 700;

  /// 曲名超过这个长度就降级到 `displayM`。
  static const int longTitleThreshold = 18;
}

/// 播放舞台（`DESIGN.md` §6.3 / `docs/UX_REDESIGN.md` §5.4）。
///
/// - 背景由使用方传入（封面动态取色只在这一层铺满，组件自己不做取色）；
/// - 封面 `TyCover`（圆角 `xl`，无阴影）→ 曲名 `displayL`（compact `titleL`）→
///   艺术家 `bodyL`（可点进艺人）→ 专辑 `bodyS` → 进度（宿主接线）→ 传输行（宿主接线）
///   → 次级行；
/// - expanded 两栏：左「封面 + 控制」，右 380 宽的 [rightPane] 槽（歌词 / 队列内容）；
/// - 关闭：顶部左箭头 [onClose]；compact 下拉收起 [onDismiss]（1:1 跟随 + 35% 阈值）。
class TyPlayerStage extends StatefulWidget {
  const TyPlayerStage({
    super.key,
    required this.background,
    this.title = '',
    this.artist = '',
    this.album,
    this.coverPath,
    this.coverUrl,
    this.coverSeed,
    this.favorite = false,
    this.onToggleFavorite,
    this.onArtistTap,
    required this.progress,
    required this.transport,
    this.actions = const <Widget>[],
    this.rightPane,
    this.onClose,
    this.onDismiss,
    this.heroTag = TyHeroTags.nowPlayingCover,
  });

  /// 铺满整窗的背景（舞台动态取色背景 / 中性渐变）。
  final Widget background;

  final String title;
  final String artist;

  /// 专辑名；占位专辑（`未知专辑` 一类）由宿主决定是否传。
  final String? album;

  final String? coverPath;
  final String? coverUrl;
  final String? coverSeed;

  final bool favorite;
  final VoidCallback? onToggleFavorite;

  /// 点击艺术家名 → 艺人详情。
  final VoidCallback? onArtistTap;

  /// 进度行（宿主接线：`TySeekBar` 或带时间的组合）。
  final Widget progress;

  /// 传输键行（宿主接线：`TyTransportRow`）。
  final Widget transport;

  /// 次级动作：收藏 / 歌词 / 队列 / 音量。
  final List<Widget> actions;

  /// expanded 的右侧槽；为 null 时单栏。
  final Widget? rightPane;

  /// 顶部左箭头。
  final VoidCallback? onClose;

  /// compact 下拉收起；null 时手势关闭。
  final VoidCallback? onDismiss;

  final String heroTag;

  @override
  State<TyPlayerStage> createState() => _TyPlayerStageState();
}

class _TyPlayerStageState extends State<TyPlayerStage> {
  /// 下拉手势的 1:1 位移。
  double _dragOffset = 0;

  bool _dragging = false;

  bool get _canDrag =>
      widget.onDismiss != null && context.formFactor == FormFactor.compact;

  void _onDragStart(DragStartDetails details) {
    setState(() => _dragging = true);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset = math.max(0, _dragOffset + details.delta.dy);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final double height = MediaQuery.sizeOf(context).height;
    final bool dismiss =
        _dragOffset > height * TyPlayerStageSize.collapseThreshold ||
        details.velocity.pixelsPerSecond.dy >
            TyPlayerStageSize.collapseVelocity;
    setState(() {
      _dragging = false;
      _dragOffset = 0;
    });
    if (dismiss) {
      widget.onDismiss?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final FormFactor formFactor = context.formFactor;
    final bool twoColumn =
        formFactor == FormFactor.expanded && widget.rightPane != null;
    final Duration duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : TyDuration.sheet;

    final Widget column = AnimatedContainer(
      // 拖动时 1:1 跟随；松手后按 `stageCollapse` 的 240ms 回弹。
      duration: _dragging ? Duration.zero : duration,
      curve: TyCurve.decelerate,
      transform: Matrix4.translationValues(0, _dragOffset, 0),
      transformAlignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _topBar(context),
          Expanded(
            child: twoColumn
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(child: _stage(context, formFactor)),
                      SizedBox(
                        width: TyPlayerStageSize.rightPaneWidth,
                        child: widget.rightPane,
                      ),
                    ],
                  )
                : _stage(context, formFactor),
          ),
        ],
      ),
    );

    // 舞台挂在根 Navigator 上（不在外壳的 Scaffold 里），必须自己给一层
    // `Material`：否则 `Text` 会落到 MaterialApp 的 fallback 样式上——
    // 那套样式带一条黄色下划线（Flutter 用来提示「你的文本不在 Material 里」）。
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 背景铺满整窗；内容在它之上，背景不随下拉位移（收起时是内容滑走）。
          Positioned.fill(child: widget.background),
          column,
        ],
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final TyTokens ty = context.ty;
    final EdgeInsets padding = MediaQuery.paddingOf(context);
    return Padding(
      padding: EdgeInsets.only(
        top: padding.top,
        left: TySpace.x8,
        right: TySpace.x8,
      ),
      child: SizedBox(
        height: TyPlayerStageSize.topBarHeight,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (widget.onClose != null)
                  TyIconAction(
                    icon: Icons.arrow_back_rounded,
                    semanticLabel: '关闭舞台',
                    tooltip: '关闭（Esc）',
                    size: TyIconSize.toolbar,
                    onPressed: widget.onClose,
                  ),
                const Spacer(),
              ],
            ),
            if (_canDrag)
              // 收起手势落在顶部条上：内容本身要能滚动，不与滚动抢手势。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: _onDragStart,
                onVerticalDragUpdate: _onDragUpdate,
                onVerticalDragEnd: _onDragEnd,
                child: SizedBox(
                  width: TyPlayerStageSize.dragHandleWidth,
                  height: TyPlayerStageSize.topBarHeight,
                  child: Center(
                    child: Container(
                      width: TyPlayerStageSize.dragHandleWidth,
                      height: TyPlayerStageSize.dragHandleHeight,
                      decoration: BoxDecoration(
                        color: ty.colors.borderStrong,
                        borderRadius: TyRadius.fullAll,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stage(BuildContext context, FormFactor formFactor) {
    final EdgeInsets padding = MediaQuery.paddingOf(context);
    final double bottomInset = padding.bottom + TySpace.x24;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 封面尺寸（`DESIGN.md` §3.3）：compact 按宽度，桌面按高度的一半，封顶 420。
        final double raw = formFactor == FormFactor.compact
            ? math.min(
                constraints.maxWidth - TySpace.x40,
                constraints.maxHeight *
                    TyPlayerStageSize.compactCoverHeightRatio,
              )
            : math.min(
                TyPlayerStageSize.coverMax,
                constraints.maxHeight * TyPlayerStageSize.coverHeightRatio,
              );
        final double coverSize = raw
            .clamp(TyPlayerStageSize.coverMin, TyPlayerStageSize.coverMax)
            .toDouble();
        final double horizontal = formFactor == FormFactor.compact
            ? TySpace.x20
            : TySpace.x32;
        // 控件固定在下缘，封面与标题占满剩余空间（放不下就在这一块内滚动）。
        //
        // 走过的弯路都别再走：
        // - `IntrinsicHeight` / `SliverFillRemaining(hasScrollBody: false)`：两者都要
        //   询问子树的固有高度，而宿主接线的进度条（`TySeekBar`）用了
        //   `LayoutBuilder`，一问就抛 performLayout 断言；
        // - `SingleChildScrollView` + `minHeight`：滚动视图给的是无界高度，
        //   Column 不会被拉伸，spaceBetween 拿不到余量（控件还是浮在中间）。
        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontal,
            TySpace.x8,
            horizontal,
            bottomInset,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: TyPlayerStageSize.contentMaxWidth,
              ),
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: SingleChildScrollView(
                      child: _coverAndInfo(context, coverSize, formFactor),
                    ),
                  ),
                  const SizedBox(height: TySpace.x24),
                  _controls(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _controls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        widget.progress,
        const SizedBox(height: TySpace.x16),
        widget.transport,
        if (widget.actions.isNotEmpty) ...<Widget>[
          const SizedBox(height: TySpace.x16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              for (final Widget action in widget.actions) ...<Widget>[
                const SizedBox(width: TySpace.x8),
                action,
              ],
            ],
          ),
        ],
      ],
    );
  }

  /// 封面 + 曲名 + 艺术家 + 专辑：占满控件之上的剩余空间（放不下就在这一块滚动）。
  Widget _coverAndInfo(
    BuildContext context,
    double coverSize,
    FormFactor formFactor,
  ) {
    final TyTokens ty = context.ty;
    final String title = widget.title;
    final TextStyle titleStyle =
        formFactor == FormFactor.compact ||
            title.length > TyPlayerStageSize.longTitleThreshold
        ? ty.typography.titleL
        : ty.typography.displayL;
    final String? album = widget.album;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Hero(
          tag: widget.heroTag,
          child: TyCover(
            path: widget.coverPath,
            url: widget.coverUrl,
            seed: widget.coverSeed,
            size: coverSize,
            radius: TyRadius.xl,
          ),
        ),
        const SizedBox(height: TySpace.x24),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: titleStyle.copyWith(color: ty.colors.textPrimary),
        ),
        const SizedBox(height: TySpace.x4),
        _artist(context),
        if (album != null && album.isNotEmpty) ...<Widget>[
          const SizedBox(height: TySpace.x2),
          Text(
            album,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: ty.typography.bodyS.copyWith(color: ty.colors.textSecondary),
          ),
        ],
      ],
    );
  }

  Widget _artist(BuildContext context) {
    final TyTokens ty = context.ty;
    final String artist = widget.artist;
    final TextStyle style = ty.typography.bodyL.copyWith(
      color: ty.colors.textSecondary,
    );
    if (widget.onArtistTap == null || artist.isEmpty) {
      return Text(
        artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: style,
      );
    }
    return TyInteractive(
      onTap: widget.onArtistTap,
      semanticLabel: '查看艺人 $artist',
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, TyInteractionState state) => Text(
        artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: style.copyWith(
          color: state.hovered
              ? ty.colors.textPrimary
              : ty.colors.textSecondary,
          decoration: state.hovered ? TextDecoration.underline : null,
          decorationColor: ty.colors.textPrimary,
        ),
      ),
    );
  }
}
