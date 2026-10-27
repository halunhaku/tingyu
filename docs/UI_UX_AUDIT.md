# 听屿 3.0 — UI/UX 审计（Phase 1）

> 历史记录：旧 Swift 客户端及其一次性导出工具已从当前工作树清理；下文相关路径描述的是当时的状态。

> 范围：`app/`（现役 Flutter 实现）。`legacy-swift/` 仅作设计语言与能力对照，不参与重构。
> 方法：完整读取 Presentation 层全部 30 个文件 + 主题/路由/外壳/控制器；对主题 token、排版、间距做**实测**（探针测试 + 截图取色）；对交互能力做全库检索计数；在 Windows 真机上启动真实应用并截图核对。
> 所有结论都可回溯到「文件:行」或「实测命令」。文档中 `[推断]` 标记表示由证据推导而非直接观测。

---

## 0. 一句话结论

听屿的业务内核（播放、来源、数据、元数据、歌词）已经相当扎实，**问题几乎全部集中在 Presentation 层**：
没有设计 token 层、没有排版与间距规范、缺乏成体系的桌面交互语汇（自建 hover/快捷键/多选）、播放器缺少沉浸与二次操作、两套外壳按平台硬切而非按窗口尺寸，且核心页面的视觉主体（封面与音乐内容）没有成为主角。

一句话概括现状观感：**Material 3 默认皮肤 + Apple Music 红种子色 + 手写散点的 Flutter 界面**。它与"Premium / Calm / Editorial / Immersive"的产品目标之间的差距是**系统性的**，不是调参可以弥合的。

---

## 1. 事实基线

### 1.1 平台与构建

| 项目 | 事实 | 证据 |
|---|---|---|
| 框架 | Flutter 3.47.2 / Dart 3.13.2，`app/` 为唯一现役实现 | `app/pubspec.yaml:5`、`flutter --version` |
| 声明平台 | macOS / Windows / Linux / Android / iOS（`macos/ windows/ linux/ android/ ios/` 五个平台目录齐全） | `ls app/` |
| Windows 构建前提 | **必须**使用仓库内本地补丁引擎（`LOCAL_ENGINE=host_release`），stock 引擎会崩 | `app/windows/runner/CMakeLists.txt:1-10`、`tools/build-windows-engine.ps1` |
| 本地引擎状态 | 已构建并就绪（`app/build/flutter-engine/checkout/engine/src/out/host_release`，3.1GB，revision 与 manifest 一致 `d3b14c8769…`） | `windows-engine.json`、`git -C … rev-parse HEAD` |
| CI | `flutter analyze` + `flutter test`（Linux）+ 五个平台构建矩阵 | `.github/workflows/flutter.yml` |

**本机（Windows 11，无 Xcode/Android SDK）的验证能力边界**：

| 能力 | 可用性 | 说明 |
|---|---|---|
| `flutter analyze` / `flutter test` | ✅ | 244 个测试 12.6s 全绿（本审计基线） |
| Windows 真机构建 + 运行 | ✅ | 需 `tools/build-windows-engine.ps1 -Stage App`；已用既有 Release 产物实测启动并截图成功 |
| 真机截图 | ✅ | Win32 `SetWindowPos` + `CopyFromScreen`（已有 `tools/windows-smoke-test.ps1` 范式；本次用临时脚本复现成功） |
| 屏幕 DPI | ⚠️ | 本机 150% 缩放：物理 1440×900 ⇒ 逻辑 960×600。桌面大窗排版需用无头渲染补齐 |
| macOS 运行/截图 | ❌ | 本机无 Xcode；仅 CI 能编译（macos-14） |
| Android 运行/截图 | ❌ | 无 Android SDK、无 AVD、无设备 |
| Web 运行 | ❌ | 依赖（drift/media_kit/webview）未配 Web 后端 |

> 结论：**桌面端可在本机做"真机 + 截图"闭环验证；macOS 与 Android 必须靠"尺寸/平台参数化的无头渲染 + 真机截图（用户侧）"替代**。这一点直接决定 Phase 6 的验证方案（见 §9）。

### 1.2 代码规模

| 层 | 文件数 | 行数（约） | 说明 |
|---|---|---|---|
| Presentation（`lib/features/**` + `app/theme.dart` + `app/router.dart`） | 30 | 5.9k | 本次重构主战场 |
| 播放控制器（`lib/app/playback_controller.dart`） | 1 | 572 | 稳定内核，只接不改 |
| 播放引擎与处理器（`lib/playback/**`） | 8 | — | 稳定内核 |
| 数据层（`lib/data/**`，drift + 仓储） | 14 | — | 稳定，接口只读 |
| 来源适配（`lib/sources/**`） | 22 | — | 稳定，接口只读 |
| 测试 | 46 文件 | — | 244 个用例全绿 |

### 1.3 不可破坏契约（重构期间必须保持的公开接口）

