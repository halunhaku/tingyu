# Tingyu Design System (Phase 3)

> **2026-10-26 M7 现状说明**：本文写于 Flutter 客户端（`app/`）时期，是该客户端的「声档」设计契约。`app/` 已在 M7 删除（可从 tag `archive/flutter-macos` 找回），因此文中的 `lib/**`、`app/lib/**`、`test/*.dart`、`flutter test` 与 `tools/windows-*.ps1` 都是历史路径，不再是可执行的构建或测试入口；现行实现是 Go + MyGo 的 `client/`，令牌与配色按同一套设计实现（`client/internal/ui/tokens`），迁移记录见 `docs/plan/2026-10-26-macos-mygo-m7-record.md`。本文作为设计语言的历史依据保留。

> 2026-10-18 分页迁移说明：用户已批准 [声档P2 v0.1](docs/ui-redesign/02-design-system.md)（批准记录 `docs/ui-redesign/decision-c.json`）。本轮仅全屏播放与直接关联控件采用新规范；其他页面继续遵循下文。舞台通过现有TyTheme/TyColors的局部作用域接入声档令牌，不替换业务架构或提前改变全局页面。Golden基准仍须单独明确批准后更新。

> 适用版本:Tingyu 3.0(`app/`, Flutter 客户端，M7 已删除)。
> 本文是**实现契约**:Phase 4/5 的任何 UI 代码必须只用本文定义的 token 与组件,不得出现魔法常量、硬编码颜色、平台分支布局。
> 上游依据:`docs/UI_UX_AUDIT.md`(问题编号)、`docs/UX_REDESIGN.md`(结构决策)。
> 本文件中所有对比度数值都是用实际十六进制值计算的(见每个色板的「实测」列),不是估计。

---

## 0. 使用方式(强制性)

1. **零魔法值**:颜色/间距/圆角/字号/时长/曲线/控件高度只能来自 `TyTokens`。
2. **单一样式来源**:组件不得直接读 `Theme.of(context).colorScheme`,一律读 `TyTheme.of(context)`(Material `ColorScheme` 由 token 派生,仅供 Material 内建控件继承)。
3. **布局只看宽度**:`FormFactor`(`compact < 640 ≤ medium < 1024 ≤ expanded`)决定结构;`PlatformTraits`(hover/右键/快捷键/手势/滚动条)决定交互。禁止在任何页面里写 `Platform.isAndroid` 决定结构(修 A2/A3)。
4. **状态必须四态完备**:每个异步页面必须用 `TyAsyncView` 覆盖 loading / error / empty / data(修 V10)。
5. **可扫描守卫**:`test/design_guard_test.dart` 负责机械检查以下禁止项(Phase 4 首先落地)。守卫只扫**表现层**,并支持行内豁免 `// guard-ok: <理由>`(豁免必须写明理由,数量纳入 review):
   - 扫描范围:`lib/features/**`、`lib/design/components/**`;
   - 规则(逐条正则,均有正反样例测试):
     - `Colors.`(允许 `Colors.transparent`;二维码白底等实物颜色用 `// guard-ok`);
     - `Color(0x` / `Color.fromARGB`(token 定义文件 `lib/design/tokens/` 天然豁免);
     - `CircularProgressIndicator(`(行内同步等瞬时反馈用 `TyProgressBar`);
     - 结构型常量:`EdgeInsets.all(`/`EdgeInsets.only(`/`EdgeInsets.symmetric(`/`EdgeInsets.fromLTRB(`/`SizedBox(height:`/`SizedBox(width:`/`BorderRadius.circular(` 的数字字面量(0/1/2 与 `double.infinity` 除外);
     - 内联样式:`TextStyle(` 与 `fontSize:`(必须走 `ty.typography`);
     - `Platform.is*(`(仅 `lib/features/**` 与 `lib/app/**` 的**布局**判断;媒体/权限/文件管理等业务分支在豁免清单里逐文件列出,理由写注释)。
   - 白名单必须**按文件路径 + 表达式**列出,不允许整目录豁免;守卫自身的正反样例放在 `test/fixtures/guard/`,保证规则既不会漏报也不会误伤业务分支。

---

## 1. 架构与文件落点

```
lib/design/
├── tokens/
│   ├── color.dart        TyColors(浅/深色板)+ 语义别名(选中/播放中/危险/骨架/遮罩)
│   ├── typography.dart   TyType(11 级 Type Scale)+ 平台字体栈
│   ├── metrics.dart      TySpace / TyRadius / TySize / TyIconSize / TyElevation
│   ├── motion.dart       TyDuration / TyCurve
│   └── tokens.dart       TyTokens(ThemeExtension,聚合以上)
├── theme.dart            TyTheme.build(brightness, density) → ThemeData;TyTheme.of(context) + context.ty
├── layout/
│   ├── form_factor.dart  FormFactor 枚举 + formFactorProvider + PlatformTraits
│   ├── app_shell.dart    唯一外壳(侧栏 / rail / 底部导航 + 传输条 + 迷你条 + 检查器宿主)
│   └── panels.dart       检查器与舞台宿主(Overlay / 全屏路由)
├── motion/
│   └── transitions.dart  命名过渡 + Hero 配置
└── components/           见 §6(按职责分文件,统一 Ty 前缀;交互原语 interactive.dart,按钮 buttons.dart,封面 cover.dart,反馈 feedback.dart)
```

现役 `lib/app/theme.dart` 的 `ThemeData` 构造、`lib/features/shell/app_shell.dart`、`mobile_shell.dart`、`lib/features/player/fluid_background.dart` 在 Phase 4 被替换后删除(干净切换,不留别名)。

