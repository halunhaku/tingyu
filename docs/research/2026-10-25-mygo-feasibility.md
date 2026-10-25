# 调研：能不能用 MyGo 重写听屿（桌面端 / 全平台）

日期：2026-10-25
性质：**只读调研**。没有修改任何代码、没有新建原型工程、没有合并分支、没有打 tag。
核查基准：
- MyGo 仓库 `main` @ `d4067ac`（2026-10-25 14:06 +0800），最新发布 [`v0.6.3`](https://github.com/egoist/mygo/releases/tag/v0.6.3)（2026-10-23）。
- 听屿：本仓库 `app/`（Flutter 3.47 / `2.0.0-preview+5`），`main` @ `19ae15c`。

## 结论速览

| 口径 | 结论 | 一句话依据 |
|---|---|---|
| **仅桌面三平台**（macOS / Windows / Linux） | **有条件可行** | 桌面能力（窗口、原生 UI、列表/表格、SQLite、密钥、打包更新）基本齐备；**但播放内核要自建**：音频包只解 WAV/Vorbis/MP3、只出 48kHz、没有跨曲无缝、**完全没有系统媒体会话与媒体键**，且这是单文件用例，不是换库能补上的量级 |
| **全五平台**（含 Android / iOS） | **不建议** | 上游**没有** iOS/Android 后端：官方平台表只有三桌面（[docs](https://mygo.egoist.dev/docs)），路线图 16 项无移动项（[#105](https://github.com/egoist/mygo/issues/105)），iOS 只存在于个人 fork（[#157](https://github.com/egoist/mygo/issues/157) + [daodao97/mygo `feat/ios-platform`](https://github.com/daodao97/mygo)），Android 后端在 issue 评论里被"递手"但**未合并**；连 SQLite 官方插件都只支持三桌面（[docs](https://mygo.egoist.dev/docs/plugins/sqlite)） |

一句话总结：**MyGo 是一门"能写桌面应用"的年轻框架，不是"能承载一个成熟五平台音乐播放器"的框架。**桌面重写技术上走得通，但真正的成本不在界面，而在音频解码、流式播放、系统媒体控制这三块**它现在没有、也没承诺近期会做**的地方。

---

## 0. 证据边界与核查方法

- 所有版本号、star、issue 数、发布时间均来自 **2026-10-25 当日**的 GitHub REST API 与官方站点实时抓取，不是记忆。查询命令见 [§11](#11-证据清单与复核方式)。
- 文档结论来自仓库内 `docs/*.md` 原文（我已浅克隆 `main`）与站点的同名页面逐条对照。
- **我没有做原型验证**：没有跑起来一个 MyGo 应用，没有在真机上试过媒体键、没有测过 FLAC 解码性能。因此凡是「能做」的判断，都是**文档 + 源码能力**层面的判断；凡是性能数字，均引用官方基准页并标明其测量日期与机型。
- 工作量数字是**我的粗估**（依据是听屿现有代码量与被缺失能力清单），已标注「粗估」，不构成承诺。
- **查不到的，明确写「未查到」**，不用推测填补。

> ⚠️ 术语澄清（重要，避免混淆）：本报告里的「MyGo」一律指 [`egoist/mygo`](https://github.com/egoist/mygo)——用 Go 写桌面应用的框架。**不是** [`mygo-lang/mygo`](https://github.com/mygo-lang/mygo)（把类 Go 语法转译到 Go 的实验语言，描述写着 "MyGO!!!!! Transpiler"，7 star）。两者只是同名。

---

## 1. 名实核验：两个 MyGo

| 项目 | 是什么 | 关键数据（2026-10-25） | 与本需求 |
|---|---|---|---|
| [`egoist/mygo`](https://github.com/egoist/mygo) | 用 Go 写桌面应用的框架：系统 WebView 承载 Web 前端，或 `ui` 包原生 UI（Go 写、GPU 绘制） | MIT；2861 star / 152 fork；建于 2026-09-26；最新 `v0.6.3`（2026-10-23） | **就是用户口述的那个** |
| [`mygo-lang/mygo`](https://github.com/mygo-lang/mygo) | 名字取自动画《BanG Dream!》乐队 MyGO!!!!! 的转译器实验 | MIT；7 star；建于 2024-10-17；0 open issue | **无关**，不能拿来写应用界面 |

补充区分（同名干扰源）：npm 上还有一个与框架无关的抢注包 `mygo`（`1.0.0-canary.0`，描述 "Compatibility package for mygo-cli"），以及若干同名个人练手仓库；框架本体在 npm 上叫 **`mygo-cli`**、`mygo-runtime`、`@mygo-plugins/*`。

作者：**EGOIST（egoist）**，GitHub 账号 [`egoist`](https://github.com/egoist)，前端工具链作者（如 [tsup](https://github.com/egoist/tsup)，11.3k star）。仓库贡献者统计：`egoist` 516 次提交、`claude` 82 次、机器人 43 次，其后是 `saanuregh` 13、`zzstar101` 13、`rjyo` 9、`baranwang` 9 等。

---

## 2. 项目现状与维护健康度

### 2.1 基本盘

| 项 | 数值 | 来源 |
|---|---|---|
| 许可证 | MIT | [LICENSE](https://github.com/egoist/mygo/blob/main/LICENSE) |
| 首次提交 / 建仓 | 2026-09-26 | GitHub API `created_at` |
| 最新版本 | **v0.6.3**（2026-10-23） | [Releases](https://github.com/egoist/mygo/releases) |
| star / fork | 2861 / 152 | GitHub API，2026-10-25 |
| issue：累计 / 已关 | 157 / 106（**开放 51**） | GitHub Search API |
| PR：累计 / 已合 | 540 / **437** | GitHub Search API |
| `open_issues_count` | 114（= 开放 issue + 开放 PR） | GitHub API |
| release 总数 | **70 个，26 天**（v0.1.1 2026-09-27 → v0.6.3 2026-10-23） | Releases 全量分页 |
| CLI 月下载 | `mygo-cli` 12,768 次（2026-09-23 ~ 2026-10-22） | npm downloads API |
| 运行要求 | Go **1.27.3+**；纯 Go，**无 cgo**（`CGO_ENABLED=0`） | [README](https://github.com/egoist/mygo#getting-started)、`AGENTS.md` |
| 体积 / 内存 | 单文件二进制约 **7 MB**；原生 UI 约 **44 MB** 内存；WebView 模式约 **62 MB** | [官网首页](https://mygo.egoist.dev/) |

> ⚠️ **需要修正 Spec 里的一条事实**：Spec 写「当前 v0.5.x（预 1.0）」。实际核查结果是 **v0.6.3**，v0.5.x 只存在了 2026-10-14 ~ 10-16 三天（v0.6.0 已于 10-21 发布）。这个差异不影响判断方向，但报告一律以 v0.6.3 为准。

### 2.2 发布节奏：这是本项目最需要正视的一条

- 26 天 **70 个 release**，约 **2.7 个/天**；单看版本号：`v0.5.0`(10-14) → `v0.6.3`(10-23)，**9 天走了 9 个版本**（`v0.5.0/1/2/3/4/5`、`v0.6.0/2/3`）。
- 版本号停在 `0.x`：按 Go 模块与语义化版本惯例，`0.x` 期间**允许破坏性 API 变更**。
- 已发生过**破坏性变更并配了迁移工具**：`ui` 的元素从指针改为值类型，官方专门写了迁移指南，提供 codemod `go tool mygo migrate-ui` 与 `mygo vet`（[docs/ui/migration](https://mygo.egoist.dev/docs/ui/migration)）。这说明"跟着升级"是**有实际成本的持续动作**，不是一次性配置。

### 2.3 是否有正式 1.0 计划

**未查到。**依据：
- GitHub **milestones 为 0 个**（API 查询 `state=all`，返回空数组）。
- 仓库 `README.md` / `docs/*` 中没有 1.0 时间表或稳定性承诺（全文检索 `1.0`、`stability` 只命中示例版本号）。
- 公开路线图只有一份 **Native UI 能力 backlog**（[#105](https://github.com/egoist/mygo/issues/105)，2026-10-06，open），且它本身写明：排名"**not a commitment to feature parity with SwiftUI or WinUI**"，只列到 16 项能力，**没有发布日期**。

### 2.4 维护结构风险

- **单点维护**：作者本人 516 次提交；AI 代理提交者 `claude` 82 次、机器人 43 次，其余外部贡献者均 ≤13 次。至少部分 issue 正文带 `claude-projects-attribution` 标记与 Cloudflare 预览链接（如 [#654](https://github.com/egoist/mygo/issues/654)），说明相当比例的改动由代理产出。这解释了 26 天 70 个版本的速度，也意味着**代码质量与 API 稳定性依赖一个人 + 一套代理流程**。
- **bus factor ≈ 1**。对一个要长期维护的商业产品，这是需要写进风险页的事实。
- 社区确有真实使用者在提需求（如 [#654 系统媒体键](https://github.com/egoist/mygo/issues/654)、[#464 视频/采集](https://github.com/egoist/mygo/issues/464)），说明有真实用户群，但规模仍早期。

---

## 3. 平台支持：官方只有三个桌面平台

### 3.1 官方支持表（原文）

来源：[docs 首页 Requirements](https://mygo.egoist.dev/docs)（版本页脚 `v0.6.3`）

| 平台 | Web 页面模式需要 | 原生 UI 模式需要 |
|---|---|---|
| **macOS 12+** | 无需额外依赖（WKWebView 属系统） | 无需（Metal 绘制） |
| **Linux (x64, arm64)** | GTK 3 + WebKitGTK 4.1（或 4.0） | 仅 GTK 3（OpenGL 绘制） |
| **Windows 10/11 (x64, arm64)** | WebView2 Runtime（Win11 自带） | 无需（Direct3D 11 绘制） |
| iOS / Android | **无** | **无** |

其它：Linux 托盘图标另需 `libayatana-appindicator3`；`internal/unsupported` 只保证其它平台"能编译"，不是能运行。

### 3.2 移动端真相：有前史，但不在上游

必须把三件事分开说，否则容易被误读成"马上就有移动端"：

1. **上游没有移动后端。** 仓库目录树中不存在 `internal/ios`、`internal/android` 或任何移动宿主代码（我浅克隆 `main` 全量检索确认）；`docs/README.md` 的平台表只有三桌面。
2. **iOS 存在于个人 fork。** [#157](https://github.com/egoist/mygo/issues/157)（2026-10-08 关闭）标题是"Add experimental iOS native UI and mobile build tooling"，正文详述 UIKit 宿主、Metal 渲染、触摸滚动、APNs、Xcode 打包等；但**合入的是贡献者自己的 fork**，即 [`daodao97/mygo` 的 `feat/ios-platform` 分支](https://github.com/daodao97/mygo)（`bc60b9d`）。该分支已被真实应用 [`daodao97/retty`](https://github.com/daodao97/retty)（终端接力工具，macOS + iOS，Go）使用。
3. **Android 仅停留在"愿意接"的对话。** 同一 issue 评论区里，开发者 `Heyana` 提出有一份约 **1 万行**的 Android 后端（`internal/android/` + JNI + Kotlin 脚手架）可以交接，双方交换了联系方式；**没有任何 PR 合入上游**。
4. **路线图无移动项。** [#105](https://github.com/egoist/mygo/issues/105) 的 16 项 backlog 全部是桌面能力（可达性、本地化、RTL、跨应用拖放、原生视图宿主、富文本…），没有 iOS/Android。

### 3.3 这对「五平台产品」意味着什么

听屿现在是**一套 Dart 代码覆盖五端**（[README](../../README.md)、`app/pubspec.yaml`）。如果改 MyGo：

| 方案 | 结果 | 评价 |
|---|---|---|
| MyGo 重写桌面 + 保留 Flutter 移动 | **双技术栈**：两套 UI、两套播放内核、两套领域模型（Dart 一套、Go 一套），数据库或接口要跨语言对齐 | 维护成本**高于**现在的单栈，违背迁移的初衷（少维护一套） |
| MyGo 重写全部五端 | 需自养 iOS + Android 两个后端（各万行量级，且都在他人 fork / 未合并状态），并自行承接上游 API 变动 | 相当于**自己维护一门框架的移动分支**，超出"重写一个播放器"的范畴 |
| 只做桌面、移动端产品线单独演进 | 相当于承认听屿变成两个产品 | 这是**产品决策**，不是技术决策 |

**结论**：MyGo 的移动能力目前是「他人分支上的实验」，不是「可以排期依赖的平台支持」。

---

## 4. 能力边界（逐条，带官方链接与版本）

### 4.1 音频播放 —— 本次调研的**决定性缺口**

官方文档：[docs/audio](https://mygo.egoist.dev/docs/audio)（对应仓库 `docs/audio.md`，`v0.6.3`）。官方定位是"effects decoded into memory, music streamed as it plays, and sound an app makes itself… mixed in Go"——即**一个 Go 内实现的混音器**，不是系统播放器的封装。

| 能力 | MyGo 现状 | 证据 | 对听屿的含义 |
|---|---|---|---|
| **解码格式** | WAV 内置；Ogg Vorbis、MP3 各自需 import 一个可选包 | docs/audio「Formats」表 | 听屿支持 `mp3/flac/m4a/aac/wav/ogg/opus/aiff/alac` **9 种**（`app/lib/sources/local/local_library_scanner.dart:50`），**6 种缺**：FLAC、M4A/AAC、ALAC、AIFF、Opus |
| 补格式的成本 | 可通过 `RegisterFormat` 注册自定义 `Decoder` | docs/audio「Formats」 | FLAC/Opus 有较成熟的纯 Go 解码器可用；**AAC/ALAC 没有成熟纯 Go 实现**，需引入 FFmpeg 子进程或预编译原生库——而框架硬规则是 **no cgo**（`AGENTS.md`），预编译 shim 要走插件的 purego 路线（官方 SQLite 插件就是这么做的），工作量和风险都上一个台阶 |
| **输出格式** | 固定 **48 kHz 立体声**，其它采样率的 player "被重采样"；提前约 40 ms；macOS Audio Queue / Linux PulseAudio·ALSA / Windows WASAPI 共享模式 | docs/audio「The output」 | 44.1 kHz 曲目全部经过重采样，**不是位完美/独占输出**。发烧向用户会在意；普通用户无感 |
| **流式播放（WebDAV/夸克）** | `OpenStream(io.ReadSeeker)`——只吃"可 seek 的 reader"，**不认 URL** | docs/audio「Sounds and streams」 | 要自己实现基于 HTTP Range 的 `io.ReadSeeker`，再叠缓冲、预取、断流重试、seek 抖动。听屿现在由 `media_kit`(libmpv)/`just_audio` 免费得到这些 |
| **跨曲无缝（gapless）** | 只有**单文件内**循环无间隙（`SetLoop(true)`）与区间循环（`SetLoopRange`） | docs/audio「Players」 | 专辑连续播放的 gapless、淡入淡出交叉、播放结束自动下一首都要**自己写** |
| **播放结束回调** | **没有 `OnEnd`**；`Playing()` 变 false 需轮询 | docs/audio「Players」+ 源码 `audio/audio.go` 检索无 `OnEnd` | [#654](https://github.com/egoist/mygo/issues/654) 的方案里才计划给 `audio.Player` 加 `OnEnd`——反证当前没有 |
| **系统媒体会话 / 媒体键 / Now Playing / SMTC / MPRIS** | **完全没有**：`MPNowPlayingInfoCenter`、`MPRemoteCommandCenter`、`SystemMediaTransportControls`、`org.mpris.MediaPlayer2` 在整份文档与源码里都不存在 | 全仓库检索 `nowplaying`/`mediakey`/`mpris`/`smtc` 零命中；[#654](https://github.com/egoist/mygo/issues/654) 是**尚未实现的提案**（2026-10-23 open） | 这是音乐播放器的**标配**。听屿现在由 `audio_service` + `audio_service_win`(自带补丁) + `audio_service_mpris` 三端打通（`app/pubspec.yaml`）。换 MyGo 等于把这块**推倒重写**，且 macOS 的 MediaPlayer、Windows 的 SMTC 在纯 Go/no-cgo 下都要走 purego/COM 手写 |
| 后台播放 | 桌面无此概念；移动无后端 | — | 桌面端"后台"= 应用不退出，OK |
| 音量/声像/倍速 | `SetVolume` / `SetPan` / `SetSpeed`（变速同时变调，像唱片） | docs/audio「Players」 | 倍速**会变调**；若要"变速不变调"需自己做时间伸缩 |

**小结**：MyGo 的音频是"给游戏/小工具用的音效与简单音乐播放器"级别，不是"给音乐播放器产品用的播放内核"。要承载听屿，需要补齐 **格式解码 + 网络流 + 无缝 + 媒体会话** 四块，其中媒体会话（三端）与 AAC 解码是硬骨头。

### 4.2 网络与本地文件

| 能力 | 结论 | 证据 |
|---|---|---|
| HTTP / HTTPS 客户端 | **够用**：Go 标准库 `net/http`；Web 前端另有 [`fetch` 插件](https://mygo.egoist.dev/docs/plugins/fetch)（无 CORS、任意头、流式 body、可取消） | Go 生态常识 + 插件文档 |
| WebDAV（PROPFIND） | **够用**：`net/http` 自建请求 + `encoding/xml` 解析；听屿现有 `webdav_client.dart`/`webdav_xml_parser.dart` 逻辑可直译 | 无官方 WebDAV 客户端，需自写（约 300–600 行 Go） |
| 本地文件遍历 | **够用**：`os`/`io/fs`；另有官方 `watch` 插件做变更监听 | [docs/native「Watching files」](https://mygo.egoist.dev/docs/native) |
| 下载/断点 | 框架有 `downloads.go`，官方文档层面未见完整 API 说明 | 仓库文件存在，**未查到**成体系的文档，需读 `go doc` |
| Cookie（夸克登录态） | **有**：`mygo.Cookies` 可读 webview 的 cookie（含 HTTPOnly），支持按 URL 过滤 | `cookies.go`；docs/app「browsing data and cookies」 |
| 网络状态 | **有**：`Network` 状态 API | docs/native「Network」 |

### 4.3 SQLite 持久化

官方插件：[docs/plugins/sqlite](https://mygo.egoist.dev/docs/plugins/sqlite)（`v0.6.3`）。

- **零 cgo**：随插件分发预编译 SQLite 库，经 `purego` 加载；支持 macOS / Linux / Windows 的 amd64 与 arm64。
- **原生 UI 与 Go 侧可直接用**：`sqlite.Open(...)`；页面侧用 `@mygo-plugins/sqlite`，`mygo.Use(sqlite.Plugin)` 注册。
- **能力**：参数化查询、`execute`/`query`、事务、`BusyTimeout`、只读打开、`:memory:`；DB 文件默认在 `mygo.PathUserData`。
- **限制**：只支持三桌面平台；**没有 ORM/代码生成**——听屿现在的 `drift` 是"schema + 迁移 + 类型安全查询"一整套（`app/lib/data/db/schema.dart` 等 17 个文件、7,014 行），换过去要**手写 SQL + 手写迁移 + 手写映射**。

### 4.4 长列表 / 表格虚拟化（这一项 MyGo 明显强）

| 能力 | 结论 | 证据 |
|---|---|---|
| 列表虚拟化 | **强**：`ui.List` 只构建视口内行 + 少量缓冲，"a list of millions of rows is as fast as one of ten"；支持变高行（已建行实测 + 未建行估算） | [docs/ui/list](https://mygo.egoist.dev/docs/ui/list) |
| 首屏性能 | 百万行列表的**可见行**每帧 **14.5 µs / 20 次分配 / 176 B**（Apple M5，2026-10-08，`CGO_ENABLED=0 GOMAXPROCS=1`） | [docs/ui/performance](https://mygo.egoist.dev/docs/ui/performance) |
| 定位/跳转 | `ScrollTo(row, align)`、`ScrollToEnd`（含未构建行） | docs/ui/list |
| 吸顶分组头 | `Header` + 下一组头顶开，Finder 式 | docs/ui/list |
| 键盘/多选/重排 | `Selected`/`Selection`/`Submitted`、首字母跳转（`Label`）、拖拽重排 | docs/ui/list、docs/ui/drag-and-drop |
| 表格 | `ui.Table`：列头、排序、列宽拖拽、列序拖拽、单元格选择、矩形区域 TSV 复制；同样只建可见行 | [docs/ui/table](https://mygo.egoist.dev/docs/ui/table) |
| 树/大纲/网格 | `Tree`、`Outline`（任意规模）、`GridView`（照片墙式） | [docs/ui](https://mygo.egoist.dev/docs/ui) |

听屿的曲库（Spec 记为约 178 首，实际随用户库变化；扫描器单次上限 `maxFiles = 5000`）在这个维度上**毫无压力**，甚至比 Flutter 的 `ListView.builder` 更省事（原生行高估算与吸顶）。

### 4.5 图片加载与缓存（这一项要自建）

- **有的**：`ui.DecodeBitmap` 支持 PNG/JPEG/GIF(首帧)/WebP/BMP、EXIF 方向校正；`ui.ParseSVG`/`MustParseSVG`；GPU 纹理常驻；给小尺寸时自动取"减半副本"避免闪烁；`Pixelated` 像素风；`Fit`/`Radius`/`Grayscale`。（[docs/ui/image](https://mygo.egoist.dev/docs/ui/image)）
- **没有的**：**网络图片加载、磁盘缓存、内存 LRU、解码并发控制、失败重试、占位/骨架**——文档明确要求"Make bitmaps once, not in the view"，即**由应用自己管生命周期**。
- 对听屿的含义：现在 `cached_network_image` 一行搞定的封面墙，换过去要自建"HTTP 取图 → 落盘（内容哈希）→ 解码 → LRU → 淘汰"整条管线。仓库里 `cover_store.dart` 已有落盘与回收逻辑，可作为移植参照，但代码要重写。
- 另外，**封面取色**（DESIGN.md §2.5）没有现成 API：需自己用 `image/jpeg` 解码出 RGBA、丢弃极端亮度/饱和度、聚类算主/次色。逻辑可直译，属于可控工作量。

### 4.6 字体排版 / 主题 / 深色 / 动画

| 能力 | 结论 | 证据 |
|---|---|---|
| 字体 | 系统字体（CoreText / DirectWrite / Pango），**可 `ui.RegisterFont` 内嵌自有字体**，可按 family 列表回退；`ui.FontFamilies()` 列系统字体 | [docs/ui/text](https://mygo.egoist.dev/docs/ui/text) |
| 排版细节 | `FontSize/FontWeight/Italic/LineHeight/FixedLineHeight/LetterSpacing/FontFeatures`（OpenType，如 `tnum`、关连字）；富文本 `Span`（字体/字号/粗斜/颜色/下划线/删除线/背景/圆角） | docs/ui/text |
| 中文/IME | 系统文本引擎负责断行与输入法组合；中日文逐字成词的修复见 issue #671（已关闭） | docs/ui/text、[#671](https://github.com/egoist/mygo/issues/671) |
| 主题/设计令牌 | `c.Theme()` 提供 light/dark，**跟随系统外观实时切换**，并跟随桌面设置（强调色、可达性偏好） | [docs/ui/styling](https://mygo.egoist.dev/docs/ui/styling)、[docs/native「Dark mode」](https://mygo.egoist.dev/docs/native) |
| 样式能力 | 背景/边框（含分段边框、虚线）/圆角/阴影（外+内）/不透明度/`Gradient`/`LinearGradient`（Oklab 混色、多 stop）/`ConicGradient`/渐变描边/条纹/`Blur`（元素+子树，GPU）/`Material`（材质，如 glass 插件）/`Oklch()` 广色域 | docs/ui/styling |
| 动效 | `AnimateTo(key, target, spring 或 curve)`、spring 保速、曲线、延迟与交错、手势投掷、关键帧、多轨 timeline、"何时结束"回调、`WithoutAnimation`、减少动态偏好、滚动驱动 | [docs/ui/motion](https://mygo.egoist.dev/docs/ui/motion) |
| 布局变化过渡 | `Transitions`：元素随布局变化平滑移动/改变尺寸/变色 | [docs/ui/transitions](https://mygo.egoist.dev/docs/ui/transitions) |
| 任意元素变换 | `Transforms`：位移/缩放/旋转，指针、文本输入、可达性跟随 | [docs/ui/transforms](https://mygo.egoist.dev/docs/ui/transforms) |
| GPU 着色器 | 用 Go 语法写着色器（`ui.Shader`），uniform 可传图像/颜色，可做元素级 layer effect | [docs/ui/shaders](https://mygo.egoist.dev/docs/ui/shaders) |
| 共享元素 Hero 转场 | **没有内置**（Flutter 的 `Hero` 概念不存在）；要自己做：两个元素在同一帧内用 transform + 交叉淡入拼出 | 文档无此概念；`Transforms` 可作基础 |
| 无障碍 | 有（读屏可读原生 UI），但路线图自认"文本与集合可达性未完成"（[#105](https://github.com/egoist/mygo/issues/105) 第 1、2 项） | docs/ui/accessibility、#105 |

听屿视觉规格与 MyGo 的对照（逐条，对应 `DESIGN.md` §2.5 / §7.2）：

| 听屿规格 | MyGo 能否实现 | 说明 |
|---|---|---|
| 单层 160° 线性渐变舞台，主色→次色，压平 35% | ✅ 能 | `LinearGradient` 多 stop + 单层元素；还能顺手用 shader 做更细腻的噪声/漂移 |
| 封面动态取色 + LRU 64 + isolate 提取 | ✅ 能（逻辑自写） | Go 侧 goroutine + 自建缓存；无 `compute()` 等价物，但 goroutine 更直接 |
| `ambientDrift` 24s 渐变起止点插值 | ✅ 能 | `AnimateTo` + 循环，或 timeline |
| `stageExpand` 320ms，封面 Hero 共享元素 | ⚠️ **需手写** | 无 Hero；用 transforms + 两个 element 的交叉淡入近似，**观感会有差异**，需专门调 |
| `stageCollapse` 手势 1:1 跟随 + 35% 阈值按速度回弹 | ✅ 能 | 手势 + 投掷速度（docs/ui/motion「Gestures」） |
| `listStagger` 首屏 6 项 20ms 递增 | ✅ 能 | 延迟/交错 |
| `lyricFocus` 240ms 透明度 + translateY(-2) | ✅ 能 | 富文本 span + 动画 |
| 响应式断点（<640 / 640–1023 / ≥1024） | ✅ 能（自写） | 无 `LayoutBuilder`，用窗口尺寸 + 断点函数；窗口 resize 事件有 |
| 磨砂/玻璃材质 | ✅ 能（更强） | `Blur` / glass 插件（Liquid Glass）/ 窗口 vibrancy |
| 深浅色 + 系统强调色 | ✅ 能 | theme 跟随系统 |
| 列表重绘隔离（进度 tick 不重建列表） | ✅ 能（范式不同） | 即时模式按帧重建视图，但列表只建可见行、位图常驻 GPU；官方基准给出帧成本，需实测确认与听屿同等体验 |

### 4.7 系统集成

| 能力 | 结论 | 证据 |
|---|---|---|
| 文件/目录选择、保存、消息框 | ✅ `mygo.Dialog.Open/Save/Message/Error`（macOS 上可作 sheet） | [docs/native「Dialogs」](https://mygo.egoist.dev/docs/native) |
| 通知 | ✅ 系统通知（macOS 首次询问权限；Windows 气泡；Linux 桌面服务），可分组/替换/点击回调 | docs/native「Notifications」 |
| 托盘 / Dock / 应用菜单 / 右键菜单 / 全局快捷键 | ✅ 均有（含 Linux `libayatana-appindicator3` 依赖） | [docs/menus](https://mygo.egoist.dev/docs/menus)、docs/native「Global shortcuts」 |
| 剪贴板 / 拖放 | ✅ 文本、HTML、图片、文件列表、自定义格式；窗口内拖拽、接收文件拖入 | docs/native、[docs/data-transfer](https://mygo.egoist.dev/docs/data-transfer) |
| 凭据存储（夸克 Cookie、WebDAV 密码） | ✅ `mygo.Secrets`：macOS Keychain / Linux Secret Service(libsecret) / Windows Credential Manager；单条上限 2560 B | docs/native「Secrets」 |
| 深链 / 单实例 / 开机自启 / 最近文档 | ✅ | docs/app |
| 自动更新 | ✅ 签名更新（GitHub Releases / S3 / 自建），含 delta 与 Sparkle 式更新窗 | [docs/updates](https://mygo.egoist.dev/docs/updates) |
| 打包分发 | ✅ `.app`+`.dmg`、Windows 安装器、`.deb`+`install.sh`；签名/公证；GitHub Actions 全平台流水线 | [docs/distribution](https://mygo.egoist.dev/docs/distribution) |
| **系统媒体控件（Now Playing / SMTC / MPRIS / 媒体键）** | ❌ **没有**（见 §4.1） | — |
| iOS/Android 系统集成 | ❌ 上游无移动后端 | §3.2 |

### 4.8 汇总：内置 / 需自建 / 缺失

| 能力块 | 状态 | 需自建量级（粗估） |
|---|---|---|
| 窗口、菜单、托盘、通知、对话框、快捷键、深链 | 🟢 内置 | 0 |
| 列表/表格/树/网格虚拟化、吸顶、跳转、多选 | 🟢 内置 | 0 |
| 布局、样式、渐变、模糊、材质、主题、动效、变换 | 🟢 内置 | 小（无 Hero，需手写） |
| 字体与中文排版、IME、富文本 | 🟢 内置 | 0 |
| SQLite 持久化 | 🟢 官方插件 | 中（无 ORM，schema 与迁移手写） |
| 凭据存储 | 🟢 内置 | 0 |
| 打包/签名/更新/CI | 🟢 内置 | 小（配置为主） |
| UI 测试（无窗口） | 🟢 内置 `ui.Tester` | 0 |
| HTTP / WebDAV / 文件遍历 | 🟡 标准库自建 | 小–中 |
| 图片网络加载 + 磁盘/内存缓存 + 取色 | 🟡 全自建 | 中 |
| 音频**解码格式**扩展 | 🟡 部分可得（FLAC/Opus 有纯 Go），AAC/ALAC 难 | 中–大 |
| 音频**流式**（HTTP Range + 缓冲 + seek） | 🟡 全自建 | 中 |
| 跨曲 gapless / 自动续播 / 结束回调 | 🟡 全自建 | 中 |
| **系统媒体会话 + 媒体键（三端）** | 🔴 缺失（#654 提案未实现） | **大** |
| iOS / Android 平台后端 | 🔴 上游缺失（他人 fork） | **极大** |

---

## 5. 「怎么写好看的 MyGo 页面」

这是用户最关心的部分，结论先说：**官方组件给得相当足（近百个），文档质量高、每页带可交互预览；但"好看的房子"要自己设计——官方的审美基调是 macOS 原生风，第三方组件库/设计系统生态基本为零。**

### 5.1 官方 `ui` 包组件清单（v0.6.3）

`ui` 包内以 `c *ui.Context` 为首参的导出构造函数共 **98 个**（含 `*Base` 基类与 `Textf` 这类工具函数，真正的复合控件约 80 个）；另有独立子包 `ui/chart` 提供图表原语。

按官方分类整理（每类都能在 [docs/ui](https://mygo.egoist.dev/docs/ui) 找到对应页面）：

| 分类 | 组件 |
|---|---|
| 操作 | `Button`/`PrimaryButton`/`ButtonBase`、`Link`、`MenuButton`、`Context menu`、`Toggle`/`ToggleGroup`、`Segmented`、`Toolbar` |
| 选择 | `Checkbox`/`CheckboxGroup`、`Switch`、`RadioGroup`、`Select`、`Slider`/`StepSlider`/`RangeSlider`、`Stepper`、`Rating` |
| 文本输入 | `TextInput`、`TextArea`、`NumberInput`、`SearchField`、`Combobox`、`Autocomplete`、`TokenField`、`EditableText`、`FindBar`、`RichText` 编辑器 |
| 代码/文档 | `Code editor`、`DiffViewer`、`Markdown` |
| 日期颜色 | `Calendar`、`DateInput`、`TimeInput`、`ColorPicker`/`ColorWell` |
| 集合 | `List`、`Table`、`Tree`/`TreeItem`、`Outline`、`GridView` |
| 容器 | `Scroll`/`ScrollBoth`/`ScrollHorizontal`、`Grid`、`Split`/`SplitVertical`、`Collapsible`/`CollapsibleItem`、`Accordion`/`AccordionItem`、`Form`/`Fieldset`/`Field`、`WebView` |
| 导航 | `Tabs`、`Sidebar`/`SidebarItem`/`SidebarSection`、`Breadcrumbs`、`BackButton`/`ForwardButton` |
| 弹层 | `DialogBase`/`Modal`、`AlertDialog`、`Popover`、`TooltipBase`、`ToastBase`/`ToastViewportBase`、`Overlay` |
| 状态 | `Progress`、`Spinner`、`Meter`、`Badge` |
| 图表 | 子包 `ui/chart`：`chart.Plot`/`Rect`/`Point`/`RuleX`、刻度/轴/堆叠/环形，指针与键盘可选中，颜色尺寸字体全部自定 |
| 图像 | `Image`、`Icon`、`Avatar` |
| 基础 | `Box`、`Row`、`Column`、`Spacer`、`Divider`、`Text`、`Textf`、`Clip` 等 |

另有官方插件补"氛围件"：
- [Glass](https://mygo.egoist.dev/docs/plugins/glass)：仿 macOS Liquid Glass 的材质（**听屿磨砂观感的正解**）。
- [Loading](https://mygo.egoist.dev/docs/plugins/loading)：loading.dev 的 29 个加载指示器（骨架屏可用）。
- 其余：sqlite / fetch / websocket / watch / updater / terminal / game。

### 5.2 官方文档的"教学材料"质量

- 每篇组件页开头有 `<!-- preview xxx -->` 标记，官网用 `website/docs-demo` 组件把它渲染成一个**可交互的实时预览**（仓库源码可证；我未逐页在浏览器里点过），比静态截图有用得多。
- 有专门的 **Performance**（帧成本/内存实测）、**Testing**（无窗口跑 UI 测试）、**Rendering**（GPU/CPU 回退、`MYGO_FRAME_STATS` 帧剖析）、**Inspector**（元素树 + 样式 + 耗时）、**Accessibility**、**Migration** 页面——这套"工程化配套"在新框架里相当罕见，是加分项。
- 官网自带 **Benchmarks** 面板（每次 push 在 macOS/Linux/Windows runner 上测）。

### 5.3 示例项目（官方 examples，32 个目录）

仓库 [`examples/`](https://github.com/egoist/mygo/tree/main/examples)：`gallery`（控件与布局总览，**最接近"组件库巡览"**）、[`piano`](https://github.com/egoist/mygo/tree/main/examples/piano)（合成器，含音频示例）、`notes`、`todo`、`chart-streaming`、`code-editor`、`confetti`、`terminal`、`menubar-native`、`flyout`、`vibrancy`、`mayoi` 等。
与听屿最相关的是 `gallery`（设计语汇参考）与 `piano`（音频 API 用法）。

### 5.4 社区文章、真实上线应用、第三方组件库

| 项 | 结论 | 依据 |
|---|---|---|
| 中文教程 / 博客文章 | **未查到**（在本次可用的检索渠道内） | DuckDuckGo 仅返回官方站、GitHub、pkg.go.dev 与聚合站（reporank/hysenlabs 之类）；Bing/Mojeek 在本机被拦或空结果 |
| Hacker News 讨论 | **未查到** | HN Algolia 检索 `mygo`/`egoist mygo`/`mygo desktop` 无相关 Story（其余为 "My Go" 短语噪音） |
| 真实上线应用 | **找到 1 个**：[`daodao97/retty`](https://github.com/daodao97/retty)（Retty：终端无缝接力，macOS + iOS，Go，27 star，但它用的是 **fork 的 iOS 分支**，不是上游） | issue [#157](https://github.com/egoist/mygo/issues/157) 评论区自述 |
| 官方 showcase | **无**：官网只有 docs / examples / benchmarks，没有"谁在用"页面 | 官网导航与页面结构 |
| 第三方组件库 / 设计系统 | **未查到**。npm 搜索 `mygo` 只有官方包（`mygo-cli`、`mygo-runtime`、`@mygo-plugins/*`）+ 一个无关抢注包 | npm registry 搜索 API |
| Go 模块被引用数 | **未查到可靠数字**（pkg.go.dev 的 Imported by 需 JS 渲染；deps.dev 对该模块返回 404 "dependents not found"） | 两次 API 尝试均失败 |

**生态判断**：能直接复用的"设计系统"**只有官方 `ui` 包自带的主题与近百个组件**。想做出听屿那种有辨识度的观感，靠的是**用它的样式/动效原语自己搭一套令牌**——这和 Flutter 侧 `lib/design/tokens/*` 是一模一样的工作，只是换语言重做一遍。

### 5.5 与听屿现有设计系统的对照结论

听屿 `app/lib/design/` 有 33 个文件、10,805 行（令牌 + 23 个组件文件 + 布局）。MyGo 侧**不存在"迁移"，只有"重画"**：
- 令牌（颜色/字阶/间距/圆角/动效时长曲线）可从 `tokens/*.dart` 直译成 Go 结构体，工作量小。
- 23 个组件文件（`transport.dart` 1150 行、`track.dart` 865 行、`player_stage.dart` 506 行…）要在即时模式范式下重写：**同样的视觉，不同的写法**，这是本次迁移里最大的确定性成本。
- 唯一"天然更强"的是列表/表格（虚拟化与吸顶是内置的）。

---

## 6. 迁移成本

### 6.1 现状盘点（基线）

| 模块 | 文件数 | 行数 | 迁移性质 |
|---|---:|---:|---|
| `app/lib/app/`（外壳/路由/主题装配） | 6 | 1,715 | 重写 |
| `app/lib/design/`（令牌 + 23 个组件文件 + 布局） | 33 | 10,805 | **重画** |
| `app/lib/features/`（12+ 个页面 + 播放舞台/歌词/队列/命令面板） | 38 | 11,557 | **重画** |
| `app/lib/data/`（drift 数据库、仓储、封面存储、安全存储、设置） | 17 | 7,014 | 重写（去 ORM） |
| `app/lib/sources/`（本地/WebDAV/夸克/抓取/AI） | 31 | 4,915 | 直译为主 |
| `app/lib/playback/`（双引擎抽象、控制器、快照） | 8 | 1,211 | 重写（引擎换成自建） |
| `app/lib/main.dart` | 1 | 463 | 重写 |
| **合计** | **134** | **37,680** | — |
| 测试 | 71 个 Dart 测试文件 | — | 大部分需重写（`ui.Tester` 可承接 UI 测试） |
| 平台桥 | `tingyu_saf`（SAF）、`audio_service_win`（vendored 补丁） | — | `tingyu_saf` 仅移动端，桌面重写可整体丢弃；`audio_service_win` 提供的 Windows SMTC/媒体键**反而必须重写** |

### 6.2 逐模块评估（「直译 / 重写 / 需原生 / 缺失」）

| 功能块 | 现状实现 | MyGo 侧结论 | 量级（人日，粗估） |
|---|---|---|---:|
| 曲库表结构 + 迁移 + 仓储 | drift | 重写：手写 SQL + 迁移 + 映射（无 ORM/代码生成） | 8–12 |
| 本地文件夹源（遍历/标签/封面落盘/增量判断） | `local_library_scanner.dart` + `audio_metadata_reader` | 直译为主（Go 有成熟标签库；遍历/哈希/增量逻辑照搬） | 8–12 |
| WebDAV 源 | `webdav_client.dart` + XML 解析 | 直译（`net/http` + `encoding/xml`） | 3–5 |
| 夸克网盘（网页登录/二维码/Cookie/直链） | `quark_*` 7 个文件 + webview | 直译 + 用 `mygo.Cookies`/`WebView` 窗口替代 `webview_flutter`；二维码需引 Go QR 库 | 8–12 |
| 元数据刮削 4 源 + OpenCC + 人工匹配 + AI | `scraper/*`、`ai/*` | 直译（HTTP + JSON 解析）；OpenCC 需换纯 Go 字表实现 | 8–12 |
| **播放内核**（格式解码、流式、队列、循环、失败快照） | `media_kit`/`just_audio` + `PlaybackEngine` 抽象 | **重写**：补 6 种格式解码器、HTTP Range reader、gapless、`OnEnd` 自建 | 18–30 |
| **系统媒体会话 + 媒体键（macOS/Windows/Linux）** | `audio_service` + `audio_service_win` + `audio_service_mpris` | **缺失，需原生**：purego 调 MediaPlayer、手写 MPRIS（godbus）、COM 调 SMTC | 15–30（若上游 #654 落地，降到 3–5 集成） |
| 设计系统 + 12+ 个页面（响应式、深浅色、无障碍） | `design/` + `features/` | **重画**（即时模式范式） | 30–45 |
| 封面取色 + 图片缓存管线 | `stage_palette.dart`、`cover_store.dart`、`cached_network_image` | 重写（无网络图缓存、无取色 API） | 5–8 |
| 打包/签名/公证/自动更新/CI | Flutter 各平台打包 + GitHub Actions | 重写配置（框架自带 dmg/NSIS/deb/更新器） | 5–8 |
| 测试体系 | 71 个测试文件 + golden | 重写（`ui.Tester` + Go 单测；golden 需另建） | 8–12 |
| **合计** | | | **116–186** |

**换算**：116–186 人日 ≈ **5.5–9 人月**（单人全投入）；若媒体会话等上游 #654 合并，可压到约 **100–160 人日（5–8 人月）**。
这是**纯开发**估算，不含设计重做、用户验收、双栈并行期的维护、以及跟着 MyGo 0.x 升级的持续成本。

### 6.3 三条可执行路线

| 路线 | 做法 | 工作量（粗估） | 得到什么 | 代价/风险 |
|---|---|---|---|---|
| **A. 保持 Flutter** | 不动技术栈 | 0 | 现状全部能力 | 放弃"小体积/低内存/原生观感"；Flutter 桌面在 macOS 上仍是自绘 UI，与系统观感有差 |
| **B. MyGo 原生 UI 重写桌面三端** | Go 单一语言；音频内核自建；桌面三平台发布；移动端另行决定 | **5.5–9 人月** | 单文件 ~7 MB、原生内存 ~44 MB、系统级观感、单一语言栈 | 播放内核与媒体键自建；0.x 升级成本；生态薄；UI 需重画 |
| **C. MyGo 外壳 + Web 前端重写**（webview 模式） | 用 HTML/CSS/TS 重写界面，Go 做后端与音频 | 与 B 相当（前端换语言，工作量不降），UI 自由度最高 | 前端生态最丰富（Tailwind/shadcn 等可直接用，**解决"好看的页面"问题**） | 内存 ~62 MB（比 B 高）；仍是 WebView 渲染，无原生控件观感；音频缺口同样存在 |

> 无论 B 还是 C，**音频内核与系统媒体会话都得自己做**——这两块与"用不用 `ui` 包"无关。

### 6.4 建议的最小先验验证（spike，3–5 人日）

在下任何结论之前，值得先花几天证伪这三件事（成本极低、信息量极大）：
1. **FLAC + HTTP Range 流式播放**：注册自定义 Decoder + 自写 `ReadSeeker`，放一首 24/44.1 的 FLAC 与一首 WebDAV 上的曲目，看 CPU 与 seek 手感。
2. **三端媒体键**：macOS 用 purego 接 `MPRemoteCommandCenter`、Linux 起一个 godbus MPRIS、Windows 试 COM SMTC——**任一端卡住，路线 B/C 的成本就要重估**。
3. **即时模式下的"舞台"观感**：把 `player_stage` 的渐变漂移 + 封面 Hero 用 `AnimateTo` + transforms 复刻一版，人工对比观感差距。

---

## 7. 备选对比（同价位/同诉求）

| 方案 | 一句话定位 | 授权 / 最新版（2026-10-25） | 在「五平台 + 高质量音乐播放器界面」上的短板 |
|---|---|---|---|
| **继续 Flutter**（现状） | 一套 Dart 代码覆盖五端，UI 完全自绘 | BSD-3；Flutter **3.47.8**（2026-10-23） | 桌面端非原生控件观感；macOS 内存/体积偏大；已有 `media_kit`/`just_audio`/`audio_service` 生态**已经解决**音频与媒体会话 |
| **MyGo（egoist/mygo）** | Go 单语言桌面框架，原生 UI 或系统 WebView；小体积低内存 | MIT；**v0.6.3**（2026-10-23），0.x | **无移动后端**；音频只到"简单播放器"级别；**无媒体会话/媒体键**；生态与社区极早期；bus factor 1 |
| **Wails** | Go + 系统 WebView，思路最接近 MyGo 的 WebView 模式 | MIT；**v2.17.0**（2026-10-18）；**v3 仍在 beta**（`v3.0.0-beta.34`，2026-10-20） | 仅桌面三平台；WebView 渲染无原生观感；v3 长期 beta；音频同样要自己接 Go 库或前端 `<audio>` |
| **Tauri v2** | Rust 内核 + 系统 WebView，**官方支持 iOS/Android** | Apache-2.0；CLI **2.12.4**（2026-10-21） | 不是 Go（团队要学 Rust 才能写原生侧）；WebView 渲染；移动端音频/媒体会话仍需自写插件；Rust↔JS 边界增加复杂度 |
| **Fyne** | Go 原生自绘 UI，主打"一套代码桌面+移动" | BSD-3；**v2.8.2**（2026-10-12） | 移动端是"可打包"级别（[README](https://github.com/fyne-io/fyne) "Packaging for mobile"）；控件观感与交互细腻度**达不到 Apple Music 级**；复杂动效/材质吃力 |
| **Gio** | Go 即时模式 GUI，底层、跨 Android/iOS/桌面/WASM | 见 [gioui.org](https://gioui.org)（GitHub 为镜像，2284 star） | 极低层：组件只有 `widget/material` 一层薄封装，**没有表格/虚拟化列表/富文本/对话框这些成品**；做播放器基本等于先写半个 UI 框架 |
| **Bubble Tea** | Go 终端 TUI 框架 | MIT；**v2.1.0**（2026-10-08） | 终端里跑，**不是图形界面**；与"好看的桌面播放器"不同赛道 |

一句话对比：
- 要**保住五平台**又想要新技术栈 → **Tauri v2** 是唯一官方支持移动端的同代方案（代价：Rust）。
- 要**留在 Go** → **Wails**（WebView 路线、生态比 MyGo 成熟）或 **MyGo**（原生 UI 路线、观感更好但更年轻）。
- **Flutter 的音频/媒体会话能力是这轮对比里唯一"已经全绿"的**，这恰恰是 MyGo 最红的一块。

---

## 8. 结论

### 口径一：只看桌面三平台

**有条件可行（Conditional Go）。** 条件如下，缺一不可：

1. **接受播放内核自建**：补 FLAC/Opus（纯 Go 可得）与 AAC/ALAC（需 FFmpeg 子进程或预编译原生 shim），自写 HTTP Range 流式与跨曲 gapless，自建播放结束回调。
2. **接受三端媒体会话从零做**：macOS `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`、Windows SMTC（COM）、Linux MPRIS（D-Bus），或**明确等上游 [#654](https://github.com/egoist/mygo/issues/654) 合并**再把这块降级为集成工作。
3. **接受 UI 是"重画"而非"迁移"**：约 2.2 万行 Dart（design + features）在即时模式范式下重写；共享元素 Hero 需手写近似。
4. **接受 0.x 风险**：26 天 70 个版本、已发生破坏性 API 变更并配 codemod、无 1.0 计划、bus factor 1。升级预算要按"每季度一轮适配"预留。
5. **接受生态薄**：没有第三方组件库/设计系统，官方文档与 examples 是唯一弹药。

在上述条件下，路线 B（原生 UI）能换来：**单文件约 7 MB、原生内存约 44 MB、系统级观感、Go 单一语言栈**。这是一笔"用 5.5–9 人月换长期单栈"的交易，**是否值得取决于用户对"重写一遍界面"和"自建播放内核"的意愿**，不是技术上的不可能。

### 口径二：全五平台

**不建议。** 依据不是"观感"或"性能"，而是三条**平台事实**：

1. 上游**没有** iOS/Android 后端，官方平台表只有三桌面（[docs](https://mygo.egoist.dev/docs)）。
2. iOS 支持只存在于个人 fork（[#157](https://github.com/egoist/mygo/issues/157) → [daodao97/mygo](https://github.com/daodao97/mygo) `feat/ios-platform`），Android 只有"愿意交接"的对话，**均未合入上游**；上游路线图（[#105](https://github.com/egoist/mygo/issues/105)）无移动项。
3. 连官方 SQLite 插件都只覆盖 macOS/Linux/Windows。

在「五平台」目标下用 MyGo，等于自己接手维护两个移动后端；或退化成 Flutter + MyGo 双栈——后者维护成本高于现状，与迁移动机相悖。

### 一句话建议（不是决定）

**如果目标只是"桌面端更好看、更轻"**，值得先做 §6.4 的 3–5 人日 spike，用事实决定是否投 5.5–9 人月；
**如果目标是"五平台换 Go"**，现阶段应排除 MyGo，把 Tauri v2（Rust + 官方移动端）或"继续 Flutter"作为对照候选。
最终取舍属于用户——本报告只给证据与条件，不做决定。

---

## 9. 风险登记

| 风险 | 影响 | 证据 | 缓解 |
|---|---|---|---|
| **媒体会话缺失** | 音乐播放器核心体验（锁屏/控制中心/媒体键）没有 | [#654](https://github.com/egoist/mygo/issues/654) open | 等上游 / 自建 / 作为"暂不迁移"的依据 |
| **0.x 破坏性变更** | 每次升级都可能改 API | [migration 指南](https://mygo.egoist.dev/docs/ui/migration)、9 天 9 个版本 | 锁版本 + 预留适配预算 + 跟进 codemod |
| **单点维护（bus factor 1）** | 上游停更/转向，下游无支援 | 贡献者统计（egoist 516 / claude 82 / bot 43） | 评估 fork 自养成本 |
| **生态为零** | 无第三方组件/教程，遇到问题只能读源码 | npm 搜索、HN/搜索无结果 | 依赖官方 docs + 源码 |
| **移动端不可排期** | 五平台目标落空 | §3.2 | 二选一：放弃移动 or 不选 MyGo |
| **AAC/ALAC 解码需绕开 no-cgo** | 引入 FFmpeg 子进程会带来打包与许可证复杂度 | `AGENTS.md` "No cgo" | 用预编译 shim（学官方 SQLite 插件）或转码缓存 |
| **无 ORM** | 数据层要重写并自行保证迁移正确 | §4.3 | 复用 drift schema 生成 SQL DDL 作为起点 |
| **性能数字来自官方 bench** | 未在听屿负载下验证 | [docs/ui/performance](https://mygo.egoist.dev/docs/ui/performance)（M5，2026-10-08） | spike 内自测 |

---

## 10. 待确认（写进报告，不预设答案）

1. **迁移范围**：只做桌面三平台，还是必须保住五平台？（本报告已按两种口径分别给结论）
2. **对 0.x 预 1.0 框架的风险接受度**：能否接受"每季度一轮 API 适配"？如果要求"两年不用动框架 API"，MyGo 现在给不了这个保证。
3. **媒体键/系统媒体控制是不是死线需求**：如果是，MyGo 当前状态直接否决；如果可以等上游 #654 落地，桌面路线才成立。
4. **"好看的页面"指的是什么**：是"原生 macOS 观感"（`ui` 包强项），还是"高度定制、复杂排版/动画的视觉"（WebView 路线 + Web 生态更强）？这决定 B/C 路线的取舍。

---

## 11. 证据清单与复核方式

### 关键链接（均于 2026-10-25 访问；GitHub 的 issue/tag 链接会先 302 规范化再 200，最终均可打开）

**MyGo 本体**
- 仓库：https://github.com/egoist/mygo
- 文档首页（含平台表）：https://mygo.egoist.dev/docs
- 最新发布：https://github.com/egoist/mygo/releases/tag/v0.6.3
- 原生 UI 总览：https://mygo.egoist.dev/docs/ui
- 音频：https://mygo.egoist.dev/docs/audio
- 桌面 API（对话框/通知/密钥/深色/监视文件/快捷键）：https://mygo.egoist.dev/docs/native
- SQLite 插件：https://mygo.egoist.dev/docs/plugins/sqlite
- 列表虚拟化：https://mygo.egoist.dev/docs/ui/list
- 表格：https://mygo.egoist.dev/docs/ui/table
- 图片：https://mygo.egoist.dev/docs/ui/image
- 文本与字体：https://mygo.egoist.dev/docs/ui/text
- 样式与主题：https://mygo.egoist.dev/docs/ui/styling
- 动效：https://mygo.egoist.dev/docs/ui/motion
- 过渡：https://mygo.egoist.dev/docs/ui/transitions
- 变换：https://mygo.egoist.dev/docs/ui/transforms
- 着色器：https://mygo.egoist.dev/docs/ui/shaders
- 性能实测：https://mygo.egoist.dev/docs/ui/performance
- UI 测试：https://mygo.egoist.dev/docs/ui/testing
- 迁移指南（破坏性变更证据）：https://mygo.egoist.dev/docs/ui/migration
- 打包分发：https://mygo.egoist.dev/docs/distribution
- 自动更新：https://mygo.egoist.dev/docs/updates
- Web 前端模式：https://mygo.egoist.dev/docs/frontend
- 菜单与托盘：https://mygo.egoist.dev/docs/menus
- 路线图 backlog：https://github.com/egoist/mygo/issues/105
- 系统媒体键提案（open）：https://github.com/egoist/mygo/issues/654
- iOS 实验分支议题：https://github.com/egoist/mygo/issues/157
- 视频/媒体后端提案（open）：https://github.com/egoist/mygo/issues/464
- 示例 gallery：https://github.com/egoist/mygo/tree/main/examples/gallery
- 示例 piano（音频）：https://github.com/egoist/mygo/tree/main/examples/piano
- 同名但无关的仓库：https://github.com/mygo-lang/mygo
- iOS fork：https://github.com/daodao97/mygo（分支 `feat/ios-platform`）
- 使用该 fork 的真实应用：https://github.com/daodao97/retty

**备选方案**
- Wails：https://github.com/wailsapp/wails （v2.17.0 / v3.0.0-beta.34）
- Tauri v2：https://github.com/tauri-apps/tauri 、移动端文档 https://v2.tauri.app/develop/
- Fyne：https://github.com/fyne-io/fyne 、移动打包见 README「Packaging for mobile」
- Gio：https://gioui.org 、GitHub 镜像 https://github.com/gioui/gio
- Bubble Tea：https://github.com/charmbracelet/bubbletea
- Flutter 版本矩阵：https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json （stable 3.47.8，2026-10-23）

### 复核命令（可直接重跑）

```bash
# 1) 仓库元数据（star / fork / 建仓时间 / license / 最新 push）
curl -s https://api.github.com/repos/egoist/mygo | jq '{stargazers_count,forks_count,created_at,license:.license.spdx_id,pushed_at}'

# 2) 最新发布
curl -s https://api.github.com/repos/egoist/mygo/releases/latest | jq '{tag_name,published_at}'

# 3) issue / PR 统计
curl -s 'https://api.github.com/search/issues?q=repo:egoist/mygo+is:issue' | jq .total_count
curl -s 'https://api.github.com/search/issues?q=repo:egoist/mygo+is:issue+is:closed' | jq .total_count
curl -s 'https://api.github.com/search/issues?q=repo:egoist/mygo+is:pr+is:merged' | jq .total_count

# 4) 是否存在移动后端（应无输出）
git clone --depth 1 https://github.com/egoist/mygo /tmp/mygo-src
ls /tmp/mygo-src/internal | grep -E 'ios|android' || echo "无移动后端"

# 5) 是否有系统媒体键实现（应无输出）
grep -rni "nowplaying\|mpris\|smtc\|mediakey" /tmp/mygo-src --include=*.go | grep -v _test || echo "无媒体会话实现"

# 6) 音频支持的格式（应只有 wav/mp3/vorbis）
ls /tmp/mygo-src/audio /tmp/mygo-src/audio/*/

# 7) 1.0 计划（milestones 应为空）
curl -s 'https://api.github.com/repos/egoist/mygo/milestones?state=all' | jq 'length'

# 8) npm 下载量
curl -s https://api.npmjs.org/downloads/point/last-month/mygo-cli
```

### 本次核查中「未查到」的项（不用推测填补）

- MyGo 的正式 1.0 计划、路线图时间表、稳定性承诺 → **未查到**（milestones 为空、文档无表述）。
- 第三方 MyGo 组件库/设计系统 → **未查到**。
- 中文教程/博客/视频 → **未查到**（受本机检索渠道限制：DuckDuckGo 可用但仅返回官方与聚合站，Bing/Mojeek 被拦或空结果）。
- Hacker News 上的讨论帖 → **未查到**。
- MyGo 被多少项目引用（Import by 统计）→ **未查到**（pkg.go.dev 需 JS、deps.dev 无数据）。
- 是否有商业级音乐播放器用 MyGo 上线 → **未查到**；仅确认 1 个真实应用 Retty（终端工具，非音乐）。