| 类别 | 接口 | 消费者 |
|---|---|---|
| 播放控制 | `PlaybackController`：`trackIds / queue / currentItem / items / sourceQueue / queueDisplayIndex / handler`；`playTracks / playAt / togglePlayPause / pause / next / previous / seek / toggleShuffle / cycleRepeatMode / setVolume` | 播放条、迷你条、播放页、队列、测试 |
| 播放状态 | `PlaybackSnapshot`（含 `processing / playing / position / duration / buffered / index / rate / volume / playOrder / repeatMode / failure`）与其**按值相等**语义（进度 tick 不得触发全量重建） | 全部播放 UI + `ui_rebuild_seek_test` |
| 曲库数据 | `TrackRepository`（`watchAll / watchFavorites / watchAlbums / watchArtists / watchBySource / watchById / watchRecentlyAdded / watchSearch / setFavorite / applyEnrichment`）、`PlaylistRepository`、`SourceRepository` | 各页面 provider |
| UI 派生 provider | `allTracksProvider / favoritesProvider / albumsProvider / artistsProvider / sourcesProvider / playlistsProvider / playlistTrackCountsProvider / searchResultsProvider / visibleTracksProvider / recentlyAddedProvider / tracksOfSourceProvider / playlistTracksProvider / artistTracksProvider / albumTracksProvider / trackByIdProvider / sourceByIdProvider / currentTrackRefProvider / currentTrackProvider / isCurrentTrackProvider / playbackProvider / searchQueryProvider / debouncedSearchQueryProvider / sourceSyncProvider / enrichmentServiceProvider / metadataEnricherProvider / artistAvatarStoreProvider / trackResolverProvider / aiSettingsProvider / databaseProvider / coverStoreProvider / secureStoreProvider` | 全部 UI |
| 来源同步文案 | `SourceSyncController` 的状态文案（`已同步（新增…）`、`已取消…`、`部分同步…`） | 来源页/来源详情页 |
| 路由 | `/library /recent /favorites /artists /artists/:name /albums /albums/:artist/:album /playlists /playlist/:id /sources /source/:id /settings /settings/ai /now-playing`；四个 Tab 根路由**不压栈**、二级页 `canPop()==true` | `navigation_gesture_test`、深链规划 |

**允许重写**：`lib/features/**` 全部、`app/theme.dart` 全部、`app/router.dart`（除上表路由语义）、`buildTingyuTheme` 的入参签名、各页面私有 widget。
**禁止改动**：`lib/playback/**`、`lib/data/**`、`lib/sources/**`、`lib/app/playback_controller.dart`、`lib/app/track_resolver.dart`（除非为修复确凿缺陷）。

### 1.4 现有测试对 UI 的锁点（重构前必须处理）

| 测试 | 锁什么 | 纯 UI 重写后 |
|---|---|---|
| `now_playing_layout_test` | 传送器距底 `44±4`、内容列宽 `≤420`、横屏不溢出、`PlaybackControls` 类型 | **必挂** → 断言应改为"控件在可视区内、不溢出、不超出内容列宽"，数值随新设计重定 |
| `transport_row_layout_test` | 5 键等距 `<1dp`、播放键居中 `±0.5`、左右对称、`iconSize` 关系、`≥48dp` 触控、tooltip 文案、`IconButton.iconSize`/`FilledButton` 类型 | **必挂** → 保留「等距/对称/≥48dp 触控」三条**原则**，重写为新组件的等价断言 |
| `ui_rebuild_seek_test` | 按 `runtimeType` 计重建次数（`TrackRow`/`CoverArt`/`MiniPlayer`/`PlayerBar`/`SeekBar`/`_QueueRow`） | **多半挂** → 必须保留"进度 tick 不重建行/封面"的性能不变量，改按新组件类型与新类名断言 |
| `library_mobile_search_test` | 移动端搜索框 hint、`清除搜索` tooltip、`Theme.platform` 分支 | 文案/控件不变则不挂 |
| `ai_settings_page_test` | `Switch` 类型 + 8 处中文文案 + 入口标题 | 同上 |
| `playback_failure_listener_test` | 失败提示文案 `「标题」原因`、挂载点 `MaterialApp.builder` | 同上 |
| `navigation_gesture_test` | 四 Tab `canPop()==false`、二级页 `BackButton`、专辑详情页类型 | 保路由语义即可 |
| `theme_density_test` | 桌面 `VisualDensity.compact` / 移动 `standard` | **可挂**（若改密度策略）→ 需按新规范重写 |
| `search_debounce_test` / `router_path_parameters_test` | 纯 provider / 纯路由 | 不受影响 |

**处置原则（写进验收标准）**：不得为了通过而删除测试或降低断言强度。做法是把**被锁死的实现细节**（具体 dp、具体 widget 类型、私有类名）替换为**同等强度的设计不变量**（不溢出、触控目标下限、等距/对称、重建粒度、可达性）；测试数量与"行为覆盖"只增不减。

---