**注意(与审计一致,避免实现时假设能力已存在)**:当前 `main.dart` 把 `themeMode` 硬编码为 `ThemeMode.system`,密度由 `platformVisualDensity(defaultTargetPlatform)` 推导,**不存在任何主题/外观设置状态**。因此「外观设置」是**新增能力**,实现方式为:

- 新增 `lib/data/settings_store.dart`:应用级偏好(JSON 文件,位于 `getApplicationSupportDirectory()`),字段 `{themeMode, density, coverTint}`;不含敏感信息(敏感信息继续走 `secure_store`)。
- 新增 `preferencesProvider`(Riverpod `AsyncNotifier`),`main.dart` 读它并构造 `MaterialApp(themeMode: …, theme: TyTheme.build(light, density), darkTheme: TyTheme.build(dark, density))`。
- 这是**纯新增**、无 schema 改动、不触碰同步/播放/数据库契约。

---

## 2. 色彩系统

### 2.1 设计原则

- **中性色与品牌色解耦**:中性灰是冷灰(略偏蓝),**不含任何红色分量**——修正 V1「粉色米白」。封面是页面上唯一的高彩度物体。
- **品牌红只作强调**:播放中、选中、进度、主按钮、焦点环。绝不用于大面积背景。
- **深色用亮度分层,浅色用描边分层**:深色下禁用装饰性阴影(V2);浅色下阴影只给"浮起层"。

### 2.2 浅色主题

| Token | 值 | 用途 | 实测对比度 |
|---|---|---|---|
| `canvas` | `#F7F7F9` | 窗口底色 | — |
| `surface` | `#FFFFFF` | 卡片/面板/列表底 | vs canvas 1.07(靠描边区分) |
| `surfaceSunken` | `#F1F1F4` | 输入框/分段控件槽/chip 底 | vs surface 1.13 |
| `surfaceHover` | `textPrimary @ 4%` → `#EEEEF0`(canvas 上) | 行/卡 hover | — |
| `surfacePressed` | `textPrimary @ 8%` → `#E5E5E7` | 按下 | — |
| `surfaceSelected` | `accent @ 8%` → `#FCEDEF` | 选中行/选中导航 | 其上正文 15.9:1 |
| `border` | `#E4E4EA` | 1px 分隔/卡片描边 | vs canvas 1.18(仅结构性) |
| `borderStrong` | `#D3D3DC` | 输入框描边/聚焦前 | vs canvas 1.51 |
| `textPrimary` | `#16161A` | 标题/正文 | canvas 16.9 / surface 18.0 |
| `textSecondary` | `#5A5A66` | 次信息(艺术家、计数) | 6.35 / 6.80 |
| `textTertiary` | `#6A6A76` | 第三级元数据、时间 | 4.99 / 5.34 / sunken 4.73 |
| `textDisabled` | `#A0A0AC` | 禁用 | 2.42(豁免) |
| `accent` | `#D81E32` | 主按钮底、进度、播放中、焦点环 | 4.73 / 5.06;白字在其上 5.06 |
| `accentHover` | `#C0182B` | hover | 白字 6.16 |
| `accentPressed` | `#A81226` | 按下 | — |
| `accentSoft` | `accent @ 12%` → `#FAE4E6` | 选中底、徽标底 | 其上正文 14.9 |
| `onAccent` | `#FFFFFF` | 强调底上的文字 | 5.06 |
| `success` | `#1C7A4A` | 同步成功、已连接 | 4.99 |
| `warning` | `#96560A` | 需注意 | 5.40 |
| `danger` | `#B32219` | 失败、危险操作 | 6.21 |
| `focusRing` | `accent`(2px + 2px offset) | 键盘焦点 | 5.06 |
| `scrim` | `#000000 @ 40%` | 模态遮罩 | — |
| `skeletonBase` / `skeletonHighlight` | `#EAEAF0` / `#F5F5F8` | 骨架屏 | 层次 1.08 |
| `coverPlaceholder` | `#E7E7EC` + `textTertiary` 音符 | 缺封面 | 音符 4.5 |

### 2.3 深色主题

| Token | 值 | 用途 | 实测对比度 |
|---|---|---|---|
| `canvas` | `#0C0C0F` | 窗口底色 | — |
| `surface` | `#141418` | 面板/列表底 | vs canvas 1.06 |
| `surfaceRaised` | `#1B1B21` | 卡片、传输条、检查器 | vs canvas 1.14 / vs surface 1.07 |
| `surfaceOverlay` | `#232329` | 菜单/浮层/对话框 | vs surface 1.18 |
| `surfaceHover` | `#FFFFFF @ 6%` → `#222226` | 行/卡 hover | 其上 accent 5.29 |
| `surfacePressed` | `#FFFFFF @ 10%` → `#2C2C2F` | 按下 | — |
| `surfaceSelected` | `accent @ 14%` → `#2F1E24` | 选中 | 其上正文 14.4 |
| `border` | `#2A2A33` | 1px 分隔 | vs canvas 1.37 |
| `borderStrong` | `#3A3A45` | 输入框/选中描边 | vs surface 1.64 |
| `textPrimary` | `#F4F4F7` | 标题/正文 | canvas 17.8 / surface 16.7 |
| `textSecondary` | `#A6A6B3` | 次信息 | 8.12 / 7.64 |
| `textTertiary` | `#8C8C99` | 第三级 | 5.88 / 5.53 / raised 5.16 |
| `textDisabled` | `#5A5A64` | 禁用 | 2.87(豁免) |
| `accent` | `#FF5C6E` | 强调(深底提亮) | 6.52 / 6.13;`onAccent` 用 `#0C0C0F` = 6.52 |
| `accentHover` | `#FF7A89` | hover | — |
| `accentPressed` | `#E8455A` | 按下 | — |
| `accentSoft` | `accent @ 14%` → `#2F1E24` | 选中底 | — |
| `success` / `warning` / `danger` | `#5BD98F` / `#F0B45C` / `#FF7066` | 状态 | 10.9 / 10.6 / 7.2 |
| `scrim` | `#000000 @ 60%` | 遮罩 | — |
| `skeletonBase` / `skeletonHighlight` | `#1E1E24` / `#2A2A32` | 骨架 | — |
| `coverPlaceholder` | `#22222A` | 缺封面 | — |

