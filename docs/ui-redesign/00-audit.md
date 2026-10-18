# 听屿 UI/UX 现状审计（P0）

日期：2026-10-18。范围：现役 `app/`。本轮只增加文档和证据，没有修改 UI、业务、依赖或 Golden 基准。

## 结论与证据边界

当前实现已有独立设计系统、宽度响应式外壳、沉浸播放页和回归测试，应该在其基础上渐进改进。旧 `docs/UI_UX_AUDIT.md` 描述的是重构前状态，不能直接作为本轮现状结论。现有规范也不能视为本轮用户已经批准的新方向。

本轮完成代码审阅、Windows 既有 Release 实际启动截图、静态分析、普通测试及 Golden 校验。**不宣称全平台审计完成或商业品质验收通过**：手机截图来自 Windows 窄窗口；没有 Android/iOS 真机、macOS/Linux 运行证据，没有实际读屏、触控、长列表滚动或云盘在线播放验收。本轮未重新构建 Release，源码检查和运行截图属于两组证据，不能证明二进制与 HEAD 完全一致。产物 SHA256 见 [manifest.json](evidence/manifest.json)。

## 仓库与设计资产

- 起点 `5491452`，`main` 比 `origin/main` 领先 3 个提交；初始工作区干净。审计在 `codex/ui-p0-audit` 分支进行，没有覆盖或合并主分支。
- 阅读入口：`README.md`、`app/README.md`、`docs/crossplatform-migration.md`、`docs/windows-now-playing-crash.md`、`docs/PHASE7_ACCEPTANCE.md`，以及旧审计、`docs/UX_REDESIGN.md`、`docs/DESIGN_REVIEW_1.md`、根目录 `DESIGN.md`。
- 可复用：`lib/design/tokens/{color,typography,metrics,motion}.dart`、`design/theme.dart`、`design/components/`、`design/layout/`。颜色已脱离 Material seed，字号/间距/形状已有集中定义。无需重建另一套平行主题。
- `FormFactor` 按逻辑宽度划分：compact <640、medium 640–1023、expanded ≥1024；平台能力独立处理。现有 token 提供 Light/Dark、舒适/紧凑密度及舞台封面取色。
- 字体采用平台回退链，没有打包固定字体；这适用于系统观感，但不足以保证不同机器的像素基准稳定。
- `docs/screenshots/`、`app/test/golden/goldens/` 是历史资产，本轮未把它们冒充新运行截图。仓库未发现独立 Figma 源稿或打包字体。`app/assets/` 当前主要是 OpenCC 数据。
- Product Design 上下文预检脚本因系统 `python` 指向不可用的 Store 别名而未执行；未发现可读取的保存上下文，本轮以仓库和用户需求为依据。

## 架构边界与页面地图

`main.dart → Riverpod providers → GoRouter → TyAppShell → features 页面 → design 组件/令牌` 是现有表现层链路。浏览页面包括歌曲、专辑、艺术家、歌单、收藏、搜索、来源、设置和 AI 设置；详情通过参数路由进入。`/stage`、`/queue`、`/lyrics`、`/onboarding` 位于 ShellRoute 外。

后续只消费既有接口：`PlaybackController` 与 `PlaybackSnapshot`、`currentTrackProvider`、曲库/来源/搜索/歌单 providers、仓储、`SourceSyncController`。保持播放进度订阅粒度、松手一次 seek、队列索引/随机循环、根 Tab 与详情返回语义。`lib/playback/`、`lib/data/`、`lib/sources/`、播放控制器与解析器属于受保护边界；不因视觉重构替换 Riverpod、数据库、音频引擎、夸克或 WebDAV 实现。

## 实际截图与逐步审阅

这些是按启动路由独立采集的页面步骤，不代表已经通过连续点击流。原图均已打开检查：无终端遮挡、无空白加载页。Windows DPI=1.5；脚本参数为整窗物理尺寸，内容区尺寸以日志为准。