## 2. 现有信息架构

### 2.1 两套外壳

```
桌面 AppShell（platform == macOS/Windows/Linux）
├─ 固定 248px 侧栏：搜索框 → 曲库/最近添加/艺术家/专辑/收藏 → 来源组 → 播放列表组 → 设置
├─ 内容区：路由页面（底部预留 84px 给悬浮播放条）
└─ 底部悬浮 PlayerBar（16/0/16/12，圆角 12，elevation 6）

移动 MobileShell（platform == Android/iOS）
├─ 内容区（SafeArea）
├─ MiniPlayer（56px 实心条，无圆角）
└─ NavigationBar 4 Tab：曲库 / 收藏 / 歌单 / 音乐源
```

- 桌面侧栏为**固定宽度**，无折叠、无开合快捷键（legacy 有 `⌘⌃S` 与 `sidebarToggle`）。
- 移动 Tab 与桌面侧栏**不是同一套 IA**：桌面有「最近添加/艺术家/专辑」，移动把它们降级为曲库页顶部两个 `OutlinedButton`，且**移动端没有"最近添加"**（`mobile_shell.dart:14-19`、`library_page.dart:121-142`）。
- 设置入口有三个位置：桌面侧栏底部、移动曲库页右上角图标、macOS 菜单栏 `⌘,`。
- 「正在播放」是 ShellRoute 内的一个路由页（`/now-playing`）：**桌面进入后侧栏与播放条依然可见**，三套 chrome 同时在屏上（截图可证）。桌面 `<720px` 时会掉进移动形态（`now_playing_page.dart:59`），与平台无关。
- `/source/:id`（来源详情）与 `/library` 都是"曲目列表 + 播放"，职责重叠。

### 2.2 页面清单（14 条路由）

| 路由 | 页面 | 媒体主体 | 注释 |
|---|---|---|---|
| `/library` | 曲库（含搜索、截断提示、最近/收藏复用同页） | 曲目行（40px 封面） | 曲库/最近/收藏共用一个 widget |
| `/artists`、`/artists/:name` | 艺术家列表 / 详情 | 44px 圆头像 / 120px 头像 + 分组 | 详情按专辑分组 |
| `/albums`、`/albums/:artist/:album` | 专辑网格 / 详情 | 150–190px 封面 / 180px 封面 | 唯一网格页面 |
| `/playlists`、`/playlist/:id` | 歌单列表 / 详情 | 无封面（纯列表） | 详情支持拖拽重排 |
| `/sources`、`/source/:id` | 来源管理 / 来源详情 | 图标 + 统计 | 桌面为行、移动为卡片 |
| `/settings`、`/settings/ai` | 设置 / AI 识别 | 信息行 | 设置页无主题/外观/播放选项 |
| `/now-playing` | 正在播放 | ≤360px 封面 + 流体背景 | 桌面右侧可滑出歌词/队列面板 |

---

## 3. 视觉现状（实测）

### 3.1 主题 token 实测值

`buildTingyuTheme` 只做了一件事：`ColorScheme.fromSeed(#FA243C)` + 少量形状覆盖（`theme.dart:19-60`）。

| Token | 浅色 | 深色 | 问题 |
|---|---|---|---|
| `primary` | `#904A48` | `#FFB3B0` | **不是品牌红 #FA243C**；浅色下是暗淡砖红，深色下是淡粉 |
| `primaryContainer` / `secondaryContainer` | `#FFDAD8` / `#FFDAD8` | `#733332` / `#5D3F3E` | 浅色下两者**完全相同** → 选中态与容器态无法区分 |
| `surface` | `#FFF8F7` | `#1A1111` | 全体中性色被红种子染色 |
| `surfaceContainerLow / / High` | `#FFF0EF / #FCEAE8 / #F6E4E3` | `#231919 / #271D1D / #322827` | 层级差极小；深色三级容器亮度 0.011/0.014/0.023，肉眼几乎不可分 |
| `onSurface` | `#231919` | `#F0DEDD` | 深色 `onSurface` 也是暖粉调 |
| `outlineVariant` | `#D7C1C0` | `#534342` | 唯一分隔手段，对比 ~1.2:1 |

**这是"廉价粉米色"观感的根因**：用高饱和红做 seed，M3 会把**所有**中性色推向粉色，同时把强调色本身推离品牌红。

### 3.2 排版实测

主题未定义 `textTheme` / `fontFamily`（探针实测：15 级样式均为 M3 2021 默认值，`fontFamily = Roboto`，`letterSpacing` 为拉丁值 0.5/0.25/0.4）。

```
display 57/45/36 · headline 32/28/24 · title 22/16/14 · body 16/14/12 · label 14/12/11
```

实际用量分布（全库 61 处显式文本样式）：