深色下**不使用投影**;浮层靠 `surfaceOverlay` + `border` 表达。仅模态遮罩使用 `scrim`。

### 2.4 语义状态规则

| 状态 | 视觉 |
|---|---|
| 播放中行 | 左侧 3px `accent` 竖条 + 曲名 `accent` + 序号位换成 4 条跳动音柱(播放时动画,暂停时静止) |
| 选中行(多选) | `surfaceSelected` 底 + 行首复选框勾选;与播放中可叠加 |
| 选中导航项 | `accentSoft` 底 + `accent` 文字 + 桌面侧栏追加 3px 左侧圆角条 |
| 收藏(♥) | 未收藏:`textTertiary` 描边心;已收藏:`accent` 实心 |
| 危险操作 | `danger` 文字/描边按钮 + 二次确认对话框(标题/说明/破坏性按钮) |
| 加载 | 骨架块(禁止转圈) |
| 失败 | `danger` 图标 + 说明 + 重试按钮(`TyErrorView`) |
| Hover(桌面) | `surfaceHover`;行内操作键在 hover 时淡入(120ms) |
| Focus(键盘) | 2px `focusRing` + 2px offset,圆角跟随组件 `r-sm` |

### 2.5 封面动态取色(舞台背景)

要求:柔和、稳定、可读、低开销(P1 的替代实现)。

1. 只对**本地封面文件**取色(`coverFileProvider` 解析出的文件):`ImmutableBuffer.fromFilePath` → `ImageDescriptor.encoded(targetWidth: 24)` → `toByteData(rawRgba)`。`Image.file(cacheWidth:)` 不给像素,**不能**做为取色来源;远端 URL 未落盘时直接用中性渐变,不为取色额外下载。
2. 丢弃 L<0.08、L>0.92、S<0.08 的像素;剩余 <20% → 判定"灰封面",回退中性渐变。
3. 12 桶色相直方图 → 主色 = 峰值桶平均 HSL;次色 = 与主色色相差 ≥24° 的次峰(无则主色旋转 +18°)。
4. 钳制:`S ∈ [0.28, 0.46]`;`L` 浅色主题 `[0.72, 0.84]`,深色主题 `[0.10, 0.18]`(比 canvas `#0C0C0F` 略亮,保持"暗夜微光")。
5. 舞台背景 = 主色→次色 160° 线性渐变 + 一层 `canvas @ 35%` 压平;**必须**保证 `textPrimary` 在其上最差点 ≥ 7:1(不达标则按 5% 步长下调亮度直到达标)。
6. 单层 `Container` 渐变,禁止多渐变圆叠加;漂移动效只插值渐变起止点(见 §7)。
7. 缓存:键 = **本地文件绝对路径 + mtime + 目标尺寸**,LRU 64;提取在 isolate(`compute`)里;异常回退中性渐变。结果只接受**当前曲目**的:快速切歌时旧结果必须按 trackId 丢弃,不能涂到新封面上。
8. 设置项「封面动态取色」关闭、或曲目没有本地封面 → 中性渐变(深色 `#101014→#17171C` / 浅色 `#F0F0F4→#E7E7EC`)。`MediaQuery.disableAnimationsOf` 为真时**保留**已缓存的静态主/次色,只停止漂移与交叉渐变——减少动态不等于抹掉配色。

---

## 3. 间距、圆角、尺寸、层级

### 3.1 间距(TySpace,4pt 网格)

`2, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48, 64`

| 场景 | 值 |
|---|---|
| 图标与文字 | 6(紧凑)/ 8(常规) |
| 列表行水平内边距 | 桌面 16 / 移动 12(行首)/ 16(行尾) |
| 页面水平留白 | compact 20 / medium 24 / expanded 32 |
| 卡片内边距 | 12(网格卡)/ 16(功能区卡) |
| 区块之间 | 24(同页分组)/ 40(不同区块) |
| 页头到内容 | 20 |
| 网格间距 | 20(expanded)/ 16(medium)/ 12(compact) |
| 面板内边距 | 16 |

### 3.2 圆角(TyRadius)

| Token | 值 | 用途 |
|---|---|---|
| `xs` | 4 | 小徽标、内联缩略图、checkbox |
| `sm` | 8 | 按钮、输入框、菜单项、chip、焦点环 |
| `md` | 10 | 菜单/浮层容器、网格封面 |
| `lg` | 14 | 面板、对话框、编排卡 |
| `xl` | 20 | 舞台封面、底部抽屉顶部 |
| `full` | 999 | 胶囊按钮、头像、圆形控件 |

### 3.3 尺寸(TySize)

| 控件 | compact(触控) | medium | expanded(指针) |
|---|---|---|---|
| 行高(列表) | 56 | 52 | 48 |
| 表格行高 | — | 48 | 44(紧凑密度 40) |
| 侧栏/导航行 | 44 | 40 | 32 |
| 按钮高 | 44(主)/ 36(次) | 40 / 34 | 36 / 32 |
| 图标按钮命中区 | 44 | 36 | 32(视觉 20) |
| 搜索框高 | 44 | 40 | 36 |
| chip 高 | 32 | 30 | 28 |
| 分段控件高 | 36 | 34 | 32 |
| 传输条高 | — | 72 | 88 |
| 迷你条高 | 56 | 60 | — |
| 舞台封面边长 | `min(width-40, height*0.42)` | 同 | `min(420, height*0.5)` |
| 详情页封面 | 160 | 200 | 220 |
| 表格封面 / 列表封面 | 44 | 40 | 40 |