| 步骤 | 页面/状态 | 本轮证据 | 健康度 |
|---|---|---|---|
| 1 | 桌面歌曲，191 首，分页，播放错误 | [深色曲库](evidence/desktop-dark/library-songs.png) | 结构清晰；搜索入口与错误恢复需改善 |
| 2 | 桌面来源，已连接 | [深色来源](evidence/desktop-dark/sources.png) | 卡片语汇一致；选中目的地不明确 |
| 3 | 桌面舞台，缺封面/歌词，失败音源 | [深色舞台](evidence/desktop-dark/stage.png) | 沉浸层隔离良好；状态与错误条不一致 |
| 4 | 桌面队列，单条外部音频 | [深色队列](evidence/desktop-dark/queue.png) | 可读；当前曲与“接下来”关系需澄清 |
| 5 | 桌面搜索，未输入 | [搜索空查询](evidence/desktop-dark/search.png) | 提示明确；输入控件在侧栏且被截断 |
| 6 | 桌面设置，外观与播放信息 | [设置](evidence/desktop-dark/settings.png) | 分组清晰；本轮未操作设置 |
| 7 | 手机宽度歌曲/来源 | [歌曲](evidence/mobile-light/library-songs.png)、[来源](evidence/mobile-light/sources.png) | 重排正常；来源入口及曲名空间有改进余地 |
| 8 | 手机宽度舞台/队列，绝对路径静音 WAV | [舞台](evidence/mobile-light/stage.png)、[队列](evidence/mobile-light/queue.png) | 舞台显示 0:02/0:03；不能据此宣称完整播放链路通过 |
| 9 | 桌面浅色歌曲/舞台 | [歌曲](evidence/desktop-light/library-songs.png)、[舞台](evidence/desktop-light/stage.png) | 用于深浅色交叉核对 |
| 10 | 中等宽度来源 | [来源](evidence/medium-dark/sources.png) | 用于 rail 档位核对 |

桌面深色实际内容区 1898×1024（约1265×683逻辑）；手机宽度 585×1266（390×844逻辑）。其他尺寸见 `capture-*.txt`。数据来自本机既有曲库，包含191首及一个夸克来源，不是固定测试夹具。未添加、删除来源，未触发扫描/同步或修改用户设置；调试队列由脚本临时音频提供。

第一批使用相对输出目录，脚本将相对 WAV 路径交给真实播放器，出现“播放失败”。后续绝对目录批次显示可解析的3秒时长；相对路径为失败的高可信原因，但未做底层日志归因。保留第一批作为错误态证据，没有把它当作播放成功。脚本只覆盖了有库、连接、空查询、缺歌词、单条队列、播放错误；加载、整库为空、来源鉴权过期、同步中、WebDAV表单及有歌词状态仍需补证。

## 具体问题与修复要求

严重性：S1=影响主要任务或阻断验收，S2=可用性问题，S3=视觉/文案完善。以下不在本轮实施。

| ID | 类型/严重性 | 位置与证据 | 发现与明确要求 |
|---|---|---|---|
| A01 | 信息层次 S2 | 步骤1/5，左上搜索 | 提示“搜索歌曲、专辑…”被截断且类似嵌套输入框，快捷键占据较大横向空间。P1需展示完整输入/聚焦/搜索结果流程；压缩快捷键标签并保证清晰命中区。 |
| A02 | 状态一致性 S1 | 步骤1与3 | 错误条只显示“播放失败/重试”，同批舞台却呈暂停图标、0:00/0:00，缺少同等错误解释。先用固定失败快照复现，再设计统一错误原因、重试与返回队列操作；不得只换颜色或隐藏错误。 |
| A03 | 导航 S2 | 步骤2/7来源 | 桌面来源管理没有明确的导航选中项，窄屏来源归入“我的”。需验证从“我的”到来源的点击路径，为来源管理提供稳定位置提示和返回上下文。 |
| A04 | 信息密度 S2 | 步骤7歌曲首行 | 长曲名很早省略，行号、封面、时长挤占内容宽度。三方向均需用相同长标题验证，比较窄屏行号策略、时长占位和二级信息，不得压小正文换空间。 |
| A05 | 内容优先级 S3 | 步骤3/8舞台 | 外部音频无封面时巨大占位音符成为主体；桌面空歌词占据右栏。探索降低空态占位权重、缺歌词时合理收拢面板，保留歌词/队列入口。 |
| A06 | 文案/状态 S2 | 步骤4/8队列 | 唯一且带当前样式的曲目列在“接下来播放 1”下，容易混淆当前与下一首。需用播放中/已结束/多条队列验证分组语义，明确当前曲及后续列表。 |
| A07 | 验证环境 S1 | 普通测试日志、secure_store.dart:151 | 凭据文件回退无条件执行 chmod，本机测试因找不到命令失败。单独建立业务修复任务，验证平台权限策略及缓存失效，不在UI审计中顺手改动。 |
| A08 | 回归可靠性 S1 | dart_test.yaml、page_harness.dart、typography.dart | Golden默认跳过、依赖Windows环境字体；不是所有普通CI测试都做像素回归。建立固定字体/SDK/系统镜像的独立视觉任务及审批机制。 |