| 样式 | 次数 | 用途 |
|---|---|---|
| `bodySmall` (12) | **35** | 副标题、元数据、时长、计数、说明、错误信息…… |
| `titleLarge` (22) | 8 | 页面标题 |
| `bodyMedium` (14) | 6 | 曲名、输入框 |
| `titleSmall` (14) | 5 | 分组标题、迷你条标题 |
| `labelSmall` (11) | 4 | 侧栏分组 |
| `titleMedium` (16) | 3 | 卡片名、空态标题 |
| `headlineSmall` (24) | 2 | 专辑名 / 艺术家名 |
| `display*` / `headlineLarge/Medium` | 0 | 完全未使用 |

问题：**层级塌缩在 12–22 之间**，12px 承担了 8 种不同语义；没有"编辑感"的大字号；`letterSpacing` 是 Roboto 的字距，中文下偏散；字体族未指定（Latin=Roboto，中文=系统回退），macOS/Android/Windows 观感不一致。

### 3.3 空间与形状（统计）

| 维度 | 实测 | 问题 |
|---|---|---|
| `EdgeInsets` 组合 | 抽样 20+ 种（1/2/4/6/8/10/12/14/16/20/24/32…）;**总数未逐文件复算** | 无 4pt 网格，无 token |
| `BorderRadius` | 6 种直接数值（2/6/8/10/12/14，其中 8 与 10 各 2–3 处混用） | 无圆角阶梯 |
| `Icon` 尺寸 | 图标侧 14/16/18/20/22/34/36/40/44（传输键另有 30/60 变量）；120/180/220 属于头像/封面/二维码尺寸，不计入图标阶梯 | 图标无尺寸阶梯，且尺寸档位被「封面尺寸」稀释 |
| 行高（曲目行） | `CoverArt 40` + `v6` padding ≈ 52 | 相对 12px 副标题，密度尚可但缺乏 hover 反馈 |
| 封面尺寸 | 36/40/44/120/150–190/180/360 | 无尺寸规约 |

### 3.4 组件重复与冲突（同一功能多套实现）

| 组件 | 现有实现 | 位置 |
|---|---|---|
| 曲目行 | `TrackRow` + 3 个近乎逐行相同的包装类 | `track_row.dart` / `library_page.dart:255-285` / `album_detail_page.dart:195-226` / `artist_detail_page.dart:282-313` |
| 来源条目 | `SourceTile`（桌面 ListTile）与 `_SourceCard`（移动 Card） | `sources_page.dart:396 / :523` |
| 图片 | `CoverArt`（ClipRRect + file/network）与 `ArtistAvatar`（ClipOval + memory + 首字） | `shared/cover_art.dart` / `artists_page.dart:26-81` |
| 面板头 | `_SidePanel` 头 与 `QueuePanel` 头 | `now_playing_page.dart:198-215` / `queue_panel.dart:46-63`（移动端队列弹层**双层标题**） |
| 分组容器 | `_Section` × 2 | `settings_page.dart:163` / `ai_settings_page.dart:344` |
| 空态 | `EmptyState` 与 `_LyricsHint`、`manual_match_dialog` 的裸居中文本、`ai_settings` 的裸 `Text` | 4 套 |
| 远端封面判定 | `_remoteArt` 逻辑重复 3 处 | `mini_player` / `player_bar` / `now_playing_page` / `queue_panel` |
| 时长格式 | `formatDuration`（`--:--`）与 `_clock`（`0:00`）两种口径 | `format.dart` / `seek_bar.dart:100` |
| 传送键行 | `PlaybackControls` 与 `PlayerBar` 各写一遍 prev/play/next | 两处 |

---

## 4. 交互能力现状（全库检索计数）

| 能力 | 命中数 | 现状 |
|---|---|---|
| `MouseRegion` / hover | **0 处自建** | 无自建悬停语汇（Material `InkWell` 有内建叠层，但没有行高亮、封面悬浮播放键、hover 才出现的操作键） |
| 应用内快捷键（`Shortcuts`/`CallbackShortcuts`/`HardwareKeyboard`） | **0** | 只有 macOS 原生菜单 **10 个带快捷键的菜单项**（`⌘,`/`⌘Q`/`⌘P`/`⌘←→`/`⌘1..4`/`⌘⇧N` + 正在播放）；应用内 `⌘K/⌘L/⌘⇧S/⌘⇧R/⌘⇧F/⌘⌃S/Space` 全缺 |
| `Semantics` | 1 | 仅 `TrackRow` 的"正在播放"标签 |
| 动画原语（`AnimatedContainer/Switcher/Opacity/TweenAnimationBuilder/Hero`） | 2 | 无 Hero / 无共享元素 / 无播放器展开动画 |
| `Dismissible` / 侧滑 | 0 | 移动端列表无侧滑操作 |
| `RefreshIndicator` | 0 | 无下拉刷新 |
| `showMenu` / `PopupMenuButton` | 7 / 1 | 仅 `TrackRow` 右键菜单与来源卡片 |
| `ReorderableListView` | 1 | 仅歌单详情 |
| 多选 | 0 | 无任何选择模式/复选框/批量工具栏 |
| 宽度分级（`LayoutBuilder`/`MediaQuery.sizeOf`） | 4 | 专辑网格列数、播放页 `<720`、播放条 560/640/780 |
| 平台分支口径 | 3 套 | `Theme.platform`（library）/ `dart:io Platform`（albums、artists、sources、track_row）/ `defaultTargetPlatform`（theme） |