### 3.4 图标(TyIconSize)

`14`(徽标内)/ `16`(行内紧凑)/ `20`(默认,行内操作)/ `24`(工具栏、导航)/ `28`(次级传输)/ `56`(播放主控的圆形底,图标 24)。

### 3.5 阴影(TyElevation,仅浅色)

| Token | 值 | 用途 |
|---|---|---|
| `flat` | 无 + 1px `border` | 列表、卡片 |
| `popover` | `0 4 16 rgba(0,0,0,.10)` | 菜单、tooltip、右键菜单 |
| `sheet` | `0 12 32 rgba(0,0,0,.14)` | 对话框、底部抽屉 |
| `palette` | `0 20 48 rgba(0,0,0,.18)` | 命令面板 |

深色:全部替换为 `border` + 更亮的 surface 层。

### 3.6 层级(z 轴顺序)

内容 → 传输条/迷你条 → 检查器面板 → 舞台(`/stage`) → 命令面板 → 对话框/菜单 → SnackBar。

---

## 4. 排版

### 4.1 字体栈(零体积方案,不打包字体文件)

`fontFamily` 留空(使用各平台系统字体),显式提供 CJK/Latin 回退链,避免三端观感分裂(V5):

| 平台 | fontFamilyFallback |
|---|---|
| macOS | `PingFang SC`, `Helvetica Neue`, `Arial Unicode MS` |
| iOS | `PingFang SC`, `Helvetica Neue` |
| Windows | `Segoe UI Variable Text`, `Segoe UI`, `Microsoft YaHei UI`, `Microsoft YaHei` |
| Android | `Roboto`, `Noto Sans CJK SC`, `Noto Sans SC` |
| Linux | `Noto Sans`, `Noto Sans CJK SC`, `DejaVu Sans` |

规则:
- **`letterSpacing: 0`**(除 `labelS`);M3 的拉丁字距(0.5/0.25)在中英混排下过散,统一清零(V4)。
- 时间/计数/序号使用 `FontFeature.tabularFigures()`,保证跳动时不抖。
- 中英混排不加人工空格;长标题 1 行省略 + tooltip 全文。
- 禁止在业务代码里出现 `TextStyle(...)` 字面量,必须取 `ty.type.*`。

### 4.2 Type Scale(TyType)

| Token | size / weight / height / ls | 用途 |
|---|---|---|
| `displayL` | 40 / 700 / 1.20 / 0 | 舞台曲名(超长降级 `displayM`) |
| `displayM` | 32 / 700 / 1.25 / 0 | 详情页主标题(专辑/艺人/歌单) |
| `titleXL` | 26 / 600 / 1.30 / 0 | 页面标题(歌曲/专辑/搜索结果) |
| `titleL` | 20 / 600 / 1.35 / 0 | 面板标题、对话框标题、舞台曲名(compact) |
| `titleM` | 17 / 600 / 1.40 / 0 | 分组标题、卡片标题、设置分组名 |
| `bodyL` | 16 / 400 / 1.60 / 0 | 舞台艺术家、说明段落 |
| `bodyM` | 15 / 400 / 1.50 / 0 | 曲目名、正文、菜单项 |
| `bodyS` | 13 / 400 / 1.50 / 0 | 专辑名、年份、计数、来源状态行 |
| `labelL` | 15 / 500 / 1.40 / 0 | 按钮、分段控件当前项 |
| `labelM` | 13 / 500 / 1.40 / 0 | chip、导航标签、次级按钮 |
| `labelS` | 11 / 600 / 1.30 / 0.3 | overline / 徽标(仅短标签) |
| `numericM` | 15 / 500 / 1.40 / 0 + tabular | 时长、进度时间 |
| `numericS` | 13 / 500 / 1.40 / 0 + tabular | 列表计数、徽标数字 |

层级纪律(修 V4):**正文默认 `bodyM`,元数据默认 `bodyS`,标题只用 `titleM` 及以上**;`bodySmall`/`labelSmall` 级别的"通用小字"不再承担标题职责。

---

## 5. 响应式与密度

### 5.1 断点

| FormFactor | 宽度 | 外壳 | 播放器 | 网格 minTile / gap | 页面留白 |
|---|---|---|---|---|---|
| `compact` | < 640 | 底部 4 Tab(导航高 64)+ 迷你条 | `TyMiniPlayer` | 140 / 12 | 20 |
| `medium` | 640–1023 | NavigationRail 88(图标+标签) | `TyTransportBar`(72,仅音量) | 152 / 16 | 24 |
| `expanded` | ≥ 1024 | 侧栏 248(可折叠为 72) | `TyTransportBar`(88,全功能)+ 检查器 | 168 / 20 | 32 |

- 网格列数:`cols = max(2, floor((w - 2*pad + gap) / (minTile + gap)))`;不做固定列数(V6/A2)。
- 表格列:expanded 显示 `# / 标题 / 专辑 / 时长 / ♥ / ⋯`;medium 隐藏「专辑」列;compact 使用列表形态。
- 内容最大宽度:详情页 1200(超出居中,两侧留白);列表不限宽但行内容右侧对齐。
- 窗口软下限:360×480;更窄时显示居中提示页(`TyErrorView` 语义:窗口过小 + 当前尺寸),不崩版(I13)。不申请原生最小尺寸(需要窗口管理依赖,且会挡住 `compact` 形态与调试手机外壳);`compact` 在 360–639 宽度下必须完整可用。
- 面板/检查器:仅 `expanded` 可用(320–380px);`medium` 与 `compact` 用抽屉/全屏页承载同一组件。