可保留的优点：中性背景与强调色分工明确，来源/设置有清晰分组，桌面表格可扫描，手机布局能重排，舞台在外壳之外，没有三层播放控件叠加。以上不等同于全面视觉批准。

无障碍：代码有命中区、焦点与 reduced-motion 设计及相关测试，但截图只能判断可见布局风险。未测文本放大200%、实际对比度、键盘完整路径、读屏顺序及触屏操作。P1/P2需明确移动触控下限、焦点可见、非颜色状态标识和动态字体要求，P4用真实运行验证。

## 本轮验证结果

| 命令（app目录） | 结果 | 证据 |
|---|---|---|
| `flutter analyze --no-pub` | 通过，无问题 | [日志](evidence/analyze.txt)，退出0 |
| `flutter test --no-pub --reporter expanded` | 315通过，1跳过，1失败 | [日志](evidence/tests.txt)，退出1；失败为A07 |
| `flutter test --no-pub --run-skipped -t golden --reporter expanded` | 12通过，未更新基准 | [日志](evidence/golden.txt)，退出0 |
| 既有Release启动与页面截图 | 已取得10个步骤的原图 | [采集日志](evidence/capture-desktop.txt)及其他capture日志 |

首次带pub的分析长时间未输出，已终止，改用现有锁文件与依赖执行 `--no-pub`；没有升级依赖。SDK和设备清单见 [Flutter版本](evidence/flutter-version.txt)、[设备](evidence/devices.txt)。静态分析通过不代表视觉验收通过；Golden一致只说明与历史基准一致，不代表基准已获本轮设计批准。

## 可复用调试和测试能力

- `TINGYU_DEBUG_ROUTE`、`TINGYU_DEBUG_THEME`、`TINGYU_DEBUG_DENSITY`：启动即固定页面/主题/密度；本次使用。
- `TINGYU_DEBUG_SOURCES`：本地WAV/URL队列；截图脚本输出目录必须用绝对路径。不要用需鉴权远端音源作为稳定截图夹具。
- `TINGYU_DEBUG_SCAN_DIR`、`TINGYU_DEBUG_LEGACY_JSON` 会写入曲库，本轮未使用。README列出的移动强制外壳/窗口变量不可假设对Windows有效；Windows本次靠真实窗口宽度触发FormFactor。
- `tools/windows-ui-screenshots.ps1`：路线截图；`windows-ui-flow-shots.ps1`：弹窗点击流；contact-sheet脚本：拼版。截图日志保存DPI/内容区尺寸。后两者本轮未用作交互验收。
- `windows-smoke-test.ps1` 与 narrator脚本可复用播放/原生无障碍冒烟；本轮未重跑，不引用历史结果为当前通过。
- `test/support/page_harness.dart` 有固定数据、假引擎、固定视口、动画关闭；Golden覆盖12个核心页面。`design_guard`、令牌、响应式、布局、导航、seek重建测试可以保留为保护网。没有发现 `app/integration_test/`，真实端到端交互仍是缺口。
- Windows构建必须遵循 `tools/engine-patches/README.md` 的固定补丁引擎，不能直接用官方预编译引擎替换。CI配置的五平台构建不等于本轮实际运行通过。

## 下一阶段

见 [P1三方向与执行计划](01-directions.md)。本轮只提出方向，不生成最终设计、不修改现有规范。P0尚待补充的状态和平台明确列入下一轮证据任务；P1视觉稿评审后由用户选择，P2才可制定新规范，P3才可逐页实现。