### 4.1 播放器栈能力矩阵

| 能力 | 播放条（桌面） | 迷你条（移动） | 正在播放页 | 队列面板 | 歌词面板 |
|---|---|---|---|---|---|
| 上/下一首 | ✅ | 仅下一首 | ✅ | — | — |
| 播放/暂停 | ✅ | ✅ | ✅ | — | — |
| 进度拖动 | ✅（<560px 隐藏） | ❌ | ✅ | — | — |
| 音量 | ✅（<780px 隐藏） | ❌ | ❌ | — | — |
| 随机 / 循环 | ❌ | ❌ | ✅ | — | — |
| 收藏 | ❌ | ❌ | ❌ | ❌（也不显示收藏态） | — |
| 播放失败提示 | ❌ | ❌ | ❌ | — | — |
| 缓冲进度 | ❌（`buffered` 从未使用） | ❌ | ❌ | — | — |
| 倍速 | ❌（`rate` 从未使用） | ❌ | ❌ | — | — |
| 队列编辑 | — | — | — | ❌（无移除/清空/重排） | — |
| 歌词点击跳转 | — | — | — | — | ❌ |
| 歌词逐字高亮 | — | — | — | — | ❌（整行变色） |
| 自动滚动可靠性 | — | — | — | — | ⚠️ 固定 44px 行高估算，用户手滚会被拽回 |
| 输出设备（AirPlay 等） | ❌ | ❌ | ❌ | — | — |
| 展开/收起动画 | ❌（直接 push 路由） | ❌ | ❌ | — | — |

刷新率相关的好消息：`ui_rebuild_seek_test` 已把"进度 tick 不重建曲目行/封面"固定下来，重构时必须保持。

---

## 5. 与 legacy（SwiftUI 版）的能力对照

**legacy 有、Flutter 丢失**（重构应评估恢复）：

1. 桌面整套 hover 语汇（封面悬浮播放键、hover 才出现的收藏/删除键、行底色高亮）。
2. 桌面真表格 + 多选（`Set<String>` 选择、5 列、斑马纹、双击播放、选中集驱动的右键菜单）。
3. 播放条上的随机 / 循环 / 歌词开关 / 队列 popover / 音量 popover / AirPlay。
4. 全屏"正在播放舞台"（整窗替换 + 封面模糊背景 + 右侧歌词列 + `Esc`/`⌘⇧F`）。
5. 正在播放页的收藏键；队列的"清空"与悬停删除、"正在播放 / 接下来播放"分节。
6. 歌词点击跳转、当前行缩放强调。
7. 键盘快捷键全套（`⌘K` 搜索、`⌘L` 歌词、`⌘⇧S` 随机、`⌘⇧R` 循环、`⌘⇧F` 全屏、`⌘⌃S` 侧栏、`Space` 播放暂停）。
8. 右键菜单的"下一首播放 / 添加到队列 / 在专辑中查看 / 在艺人中查看"。
9. macOS 统一工具栏窗口外观、侧栏可折叠、系统 `.searchable`。
10. 品牌化封面占位（indigo→purple 渐变 + 音符 + 随尺寸缩放的阴影）与玻璃态播放条/迷你条。
11. 播放中的动态波形指示、`symbolEffect` 类动效。
12. 歌单侧滑删除 / 桌面侧栏歌单右键重命名。

**Flutter 新增、legacy 没有**（应保留并强化）：
统一 `EmptyState` 三态体系、`SeekBar` 的拖动预览 + 2s settle、等宽槽传送器布局、来源同步的权威性判定文案、`Semantics`/tooltip（虽少）、歌单拖拽重排、`FluidBackground` 按封面色派生的呼吸背景（含"减少动态效果"适配）、`recentlyAdded`、截断提示。

**形态差异（不视为缺失，按新设计统一）**：光晕背景、SeekBar、传送器、空/错/加载态的具体形态。

---

## 6. 问题清单（按类型与严重度）

> 严重度：`P0` 直接决定"是否像成品"；`P1` 明显损伤体验或平台习惯；`P2` 打磨项。
> 类型：`V` 视觉 · `I` 交互 · `A` 架构/一致性 · `S` 无障碍 · `P` 性能

### 架构与一致性