### 5.2 密度开关

设置项「密度:舒适 / 紧凑」影响 `TySize` 的行高与间距一档(48↔40 行高、16↔12 内边距);`compact` 形态忽略紧凑密度(触控最小 44px 硬约束)。

---

## 6. 组件规范

命名统一 `Ty` 前缀。每个组件都要实现「默认 / hover / pressed / focus / selected / disabled」中适用的状态(§2.4)。

### 6.1 结构与容器

| 组件 | 规格 |
|---|---|
| `TyAppShell` | 唯一外壳:决定 sidebar/rail/bottomnav + 运输条 + 检查器宿主;`Scaffold` 之外无自定义窗口装饰 |
| `TySidebar` | 宽 248 / 折叠 72;分组标题 `labelM + textTertiary`,行 32;顶部搜索框(点击 → `/search` 或 ⌘K);底部固定「设置 / 来源状态点」;可拖拽分栏 200–360 |
| `TyNavRail` | 宽 88;图标 24;选中 = `accentSoft` 底 + `accent`。内容 = 四个曲库段(歌曲/专辑/艺术家/歌单),底部固定「收藏 / 设置」;「最近添加」按规范是排序,入口在歌曲页的排序菜单里 |
| `TyBottomNav` | 高 64 + `SafeArea`;4 项;图标 24 + `labelM`;选中 = `accent` 图标/文字 + 顶部 2px `accent` 指示条 |
| `TyPageHeader` | 标题 `titleXL` + 可选副标题 `bodyS` + 右侧动作槽;支持 `sliver` 版本 |
| `TySectionHeader` | 标题 `titleM` + 可选计数 `bodyS` + 右侧「全部 →」`labelM` |
| `TyDetailHero` | 封面(§3.3)+ 标题 `displayM` + 元数据行(`bodyS`,·分隔)+ 动作行;compact 垂直堆叠,expanded 水平 |
| `TyPanel` | 检查器/抽屉容器:`surfaceRaised` + `border`(仅内侧)+ 圆角 `lg`(内嵌时);头部 48 高 |
| `TyInsetGroup` | 设置/表单分组容器:`surface` + `border` + `lg`,行之间 1px 分隔 |

### 6.2 列表与表格

| 组件 | 规格 |
|---|---|
| `TyTrackTable` | 桌面表格:列头 32 高(`labelM`,`textTertiary`,可点排序,排序态显箭头);行高 §3.3;`itemExtent` 固定(修 P2);列宽:标题 flex、专辑 flex(可关)、时长 64 右对齐、♥ 40、⋯ 32 |
| `TyTrackList` | compact 列表:封面 44 + 曲名 `bodyM` + 艺术家 `bodyS`;行高 56;右侧 ♥ + ⋯ |
| `TyTrackRow` | 共有逻辑:封面、序号/音柱、播放中语义、hover 操作键、上下文菜单、多选、收藏;`onTap` 语义由宿主注入(表格单击=选中/双击=播放;列表单击=播放) |
| `TyAlbumCard` | 封面(`md` 圆角 + 1px `border`)+ 标题 `bodyM` 1 行 + 艺术家 `bodyS` 1 行;hover:封面浮起 2px + 中央播放圆钮(chrome)+ 右上 ⋯ |
| `TyArtistRow` | 头像 44(`full`)+ 名称 `bodyM` + 「N 张专辑 · M 首」`bodyS` + chevron 16 |
| `TyPlaylistCard` | 2×2 封面拼贴(`md`)+ 名称 + 「N 首」;首个网格位为「新建歌单」 |
| `TyHighlightedText` | 搜索命中高亮:按**原文子串**匹配(不做大小写之外的必要归一化),命中段 `accent`;空查询原样返回,不额外包一层 `Text.rich` |
| `TyTrackTable` / `TyTrackList` 的 `rowBuilder` | 宿主自建行时把「这一行是不是正在播放」的订阅放进**行自己**里(`features/shared/playback_track_row.dart`):进度 tick 一行都不重建,换曲只重建高亮翻转的两行。不传则用内置行,播放态由 `playingTrackId` / `playing` 给 |
| `TyQueueView` | 两段:`正在播放` / `接下来`;行 48;点击行跳转(`playAt`);显示播放中/收藏态;不做拖拽/移除/清空(引擎重建会打断播放,见 `docs/UX_REDESIGN.md` §4.1) |

### 6.3 播放器

