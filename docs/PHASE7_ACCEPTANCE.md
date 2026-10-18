# 听屿 Phase 7 — 跨平台验收与 UI/UX 精修（验收记录）

> 本文只记录**本阶段实际执行过的动作与实测结果**。四类结论严格分开写：
> 「代码已修改」/「测试已通过」/「CI 已配置」/「真机已验证」互不替代。
> 证据形式：命令 + 输出、截图文件路径、测试文件与用例名。

---

## 0. 本机工具链事实（决定能验证什么）

`flutter doctor`（本机，2026-10-18 实测）：

| 项 | 状态 |
|---|---|
| Flutter | 3.47.2 / Dart 3.13.2（`F:\flutter`，user-branch） |
| Windows 桌面 | ✅ Visual Studio Community 2022 17.14.41 |
| 连接设备 | ✅ `windows`、`chrome`、`edge`（后两个是 Web 目标，本项目依赖不支持 Web） |
| Android 工具链 | ❌ 无法定位 Android SDK |
| macOS / iOS | ❌ Windows 主机不可能有 Xcode；无法构建、无法运行 |
| Linux | ❌ 无 GTK/libmpv/ninja 依赖，且主机是 Windows，不能交叉构建 |

结论：**真机运行与截图只能在 Windows 上做**；其余平台只能做静态检查、组件测试与 CI 配置审阅。

---

## 1. Phase 7.1 基线复核（复核上一轮报告，不假设其成立）

| 上轮报告说法 | 复核方式 | 结论 |
|---|---|---|
| `flutter analyze` 零问题 | 重新执行 `flutter analyze --no-pub` | ✅ `No issues found!` |
| 311 个测试通过 | 重新执行 `flutter test --no-pub` | ✅ 起步 311 通过（本阶段新增后为 316） |
| 18 个页面已迁移设计系统 | 逐文件统计 `design/` 引用数 | ⚠️ **16/18**：`quark_qr_login_page.dart`、`quark_web_login_page.dart` 引用数为 0（旧 Material + 页面级 `CircularProgressIndicator`）→ 本阶段已修（见 §4.1） |
| `DESIGN.md` 为唯一权威 | 存在性 + 内容对照 | ✅ 存在；本阶段补齐了测试清单与两条新禁止项 |
| Windows 已完成真机运行与截图 | 查看 `app/build/ui-shots/**`、`docs/screenshots/**` | ✅ 有历史证据；本阶段重新执行（见 §2.2） |
| Android/macOS/Linux/iOS 未验收 | `flutter doctor` + 平台目录 diff | ✅ 属实（见 §5） |

平台目录（`app/{macos,ios,android,linux,windows}`）本阶段无实质改动：
只有 `pub get` 生成的插件注册文件与 `windows/runner/CMakeLists.txt` 的补丁引擎守卫；
平台专属源码里 grep 不到任何旧路由字符串。

---

## 2. Phase 7.2 跨平台验证

### 2.1 CI 覆盖（`.github/workflows/flutter.yml`）

| Job | 平台 | 做了什么 |
|---|---|---|
| `analyze` | ubuntu-22.04 | `flutter pub get` → drift 生成代码新鲜度校验（`git diff --exit-code`）→ `flutter analyze` → `flutter test --exclude-tags golden` |
| `build` (matrix) | macos-14 / macos-14(iOS,--no-codesign) / windows-2022 / ubuntu-22.04(linux) / ubuntu-22.04(apk) | 五平台**构建**（Windows 走补丁引擎的 bootstrap+Sync+Configure+Compile+Test+App） |

结论：**五个平台在 CI 上都有覆盖，但都只到「能编过」这一层**，没有任何平台在 CI 上做运行/交互验证；
golden 被 CI 排除（`dart_test.yaml` 已配置 skip）。

### 2.2 Windows 真机验证（本阶段执行）

构建：`tools/build-windows-engine.ps1 -Stage App` → `✓ Built build\windows\x64\runner\Release\tingyu.exe`

截图（`tools/windows-ui-screenshots.ps1`，只截 Flutter 子窗口客户区；DPI 150%）：