| ID | 严重度 | 问题 | 证据 |
|---|---|---|---|
| A1 | P0 | **没有设计 token 层**：只有 `ColorScheme.fromSeed` + 3 个形状覆盖，页面直接消费 M3 角色 | `theme.dart:19-60` |
| A2 | P0 | **外壳按平台硬切，不按窗口尺寸**：桌面窄窗得到 248px 侧栏；移动端不做宽度分级；播放页另有 `<720` 的第三套口径 | `router.dart:26-32`、`mobile_shell.dart`、`now_playing_page.dart:59` |
| A3 | P1 | 平台判断三套口径（`Theme.platform` / `dart:io` / `defaultTargetPlatform`），"是不是手机布局"有三个答案 | 见 §4 表 |
| A4 | P1 | 组件重复 9 处（见 §3.4），修一次要改多处，且已经出现"移动端队列弹层双标题"这类可见缺陷 | 见 §3.4 |
| A5 | P1 | 间距/圆角/图标尺寸散落 20+ 文件、28 种 padding、6 种圆角、14 种图标尺寸 | §3.3 |
| A6 | P1 | 播放页是 ShellRoute 子路由 → 桌面"沉浸式播放"里仍有侧栏与播放条 | `router.dart:56-59`、截图 |
| A7 | P2 | UI 测试无共享脚手架（4 套 pump 助手、3 套假引擎各自内联） | `test/support/` 仅数据工具 |

### 视觉

| ID | 严重度 | 问题 | 证据 |
|---|---|---|---|
| V1 | P0 | 全体中性色被红种子污染（`#FFF8F7/#FFF0EF/#FCEAE8`；`#1A1111/#231919/#271D1D`）→ 浑浊粉米色，与 Calm/Premium 相悖 | 探针实测 |
| V2 | P0 | 强调色实际不是品牌红（浅 `#904A48`、深 `#FFB3B0`），品牌辨识丢失 | 探针实测 |
| V3 | P1 | 深色模式容器层级差 < 0.02 亮度，结构几乎不可辨 | 探针实测 |
| V4 | P0 | 排版层级塌缩在 12–22，12px 承担 8 种语义，无大字号编辑感 | §3.2 |
| V5 | P1 | 未定义字体族：Latin=Roboto + 中文系统回退，跨端不一致；字距为拉丁值 | §3.2 |
| V6 | P0 | 曲库列表在宽窗下出现 300px+ 空白列，无列头/无 hover/无斑马纹 | 截图 + `track_row.dart:87-135` |
| V7 | P0 | 播放页封面用 blur 30/α0.32 厚重投影，像"卡片"；标题/艺术家/专辑 22/14/12 层级差过小 | `now_playing_page.dart:322-366` |
| V8 | P1 | 侧栏选中态与容器态同色（`secondaryContainer == primaryContainer`），图标 16px、行高约 30px，层级弱 | 探针 + `app_shell.dart:280-320` |
| V9 | P1 | 迷你条（56px 无圆角实心）与播放条（圆角 12 + elevation 6）是两种语言的同一功能；未播放时播放条仍占 84px 显示灰字占位 | 截图 + `mini_player.dart:24-49`、`player_bar.dart:45-51` |
| V10 | P1 | 空/错/加载态不统一：`EmptyState.message` 无 `maxLines`（长错误撑破布局）；settings 加载显示 `0`；AI 页错误是裸 `Text`；四处自绘空态 | `empty_state.dart:35`、`settings_page.dart:43-47`、`ai_settings_page.dart:338` |
| V11 | P2 | `lib/features/**` 中 `Colors.*` 调用 8 处（黑阴影、透明、测试结果绿×2、红×2、白×2），另有主题种子 `Color(0xFFFA243C)` 1 处；二维码白底属于实物语义 | grep 计数 |

### 交互

| ID | 严重度 | 问题 | 证据 |
|---|---|---|---|
| I1 | P0 | 桌面无自建悬停语汇：无行高亮、无封面悬浮播放、无 hover 操作键（仅 Material 内建叠层） | `MouseRegion` 0 处 |
| I2 | P0 | 应用内零快捷键；macOS 菜单 10 个快捷项；搜索框吞空格导致 `Space` 无法播放 | `Shortcuts` 0、`main.dart:220+` 注释 |
| I3 | P1 | 右键菜单只覆盖 `TrackRow`，缺「添加到队列 / 在专辑中查看 / 在艺人中查看」 | `track_row.dart:150-215` |
| I4 | P1 | 无多选与批量操作（legacy 有真表格多选） | grep 0 |
| I5 | P0 | **收藏在播放器栈完全没有入口**，且队列不显示收藏态 | §4.1 |
| I6 | P1 | 队列不可编辑（无分节、无跳转语义外的操作）；受引擎契约限制，Phase 2 收敛为「只读 + 跳转 + 末尾追加」 | `queue_panel.dart:88-89`、`playback_engine.dart` |
| I7 | P1 | 歌词不可点击跳转；自动滚动固定 44px 估算；手动滚动被拽回；无逐字高亮（数据无逐字时间戳） | `lyrics_panel.dart:113-120` |
| I8 | P1 | 播放失败只有全局 SnackBar（`PlaybackFailureListener`），**没有**行内/播放条的持久错误态与重试 | `main.dart:162-164`、`playback_failure_listener.dart` |
| I9 | P2 | `buffered` 在 UI 未使用；`rate` 在 UI 未暴露（系统媒体会话有转发） | §4.1 |
| I10 | P0 | 无排序、无筛选、无视图切换、无全局搜索范围（仅曲库内 200 条截断） | §2.2 / `library_page.dart:54-60` |
| I11 | P1 | 危险操作确认不全（同步全部/清洗整库/补全元数据）；WebDAV 表单必填项静默失败无 `errorText`（歌单删除、来源删除已有确认） | `settings_page.dart:67-72`、`ai_settings_page.dart:318`、`sources_page.dart:855-865` |
| I12 | P1 | 移动端设置入口藏在曲库页右上；迷你条→播放页无展开动画；无侧滑操作 | `library_page.dart:90-95` |
| I13 | P1 | 桌面窗口无最小尺寸保护（Windows 默认 1280×720、无 min），窄窗直接掉进移动形态 | `windows/runner/main.cpp:29`、`now_playing_page.dart:59` |
| I14 | P2 | 无下拉刷新、无统一重试；仅夸克网页登录可刷新、侧栏歌单失败可重试 | grep 0 + 上述两处 |
| I15 | P2 | 无"最近添加"移动入口 | `mobile_shell.dart:14-19` |

