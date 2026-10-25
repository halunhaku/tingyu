import 'package:flutter/material.dart';

/// 间距令牌：4pt 栅格（`DESIGN.md` §3.1）。
abstract final class TySpace {
  static const double x2 = 2;
  static const double x4 = 4;
  static const double x6 = 6;
  static const double x8 = 8;
  static const double x12 = 12;
  static const double x16 = 16;
  static const double x20 = 20;
  static const double x24 = 24;
  static const double x32 = 32;
  static const double x40 = 40;
  static const double x48 = 48;
  static const double x64 = 64;

  /// 页面水平留白（compact / medium / expanded）。
  static const double pagePaddingCompact = 20;
  static const double pagePaddingMedium = 24;
  static const double pagePaddingExpanded = 32;
}

/// 圆角令牌（`DESIGN.md` §3.2）。
abstract final class TyRadius {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 20;
  static const double full = 999;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius fullAll = BorderRadius.all(Radius.circular(full));

  /// 底部抽屉：仅顶部圆角。
  static const BorderRadius sheetTop = BorderRadius.vertical(
    top: Radius.circular(xl),
  );

  /// 迷你播放条：仅顶部圆角。
  static const BorderRadius miniPlayerTop = BorderRadius.vertical(
    top: Radius.circular(xl),
  );
}

/// 固定几何尺寸：不随密度变化的结构宽度与控件直径。
abstract final class TySize {
  /// 曲目行/表格左侧序号（含播放态音柱）列宽。
  static const double trackLeading = 40;

  /// 多选勾选框列宽。
  static const double tableCheckboxColumn = 24;

  /// 表格封面列宽。
  static const double tableCoverColumn = 32;

  /// 表格时长列宽。
  static const double tableDurationColumn = 56;

  /// 收藏列宽。
  static const double tableFavoriteColumn = 36;

  /// 「更多」列宽。
  static const double tableMoreColumn = 32;

  /// 表头尾部两列合计（收藏 + 更多）。
  static const double tableHeaderTrailing = 68;

  /// 勾选框边长。
  static const double checkbox = 16;
}

/// 图标尺寸令牌（`DESIGN.md` §3.4）。
abstract final class TyIconSize {
  /// 徽标 / 内联。
  static const double inline = 14;

  /// 行内紧凑。
  static const double compact = 16;

  /// 默认（行内操作）。
  static const double normal = 20;

  /// 工具栏 / 导航。
  static const double toolbar = 24;

  /// 次级传输键。
  static const double transportSecondary = 28;

  /// 播放主控圆形底。
  static const double playControl = 56;
}

/// 阴影令牌：浅色有效，深色不使用（`DESIGN.md` §3.5）。
abstract final class TyElevation {
  static const List<BoxShadow> none = <BoxShadow>[];

  static const List<BoxShadow> popover = <BoxShadow>[
    BoxShadow(color: Color(0x1A000000), blurRadius: 16, offset: Offset(0, 4)),
  ];

  static const List<BoxShadow> sheet = <BoxShadow>[
    BoxShadow(color: Color(0x24000000), blurRadius: 32, offset: Offset(0, 12)),
  ];

  static const List<BoxShadow> palette = <BoxShadow>[
    BoxShadow(color: Color(0x2E000000), blurRadius: 48, offset: Offset(0, 20)),
  ];

  /// 深色主题只保留模态层阴影，其余返回 [none]。
  static List<BoxShadow> forBrightness(Brightness brightness, List<BoxShadow> shadows) {
    if (brightness == Brightness.dark && !identical(shadows, sheet) && !identical(shadows, palette)) {
      return none;
    }
    return shadows;
  }
}