| 组件 | 规格 |
|---|---|
| `TyTransportBar` | 高 §3.3,`surfaceRaised` + 上边 1px `border`;**队列为空时整条收起**;左:封面 56(`sm` 圆角,hover 显浮起)+ 曲名 `bodyM`/艺术家 `bodyS`(点击 → `/stage`)+ ♥;中:传输行(随机 / 上一 / 播放主控 36 圆形 / 下一 / 重复)+ 进度行(时间 `numericM` / 进度条 / 时长);右:歌词、队列、音量(展开时 96px 滑条,默认静音图标点击展开);失败时整条替换为 `TyErrorView` 内联态(修 I8) |
| `TyMiniPlayer` | 高 `metrics.miniPlayerHeight`,`surfaceRaised` + 顶部圆角 `xl` + 上边 2px 进度线(**由宿主的 `progressLine` 槽给**,进度 tick 只重建那一行);左封面 40 + 曲名/艺术家(1 行)+ ♥ + 播放/暂停 + 下一;点击 → 舞台(Hero 封面);长按 → 快捷菜单 |
| `TyPlayerStage` | 结构:背景(§2.5)→ 封面(§3.3,圆角 `xl`,无阴影)→ 曲名 `displayL`/`titleL` → 艺术家 `bodyL`(可点进艺人)→ 专辑 `bodyS` → 进度(`TySeekBar` + 两侧 `numericM`)→ 传输行(随机 24 / 上一 32 / 播放主控 56 圆形 / 下一 32 / 重复 24)→ 次级行(♥、歌词、队列、音量);expanded 两栏(左:封面+控制,右:歌词或队列 380);关闭:Esc / 顶部左箭头。**布局纪律**:控件固定在下缘,封面/标题占满剩余空间(内部自己滚动);**不得**用 `IntrinsicHeight` 或 `SliverFillRemaining(hasScrollBody: false)` —— 它们要问子树固有高度,而 `TySeekBar` 内的 `LayoutBuilder` 答不了,会直接抛 performLayout 断言 |
| `TySeekBar` | 高 4(默认)/ 8(hover-drag);已播放 `accent`、缓冲 `accent @ 30%`、剩余 `borderStrong`;拖拽时手柄 12px + tooltip 显示时间;点击跳转;键盘 `←/→` ±5s、`⇧←/→` ±30s(焦点态) |
| `TyVolumeControl` | 图标按钮 + 展开滑条(96px);静音切换(音量 0 ↔ 上次非零值);图标随音量档位变化;不做输出设备选择(引擎无设备枚举,只读后端名放设置页诊断行) |
| `TyLyricsView` | 当前行 `titleL` + `accent`,其他行 `bodyL` `textSecondary`;**点击行跳转**;手动滚动后 3s 内不自动回拉;无歌词 → `TyEmptyState`(「未找到歌词」+「重新匹配」);`disableAnimations` 时行高亮不动画 |

### 6.4 输入与反馈

| 组件 | 规格 |
|---|---|
| `TySearchField` | 高 §3.3,`surfaceSunken` + `sm`;左放大镜 20 + 清空按钮(有内容时);聚焦态 1px `borderStrong`;输入时**不吞空格**(I2);`⌘F` 聚焦当前视图搜索框 |
| `TyCommandPalette` | 居中 640 宽,`surfaceOverlay` + `palette` 阴影;输入框 56 + 结果列表(分组 28 头 + 行 44);↑↓/Enter/Esc;显示快捷键提示;空查询显示「最近播放」与「快捷入口」 |
| `TyButton` | 变体:`primary`(`accent` 底 + `onAccent` 字)/ `secondary`(`surface` + `borderStrong` 描边)/ `ghost`(透明 + hover `surfaceHover`)/ `danger`(`danger` 描边或填充)/ `pill-play`(`accent` 胶囊 + 播放图标 + 「播放」);高度 §3.3 |
| `TyIconAction` | 图标按钮:视觉 20,命中 32/44;必带 tooltip + `Semantics(label)` |
| `TyChip` / `TyFilterChip` | 高 §3.3;选中 = `accentSoft` + `accent` 文字 + 无描边;未选 = `surface` + `border` |
| `TySegmentedControl` | 槽 `surfaceSunken` + 指示块 `surface`(`sm`,200ms 滑动);选中文字 `labelL` `textPrimary`,未选 `labelL` `textSecondary` |
| `TySortMenu` | 菜单元数据 `labelM`;当前项勾选 `accent`;支持 `?sort=` 同步 |
| `TyContextMenu` | 桌面:浮层(圆角 `md`,`popover`,最小宽 220,行 36,分隔线 1px,危险项 `danger`);移动:bottom sheet 同项同序 |
| `TyDialog` | 宽 420(表单 480),标题 `titleL`,正文 `bodyM`,动作右对齐;危险操作主按钮 `danger`;必填表单逐字段 `errorText`(I11) |
| `TySheet` | 移动端底部抽屉:顶部 `xl` 圆角 + 抓手;最大高 90%;可下拉关闭 |
| `TySnack` | 底部居中(桌面)/ 迷你条上方(移动);`bodyM` + 可选动作;**不得**用于承载错误详情(用 `TyErrorView` 或对话框) |
| `TyTooltip` | 400ms 延迟;`surfaceOverlay` + `bodyS` |
| `TyProgressBar` | 线性,高 4/6;`accent` 前景 + `borderStrong` 底;用于扫描/同步,支持不定态(1.2s 循环) |
| `TyBadge` | 高 20,`sm` 圆角,`accentSoft` + `accent` 文字 `labelS`;用于「失败 3」「新增 12」 |
| `TySourceCard` | 类型徽标 + 名称 `titleM` + 状态行 `bodyS`(状态点 8px:success/warning/danger)+ 右对齐主操作(同步/重试/重新登录)+ ⋯ 菜单 |
| `TySettingsRow` | 高 56:标签 `bodyM` + 说明 `bodyS` + 控件右对齐;`SwitchRow` / `SelectRow` / `NavRow` / `ActionRow` 四种变体 |

### 6.5 状态与骨架

| 组件 | 规格 |
|---|---|
| `TyAsyncView<T>` | 统一四态:loading → 骨架(依据 `skeleton` 参数选择 row/grid/hero 形态);error → `TyErrorView`;empty → `TyEmptyState`;data → builder |
| `TySkeleton` | 列表:12 行(封面块 + 两条文本块);网格:按列数 3 行;用 §2.2/2.3 的 base/highlight 做 1.4s 微光(禁用动态时静止) |
| `TyEmptyState` | 图标 48 `textTertiary` + 标题 `titleM` + 说明 `bodyS`(≤2 行,自动省略)+ 主操作按钮;用于空库、无搜索结果、无歌词、无歌单 |
| `TyErrorView` | `danger` 图标 + 标题 `titleM` + 详情 `bodyS`(可展开)+ 重试按钮 + 可选「查看详情/复制诊断」 |
| `TyCover` | 唯一封面组件:统一尺寸解码(cacheWidth)、缺封面占位(确定性色 + 音符)、圆角参数、`RepaintBoundary`;`TyAvatar` 是它的圆形变体 |