| 批次 | 尺寸（物理 → 逻辑） | 主题 | 页面 |
|---|---|---|---|
| `p7-light-expanded` | 2138×1294 → 1425×863 | 亮 | 12 条根路由 |
| `p7-dark-expanded` | 同左 | **暗** | 12 条根路由 + 专辑详情 + 艺人详情 + 来源详情 + 首次引导 |
| `p7-light-compact` | 563×1210 → 375×807 | 亮 | 12 条根路由 |
| `p7-dark-compact` | 同左 | **暗** | 8 条关键路由 |
| `p7-2-light-expanded` | 2130×1294 | 亮 | 修复后的来源/来源详情/收藏/专辑详情 |
| `p7-flow2` | 2160×1350 | 亮 | 真机点击流：来源页 →「添加来源」弹窗 |

播放冒烟：`tools/windows-smoke-test.ps1 -Cycles 4` → 结论见 §7。

关键截图证据（可直接打开核对）：

- `app/build/ui-shots/sheet-light-1.png`、`sheet-light-2.png`、`sheet-dark-1.png`、`sheet-dark-2.png`、`sheet-dark-3.png`（会话内生成的拼版）
- `app/build/ui-shots/sheet-compact-1.png`、`sheet-compact-2.png`、`sheet-compact-dark.png`
- `app/build/ui-shots/zoom-dialog.png`（添加来源弹窗 2× 放大）
- `app/build/ui-shots/p7-flow2/01-add-source-dialog.png`

### 2.3 Android / macOS / Linux / iOS

| 平台 | 本阶段能做的 | 结果 | 阻塞原因 |
|---|---|---|---|
| Android | 平台能力分支的组件测试（触控常显、长按、无 hover） | ✅ 新增 3 条用例（`design_system_render_test.dart` 的 `_platformTraitsCoverage`） | 无 SDK、无设备 → **不能**声称触控/返回手势/SAF 真机通过 |
| macOS | 平台能力分支测试（hover/右键/⌘ 修饰键） | ✅ 同上 | 无 Xcode → 菜单栏、窗口内边距未真机验证 |
| Linux | 无（同一份 Dart 代码，静态分析覆盖） | — | 无 GTK 依赖 + 主机不匹配 |
| iOS | 无 | — | 无 Xcode；仅 CI 编译校验 |

`withTargetPlatform()`（`test/support/pump.dart`）让组件测试能在「Android/macOS 能力」下渲染并断言，
这是本阶段对「非 Windows 平台风险」能做到的最接近机制；它**不等于**真机验证。

---

## 3. Phase 7.3 产品级审查（逐页）

审查方法：4 个批次 × 目标窗口尺寸的真机截图 + 逐张拼版核对 + 关键区域放大；
每个页面检查：层级与留白、控件一致性、四态（数据/加载/空/错误）、
hover/focus/pressed/disabled、触控形态、深浅色、边界（长标题/缺封面/0 时长）。

覆盖到的页面（18/18）：

| 页面 | 亮·大屏 | 暗·大屏 | 亮·窄屏 | 暗·窄屏 |
|---|---|---|---|---|
| 曲库·歌曲 | ✅ | ✅ | ✅ | ✅ |
| 曲库·专辑 | ✅ | ✅ | ✅ | ✅ |
| 曲库·艺术家 | ✅ | ✅ | ✅ | — |
| 曲库·歌单（空态） | ✅ | ✅ | ✅ | — |
| 收藏（空态） | ✅ | ✅ | ✅ | ✅ |
| 搜索（空查询） | ✅ | ✅ | ✅ | ✅ |
| 来源管理 | ✅ | ✅ | ✅ | ✅ |
| 来源详情 | ✅ | ✅ | — | — |
| 专辑详情 | ✅ | ✅ | — | — |
| 艺人详情 | — | ✅ | — | — |
| 设置 | ✅ | ✅ | ✅ | ✅ |
| AI 设置 | ✅ | ✅ | ✅ | — |
| 播放舞台 | ✅ | ✅ | ✅ | ✅ |
| 播放队列 | ✅ | ✅ | ✅ | ✅ |
| 歌词（空态/整页） | ✅ | ✅ | ✅ | — |
| 首次引导 | — | ✅ | — | — |
| 扫码登录页 | 只有组件级渲染（golden + 渲染测试） | | | |
| 网页登录页 | 同上 | | | |

审查发现（全部在本阶段处理，见 §4）。

---

## 4. Phase 7.4 实施与返工（发现的真实问题 + 修复）

### 4.1 未迁移页面（P1，上轮报告的遗漏）

