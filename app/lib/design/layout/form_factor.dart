import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme.dart';
import '../tokens/metrics.dart';
import '../tokens/typography.dart';
import '../tokens/tokens.dart';

/// 外壳形态：**只看窗口宽度**，不看平台（修 A2/A3）。
///
/// 平台只影响交互语汇（hover / 右键 / 快捷键 / 手势 / 滚动条），见 [PlatformTraits]。
enum FormFactor {
  /// < 640：底部 4 Tab + 迷你播放条。
  compact,

  /// 640–1023：NavigationRail + 传输条（隐藏音量 / 输出）。
  medium,

  /// ≥ 1024：侧栏（可折叠）+ 传输条 + 检查器。
  expanded;

  static const double compactMaxWidth = 640;
  static const double mediumMaxWidth = 1024;

  static FormFactor ofWidth(double width) {
    if (width < compactMaxWidth) {
      return FormFactor.compact;
    }
    if (width < mediumMaxWidth) {
      return FormFactor.medium;
    }
    return FormFactor.expanded;
  }

  bool get isCompact => this == FormFactor.compact;
  bool get isMedium => this == FormFactor.medium;
  bool get isExpanded => this == FormFactor.expanded;

  /// 侧栏可用（可折叠为 72 rail）。
  bool get hasSidebar => this == FormFactor.expanded;

  /// 图标 rail 可用。
  bool get hasRail => this == FormFactor.medium || this == FormFactor.expanded;

  /// 右侧检查器（队列 / 歌词）可用。
  bool get hasInspector => this == FormFactor.expanded;
}

/// 尺寸类令牌：由 [FormFactor] + [TyDensity] 解析（`DESIGN.md` §3.3 / §5.1 / §5.2）。
@immutable
class TyMetrics {
  const TyMetrics({
    required this.formFactor,
    required this.density,
    required this.rowHeight,
    required this.tableRowHeight,
    required this.navRowHeight,
    required this.navBarHeight,
    required this.railWidth,
    required this.sidebarWidth,
    required this.sidebarCollapsedWidth,
    required this.transportHeight,
    required this.miniPlayerHeight,
    required this.buttonHeight,
    required this.buttonHeightSmall,
    required this.hitTarget,
    required this.searchHeight,
    required this.chipHeight,
    required this.segmentedHeight,
    required this.coverTable,
    required this.coverList,
    required this.coverDetail,
    required this.pagePadding,
    required this.gridMinTile,
    required this.gridGap,
    required this.panelPadding,
    required this.inspectorWidth,
    required this.maxContentWidth,
    required this.headerToContent,
    required this.transportShowsVolume,
  });

  final FormFactor formFactor;
  final TyDensity density;

  /// 列表行高（compact 56 / medium 52 / expanded 48）。
  final double rowHeight;

  /// 表格行高（medium 48 / expanded 44，紧凑密度 40）。
  final double tableRowHeight;

  /// 侧栏 / rail / 导航行高。
  final double navRowHeight;

  /// 底部导航高。
  final double navBarHeight;

  /// 图标 rail 宽。
  final double railWidth;

  /// 侧栏展开宽 / 折叠宽。
  final double sidebarWidth;
  final double sidebarCollapsedWidth;

  /// 桌面传输条高（medium 72 / expanded 88），compact 为 0。
  final double transportHeight;

  /// 迷你条高（compact 56 / medium 60）。
  final double miniPlayerHeight;

  /// 按钮高（主 / 次）。
  final double buttonHeight;
  final double buttonHeightSmall;

  /// 图标按钮命中区（compact 44 / medium 36 / expanded 32）。
  final double hitTarget;

  /// 搜索框高。
  final double searchHeight;

  /// chip / 筛选 chip 高。
  final double chipHeight;

  /// 分段控件高。
  final double segmentedHeight;

  /// 表格封面 / 列表封面 / 详情封面边长。
  final double coverTable;
  final double coverList;
  final double coverDetail;

  /// 页面水平留白。
  final double pagePadding;

  /// 网格最小瓦片边长与间距。
  final double gridMinTile;
  final double gridGap;

  /// 面板内边距。
  final double panelPadding;

  /// 检查器宽（仅 expanded）。
  final double inspectorWidth;

  /// 详情页最大内容宽。
  final double maxContentWidth;

  /// 页头到内容的间距。
  final double headerToContent;

  /// 传输条是否显示音量控件（compact 形态交给系统音量，不占位）。
  final bool transportShowsVolume;