### 无障碍

| ID | 严重度 | 问题 | 证据 |
|---|---|---|---|
| S1 | P1 | `Semantics` 仅 1 处；大量图标按钮依赖 tooltip | grep 1 |
| S2 | P1 | 桌面 `VisualDensity.compact` 会把 Material 控件压到 48dp 以下（代码注释自述），自绘行未验证最小目标 | `theme.dart:10-18` |
| S3 | P2 | 无焦点（Tab）导航设计与可见焦点环 | grep 0 |
| S4 | P2 | `disableAnimationsOf` 仅在流体背景尊重，其余动画未检查 | `fluid_background.dart:39` |

### 性能

| ID | 严重度 | 问题 | 证据 |
|---|---|---|---|
| P1 | P1 | 流体背景每帧 1 次全屏 `drawRect` + 3 个近全屏半径径向渐变（4 层全屏过绘制），24s 常驻；`willChange: true` 禁缓存 | `fluid_background.dart:104-167` |
| P2 | P2 | 列表未设 `itemExtent`/`prototypeItem`，滚动时按子项测量估算 | 各 `ListView.builder` |

---

## 7. 设计的根本性判断

1. **信息架构没有为"音乐优先"服务**：曲库把序号、标题、艺术家、专辑、时长、更多塞进同一行，却让封面停在 40px；播放页把封面放在卡片投影里，而侧栏与播放条仍在争抢注意力。
2. **两套布局的差异是被"平台"而非"尺寸"定义的**：这既让桌面窄窗不可用，也让平板/折叠屏这类"移动宽度、桌面交互"的场景无解。
3. **桌面交互语汇整体缺位**（hover/快捷键/右键/多选/焦点），这直接违背"Native"与"桌面级侧边导航"的要求。
4. **设计系统事实上不存在**：没有 token、没有排版规范、没有组件库、没有动效规范、没有无障碍规约。
5. 因此本项目的正确路径不是"美化"，而是按 Phase 2/3 **重建 IA 与设计系统**，再在 Phase 4/5 用新系统重写 Presentation 层。

---

## 8. 重构范围与非目标

### 范围（允许大幅重写）

- `app/lib/app/theme.dart` → 拆为完整设计系统（token + 主题构建 + 组件主题 + 排版 + 动效 + 平台适配）。
- `app/lib/features/**` → 全部重写为新的组件体系与页面结构（保留业务语义、文案口径、provider 契约）。
- `app/lib/app/router.dart` → 允许增加/调整路由与外壳，但保留 §1.3 的路由语义（Tab 根不压栈、深链可走）。
- 新增：设计系统文档 `DESIGN.md`、UX 重设计文档 `docs/UX_REDESIGN.md`、本审计 `docs/UI_UX_AUDIT.md`。
- 允许在 `main.dart` 增加 **QA 专用环境开关**（如主题强制、窗口尺寸），与现有 `TINGYU_DEBUG_ROUTE` / `TINGYU_DEBUG_MOBILE_SHELL` 同风格。

### 非目标（明确不做）

- 不改播放引擎、不改 `audio_service` 集成、不改来源适配/刮削/数据库/迁移逻辑。
- 不引入大型 UI 依赖（不引入第三方设计系统包；动画用 Flutter 原生 + 现有依赖）。
- 不实现 legacy 的 iCloud 同步与 AirPlay（前者需要基础设施，后者平台专属；仅在文档中标注）。
- 不做占位 UI：任何进入主路径的控件必须真实可用，否则不出现。
- 不以"通过测试"为目的删除/削弱断言（见 §1.4 处置原则）。