`quark_qr_login_page.dart` / `quark_web_login_page.dart` 是旧 Material 实现，且用
`CircularProgressIndicator` 作页面级加载态（违反 `DESIGN.md` §10.4）。

修复：两页逻辑不动，表现层抽出纯展示组件 `QuarkQrLoginView` / `QuarkWebLoginChrome`，
换成 `TyPanel`/`TySkeleton`/`TyErrorView`/`TyButton`/`TyIconAction`/`TyProgressBar`；
二维码画框保留白底并标 `// guard-ok: 二维码白底`。
顺带新增：扫码页的倒计时改成每秒推进的 `Ticker` + 进度环（原来是 2 秒轮询顺带刷新，读秒会跳）。

验收：`test/quark_login_render_test.dart`（三形态 × 两主题 × 加载/就绪/失败三态；
断言加载态是骨架不是转圈、失败态有 `TyErrorView` + 重试、忙碌时主操作禁用）。

### 4.2 分段控件铺满整行（P1，视觉缺陷）

收藏页只有 2 个分段，却横跨 1250px 变成一条空槽；搜索页当时用页面内 `ConstrainedBox(480)` 各自兜底。

修复：把宽度上限收进组件 `TySegmentedControl.maxWidth`（默认 480，`null` = 铺满），
搜索页删掉自己的临时实现（单一约定）；外壳的窄屏分段切换显式传 `maxWidth: null`（它就是那一层的导航）。

验收：`design_system_render_test.dart` 的「分段控件：桌面限宽 480，窄屏铺满」（量的是控件本体，不是外层 Align）。

### 4.3 来源详情页头信息重复（P1）

页头副标题曾是「夸克网盘 · 191 首 · 已连接 · 191 首 · 上次同步…」——来源名与曲目数各出现两次。

修复：副标题 = 类型（与名称不同才显示） + 状态标签。

验收：真机截图 `app/build/ui-shots/p7-2-light-expanded/source-src-1791263687892191.png`
（现在显示「已连接 · 191 首 · 上次同步 2026-10-06」）。

### 4.4 来源管理主操作沉底（P2）

「添加来源」原本钉在页面底部，只有一张卡片时中间留下半屏空白。

修复：移入页头右侧 actions；窄屏换成图标键（避免标题/副标题被挤到词中断行）。

验收：真机截图 `p7-light-expanded/sources.png`（大屏）与 `p7-light-compact/sources.png` + `p7-dark-compact/sources.png`（窄屏 ＋ 图标键）。

### 4.5 专辑详情表格重复「专辑」列（P2）

专辑页里每一行的专辑列恒等于页面标题，纯噪声。

修复：专辑详情 `showAlbum: false`（艺人/歌单/搜索页保留该列，那里它有用）。

### 4.6 设置页在 build 里起 Future（P2，顺带修可测性）

`FutureBuilder(future: getApplicationSupportDirectory())` 每次重建都重新问一次系统目录，
widget 测试里还会抛 `MissingPluginException`。

修复：新增 `dataDirectoryProvider`（`FutureProvider<Directory>`），设置页改读 provider；
golden 测试可注入固定目录。

### 4.7 舞台文本落到 MaterialApp fallback 样式（P1，上阶段发现，本阶段补回归网）

真机曾出现「每条文本下一条纯黄下划线」——舞台挂在根 Navigator、没有 Material 祖先，
Flutter 用 `_errorTextStyle` 兜底（黄下划线）。已由 `TyPlayerStage` 自带透明 `Material` 修好；
本阶段新增用例把「舞台文本必须落在真实 `DefaultTextStyle` 里」钉死
（`now_playing_layout_test.dart`，且测试挂载方式与真实路由同构——不套 Scaffold）。

### 4.8 已复核但**决定不改**的项

| 项 | 结论 |
|---|---|
| 窄屏曲库列表保留序号列 | `DESIGN.md` §6.2 的 `TyTrackRow` 明确写了「序号/音柱」；序号在移动端用于定位，且占位与播放态音柱同一槽位，删列收益小于改动风险 |
| 添加来源弹窗三个图标笔画粗细不完全一致 | 放大到 2× 后逐像素扫描确认三个图标都渲染（72 / 82 / 261 个深色像素）；差异来自字形本身（folder/cloud 描边 vs cloud_queue），语义上三者需要区分 |
| 首次引导内容贴顶、下方留白 | 单页引导，内容对齐顶部与全局页面基线一致 |
| 「来源」空态 / 队列空态等高留白 | 空态居中符合组件规范，不额外填充 |