  static const TyMetrics compactBase = TyMetrics(
    formFactor: FormFactor.compact,
    density: TyDensity.comfortable,
    rowHeight: 56,
    tableRowHeight: 0,
    navRowHeight: 44,
    navBarHeight: 64,
    railWidth: 0,
    sidebarWidth: 0,
    sidebarCollapsedWidth: 0,
    transportHeight: 0,
    miniPlayerHeight: 56,
    buttonHeight: 44,
    buttonHeightSmall: 36,
    hitTarget: 44,
    searchHeight: 44,
    chipHeight: 32,
    segmentedHeight: 36,
    coverTable: 0,
    coverList: 44,
    coverDetail: 160,
    pagePadding: TySpace.pagePaddingCompact,
    gridMinTile: 140,
    gridGap: 12,
    panelPadding: TySpace.x16,
    inspectorWidth: 0,
    maxContentWidth: 1200,
    headerToContent: TySpace.x20,
    transportShowsVolume: false,
  );

  static const TyMetrics mediumBase = TyMetrics(
    formFactor: FormFactor.medium,
    density: TyDensity.comfortable,
    rowHeight: 52,
    tableRowHeight: 48,
    navRowHeight: 40,
    navBarHeight: 0,
    railWidth: 88,
    sidebarWidth: 248,
    sidebarCollapsedWidth: 72,
    transportHeight: 72,
    miniPlayerHeight: 60,
    buttonHeight: 40,
    buttonHeightSmall: 34,
    hitTarget: 40,
    searchHeight: 40,
    chipHeight: 30,
    segmentedHeight: 34,
    coverTable: 40,
    coverList: 40,
    coverDetail: 200,
    pagePadding: TySpace.pagePaddingMedium,
    gridMinTile: 152,
    gridGap: 16,
    panelPadding: TySpace.x16,
    inspectorWidth: 0,
    maxContentWidth: 1200,
    headerToContent: TySpace.x20,
    transportShowsVolume: true,
  );

  static const TyMetrics expandedBase = TyMetrics(
    formFactor: FormFactor.expanded,
    density: TyDensity.comfortable,
    rowHeight: 48,
    tableRowHeight: 44,
    navRowHeight: 32,
    navBarHeight: 0,
    railWidth: 72,
    sidebarWidth: 248,
    sidebarCollapsedWidth: 72,
    transportHeight: 88,
    miniPlayerHeight: 0,
    buttonHeight: 36,
    buttonHeightSmall: 32,
    hitTarget: 36,
    searchHeight: 36,
    chipHeight: 28,
    segmentedHeight: 32,
    coverTable: 40,
    coverList: 40,
    coverDetail: 220,
    pagePadding: TySpace.pagePaddingExpanded,
    gridMinTile: 168,
    gridGap: 20,
    panelPadding: TySpace.x16,
    inspectorWidth: 340,
    maxContentWidth: 1200,
    headerToContent: TySpace.x20,
    transportShowsVolume: true,
  );

  /// 解析缓存：保证同一 (形态, 密度) 始终返回同一实例（`InheritedWidget` 比较依赖它）。
  static final Map<(FormFactor, TyDensity), TyMetrics> _resolved =
      <(FormFactor, TyDensity), TyMetrics>{};

  /// 解析当前形态与外壳尺寸。
  static TyMetrics resolve(FormFactor formFactor, TyDensity density) {
    final (FormFactor, TyDensity) key = (formFactor, density);
    return _resolved.putIfAbsent(key, () {
      final TyMetrics base = switch (formFactor) {
        FormFactor.compact => compactBase,
        FormFactor.medium => mediumBase,
        FormFactor.expanded => expandedBase,
      };
      return base.forDensity(density);
    });
  }

  /// 应用密度设置（compact 形态忽略紧凑密度：触控目标不得小于 44）。
  TyMetrics forDensity(TyDensity target) {
    if (target == density || formFactor.isCompact) {
      return this;
    }
    if (target == TyDensity.compact) {
      return copyWith(
        density: target,
        rowHeight: rowHeight - 8,
        tableRowHeight: math.max(36, tableRowHeight - 4),
        navRowHeight: navRowHeight - 4,
        panelPadding: TySpace.x12,
        gridGap: math.max(8, gridGap - 4),
      );
    }
    return TyMetrics.resolve(formFactor, target);
  }

  /// 自适应网格列数：`cols = max(2, floor((w - 2*pad + gap) / (minTile + gap)))`。
  int gridColumns(double width) {
    final double usable = width - 2 * pagePadding + gridGap;
    final int cols = (usable / (gridMinTile + gridGap)).floor();
    return math.max(2, cols);
  }