---

## 7. 动效

### 7.1 Token

| 时长 | 值 | 曲线 | 值 |
|---|---|---|---|
| `micro` | 90ms | `standard` | `Cubic(0.2, 0.0, 0.0, 1.0)` |
| `fast` | 120ms | `decelerate` | `Cubic(0.05, 0.7, 0.1, 1.0)` |
| `base` | 200ms | `accelerate` | `Cubic(0.3, 0.0, 0.8, 0.15)` |
| `slow` | 320ms | `linear` | `Curves.linear`(进度/骨架) |
| `ambient` | 24000ms | — | — |

### 7.2 命名过渡(全部来自 `lib/design/motion/transitions.dart`)

| 名称 | 行为 | 参数 |
|---|---|---|
| `pressFeedback` | 按下缩放 0.97 + overlay 8% | 90ms / standard |
| `hoverReveal` | 行内操作键淡入 | 120ms / decelerate |
| `fadeThrough` | 曲库分段切换 | 旧 60ms 淡出,新 200ms 淡入 + 8px 上移 |
| `stageExpand` | 迷你条/传输条 → 舞台 | 320ms;封面 Hero 共享元素;背景 200ms 淡入;内容 16px 位移 + 淡入 |
| `stageCollapse` | 舞台 → 迷你条 | 手势 1:1 跟随,越过 35% 阈值后按速度决定收起/回弹 |
| `coverMorph` | 换曲封面交叉淡入 | 180ms / decelerate |
| `ambientDrift` | 舞台背景极缓漂移(渐变起止点插值) | 24s 循环;`disableAnimations` 静止 |
| `listStagger` | 列表首屏前 6 项 20ms 递增淡入 | 200ms;滚动中禁用 |
| `lyricFocus` | 歌词行高亮 | 240ms / standard(透明度 + `translateY(-2)`),不做缩放跳变 |
| `barCollapse` | 队列为空时传输条收起 | 200ms / standard(高度 + 透明度) |
| `sheetSlide` | 移动端抽屉/上下文菜单 | 240ms / decelerate |

### 7.3 约束

- 任何动画都不得触发列表整体重建(`ui_rebuild_seek_test.dart` 的断言必须继续通过)。
- 滚动进行中禁止 `listStagger` 与骨架微光重排。
- `MediaQuery.disableAnimationsOf(context) == true` 时:所有过渡时长按 0 处理(仅保留必要的即时切换),背景静止。
- 舞台背景单层重绘(`RepaintBoundary`),禁止 `willChange: true` 与多渐变圆(P1)。

---

## 8. 无障碍