---

## 5. Phase 7.5 性能与回归

### 5.1 新增的结构级性能回归（`test/performance_regression_test.dart`）

| 用例 | 断言 | 结果 |
|---|---|---|
| 2000 首的曲库 | 只构建可见行（`< 60`），拖动 4000px 后仍 `< 60` 且无异常 | ✅ |
| 舞台漂移背景 | 推进 60 帧（≈1s，漂移周期 24s）内，`TyCover` 与 `TyPlayerStage` 重建次数均为 0 | ✅ |

### 5.2 已存在的性能相关覆盖（本阶段复核，未重复造）

- 进度 tick 不重建列表行/封面/标题、换曲只重建高亮翻转的两行、拖动只在松手时 seek 一次：`ui_rebuild_seek_test.dart` ✅
- 分页查询给真实 COUNT、翻页不重复、`查看全部` 走分页：`search_debounce_test.dart` + `search_page_test.dart` ✅
- 封面按显示尺寸解码（`cacheWidth = size × DPR`）：`ui_rebuild_seek_test.dart` 最后一条 ✅

### 5.3 视觉回归基线（golden）

`test/golden/core_pages_golden_test.dart`（`@Tags(['golden'])`）+ `test/support/page_harness.dart`：

- 12 张基准图（`test/golden/goldens/`，共 156 KB）：曲库（expanded 暗 / compact 亮）、
  专辑网格、专辑详情、搜索（空查询 / 有结果）、队列面板、歌词空态、舞台（compact 暗）、
  设置、来源管理、来源详情。
- 确定性来自三条纪律：`disableAnimations: true`（骨架/音柱/漂移静止）、数据全部走 provider 覆盖、
  每张图固定一个尺寸。
- 生成：`flutter test --run-skipped -t golden --update-goldens`
- 校验：`flutter test --run-skipped -t golden` → 12/12 通过
- CI 排除：`dart_test.yaml` 已配置 `golden` tag skip，CI 用 `--exclude-tags golden`

---

## 6. 门禁与真实输出

```
$ flutter analyze --no-pub
Analyzing app...
No issues found! (ran in 4.0s)

$ flutter test --no-pub
00:08 +316 ~1: All tests passed!
（316 通过；~1 是 golden 用例被 tag 跳过，用 --run-skipped -t golden 单独校验：12/12 通过）
```

本阶段新增/改写测试文件：

| 文件 | 内容 |
|---|---|
| `test/quark_login_render_test.dart`（新） | 两个登录页 × 三形态 × 两主题 × 三态 |
| `test/performance_regression_test.dart`（新） | 大曲库虚拟化、舞台漂移不重建内容 |
| `test/golden/core_pages_golden_test.dart`（新） | 12 张核心页面基准图 |
| `test/support/page_harness.dart`（新） | 页面脚手架：路由挂载、假播放控制器、冻结动画 |
| `test/support/pump.dart`（改） | `withTargetPlatform`（平台能力可注入）、`layoutScopeOf` |
| `test/design_system_render_test.dart`（改） | 触控/桌面平台分支 + 分段控件宽度纪律 |

---

## 7. 真机运行与冒烟（Windows）

- 构建产物：`app/build/windows/x64/runner/Release/tingyu.exe`（补丁引擎，Release）
- 截图：见 §2.2 六个批次（亮/暗 × 大屏/窄屏 + 详情页 + 真机点击流）
- 播放冒烟：`tools/windows-smoke-test.ps1 -Cycles 4`
  - 实测（`app/build/ui-shots/p7-smoke/result.json`）：`cyclesAttempted=4`、`exited=false`（4 轮导航开合后仍在运行）、
    `nativeAccessibilityErrors=0`；`stdout.log` 中 `playing=true` 快照 1770 条（真实音轨播放中）
- **未做**：CI（GitHub Actions）本次未触发；Android/macOS/Linux/iOS 无真机运行

---