  TyMetrics copyWith({
    TyDensity? density,
    double? rowHeight,
    double? tableRowHeight,
    double? navRowHeight,
    double? panelPadding,
    double? gridGap,
  }) {
    return TyMetrics(
      formFactor: formFactor,
      density: density ?? this.density,
      rowHeight: rowHeight ?? this.rowHeight,
      tableRowHeight: tableRowHeight ?? this.tableRowHeight,
      navRowHeight: navRowHeight ?? this.navRowHeight,
      navBarHeight: navBarHeight,
      railWidth: railWidth,
      sidebarWidth: sidebarWidth,
      sidebarCollapsedWidth: sidebarCollapsedWidth,
      transportHeight: transportHeight,
      miniPlayerHeight: miniPlayerHeight,
      buttonHeight: buttonHeight,
      buttonHeightSmall: buttonHeightSmall,
      hitTarget: hitTarget,
      searchHeight: searchHeight,
      chipHeight: chipHeight,
      segmentedHeight: segmentedHeight,
      coverTable: coverTable,
      coverList: coverList,
      coverDetail: coverDetail,
      pagePadding: pagePadding,
      gridMinTile: gridMinTile,
      gridGap: gridGap ?? this.gridGap,
      panelPadding: panelPadding ?? this.panelPadding,
      inspectorWidth: inspectorWidth,
      maxContentWidth: maxContentWidth,
      headerToContent: headerToContent,
      transportShowsVolume: transportShowsVolume,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is TyMetrics &&
        other.formFactor == formFactor &&
        other.density == density;
  }

  @override
  int get hashCode => Object.hash(formFactor, density);
}

/// 平台交互语汇：只描述**交互能力**，不描述布局（`DESIGN.md` §6）。
@immutable
class PlatformTraits {
  const PlatformTraits({
    required this.hover,
    required this.rightClickMenus,
    required this.longPressMenus,
    required this.systemScrollbar,
    required this.primaryModifierIsMeta,
    required this.touchPrimary,
    required this.keyboardShortcuts,
  });

  /// 是否有指针 hover 语汇。
  final bool hover;

  /// 右键上下文菜单。
  final bool rightClickMenus;

  /// 长按上下文菜单（移动端形态）。
  final bool longPressMenus;

  /// 是否显示系统滚动条。
  final bool systemScrollbar;

  /// 主修饰键是否为 ⌘（否则 Ctrl）。
  final bool primaryModifierIsMeta;

  /// 触控优先（决定最小命中区与手势可用性）。
  final bool touchPrimary;

  /// 是否有应用内快捷键。
  final bool keyboardShortcuts;

  static PlatformTraits forPlatform(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.macOS:
        return const PlatformTraits(
          hover: true,
          rightClickMenus: true,
          longPressMenus: false,
          systemScrollbar: true,
          primaryModifierIsMeta: true,
          touchPrimary: false,
          keyboardShortcuts: true,
        );
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return const PlatformTraits(
          hover: true,
          rightClickMenus: true,
          longPressMenus: false,
          systemScrollbar: true,
          primaryModifierIsMeta: false,
          touchPrimary: false,
          keyboardShortcuts: true,
        );
      case TargetPlatform.iOS:
        return const PlatformTraits(
          hover: false,
          rightClickMenus: false,
          longPressMenus: true,
          systemScrollbar: false,
          primaryModifierIsMeta: true,
          touchPrimary: true,
          keyboardShortcuts: false,
        );
      case TargetPlatform.android:
        return const PlatformTraits(
          hover: false,
          rightClickMenus: false,
          longPressMenus: true,
          systemScrollbar: false,
          primaryModifierIsMeta: false,
          touchPrimary: true,
          keyboardShortcuts: false,
        );
    }
  }

  /// 快捷键提示前缀（⌘ / Ctrl）。
  String get primaryModifierLabel => primaryModifierIsMeta ? '⌘' : 'Ctrl';
}

/// 布局作用域：由应用根部的 `LayoutBuilder` 提供宽度，派生形态、尺寸令牌与平台语汇。
///
/// 布局是 widget 关注点：宽度本身不写回 provider（窗口缩放时写 provider 会造成
/// build 期状态变更）。不在 widget 树内的业务代码读 [formFactorProvider]，
/// 它由根部的同一次测量覆盖，与 `context.formFactor` 恒等。
class TyLayoutScope extends InheritedWidget {
  const TyLayoutScope({
    required this.width,
    required this.formFactor,
    required this.metrics,
    required this.traits,
    required super.child,
    super.key,
  });