1. **触控/命中**:compact ≥ 44×44;medium ≥ 40×40;expanded ≥ 36×36(表格行内小按钮可 32 视觉 + 4px 命中扩展,但命中区不得小于 36);传输主控 ≥ 48。命中区由 `TyMetrics.hitTarget` 统一给值,**不随密度开关缩小**。
2. **对比度**:正文 ≥ 4.5:1,大字与图标 ≥ 3:1,均已实测(§2.2/2.3)。禁用态豁免但不得用于承载信息。
3. **语义**:
   - 所有纯图标控件:`tooltip` + `Semantics(label)` + `Semantics(button: true)`;
   - 行:`Semantics` 合并为「曲名 · 艺术家 · 时长`(+` · 播放中`)」,并提供 `onTap`/`onLongPress` 语义动作;
   - `TySeekBar`:`Semantics(value: '1:23 / 4:05', increasedValue/decreasedValue)` 且支持键盘;
   - 同步/扫描进度:`Semantics(liveRegion: true, value: '已扫描 128 / 540')`;
   - 播放状态变化:迷你条/传输条用 `Semantics(liveRegion: true)` 播报「正在播放 X」。
4. **焦点**:焦点顺序 = 视觉顺序;`FocusTraversalGroup` 分层(导航 / 内容 / 传输条 / 面板);模态层焦点陷阱 + `Esc`;焦点环可见且不被裁剪;命令面板全键盘可用。
5. **减少动态**:见 §7.3;`disableAnimations` 下不出现"漂移"与"步行音柱"。
6. **文本**:不使用丝带图标表意;文案中文优先、术语一致(「歌曲/专辑/艺术家/歌单/来源/队列/歌词」);数字单位与中文间按现有习惯留半角空格。
7. **验证工具**:沿用 `tools/windows-accessibility-probe.ps1` 做 Windows 端语义树抽查;`flutter test` 中断言关键 `Semantics` 标签存在。

---

## 9. 测试与回归网(Phase 4 首先落地)

| 文件 | 职责 |
|---|---|
| `test/support/pump.dart` | `pumpTyApp(tester, {required Widget home, Size size, Brightness brightness, TyDensity density, List<Override> overrides, Locale locale})`:注入表面尺寸、主题、`TyLayoutScope`、可选 provider overrides;另有 `metricsFor(size)` |
| `test/support/fake_audio_engine.dart` | `FakeAudioEngine`(可控播放/暂停/seek/失败注入 + 调用计数),供播放器类测试使用 |
| `test/support/page_harness.dart` | 页面级测试脚手架:`pumpPage` / `pumpRoutedPage`(带 `GoRouter`)、固定曲目与假播放控制器、内存凭证存储;**冻结动画**(骨架/音柱/漂移是永久动画,不关掉 golden 与截图永远不稳定) |
| `test/design_guard_test.dart` | §0.5 的机械守卫(含 `test/fixtures/guard/` 正反样例) |
| `test/form_factor_test.dart` | 三个断点的外壳选择、网格列数、表格列可见性;窗口从 expanded 缩到 medium 后 rail 的目的地仍全在可见范围内 |
| `test/design_system_render_test.dart` | 三形态 × 浅深主题渲染;**平台能力分支(hover / 触控常显 / 主修饰键)必须在这里覆盖** —— 真机只有 Windows 能跑,触控分支没有测试就等于没人跑 |
| `test/async_state_test.dart` | 四态渲染与重试回调 |
| `test/now_playing_layout_test.dart`、`test/transport_row_layout_test.dart` | 舞台竖向排布与传输行等距分布;舞台文本必须落在真实 `DefaultTextStyle` 里(真机曾出现 MaterialApp fallback 的黄下划线) |
| `test/ui_rebuild_seek_test.dart` | 进度 tick 的重建口径:列表行/封面/标题零重建,换曲只重建高亮翻转的两行;拖动只在松手时 seek 一次 |
| `test/golden/core_pages_golden_test.dart` | 标记 `@Tags(['golden'])`,**仅在本机(Windows 参考渲染)生成与校验**;CI 必须执行 `flutter test --exclude-tags golden`(`dart_test.yaml` 里已配置排除),否则 Linux 字体栈会造成假失败。覆盖 12 张:曲库(expanded 深色 / compact 浅色)、专辑网格、专辑详情、搜索(空查询 / 有结果)、队列面板、歌词空态、舞台(compact 深色)、设置、来源管理、来源详情。生成:`flutter test --run-skipped -t golden --update-goldens`;校验:`flutter test --run-skipped -t golden`。
| `test/performance_regression_test.dart` | 结构级性能回归:2000 首列表只构建可见行且可滚动;舞台漂移背景 60 帧内不重建舞台内容与封面 |
| `test/quark_login_render_test.dart` | 扫码 / 网页登录页的三形态 × 两主题 × 三态渲染(登录页平时没人截图,容易悄悄退化) |

规则:
- 与旧 UI 结构耦合、已按新结构改写的测试:
  `ai_settings_page_test.dart`、`navigation_gesture_test.dart`、`now_playing_layout_test.dart`、`router_path_parameters_test.dart`、`search_page_test.dart`(原 `library_mobile_search_test.dart`)、`search_debounce_test.dart`、`theme_density_test.dart`、`transport_row_layout_test.dart`、`ui_rebuild_seek_test.dart`、`form_factor_test.dart`。
  改写时**保留原有覆盖强度**(例如 `ui_rebuild_seek_test` 的“进度更新不得重建列表行”必须继续断言),不得删除业务断言,不得放宽阈值。
- Widget 测试的收尾规则:页面背后的数据要么用 provider 覆盖,要么用内存 drift 库;测试结束前调 `unmountApp(tester)`(先拆树再断言定时器),不要 `pumpAndSettle`——骨架与音柱是**永久动画**,会一直等下去。需要“等到某个东西出现”时用 `pumpUntil` / `pumpFrames`。
- 业务/数据/播放内核测试一律不动:`webdav_test.dart`、`track_repository_test.dart`、`playback_*`(11 个)、`tingyu_audio_handler_test.dart`、`source_*`、`quark_*`、`local_library_scanner_test.dart`、`metadata_*`、`database_migration_test.dart`、`legacy_import_test.dart` 等。

---

## 10. 禁止事项(供 review 逐条核对)

1. 禁止在 `lib/features/**` 出现颜色/字号/间距/圆角/时长字面量。
2. 禁止在页面层写 `Platform.is*` 决定结构。
3. 禁止两套同名组件(旧页面组件不得与新 `Ty*` 组件并存)。
4. 禁止 `CircularProgressIndicator` 作为页面级加载态(骨架优先;行内同步等瞬时反馈可用小尺寸进度条)。
5. 禁止为"好看"新增依赖(字体、动画、UI 库、状态库)。
6. 禁止改动数据层/同步/播放内核的对外契约(见 `docs/UX_REDESIGN.md` §10.3)。
7. 禁止保留旧路由别名或旧控件副本;迁移即删除。
8. 禁止用 `MediaQuery.of(context).size` 之外的隐式尺寸推断布局(统一走 `formFactorProvider`)。
9. 禁止在 `build` 里做封面解码/取色等重活(必须走 provider + 缓存)。
10. 禁止用动画掩盖真实状态缺失(例:没有失败态就加个转圈)。
11. 禁止交付没有后端的控件:队列不提供移除/重排/清空,播放器不提供输出设备选择,搜索不显示未计算的总数。能力边界见 `docs/UX_REDESIGN.md` §4.1/§10。
12. 禁止用 `Colors.*` 或 `Color(0x…)` 绕过 token;确属实物语义(二维码白底、透明遮罩)必须行内 `// guard-ok: 理由`。
13. 网格瓦片高度只走 `tyTileExtent(context, tile)`(按排版令牌 + `textScaler` 逐行向上取整),禁止各页自算 `childAspectRatio`:差一像素就会裁掉副标题。
14. 舞台这类「控件贴下缘 + 内容占满剩余」的布局,禁止用 `IntrinsicHeight` / `SliverFillRemaining(hasScrollBody: false)`(它们要问子树固有高度,而 `TySeekBar` 里的 `LayoutBuilder` 答不了);用 `Expanded` + 内部滚动。