## 8. 仍未验证的平台与原因（不夸大）
| 平台 | 未验证内容 | 原因 | 降低风险的手段（已做 / 待做） |
|---|---|---|---|
| Android | 触控手势、系统返回、SAF 授权、安全区、真机字号与命中区 | 无 SDK、无设备 | 已做：平台能力分支组件测试；待做：装机跑一遍 `/library/songs → /search → /stage → /queue` |
| macOS | 菜单栏派发顺序（⌘1..4 与外壳快捷键重叠）、窗口内边距、安全区 | 无 Xcode | 已做：菜单项与外壳快捷键对齐同一张表；待做：真机点一遍菜单 |
| Linux | GTK 依赖构建、MPRIS 媒体会话 | 主机不匹配 + 缺依赖 | 已做：CI 有 linux 构建；待做：CI 跑通 + 真机试听 |
| iOS | 编译兼容、安全区、平台能力分支 | 无 Xcode | 已做：CI 有 iOS 编译校验；待做：CI 结果确认 |
| Windows | —（本阶段已运行 + 截图 + 冒烟）；**未验证**：100%/200% DPI、真·深色系统主题跟随（截图用的是显式主题覆盖） | 系统 DPI 与主题是机器级设置，脚本无法切换 | 已做：150% DPI 下三档尺寸 + 显式亮/暗主题；待做：换 DPI 或主题的机器复跑一次截图脚本 |

---

## 9. 复现命令清单

```bash
# 静态 + 测试
cd app && flutter analyze --no-pub
cd app && flutter test --no-pub
cd app && flutter test --run-skipped -t golden            # 视觉基线校验

# 生成/更新视觉基线（仅 Windows 参考渲染）
cd app && flutter test --run-skipped -t golden --update-goldens

# Windows 真机构建 + 截图 + 冒烟（仓库根）
./tools/build-windows-engine.ps1 -Stage App
./tools/windows-ui-screenshots.ps1 -AppDirectory ./app/build/windows/x64/runner/Release -OutputDirectory ./app/build/ui-shots/run -Theme dark
./tools/windows-ui-contact-sheet.ps1 -InputDirectory ./app/build/ui-shots/run -OutputPath ./app/build/ui-shots/sheet.png
./tools/windows-ui-flow-shots.ps1 -AppDirectory ./app/build/windows/x64/runner/Release -OutputDirectory ./app/build/ui-shots/flow -Steps @('01-add-source-dialog:1331,49')
./tools/windows-smoke-test.ps1 -AppDirectory ./app/build/windows/x64/runner/Release -OutputDirectory ./app/build/ui-shots/smoke
```

调试用环境变量（`main.dart`，只影响本次进程、不写回用户设置）：
`TINGYU_DEBUG_ROUTE`（直达某路由）、`TINGYU_DEBUG_THEME=dark|light`、`TINGYU_DEBUG_DENSITY=compact|comfortable`。

### 8.1 尚存风险（按优先级）

| 优先级 | 风险 | 影响面 | 现状 | 建议动作 |
|---|---|---|---|---|
| **P0** | Android 未真机验收 | 触控手势、系统返回、SAF 授权、安全区 | 组件级分支测试已覆盖「触控常显/长按/无 hover」；真机行为未知 | 装一台 Android 设备跑 `/library/songs → /search → /stage → /queue` + 添加本地目录授权一次 |
| **P1** | macOS 未真机验收 | 菜单栏快捷键派发顺序（⌘1..4 与外壳 `CallbackShortcuts` 重叠时由 AppKit 先吃）、窗口标题栏内边距、安全区 | 菜单项与外壳快捷键已对齐同一张表；未点过 | 在 macOS 上点一遍「前往」菜单与 ⌘K/⌘F |
| **P1** | CI 本轮未跑 | 五平台构建矩阵与 iOS 编译校验的可信度 | 配置审阅通过；未触发 | 推分支让 CI 跑一遍矩阵 |
| **P2** | Windows DPI 只测了 150% | 100%/200% 下的取整与命中区 | 三档尺寸截图 + `dpr=2` 的组件测试通过 | 换 DPI 复跑 `windows-ui-screenshots.ps1` |
| **P2** | 真机深色走查用的是显式主题覆盖，未跟随系统主题变化 | 主题切换的实时性（`themeMode` 跟随系统） | 亮/暗两套主题各自截图通过；切换路径未走 | 切系统主题看一次是否即时生效 |
| **P2** | 歌单详情页的「有内容」形态没有真机截图 | 该页版式只剩组件测试与 golden 覆盖 | 用户库当前没有歌单，截图只能看到「不存在」态 | 建一个歌单后补一张截图 |
| **P3** | Linux MPRIS 媒体会话 | 桌面媒体键/系统媒体面板 | 与 Windows 共用同一份源码 | CI 跑通后真机试听 |
