import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/motion.dart';
import '../tokens/tokens.dart';
import 'feedback.dart';
import 'interactive.dart';

/// 一行歌词（组件层的展示模型）。
///
/// 解析（LRC / 纯文本）留在页面层：组件不 import `lib/features/**` 与业务解析器。
@immutable
class TyLyricLine {
  const TyLyricLine({required this.time, required this.text});

  /// 该行的起始时间；纯文本歌词（无时间轴）全为 [Duration.zero]。
  final Duration time;

  final String text;
}

/// 歌词视图（`DESIGN.md` §6.3 / §7.2）。
///
/// - 当前行 `titleL` + `accent`，其他行 `bodyL` `textSecondary`；行高固定，
///   高亮只做透明度 / 位移，不做缩放跳变；
/// - 点击行跳转（回调带整行，时间取 [TyLyricLine.time]）；
/// - 手动滚动后 3s 内不自动回拉；`disableAnimations` 时不动画；
/// - 无歌词 → `TyEmptyState`（「未找到歌词」+ 主操作「重新匹配」）。
class TyLyricsView extends StatefulWidget {
  const TyLyricsView({
    super.key,
    required this.lines,
    this.activeIndex,
    this.onLineTap,
    this.onRematch,
    this.emptyTitle = '未找到歌词',
    this.emptyDescription,
    this.rematchLabel = '重新匹配',
    this.padding = const EdgeInsets.symmetric(horizontal: TySpace.x24),
  });

  final List<TyLyricLine> lines;

  /// 当前行下标；纯文本歌词（无时间轴）传 null。
  final int? activeIndex;

  final ValueChanged<TyLyricLine>? onLineTap;

  /// 无歌词时的主操作（重新匹配 / 抓取歌词）。
  final VoidCallback? onRematch;

  final String emptyTitle;
  final String? emptyDescription;
  final String rematchLabel;

  final EdgeInsets padding;

  /// 手动滚动后多久内不自动回拉。
  static const Duration manualHold = Duration(seconds: 3);

  /// 行高：固定值，自动滚动才能按行号算偏移（`DESIGN.md` §6.2 的固定行高同理）。
  static const double lineExtent = TySpace.x48;

  /// 当前行落在视口的高度占比（1/3 处）。
  static const double anchor = 3;

  @override
  State<TyLyricsView> createState() => _TyLyricsViewState();
}

class _TyLyricsViewState extends State<TyLyricsView> {
  final ScrollController _controller = ScrollController();

  /// 手动滚动后的免打扰截止时间。
  DateTime? _manualUntil;

  bool _dragging = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TyLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeIndex != oldWidget.activeIndex) {
      _scheduleFollow();
    }
  }

  void _scheduleFollow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _follow();
      }
    });
  }

  /// 把当前行滚到视口 1/3 处；手动滚动后的 3s 内不动。
  void _follow() {
    final int? index = widget.activeIndex;
    if (index == null || index < 0 || !_controller.hasClients) {
      return;
    }
    if (_dragging) {
      return;
    }
    final DateTime? until = _manualUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      return;
    }
    final double viewport = _controller.position.viewportDimension;
    final double target =
        index * TyLyricsView.lineExtent - viewport / TyLyricsView.anchor;
    final double clamped = target
        .clamp(0, _controller.position.maxScrollExtent)
        .toDouble();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpTo(clamped);
      return;
    }
    _controller.animateTo(
      clamped,
      duration: TyDuration.stage,
      curve: TyCurve.decelerate,
    );
  }

  bool _onScroll(ScrollNotification notification) {
    // 只有用户自己的滚动才进入免打扰；组件的自动滚动不该把自己锁住。
    if (notification is ScrollStartNotification) {
      _dragging = notification.dragDetails != null;
      if (_dragging) {
        _manualUntil = DateTime.now().add(TyLyricsView.manualHold);
      }
    } else if (notification is ScrollEndNotification) {
      _dragging = false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) {
      return TyEmptyState(
        icon: Icons.lyrics_outlined,
        title: widget.emptyTitle,
        description: widget.emptyDescription,
        actionLabel: widget.onRematch == null ? null : widget.rematchLabel,
        onAction: widget.onRematch,
      );
    }
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ListView.builder(
        controller: _controller,
        padding: widget.padding,
        itemExtent: TyLyricsView.lineExtent,
        itemCount: widget.lines.length,
        itemBuilder: (BuildContext context, int index) => _LyricRow(
          line: widget.lines[index],
          active: index == widget.activeIndex,
          reduceMotion: reduceMotion,
          onTap: widget.onLineTap,
        ),
      ),
    );
  }
}

/// 一行：整体可点（跳转），高亮只做颜色 + 轻微上移。
class _LyricRow extends StatelessWidget {
  const _LyricRow({
    required this.line,
    required this.active,
    required this.reduceMotion,
    this.onTap,
  });

  final TyLyricLine line;
  final bool active;
  final bool reduceMotion;
  final ValueChanged<TyLyricLine>? onTap;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final Duration duration = reduceMotion ? Duration.zero : TyDuration.sheet;
    final String text = line.text.isEmpty ? '♪' : line.text;
    return TyInteractive(
      onTap: onTap == null ? null : () => onTap!(line),
      cursor: SystemMouseCursors.click,
      semanticLabel: text,
      semanticButton: true,
      builder: (BuildContext context, TyInteractionState state) => AnimatedContainer(
        duration: duration,
        curve: TyCurve.standard,
        transform: Matrix4.translationValues(
          0,
          active ? -TySpace.x2 : 0,
          0,
        ),
        alignment: Alignment.centerLeft,
        child: AnimatedDefaultTextStyle(
          duration: duration,
          curve: TyCurve.standard,
          style: active
              ? ty.typography.titleL.copyWith(color: ty.colors.accent)
              : ty.typography.bodyL.copyWith(color: ty.colors.textSecondary),
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}