  final double width;
  final FormFactor formFactor;
  final TyMetrics metrics;
  final PlatformTraits traits;

  /// 窗口软下限（`DESIGN.md` §5.1）：低于此值显示提示页，不崩版。
  static const Size minWindowSize = Size(360, 480);

  /// 由窗口宽度 + 密度偏好构造作用域（真实外壳与测试共用）。
  ///
  /// 宽度决定结构，平台决定交互能力：两者刻意解耦（`DESIGN.md` §0.3）。
  factory TyLayoutScope.forSize(
    Size size, {
    TyDensity density = TyDensity.comfortable,
    TargetPlatform? platform,
    required Widget child,
  }) {
    final FormFactor formFactor = FormFactor.ofWidth(size.width);
    return TyLayoutScope(
      width: size.width,
      formFactor: formFactor,
      metrics: TyMetrics.resolve(formFactor, density),
      traits: PlatformTraits.forPlatform(platform ?? defaultTargetPlatform),
      child: child,
    );
  }

  static TyLayoutScope of(BuildContext context) {
    final TyLayoutScope? scope = context
        .dependOnInheritedWidgetOfExactType<TyLayoutScope>();
    assert(scope != null, 'TyLayoutScope 未挂载：请在应用根部包裹 TyLayoutScope。');
    return scope!;
  }

  static TyLayoutScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TyLayoutScope>();

  @override
  bool updateShouldNotify(TyLayoutScope oldWidget) =>
      oldWidget.width != width ||
      oldWidget.formFactor != formFactor ||
      oldWidget.metrics != metrics ||
      oldWidget.traits != traits;
}

/// 便捷访问：`context.formFactor` / `context.metrics` / `context.traits`。
extension TyLayoutContext on BuildContext {
  FormFactor get formFactor => TyLayoutScope.of(this).formFactor;
  TyMetrics get metrics => TyLayoutScope.of(this).metrics;
  PlatformTraits get traits => TyLayoutScope.of(this).traits;
  double get layoutWidth => TyLayoutScope.of(this).width;
}

/// 当前宽度形态的 provider 视图（只读桥）。
///
/// 唯一写值处是应用根部的 `LayoutBuilder`：它用同一次测量同时挂
/// [TyLayoutScope] 与这里的覆盖，因此两者恒等（`DESIGN.md` §5.1）。
/// 供不在 widget 树内的业务代码读取形态；页面与组件继续用 `context.formFactor`。
final Provider<FormFactor> formFactorProvider = Provider<FormFactor>(
  (Ref ref) => throw StateError('formFactorProvider 必须由根部 ProviderScope 覆盖'),
);

/// 网格列数（`DESIGN.md` §5.1）：不写死列数，按可用宽度与最小瓦片边长算，最少 2 列。
///
/// 只在会重排的宿主里调用（曲库/专辑/艺人/歌单网格），卡片本身仍只适应给定的列宽。
int tyGridColumns(
  double width,
  TyMetrics metrics, {
  double? padding,
  double? minTile,
}) {
  final double pad = padding ?? metrics.pagePadding;
  final double tile = minTile ?? metrics.gridMinTile;
  return math.max(
    2,
    ((width - 2 * pad + metrics.gridGap) / (tile + metrics.gridGap)).floor(),
  );
}

/// 网格瓦片的总高：正方形封面 + 两行文案（标题 `bodyM`、副标题 `bodyS`）。
///
/// 网格要给 `mainAxisExtent`，这里用排版令牌算，避免每个宿主各写一个 magic 的
/// `childAspectRatio`；文案行数变了只改这一处。
///
/// 每行**向上取整到整像素**：Flutter 的行盒按设备像素对齐，22.5 逻辑像素的行会占
/// 到 23，直接按 22.5 相加会让卡片差一像素而裁掉副标题。
/// 行高还要跟着系统字号缩放（`textScaler`）走，否则大字号下同样会溢出。
double tyTileExtent(BuildContext context, double tile) {
  final TyType typography = context.ty.typography;
  final TextScaler scaler = MediaQuery.textScalerOf(context);
  double line(TextStyle style) => math.max(
    1,
    (scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.4)).ceilToDouble(),
  );
  return tile + TySpace.x8 + line(typography.bodyM) + line(typography.bodyS);
}