### 风险与缓解

| 风险 | 缓解 |
|---|---|
| 现有 244 测试中有 4 个锁死旧布局细节 | §1.4 逐条改写为设计不变量；改写前后各跑一次全量测试 |
| 重构期"半新半旧"造成观感割裂 | 先建 token/组件，再按 Phase 4 顺序整体替换核心页面；过渡期不合并到 main（保持一次成型） |
| 无法在 macOS/Android 真机验证 | 用参数化无头渲染（尺寸 × 平台 × 主题）覆盖布局；真机行为由用户侧截图/CI 构建兜底 |
| Windows 需补丁引擎，构建链路特殊 | 已确认引擎就绪；构建走 `tools/build-windows-engine.ps1 -Stage App`，不修改该链路 |
| 曲库真实数据（191 首、含夸克来源）与空库差异大 | 验收矩阵强制覆盖：空库/大库/长标题/缺封面/网络异常/同步中 |

---

## 9. 验收判据与验证方案（Phase 6 用）

### 9.1 客观门禁

1. `flutter analyze` 零 issue；`flutter test` 全绿（用例数 **≥ 244**，且 §1.4 四个测试以"不变量"形式保留）。
2. Windows Release 真机构建通过并启动成功（`tools/build-windows-engine.ps1 -Stage App`）。
3. 真机截图矩阵（同一构建、同一进程多次启动）：
   - 尺寸：桌面 1440×900（逻辑，DPI 换算后）、桌面临界 960×600、移动 390×844；
   - 主题：浅色、深色；
   - 页面：曲库 / 专辑网格 / 专辑详情 / 艺术家详情 / 正在播放 / 队列 / 来源管理 / 设置；
   - 状态：空库、大库、长标题、缺封面、同步中、播放失败。
4. 无头渲染矩阵（`flutter test` 内渲染真实组件树并落 PNG）用于补齐真机取不到的尺寸与主题；关键页面在 320/390/768/1024/1440/1920 宽度下无溢出（`takeException() == null`）。

### 9.2 主观判据（对照任务书第十章）

1. 首屏是否像"完成度很高的正式产品"——由 Phase 6 截图评审裁定，需给出**改动前后同尺寸对照**。
2. 是否具备一致的 Tingyu 设计语言（色彩/排版/间距/动效四类 token 全部来自设计系统，页面内无硬编码尺寸与颜色）。
3. 是否摆脱 Flutter Demo 观感（不以 Material 默认控件的原生外观作为最终形态）。
4. 音乐内容是否成为视觉主体（封面尺寸/网格比例/播放页舞台）。
5. 找歌与播歌路径是否更短（可从任意列表 ≤1 次操作起播；搜索可直达）。
6. 是否比旧版更易理解（无重复标题、无空占位、每屏一个视觉焦点）。
7. 桌面与移动是否各自符合平台习惯（hover/快捷键/右键/多选 vs 底部导航/大触控目标/手势返回/展开动画）。
8. 功能是否完整保留（§1.3 契约与 §2.2 页面逐项核对，缺失项必须显式登记）。
9. 设计系统是否可支撑后续开发（新增页面只需组合组件与 token）。

---

## 10. 下一步

Phase 2（信息架构与核心路径重设计）与 Phase 3（设计系统）的产出分别为 `docs/UX_REDESIGN.md` 与 `DESIGN.md`；两者完成后才允许开始 Phase 4 的代码重写。

---

## 附：审查修订记录（2026-10-18）

依据 `docs/DESIGN_REVIEW_1.md` 的独立核查，本审计已修正以下失准表述（编号不变，结论方向不变）：

| 原表述 | 修正后 | 依据 |
|---|---|---|
| macOS 菜单 7 项 | **10 个带快捷键的菜单项** | `app/lib/main.dart:175-283` |
| 播放失败「无任何 UI 呈现」 | 有全局 SnackBar；缺行内/持久错误态与重试 | `main.dart:162-164`、`playback_failure_listener.dart` |
| 「无任何悬停反馈」 | 无自建 hover 语汇（M3 `InkWell` 有内建叠层） | `track_row.dart:49-55` |
| 「无刷新机制」 | 无下拉刷新/统一重试；夸克登录可刷新、侧栏歌单可重试 | 代码核查 |
| 图标 14 种 | 图标侧 9 档，另有传输键 30/60；120/180/220 属头像/封面/二维码尺寸 | 代码核查 |
| `EdgeInsets` 28 种 | 抽样 20+，总数未复算 | 未复算 |
| 「无确认对话框」 | 歌单删除、来源删除已有确认；缺口是同步全部/清洗整库/补全元数据 | 代码核查 |

未复算/未实测（不得当成已验证）：`EdgeInsets` 总数、全量 `TextStyle` 数量、真机渲染对比度、动效与取色开销、各平台真机布局。这些在 Phase 6 用实际运行与截图矩阵补齐。
