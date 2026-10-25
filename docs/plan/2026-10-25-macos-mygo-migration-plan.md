# 听屿 macOS 端 MyGo 迁移方案

日期：2026-10-25（Asia/Shanghai）
性质：**规划文档**。本 todo 只做规划：未改代码、未删目录、未合并、未打 tag、未执行 spike。
基线：`main` @ `8d008a2`（已含两份输入报告）。
口径：**只保留 macOS**。Windows / Linux / Android / iOS 由并行 todo 删除；本方案按"仓库最终只有 macOS 端"编写。开工时若这些目录仍在，属并行未合并，不是基线错误。
估算性质：文中所有人日均为**粗估**，不构成承诺；凡未实测的结论都标了 `[推断]`。

输入与引用：

- [当前客户端技术底账](../audit/2026-10-25-current-client-review.md)（下称「底账」）
- [MyGo 可行性调研](../research/2026-10-25-mygo-feasibility.md)（下称「调研」）
- 本轮补测（只读）：线上库 `PRAGMA user_version`、日期文本格式、表/索引清单、现有工作区目录。命令见附录 B。

---

## 0. 结论速览

| 项 | 结论 |
|---|---|
| UI 模式 | **MyGo 原生 `ui` 模式**（不用系统 WebView 模式）。理由：单语言、内置列表/表格虚拟化、系统集成、内存 44 MB vs 62 MB（调研 §4.8） |
| 播放内核 | **进程内 libmpv，经 `purego` dlopen 调用 C API**（复用现有 `media_kit` 已随包分发的 LGPL 动态库）。降级路线：libmpv **子进程 + JSON IPC**。纯 Go 解码、原生 AudioToolbox 都不作 v1 |
| 媒体会话 | **自写约 400–500 行 ObjC C-ABI shim dylib，经 `purego` 调用**；cgo 被 MyGo 的 `CGO_ENABLED=0` 前提排除，辅助进程是次选 |
| 两条主线 | 「能播放本地库」+「媒体键 / Now Playing 可用」。先做 3–5 人日 spike 证伪死穴（**尚未执行**，见 §7），通过才开 M1 |
| 总工期 | **92–140 人日（粗估）**；含 0.x 升级储备 100–152。与调研 116–186 的差额逐项说明见 §9 |
| 数据 | 直接复用现有 `library.sqlite`（同表、同索引、同 `user_version=2`、同文本日期格式），**不导出/不重塑** |
| 切换 | Flutter（macOS 目标）在 M7 验收通过前保持可发布；切换后 30 天内禁止提升 `user_version`，以便回退 |

**需要用户拍板的核心只有一项：播放内核的原生边界**（§4.3 给了推荐与二值判定条件）。§10 另列 5 条次要确认（关窗行为、媒体键降级口径、读屏排期、更新器、移动端范围），都已给了推荐值，**不阻塞开工**。

---

## 1. 基线与证据（不重做调研，只对齐口径）

| 事实 | 数值 | 来源 |
|---|---|---|
| 手写 Dart（`app/lib`，排除 `database.g.dart`） | 33,244 行 / 133 文件 | 底账 §3.1 |
| 其中界面相关（`design/` + `features/`） | 22,362 行，67.27% | 底账 §9.1 |
| 测试 | 71 个 Dart 文件，374 个可见用例通过 | 底账 §7.1 |
| 支持格式 | `mp3 flac m4a aac wav ogg opus aiff alac` | `app/lib/sources/local/local_library_scanner.dart:50` |
| macOS 播放实现 | `media_kit` 1.2.6（libmpv）+ `audio_service` 0.18.19；随包 `Frameworks/` 内实测有 `Mpv.framework`、`Avcodec/Avformat/Avutil/Avfilter/Swresample/Swscale.framework`、`media_kit_libs_macos_audio.framework` | 底账 §2.4、§5 + 本轮 `ls`（debug 产物） |
| macOS 部署目标 | 12.0 | `app/macos/Podfile:1`、`project.pbxproj` |
| 窗口 | 最小 900×600，默认 1180×760 | `app/macos/Runner/MainFlutterWindow.swift` |
| 沙盒 | 关闭（`app-sandbox=false`），release 开 `network.client` | `app/macos/Runner/Release.entitlements` |
| 现役库位置 | `~/Library/Application Support/com.halunhaku.tingyu/library.sqlite` | 底账 §6.2（本轮复核存在） |
| 库版本 | `PRAGMA user_version = 2`；journal `delete` | 本轮只读实测 |
| 日期格式 | 文本 ISO-8601 带微秒与 `Z`，如 `2026-09-13T01:45:33.768049Z` | 本轮只读实测（drift `storeDateTimeAsText`） |
| 表 / 索引 | `tracks`、`music_sources`、`playlists`、`playlist_items` + 8 个业务索引 | 本轮只读实测，与 `app/lib/data/db/schema.dart` 一致 |
| MyGo | v0.6.3（2026-10-23）、MIT、仅三桌面、Go 1.27.3+、`CGO_ENABLED=0` | 调研 §2、§3 |
| MyGo 音频 | 只解 WAV/Ogg-Vorbis/MP3；输出固定 48 kHz 立体声；无 `OnEnd`、无跨曲无缝、只吃 `io.ReadSeeker` | 调研 §4.1 |
| MyGo 媒体会话 | 无。`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` / SMTC / MPRIS 零实现，[#654](https://github.com/egoist/mygo/issues/654) 为开放提案 | 调研 §4.1、§9 |
| MyGo `ui` | 98 个导出构造函数、列表/表格虚拟化、动效/变换/着色器齐备；无 Hero；无第三方组件库 | 调研 §5.1、§5.4 |
| MyGo SQLite | 官方插件、purego、仅三桌面、无 ORM | 调研 §4.3 |
| MyGo Secrets | macOS Keychain，**单条上限 2560 B** | 调研 §4.7 |

---

## 2. 功能取舍表

图例：**保留** = 能力与行为契约不变；**简化** = 能力保留但口径收窄（收窄处逐条写明）；**重画** = 能力保留、实现重写（UI 与去 ORM 的数据层）；**砍掉** = 明确放弃并注明理由；**不新增** = 现状没有、本次也不做。

### 2.1 数据与凭据

| # | 能力 | 现状落点 | 结论 | 口径 / 理由 |
|---|---|---|---|---|
| 1 | SQLite 曲库（4 表 + 8 索引 + 补差迁移） | `data/db/database.dart` | **保留** | 同文件、同 schema、同 `user_version=2`；只把 drift 换成手写 SQL（MyGo 插件无 ORM） |
| 2 | 扫描合并语义（`sourceId+filePathOrUrl` 对齐；只有权威扫描才删旧曲目；未变文件跳过标签解析；64 一批） | `track_repository.dart`、`local_library_scanner.dart` | **保留** | 这是数据正确性核心，不因换语言改变 |
| 3 | 时间文本存储 + 外键级联 | `database.dart`、`schema.dart` | **保留** | 实测格式 `...768049Z`，写入必须逐字兼容 |
| 4 | 封面内容寻址（FNV-1a 命名）+ 孤儿回收 | `data/cover_store.dart` | **保留** | 已有 353 个封面文件、91% 字节曾重复的历史约束不能倒退 |
| 5 | `settings.json`（themeMode / density / coverTint）+ 宽容解析 + 损坏回退 | `data/settings_store.dart` | **保留** | 键名与取值不变，MyGo 侧只映射渲染 |
| 6 | 凭据走系统安全存储（WebDAV 密码 / 夸克 Cookie） | `data/secure_store.dart` | **保留**（实现换 `mygo.Secrets`） | 见 §3.4：2560 B 上限与跨版本可读性两个约束 |
| 7 | 非 release 明文凭据回退（0600 文件） | `secure_store.dart` | **砍掉** | 只为绕开未签名 Keychain `-34018`；新栈用独立 keychain service 名即可，不再新增明文落盘面 |
| 8 | 旧版 Swift 曲库 JSON 导入 | `data/legacy_import.dart` | **砍掉** | 一次性迁移早已完成，线上库就是 drift 的 `library.sqlite`；保留只会扩大回归面 |
| 9 | 元数据富化（在途合并、失败不抛、写回） | `data/enrichment_service.dart` | **保留** | 「同一首的自动/播放/手动触发共用一次请求」必须保留 |
| 10 | 播放历史 / 次数 / 时长回填 | `app/playback_controller.dart` | **保留** | 去重口径（同一首只写一次时长）照搬 |

### 2.2 播放

| # | 能力 | 现状落点 | 结论 | 口径 / 理由 |
|---|---|---|---|---|
| 11 | 双引擎工厂（桌面 libmpv / 移动 ExoPlayer·AVPlayer） | `playback/engine_factory.dart` | **简化** | 只剩一个 macOS 引擎，保留 `Engine` 接口以便测试替身 |
| 12 | 9 种格式 | 见 §1 | **保留** | libmpv 全覆盖；纯 Go 路线会缺 AAC/ALAC，故不选 |
| 13 | HTTP Range 流式 + 直链鉴权头（WebDAV Basic、夸克播放头） | `MediaKitEngine._toMedia` | **保留** | mpv 原生支持 Range；头经 `loadfile` 的 per-file options 传入，Go 侧不中转音频字节 |
| 14 | 跨曲 gapless | libmpv | **保留** | `--gapless-audio=yes` + 预排下一首；**跨格式/跨采样率不保证无缝**（mpv 自身限制），写进验收口径 |
| 15 | 播放结束回调 | libmpv `eof-reached` / `end-file` | **保留** | MyGo 自带音频无此能力，这也是不用它的原因之一 |
| 16 | 懒解析队列 + 预取 2 首 + 世代号/闸门 + 三份平行数组一致 | `app/playback_controller.dart` | **保留** | 失败模式已写在代码注释里（重建期预取把结果追加到旧队列），重写时必须原样实现 |
| 17 | 单曲无缝循环 / 列表循环回绕 / 顺序停末尾 | 同上 + `setRepeatMode` | **保留** | 单曲循环必须下发内核（`--loop-file=inf`），否则有一声静音 |
| 18 | 播完再按播放要 `seek(0)+play` | 同上 `togglePlayPause` | **保留** | 引擎停在 completed 时 `play()` 是空操作 |
| 19 | 失败快照（不抛异常、只有重新出声且位置前进才撤下） | `MediaKitEngine._sync` | **保留** | 这条防线挡的是「直链过期/断网/解码失败全部静默」 |
| 20 | 时长未知 ≠ loading | 同上 `processingOf` | **保留** | 夸克/WebDAV 直链常无 `Content-Length` |
| 21 | 倍速 / 音量 / seek / 缓冲进度 | 同上 | **保留** | 倍速变调（mpv `speed`）与现状一致 |
| 22 | 后台播放（App Nap 抑制、关窗不中断） | 现状**关窗即退出**（`applicationShouldTerminateAfterLastWindowClosed=true`） | **简化 + 行为变更** | 见 §5.6：默认关窗继续播放 + 菜单栏控制，Cmd+Q 干净退出；偏好可切回"关窗即退出" |
| 23 | 系统媒体会话（Now Playing / 媒体键 / 控制中心） | `TingyuAudioHandler` + `audio_service` | **保留**（重写） | 见 §5 |

### 2.3 来源

| # | 能力 | 现状落点 | 结论 | 口径 / 理由 |
|---|---|---|---|---|
| 24 | 本地目录按绝对路径访问（非沙盒） | `sources/local/local_source_adapter.dart` | **保留** | macOS 非沙盒，选目录后直接用路径；不需要任何持久授权 |
| 25 | 目录选择对话框 | `file_selector` | **保留** | 换 `mygo.Dialog.Open`（目录模式） |
| 26 | WebDAV（PROPFIND、Basic、ETag/Last-Modified、503 坚果云流控文案、退避重试） | `sources/webdav/*` | **保留** | 用户可见错误文案逐字不变（含 `BlockedTemporarily` 分支） |
| 27 | 夸克扫码登录（申请 → 轮询 → `service_ticket` 换 Cookie） | `quark_qr_login.dart` + `quark_qr_login_page.dart` | **保留** | 二维码改 Go 库绘制（`qr_flutter` 无 Go 等价物） |
| 28 | 夸克网页登录（内嵌 WebView、去 `wv` UA、接管 `intent://`、读 Cookie） | `quark_web_login_page.dart`（3 个已踩坑注释） | **保留** | 换 MyGo 内嵌 `WebView` + `mygo.Cookies`；三个坑必须逐条复验，见 §3.5 |
| 29 | 夸克直链、分页、深度/数量上限、截断原因 | `quark_drive_client.dart`、`quark_source_adapter.dart` | **保留** | 默认 `maxDepth=5`、`maxFiles=5000` 不变 |
| 30 | 来源同步编排（进度、取消、权威性、错误、重登录、删除） | `features/sources/source_sync.dart`、`app/source_adapters.dart` | **保留** | 含凭据代际：凭据变更后不能复用缓存的适配器 |
| 31 | Android SAF 目录树授权 / iOS 安全作用域书签 | `tingyu_saf`、`local_bookmark_source_adapter.dart` | **砍掉** | 随平台消失；`music_sources.local_bookmark` 列保留但不再写（见 §2.4） |

### 2.4 元数据、图片、界面、系统集成

| # | 能力 | 现状落点 | 结论 | 口径 / 理由 |
|---|---|---|---|---|
| 32 | 4 个抓取源（网易云 / QQ 音乐 / iTunes 封面 / LRCLIB）+ 智能标题解析 + 人工匹配 + AI 配置/改名/解析 | `sources/scraper/*`、`sources/ai/*`、`manual_match_dialog.dart` | **保留** | 纯 HTTP + JSON，直译；AI 密钥进 Secrets |
| 33 | OpenCC 繁→简（`TSCharacters.txt`，Apache-2.0） | `assets/opencc/` | **保留** | Go `embed` 同一文件，保留 NOTICE |
| 34 | 自动补全配额（每会话最多 60 首） | 底账 §7.3 | **保留** | 防止一次进库就打死上游 |
| 35 | 远程封面缓存 + 按显示尺寸解码 | `cached_network_image`、`TyCover` | **重画** | MyGo 不提供网络图片/缓存，需自建「HTTP → 内容哈希落盘 → 解码 → LRU → 降采样」 |
| 36 | 封面取色（舞台主/次色、LRU 64） | `features/player/stage_palette.dart` | **重画** | 规则直译（丢极端亮度/饱和度、聚类） |
| 37 | 设计令牌（颜色/间距/圆角/字号/动效/声档） | `design/tokens/*` | **重画** | 数值直译成 Go 结构体，不新建设计语言 |
| 38 | 23 个组件文件（8,453 行） | `design/components/*` | **重画** | 即时模式重写；列表/表格/树/分段/弹出层用 `ui` 内置 |
| 39 | 三档响应式外壳（compact <640 / medium 640–1023 / expanded ≥1024） | `design/layout/form_factor.dart`、`app_shell.dart` | **简化** | 窗口最小 900 宽 → 生产不可达 compact（底账 §8.1 同结论）。砍掉底部导航、迷你条、安全区与移动手势；保留 medium（侧栏收窄/导航栏）+ expanded |
| 40 | 曲库/收藏/专辑/艺术家/歌单页 + 分页 | `features/{library,albums,artists,playlists}` | **重画** | 分页与"播放全部先补齐查询结果"的语义保留；滚动闸门缺陷修正（§2.5） |
| 41 | 搜索 + 命令面板（250 ms 防抖、多类型预览、分页） | `features/search/*` | **重画** | Cmd+K 保留 |
| 42 | 播放舞台（160° 渐变、封面取色漂移、Hero 展开） | `features/player/now_playing_page.dart`、`fluid_background.dart` | **简化** | 无内置 Hero：展开/收起用 `Transforms` + 交叉淡入手写近似，观感差异在 M4 验收时人工比对 |
| 43 | 队列 / 歌词（LRC 解析、逐行高亮）/ 传输条 / 迷你条 | `features/player/*`、`design/components/transport.dart` | **重画** | LRC 解析器为纯函数，可直译并有测试可继承 |
| 44 | 设置（外观/密度/取色、凭据状态、AI、数据、关于） | `features/settings/*` | **保留** | 分区与强调项不变；「存储回退中」状态改为 Keychain 状态 |
| 45 | 首启引导 | `features/onboarding/` | **保留** | 触发条件不变（有库 ∧ 无来源 ∧ 无曲目） |
| 46 | 键盘/焦点体系、焦点环、快捷键 | `design/components/interactive.dart`、`main.dart` 菜单 | **简化** | 保留全键盘可达与焦点环；全局快捷键不做（现状也只有局部） |
| 47 | 无障碍（语义标注、读屏） | 各处 `Semantics` + 语义测试 | **简化（明确的回归）** | MyGo 自认「文本与集合可达性未完成」（调研 §4.6）。**保留**键盘完全可达 + 焦点环；**读屏体验低于现状**，写入风险与发布说明，M6 后单独排期 |
| 48 | Golden 视觉回归（12 张，Windows 字体基准） | `test/golden/` | **砍掉** | 换渲染器后像素基准无意义；改为 `ui.Tester` 组件测试 + macOS 人工截图对照 |
| 49 | 原生应用菜单（播放控制/窗口/帮助）、窗口尺寸 | `main.dart` `PlatformMenuBar`、`MainFlutterWindow.swift` | **保留** | MyGo 自带菜单 API |
| 50 | 关窗即退出 + 退出前 dispose 播放器 | `AppDelegate.swift`、`main.dart:106-119` | **简化 + 变更** | 见 §5.6 |
| 51 | 拖放、深链、通知、单实例、自动更新 | 现状无 / MyGo 自带 | **不新增** | 不属本次迁移范围；自动更新只在 M6 作为可选项（§10） |
| 52 | Developer ID 签名 + 公证 + DMG | 规划中（底账 §7.3 M7 未完成） | **保留（补齐）** | MyGo 自带 dmg/签名/公证流水线；额外二进制（shim/libmpv）需单独签名 |
| 53 | 五平台 CI + Windows 源码引擎补丁链 | `.github/workflows/flutter.yml`、`tools/*.ps1`、`tools/engine-patches/` | **砍掉** | 随平台删除；新 CI 只留 macOS |

### 2.5 重写时必须修掉的现有缺陷（不移植）

底账已定位的缺陷，重写时**修掉而不是照搬**，否则换栈后原样复现：

| 缺陷 | 现状证据 | 新实现口径 |
|---|---|---|
| 曲库刷新缺口：标题/艺术家/封面/歌词/歌单改名不触发列表刷新 | `app/lib/app/providers.dart:507` 的指纹只含 length/favorites/latest | 引入**行级 revision**（曲目表与歌单表的 `changed_at`/最大 revision）+ 查询键带 revision；元数据写回后主动失效 |
| 滚动重复建页：`_loadMore` 无 loading/hasMore/total 闸门 | `features/library/library_page.dart:141-152` | 状态机 `idle/loading/done`，一页一次；到底后不再建空页 provider |
| 大库全表工作：指纹与专辑/艺术家页 watch 全部曲目 | `providers.dart` `allTracksProvider` 等 | 专辑/艺术家用 SQL 聚合 + 分页；禁止把整表塞进内存做筛选 |
| 来源详情页随播放进度整页重建 | `features/sources/source_page.dart:159` | 订阅切片：只订阅 `playing` 布尔，不订阅 position |
| 取色在后台 isolate 解码 `dart:ui`（未验证是否成功、失败静默回退） | `features/player/stage_palette.dart` | Go 侧纯计算 + 明确错误日志；不做静默回退 |

### 2.6 随平台消失的能力（明确清单）

| 能力 | 现状 | 消失原因 | 影响 |
|---|---|---|---|
| Android SAF 目录树授权与枚举桥 | `tingyu_saf`：Dart 155 行 + Kotlin 312 行 | 平台删除 | 无影响（macOS 用路径访问） |
| iOS 安全作用域书签与相对路径语义 | Swift 159 行 + `local_bookmark_source_adapter.dart` | 平台删除 | `music_sources.local_bookmark` 列保留为空，兼容旧库 |
| Windows SMTC 后端 + vendor 补丁 | `packages/audio_service_win`（含 `TINGYU_PATCHES.md`） | 平台删除 | 无影响 |
| Linux MPRIS（D-Bus） | `audio_service_mpris` 0.2.1 | 平台删除 | 无影响 |
| Android 通知权限 / 前台媒体服务 / 音频焦点 | `permission_handler`、`audio_session`、`audio_service` | 平台删除 | 桌面无对应概念 |
| 移动播放引擎 | `just_audio`（ExoPlayer / AVPlayer） | 平台删除 | 只剩 libmpv 一条 |
| Android WebView 分支（登录分流、QR） | `webview_flutter_android`、`quark_web_login_page.dart` 平台判断 | 平台删除 | macOS 仍保留内嵌 WebView（夸克网页登录） |
| Windows 源码引擎补丁链 | `tools/*windows*.ps1`、`tools/engine-patches/` | 平台删除 | 维护负担消失（底账 §5 曾列为持续成本） |
| Golden 视觉回归（Windows 字体/渲染基准） | `test/golden/` 12 张 | 平台删除 + 换渲染器 | 视觉回归改人工 + 组件测试 |
| 五平台 CI 与发布矩阵 | `flutter.yml` 的 5 个 build job | 平台删除 | 新 CI 只构建 macOS |

> 记录一条不变的事实：**`music_sources.local_bookmark` 与 `local_folder_path` 两列都不删**。旧库里可能已有书签值（底账 §2.3 提到旧版 macOS 迁移过来的书签也落在这里），删列会让旧库回退时丢数据。

### 2.7 四条不可放弃能力与保障

| 能力 | 现状语义 | 新方案保障 | 验收项 |
|---|---|---|---|
| **后台播放** | 桌面语义 = 应用不退出时持续出声；现状**关窗即退出** | 关窗继续播放 + 菜单栏迷你控制 + App Nap 抑制断言（`NSProcessInfo`/`IOPMAssertion`，由 shim 提供）；Cmd+Q 干净退出 | 关窗 30 分钟连续播放；`pmset -g assertions` 可见断言；退出后无残留进程 |
| **媒体键 / Now Playing** | `audio_service` → `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` | 进程内 ObjC shim（§5）；内核与 shim 同进程，保住归属 | 控制中心显示曲目/封面；F7/F8/F9 与拖动进度可用（§7 S2） |
| **无损格式** | FLAC / ALAC / AIFF 等 9 种 | libmpv（FFmpeg 解码）全格式；24/96 直出（不做位深降级） | 9 格式矩阵逐项出声 + seek（§6 M2） |
| **长列表性能** | SQL 分页 40/页 + `ListView.builder` 固定行高 | `ui.Table` / `ui.List` 只建可见行（官方基准：可见行 14.5 µs/帧，M5 / 2026-10-08，调研 §4.4） | 10,000 行库滚动帧时间 ≤ 16.7 ms（p95）；首屏 ≤ 200 ms |

---

## 3. 技术选型

### 3.1 UI 模式：原生 `ui` 还是系统 WebView

| 维度 | 原生 `ui` | WebView 模式 | 本项目权重 |
|---|---|---|---|
| 语言栈 | Go 单一栈 | Go + HTML/CSS/TS + 前端构建链 | **高**（用户动机就是"少维护几套"） |
| 列表/表格 | 内置虚拟化、吸顶、多选、列宽拖拽、TSV 复制 | 需自己接虚拟列表库 | **高**（曲库是主界面） |
| 系统集成 | 原生菜单/托盘/vibrancy/拖放/对话框 | 需经 Go 侧桥接 | **中高** |
| 观感 | 系统原生控件观感 | 自绘 Web 观感（可做更花哨） | 中 |
| 内存 | ~44 MB | ~62 MB | 中 |
| 视觉改造成本 | 令牌 + 组件在即时模式下重写；无 Hero | CSS 渐变/模糊/动效更省事；生态丰富 | 中 |
| 依赖风险 | 0.x API（两者相同） | 额外多一套前端工具链 | 中 |

**推荐：原生 `ui`。** 四条理由：① 单语言栈直接对应迁移动机；② 曲库的虚拟化/表格/吸顶是内置能力，而 Web 模式要再挑一个第三方库；③ 菜单、托盘、vibrancy、拖放、对话框都在同进程，媒体会话 shim 也只需一条 Go→C 边界，不新增 JS 桥；④ 内存更低。

代价与对策：
- **无 Hero 共享元素**：舞台展开用 `Transforms` + 交叉淡入近似（调研 §4.6 已标"观感会有差异"）。M4 验收接受"近似"口径，不追求逐帧一致。
- **无第三方设计系统**：`design/tokens/*` 的数值直译成 Go 结构体，组件按「声档」规范重画 —— 这与 Flutter 侧当初建令牌的工作同构，不是新增负担。
- **0.x API 破坏性变更**：锁 `v0.6.x` 精确版本（`go.mod` + `go.sum`），每次升级走 `go tool mygo migrate-ui` + `mygo vet`，并预留每季度 1–2 人日；升级窗口排在里程碑之间，不插在交付中途。

### 3.2 状态管理

不引入第三方状态库（调研 §5.4：生态里没有可信的第三方选项）。结构：

```
internal/app/store.go
  type Store struct {          // 唯一写入口
      mu       sync.Mutex
      library  LibraryState     // 曲目/来源/歌单的查询结果与 revision
      playback PlaybackState    // 内核快照 + 队列 + 顺序/循环
      sources  map[string]SourceRuntime
      ui       UIState          // 路由、选择、搜索查询、面板开合
  }
  func (s *Store) Snapshot() ViewModel   // 不可变只读视图，每帧读取
```

- **写路径串行**：所有变更经 Store 方法（持锁或投递到单写 goroutine）；IO 用 `context` 取消 + 世代号，对应现有 `_queueGeneration` / `_queueArmed` 的语义。
- **读路径无锁快照**：视图层每帧只读 `ViewModel`，不直接碰数据库或内核。
- **行级订阅**：列表行的播放进度只读「当前曲目 id/位置」，避免整表重建（对应现有 `PlaybackTrackRow` 的隔离目的）。MyGo 的即时模式按帧重建视图，因此隔离点是**取数粒度**而不是 widget 树。
- **待落地确认**：MyGo v0.6.x 是否提供局部状态/记忆原语，调研未固定其命名。spike 期间以源码确认；不可用则以 Store + `AnimateTo` 显式驱动，不依赖框架状态。

### 3.3 SQLite 落点

- **驱动**：MyGo 官方 SQLite 插件（purego + 预编译库，零 cgo，macOS amd64/arm64）。不选 cgo 版驱动（违反 `CGO_ENABLED=0`），不选第三方纯 Go 实现（无必要）。
- **库文件**：`~/Library/Application Support/com.halunhaku.tingyu/library.sqlite`，路径不变（实测）。开发期用环境变量覆盖（§8.1）。
- **schema**：与 `app/lib/data/db/schema.dart` 逐列一致（含默认值 `未知艺术家` / `未知专辑` / `mp3`、唯一键 `(sourceId, filePathOrUrl)`、`PRIMARY KEY (playlistId, position)`、外键 `ON DELETE CASCADE`）。启动时开 `PRAGMA foreign_keys = ON`。
- **迁移**：沿用「补差」策略 —— 读 `sqlite_master`，缺表建表、缺索引建索引、缺列 `ALTER TABLE ADD COLUMN`（只加可空列）。不写逐版本脚本，因为线上库可能由更早的 Swift 版或半迁移库建出（`database.dart` 的现有理由）。
- **版本号**：`PRAGMA user_version` 实测 2。**双轨期与切换后 30 天内不得提升**，否则 Flutter 版回退打开会因版本不匹配失败。
- **日期**：写文本 ISO-8601（UTC、保留微秒、带 `Z`），与实测一致；不做本地时区偏移。
- **查询**：沿用现有 SQL 语义 —— `WHERE + ORDER BY + LIMIT/OFFSET` 稳定排序 + 单独 `COUNT(*)`；每页 40（`providers.dart:498`）；`LIKE` 搜索行为迁移期不改（优化留到迁移之后，避免把"语义变化"和"换语言"混在一次发布里）。
- **并发**：单写连接 + 若干只读连接；写事务短（扫描入库按批）；封面二进制不入库（沿用 §2.1 #4）。
- **风险**：无 ORM = 无编译期类型安全。对策见 §8.4（迁移前后逐表 `count(*)` + 抽样行哈希比对脚本）。

### 3.4 凭据存储

- **落点**：`mygo.Secrets`（macOS 登录钥匙串）。不自己写 Keychain C ABI（除非下面的分片方案也不成立）。
- **键名**：沿用现有账号名规则 —— `webdav_password_<sourceId>`、`quark_cookie_<sourceId>`（`secure_store.dart` 的 `accountFor`）。
- **2560 B 上限（调研 §4.7）**：夸克 Cookie 是唯一可能超限的项。
  1. M3 第一天量测真实 Cookie 长度（含 `__puus`、`__pus` 等常见项）；
  2. 超限则按 `<account>#0..n` 分片写入并在读取时拼接，单条仍 ≤ 2560 B；
  3. 仍不够则走 `native/media_session.m` 同一 dylib 增加 `ty_keychain_get/set`（通用密码、无 2560 限制），成本约 0.5 人日。
- **跨版本可读性**：Flutter 版写入的钥匙串项受创建应用签名约束，MyGo 版**不保证能读**。迁移动作定为：首次启动检测到来源缺凭据 → 引导重填 WebDAV 密码 / 重新扫码登录夸克，并写进发布说明。不尝试导出明文、不做静默降级。
- **凭据代际**：保留 `credentialEpoch` 语义（凭据变更后丢弃缓存的来源适配器）。

### 3.5 网络（WebDAV / 夸克直链）

- **HTTP 客户端**：`net/http`；每来源一个 `*http.Client`（带超时、连接复用、`context` 取消）。
- **WebDAV**：`PROPFIND Depth:1` + `encoding/xml` 解析（直译 `webdav_xml_parser.dart`）；Basic 鉴权只放请求头，**不进 URL**（避免日志/缓存键泄漏）；401/403/429/503 的用户文案逐字保留，含坚果云 `BlockedTemporarily` 分支与"等待 5–10 分钟"文案。
- **夸克**：
  - 扫码：申请 token → 轮询（`waitingScan/scanned/expired/error` 四态）→ `service_ticket` 换 Cookie，与 `quark_qr_login.dart` 一致；
  - 网页登录：MyGo 内嵌 `WebView` 打开官方登录页，**三个坑逐条复验**：① 不打开网页版主界面（移动 UA 会跳推广页）；② 覆盖默认 UA（去 `wv`、`Version/4.0`）；③ 接管 `intent://` 等非 http 跳转（有回退地址就在当前 WebView 继续）；
  - Cookie 读取：`mygo.Cookies`（支持 HTTPOnly），再经 `QuarkCookieJar` 的解析/去重/`Set-Cookie` 回写逻辑；
  - 直链：`getDownloadUrl(fid, session)` 返回 URL + 必需播放头；头交给 mpv 的 per-file options，**不经过 Go 中转字节**（与 `media_kit` 现状一致）。
- **系统代理**：Go 默认只认 `HTTP(S)_PROXY` 环境变量，不读 macOS 系统代理设置（`scutil --proxy`）。用户库在企业代理下可能连不上 —— M3 加一次 `scutil --proxy` 读取并映射到 `http.Transport`；不引入第三方代理库。
- **重试**：保留 `sources/http_retry.dart` 的退避语义（幂等方法、上限、可取消）。

### 3.6 元数据抓取与图片管线

| 块 | 落点 | 说明 |
|---|---|---|
| 抓取源 | `internal/sources/scraper/{netease,qq,itunes,lrclib}.go` | 直译；统一 `MetadataProvider` 接口 + 超时/重试/限流 |
| 智能标题解析 / 人工匹配 | `smarttitle.go`、`internal/ui/pages/match_dialog.go` | 纯函数先单测，再接 UI |
| OpenCC | `internal/sources/scraper/opencc.go` + `embed` `assets/opencc/TSCharacters.txt` | 逐字转换，不做词组消歧（现状口径） |
| AI | `internal/sources/ai/*` | 密钥进 Secrets；解析结果写库路径不变 |
| 图片取 | `internal/images/fetch.go` | 并发上限 + 磁盘（内容哈希）+ 内存 LRU |
| 图片解 | `internal/images/decode.go` | `image/jpeg`、`image/png`、`golang.org/x/image/webp`；按显示尺寸 ×2 降采样后再进 GPU |
| 取色 | `internal/images/palette.go` | 直译现有规则（丢极端亮度/饱和、聚类主/次色、LRU 64） |

---

## 4. 播放内核方案

### 4.1 必须满足的能力（来自现状契约，不可退化）

| 能力 | 现状证据 | 新内核要求 |
|---|---|---|
| 9 种格式 | `local_library_scanner.dart:50` | FLAC / ALAC / AIFF / AAC / M4A / Opus / Ogg / MP3 / WAV 逐一出声 |
| HTTP Range + 鉴权头 | `MediaKitEngine._toMedia` | 远端曲目可 seek，鉴权头按曲目下发 |
| 跨曲 gapless | libmpv | 同专辑连播无可闻空隙；跨格式不保证（写入验收口径） |
| 结束回调 | `.completed` 流 | 播完 ≤150 ms 内上报 `completed` |
| 失败语义 | `_failure` + 撤下规则 | 不抛异常，写进快照；只有重新出声且位置前进才清 |
| 未知时长 | `processingOf` | 时长 0 不等于 loading |
| 缓冲进度 | `state.buffer` | 上报 `buffered` |
| 单曲无缝循环 | `PlaylistMode.single` | 由内核自己循环 |
| 音量/倍速 | `setVolume`/`setRate` | 0..1 映射；倍速变调 |
| 队列重建不打断 | `setQueue` | 重建后旧会话不得再推进（控制器闸门） |

### 4.2 候选对比

| 候选 | 9 格式 | HTTP Range | 跨曲 gapless | 结束回调 | 鉴权头 | cgo | 许可 | 代价（粗估） | 结论 |
|---|---|---|---|---|---|---|---|---|---|
| **A. 纯 Go 解码 + MyGo 自带混音器** | 缺 AAC/ALAC（调研 §4.1）；FLAC/Opus/AIFF 可得 | 自写 `io.ReadSeeker` + 缓冲/重试 | 自写 | 自写（轮询） | 自写 | 无 | 逐库核对（多为 MIT/BSD，需逐个确认） | 解码器补齐 8–14 + 流式 5–8 + 无缝/结束 4–6 | **不作 v1**：格式缺口在 AAC/ALAC，硬骨头且无成熟纯 Go 实现；输出固定 48 kHz 且无 `OnEnd` |
| **B. libmpv 子进程 + JSON IPC** | 全 | 原生 | 原生 | `end-file` 事件 | per-file options | 无 | mpv LGPL-2.1+（需 `--enable-lgpl` 构建）/ FFmpeg LGPL | 5–8（IPC、生命周期、崩溃重启） | **降级路线**：技术风险最低，但引入进程边界；Now Playing 归属需复测（§5.4） |
| **C. libmpv 进程内（`purego` dlopen C API）** | 全 | 原生 | 原生 | `eof-reached`/`end-file` | per-file options | 无 | 同上 | 8–14（FFI 结构体/事件循环/生命周期） | **推荐**：复用现有二进制、无 IPC、归属正确 |
| **D. AVFoundation / AudioToolbox 原生 shim** | 7/9（缺 Ogg/Opus） | 自写或 `AVAssetResourceLoader` | 自控（缓冲调度） | 自控 | 自控 | 无（ObjC 由 clang 编译，Go 不链） | 系统框架 | 25–35（自建音频引擎 + 2 格式仍要纯 Go） | **兜底**：C 失败且 B 的归属不成立时启用 |

**许可口径（必须落实，不靠推断）**：mpv 默认构建是 GPL-2.0+；只有 `--enable-lgpl` 构建才是 LGPL-2.1+，此时才可随闭源应用**动态**分发。FFmpeg 同理，不能带 GPL 组件（`--disable-gpl`）。`media_kit_libs_audio` 随包分发的 macOS 库若为 LGPL 构建，我们直接复用（现有 Flutter 版已在分发它，底账 §5 已记录该依赖）；**spike 第一步就是读该 dylib 的构建信息/许可证文件**，不是 GPL 就停在评审，不进实现。合规要求：动态链接、保留许可证与源码获取说明、允许用户替换库文件（不静态链接、不做符号裁剪）。

**与「无 cgo」前提的冲突**：四条路线在 Go 侧都不需要 cgo —— A 是纯 Go；B 是子进程；C 是运行期 `dlopen`；D 的 ObjC 由 `clang` 单独编译成 dylib，Go 只 `dlopen`，不参与链接（`CGO_ENABLED=0` 仍成立）。真正的差别不在 cgo，而在**谁在出声**（决定 Now Playing 归属）与**谁承担崩溃**。

### 4.3 推荐与判定

**推荐 C，B 为降级，D 为兜底。** 理由：

1. **归属**：macOS 的 Now Playing 面板与媒体键归属于**实际出声的进程**。只有内核与媒体会话 shim 同进程，才不依赖"子进程出声、主进程报元数据"这套未经验证的假设（§5.4）。
2. **复用**：libmpv + FFmpeg 现在就在 `听屿.app/Contents/Frameworks` 里（`Mpv.framework`、`Av*.framework`、`Sw*.framework`，本轮实测），许可路径已被现有版本走通；换 Go 只是换调用方。
3. **能力完整**：Range、gapless、`eof`、per-file 头、缓冲、倍速一次到位；纯 Go 路线要在最难的两处（AAC/ALAC、无缝）自建。
4. **无 cgo**：`purego` 运行期 `dlopen`，仍然 `CGO_ENABLED=0`，符合 MyGo 前提。

判定条件（spike S1，§7）：若 1.5 人日内无法在无 cgo 条件下稳定出声并拿到结束事件，或 `purego` 事件结构体导致 ≥2 次无法定位的崩溃 → 切 B。若 B 下归属失败 → 评估 D（+10–15 人日，总量升到约 102–155）。

### 4.4 Engine 接口（Go，对齐现有 Dart 契约）

```go
type Processing int // idle / loading / buffering / ready / completed

type Failure struct { Message, Title string }

type Snapshot struct {
    Processing Processing
    Playing    bool
    Position, Duration, Buffered time.Duration
    Index      int
    Rate, Volume float64
    Failure    *Failure
}

type Item struct {
    ID       string
    URI      string
    Headers  map[string]string // WebDAV Authorization / 夸克播放头
    Title, Artist, Album string
    Duration time.Duration
    ArtPath  string
}

type Engine interface {
    Name() string
    Snapshot() Snapshot
    Subscribe() (<-chan Snapshot, func())
    SetQueue(items []Item, start int) error // 不自动播放
    AppendQueue(item Item) error            // 不打断当前播放
    Play() error
    Pause() error
    Seek(time.Duration) error
    SetRate(float64) error
    SetVolume(float64) error
    SetRepeat(RepeatMode) error             // one → loop-file=inf
    Next() error
    Prev() error
    Close() error
}
```

失败**不返回错误**给 UI（`err` 只用于内部日志）：一律进 `Snapshot.Failure`，UI 监听快照即可，与现有 `PlaybackEngine` 契约一致。

### 4.5 关键实现口径（内核为 libmpv 时）

- **加载路径**：`dlopen("…/Contents/Frameworks/Mpv.framework/Versions/A/Mpv")`；其依赖的 `Av*`/`Sw*` framework 必须经 `@rpath`/`DYLD_FRAMEWORK_PATH` 可见（Flutter 版靠同一套 rpath 找到它们）。spike 的第一条断言就是「最小 Go 程序 dlopen + dlsym 成功」。
- **常驻 core**：进程启动建一个 idle mpv core，之后只做 `playlist-clear` + `loadfile ... append`，不复建 core（复建会丢音频设备并拖慢换队列）。
- **选项**：`--idle=yes --no-video --audio-display=no --gapless-audio=yes --ao=coreaudio --volume-max=100`。
- **每曲头**：`loadfile <uri> append -1 "<options>"`，options 里带 `http-header-fields`。per-file options 依赖 mpv 版本，**spike 必须实测这条，不能假定**（不支持时的替代是 Go 侧带头本地代理，见 §7.4）。
- **观察属性**：`playback-time`、`duration`、`pause`、`eof-reached`、`idle-active`、`volume`、`speed`、`cache-buffering-state`、`demuxer-cache-time`。
- **完成**：`eof-reached=true` 且 `idle-active=false` → `processing=completed`；`end-file` 的 `reason=error` → `Failure`（附 `mpv_request_log_messages` 的 `error` 级日志，去掉路径中的凭据）。
- **未知时长 ≠ loading**：只要队列里有曲目、且不在 `buffering`/`completed`，就报 `ready`；`duration<=0` 不能作为 loading 依据（夸克/WebDAV 直链常见无 `Content-Length`）。
- **循环**：`one` → `loop-file=inf`；`all`/`off` → `no`，回绕交给控制器重建（与现状一致，避免 mpv 自己把整条 playlist 循环时控制器索引错位）。
- **purego 注意**：`CString` 生命周期用 `runtime.KeepAlive` 保到调用返回；`mpv_wait_event` 只在单一 goroutine 调用（超时 100 ms 以便退出）；`mpv_event` 结构体按 C 头文件逐字段对齐并写一条「布局断言」测试（`unsafe.Sizeof` 与常量比对）。
- **崩溃隔离**：C 库崩溃会带走整个进程。对策：① spike 里做 200 次 `setQueue`/`seek` 压测；② 运行期写 `panic` 前的最小状态到日志；③ 若实测不稳再切 B（子进程可自动重启，这是 B 的唯一明显优势）。

### 4.6 若降级到 B（子进程）的差异

- mpv 以 `--input-ipc-server=/tmp/tingyu-<pid>.sock` 启动；Go 侧 JSON 行协议发命令、收事件；`loadfile` 同上。
- 打包多一个 `mpv` 可执行体（或复用同一套 dylib 做薄可执行体）；退出需联动（`SIGTERM` + 等 `end-file`），崩溃可自动重启并重建队列。
- **必须复测 Now Playing 归属**（§5.4）在"子进程出声"下是否成立；不成立则 D。

---

## 5. 媒体会话方案

### 5.1 必须保住的语义（从 `TingyuAudioHandler` 抄口径）

1. 元数据去重键 `(item.id, index, duration)`；**新会话强制重发**（否则控制中心挂着上一轮标题）。
2. 推送节流：纯进度 500 ms 一次；`playing/processing/index/rate` 任一变化立即推。
3. 控制项：上一首 / 播放暂停 / 下一首；seek 可拖动。
4. 播完后 `playing=false` 且能再播（`seek(0)+play`），不能出现"点了没反应"。

### 5.2 能不能直接调？

**不能从纯 Go 直接调。** `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` 是 Objective-C API；而 MyGo 的前提是 `CGO_ENABLED=0`，cgo 被排除。可行路径有三条工程方案，外加一条兜底：

| 路径 | 做法 | 代价 | 结论 |
|---|---|---|---|
| P1 `github.com/ebitengine/purego/objc` 直接发消息 | 在 Go 里 `objc.GetClass` + `Send`，手工构造 `NSDictionary` | 无额外文件，但消息发送/类型编码易错，调试困难；每加一个属性都要写桥代码 | 次选（P2 受阻时 0.5 天探针） |
| **P2 自写 ObjC C-ABI shim dylib** | `.m` 文件导出纯 C 函数；`purego` `dlopen`/`dlsym`；回调经 `purego.RegisterFunc` 回 Go | 一个 ~400–500 行原生文件 + 构建/签名步骤 | **推荐** |
| P3 独立辅助进程 | helper 进程持有 `MPRemoteCommandCenter`，JSON over stdio | 归属风险最高（谁出声谁是 Now Playing）；进程生命周期复杂 | 不选 |
| P4 `CGEventTap` 兜底媒体键 | 监听 `NSSystemDefined` 的 `NX_KEYTYPE_PLAY` 等 | 需要辅助功能/输入监控授权，体验与合规都差 | 仅作最后兜底 |

**推荐 P2**：进程内、无 cgo、边界是一层纯 C，能单测（独立小目标先跑起来），且后续 D 路线（原生音频）可以复用同一个 dylib。

### 5.3 shim 接口（C ABI）

```c
// ty_media.h —— 由 native/media_session.m 实现，purego dlopen 加载
void   ty_media_init(void);
void   ty_media_set_metadata(const char *json);   // title/artist/album/duration/artPath
void   ty_media_set_state(int playing, double rate, double position, double duration);
void   ty_media_set_enabled_commands(int has_next, int has_prev); // 单曲队列时禁用
void   ty_media_set_handler(void *ctx, void (*fn)(void *ctx, int command, double arg));
void   ty_media_set_keeps_awake(int on);          // App Nap 抑制
void   ty_media_clear(void);                      // 停止/退出时清空控制中心
```

命令码：`0=play 1=pause 2=toggle 3=next 4=prev 5=seek(arg=秒)`。

实现要点：
- `MPRemoteCommandCenter.sharedCommandCenter` 的 `play/pause/togglePlayPause/nextTrack/previousTrack/changePlaybackPosition` 全部 `addTargetWithHandler`，回调里 `dispatch_async(dispatch_get_main_queue())` 再调 Go 函数指针（媒体回调不保证在主线程）。
- `MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo` 写 `MPMediaItemPropertyTitle/Artist/Album/PlaybackDuration`、`MPNowPlayingInfoPropertyElapsedPlaybackTime`、`MPNowPlayingInfoPropertyPlaybackRate`、`MPNowPlayingInfoPropertyExternalContentIdentifier`，封面用本地文件构造 `MPMediaItemArtwork`（尺寸取 512×512 上限，避免每帧重建）。
- macOS 上同时设 `MPNowPlayingInfoCenter.playbackState`（`.playing`/`.paused`）；这是 macOS 专有属性，缺它会表现为面板不更新。
- App Nap：播放时 `[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep ...]`，暂停/停止时 `endActivity`；另加一条 `IOPMAssertion` 便于验收观测。

### 5.4 归属风险（关键，且决定内核选型）

macOS 的 Now Playing 面板与控制中心按键归属于**正在出声的应用**。由此产生一条硬约束：

> **播放内核必须与 shim 同进程**，否则系统可能不认主进程发布的元数据，媒体键也可能不投递给它。

这条约束是选 C（进程内 libmpv）而非 B（子进程）的核心理由。若最终被迫用 B，spike 必须新增一项：子进程出声时主进程的 tile 是否显示；不显示则该组合不可用，转 D（shim 同时接管音频输出）。

降级口径（若 P2 可用但 tile 长期空白）：接受"控制中心按键可用 + 菜单栏迷你控制显示完整元数据"，并在发布说明写明；**不接受**"媒体键完全收不到"。

### 5.5 线程与生命周期

- `ty_media_init` 在应用启动后主线程调用一次；`ty_media_clear` 在 `Cmd+Q` 退出前调用，保证控制中心不残留。
- Go 侧回调只做"投递命令到播放命令队列"，不做 IO，避免阻塞主线程。
- 元数据推送沿用 500 ms 节流，由 Go 侧限流（shim 不做节流，保持无状态）。

### 5.6 关窗与退出（行为变更）

现状：`applicationShouldTerminateAfterLastWindowClosed = true` + 退出前 dispose 播放器（`main.dart:106-119`）。
新行为：

| 动作 | 行为 |
|---|---|
| 关闭主窗口 | **继续播放**，菜单栏出现控制图标（播放/暂停/上一首/下一首/显示窗口/退出） |
| 点 Dock 图标 | 重新显示主窗口 |
| `Cmd+Q` / 菜单退出 | 停止内核 → `ty_media_clear()` → 关 mpv → 释放 Secrets/DB → 退出 |
| 偏好"关窗即退出" | 恢复现状行为（供不想要后台播放的用户） |

这是**默认行为变更**，需要用户确认（§10）。理由是第 2.7 节的"后台播放"在桌面端只能这样体现。

---

## 6. 分阶段实施计划

约定：每个里程碑结束时必须**能跑起来做一件事**，并按"验收结果"逐条演示。粗估人日见 §9。

| 里程碑 | 目标 | 可验收结果（跑起来能做什么） | 依赖 | 粗估 |
|---|---|---|---|---|
| **M0** 骨架与只读数据 | Go 模块 `client/`、`.app` 组装脚本、SQLite 只读打开、`ui.Table` 外壳 | 双击启动 → 最小 900×600 窗口 → 侧栏 + 表格列出线上库 178 首（只读，零写入）；`go build` 在 `CGO_ENABLED=0` 下通过 | spike 通过 | 5–8 |
| **M1** 主线（本地库 + 播放 + 媒体键） | 选目录 → 扫描 → 入库 → 播放；内核 v1（libmpv 进程内）；shim 接入 | 选一个本地目录并入 50 首 → 双击播放 FLAC 24/96 出声 → F7/F8/F9 与控制中心工作 → 关窗继续播 → `Cmd+Q` 干净退出 | M0 | 14–22 |
| **M2** 内核生产化 | 9 格式矩阵、Range/seek、gapless、循环三态、失败快照、预取/队列契约、倍速/音量 | 9 格式各播 10 秒并 seek 到 50%；专辑连播无可闻空隙；远端曲目（本地 Range 测试服务，校验 `Authorization`）可播可 seek；断网/直链过期出现可读失败提示并在恢复后消失；连播 200 首队列不错位 | M1 | 8–12 |
| **M3** 来源 | WebDAV 全链路；夸克扫码 + 网页登录 + 直链；同步编排 | 加 WebDAV 来源 → 120 首入库 → 播放远端；夸克扫码登录 → 列目录 → 播放直链；Cookie 失效时出现"重新登录"而不是静默失败；取消同步后不误删曲目 | M2 | 12–18 |
| **M4** 界面 | 令牌 + 组件 + 全部页面（曲库/收藏/专辑/艺术家/歌单/搜索+命令面板/舞台/队列/歌词/设置/引导） | 逐页可完成原有操作；曲库 10,000 行滚动 p95 帧时间 ≤16.7 ms；舞台展开/收起可用（Hero 近似）；歌词随播放高亮 | M1（可与 M2/M3 并行） | 26–38 |
| **M5** 元数据与图片 | 4 源 + AI + 人工匹配 + 封面缓存/取色 | 对 20 首无标签曲目触发补全 → 标题/封面/歌词落库并在列表与舞台立即刷新（不再需要重启）；离线时静默跳过不弹错 | M3、M4 | 8–12 |
| **M6** 分发与质量 | 签名、公证、DMG、CI、`ui.Tester` 测试、无障碍键盘路径 | `spctl -a -vv` 通过；空机器安装启动无隔离警告；CI 只跑 macOS：格式化 + `go vet` + 单测 + 构建 + 公证；测试覆盖队列/循环/合并/直链错误等契约 | M5 | 6–10 |
| **M7** 切换与收尾 | 双轨验收、数据迁移、删除 Flutter 目录与五平台 CI、文档 | 用真实库切换：MyGo 版打开同一 `library.sqlite` 不丢收藏/歌单；Flutter 版仍可回退；仓库只剩 macOS 客户端 | M6 | 5–8 |

顺序与并行：

```
spike ─► M0 ─► M1 ─► M2 ─┬─► M3 ─┬─► M5 ─► M6 ─► M7
                        └─► M4 ─┘
```

`M2` 与 `M4` 无共享文件（内核 vs 界面），可在两个工作区并行；`M3` 依赖 `M2` 的远端播放能力；`M5` 依赖 `M4` 的页面与 `M3` 的来源。

### 6.1 M1 的逐条验收（主线，最严格）

1. 冷启动到窗口可交互 ≤ 1.5 s（线上库 178 首）。
2. 选目录（含中文/空格路径）→ 扫描进度可见 → 入库数与文件数一致。
3. 点歌出声 ≤ 300 ms（本地 FLAC）；连点 10 首不同曲目无串音、无卡死。
4. 暂停/继续/上一首/下一首/拖动进度/音量 全部生效，且控制中心状态与界面一致。
5. 媒体键 F7/F8/F9 生效；控制中心显示标题、艺术家、专辑、封面。
6. 关闭窗口 → 音乐继续 → 菜单栏可控制 → 再开窗口状态一致。
7. `Cmd+Q` 后进程退出、无残留音频、控制中心项消失。
8. 播放历史与播放次数写库（重启后可见）。

---

## 7. 先做的验证小样（spike，3–5 人日）

**状态：未执行。** 本节只给任务、阈值与判定，不含结论。产出放在临时分支/目录（如 `spike/`），不并入 `client/`；结论单独落盘为 `docs/plan/2026-10-25-macos-mygo-spike-record.md`（原始日志、截图、`pmset` 输出、CPU/RSS 采样），本文件只保留判据。

### 7.1 S1 音频链路（1.5–2 人日）

做：`purego` dlopen 现有 `libmpv` 动态库 → `mpv_create` → `loadfile` 一首本地 FLAC 24/96 → 观察 `playback-time/eof-reached` → 起一个**要求 `Range` 且校验 `Authorization`** 的本地 HTTP 服务，再播一首远端 FLAC → 两首连续播放。

验收阈值（全部满足才算通过）：

| # | 观测 | 阈值 |
|---|---|---|
| 1 | 出声 | 两种采样率均出声，无爆音；日志无 audio underrun |
| 2 | 结束回调 | 文件结束 ≤150 ms 内收到 `eof-reached`/`end-file(eof)`，3/3 次 |
| 3 | Range | 远端曲目 seek 到 50% 后 ≤300 ms 恢复出声；服务端日志可见 `Range` 请求 |
| 4 | 鉴权头 | per-file `http-header-fields` 生效（无头时服务端返回 401 且播放失败，带头成功） |
| 5 | gapless | 同一专辑两首 FLAC 连续播放，间隙 ≤20 ms 或人工不可闻 |
| 6 | 无 cgo | `CGO_ENABLED=0 go build ./...` 通过；`go vet` 干净 |
| 7 | 稳定性 | 200 次 `setQueue`/`seek` 无崩溃；`-race` 干净 |
| 8 | 资源 | 播放 30 分钟：RSS ≤300 MB，单核 CPU ≤10%（M 系列） |

### 7.2 S2 媒体键与 Now Playing（1.5–2 人日）

做：`native/media_session.m` → 编译 dylib → `purego` 加载 → 与 S1 的播放器同进程，注册五个命令回调；同时验 App Nap 断言。

验收阈值：

| # | 观测 | 阈值 |
|---|---|---|
| 1 | 元数据 | 控制中心/Now Playing 显示标题、艺术家、专辑、封面；切歌后 ≤500 ms 更新 |
| 2 | 播放态 | 播放/暂停与 tile 状态一致；播完停下后 tile 显示已停止 |
| 3 | 按键 | F7/F8/F9（及控制中心按钮）→ Go 回调 ≤150 ms → 音频响应正确 |
| 4 | 拖动 | 控制中心拖动进度 → Go 收到秒数并 seek |
| 5 | 关窗 | 关主窗口继续播放时 tile 仍正确；`Cmd+Q` 后 tile 消失 |
| 6 | 回调稳定性 | 连续 100 次按键无崩溃、无竞态（`-race`） |
| 7 | App Nap | 播放期间 `pmset -g assertions` 可见断言；暂停后断言释放 |
| 8 | 无 cgo | 同上，`CGO_ENABLED=0` |

### 7.3 S3 判定记录（0.5 人日）

把 S1/S2 的原始数据（日志、截图、`pmset` 输出、帧/CPU 采样）落盘，并按 §7.4 给出「继续 / 降级 / 暂停」的结论。**未通过的不许"差不多"**：阈值是二值的。

### 7.4 放弃条件（满足任一条即触发对应动作）

| 观察 | 判定 | 动作 |
|---|---|---|
| S1 在 1.5 人日内无法在无 cgo 条件下出声 | 进程内 `purego` 路线不可行 | 切**子进程内核 B**（+3–5 人日），并补测归属 |
| S1 中 `purego` 事件结构体导致 ≥2 次不可定位崩溃 | C 不稳定 | 同上 |
| S1 gapless 用 mpv 选项无法达成（间隙 >100 ms） | 无损连播体验不达标 | 记录并以"可接受间隙"降级，或转 D；二者需用户选 |
| S1 鉴权头无法按曲目下发（mpv 版本不支持 per-file options） | 远端播放方案不成立 | 改用"Go 侧带头的本地代理端口"（增加 2–3 人日）或转 B |
| S2 按键回调完全收不到 | P2 shim 不可行 | 先花 0.5 天试 P1（`purego/objc` 直连）；仍失败 → **触发暂停** |
| S2 按键可用但 tile 长期空白，且菜单栏降级可接受 | 归属受限 | 按 §10-3 的口径接受降级，写入发布说明，继续（不改内核） |
| S2 进程内出声仍无 Now Playing 且按键也不通 | macOS 不接受该接入方式 | **触发暂停**，回报用户（这是唯一会停工的判据） |

---

## 8. 风险与回退

### 8.1 双轨期规则（硬规则）

1. **`app/`（Flutter，macOS 目标）在 M7 验收前不删**，CI 的 macOS job 保留，随时可出包。
2. **开发期不写生产库**：`client/` 支持 `TINGYU_DATA_DIR` 覆盖；开发/验收一律指向库副本（`cp library.sqlite` + `covers/`）。M7 才切到真实目录，且切换前自动备份 `library.sqlite`、`covers/`、`settings.json` 到 `.../backups/<timestamp>/`。
3. **`PRAGMA user_version` 冻结为 2**：M7 切换后 30 天内不改；只允许 nullable 加列（drift 的 `_ensureColumns` 能补差）。要加不可空列或改语义 → 排到 30 天之后，并同时下线 Flutter 版。
4. **凭据不迁移、只重填**（§3.4），发布说明必须写。
5. 两端不同时写同一目录：开发期靠 2；切换后靠 3（版本冻结 + 只加可空列）。

### 8.2 切换判据（全部满足才切换）

- [ ] §7 的 S1/S2 阈值全部通过，或降级方案经用户确认。
- [ ] 9 格式矩阵逐项通过（M2 验收表）。
- [ ] 媒体会话 8 项（M1 §6.1 第 4–7 条 + 控制中心元数据/拖动）。
- [ ] 数据语义：扫描合并权威性（取消/截断不删曲）、收藏/歌单/播放历史保留、封面孤儿回收。
- [ ] 性能：10,000 行滚动 p95 ≤16.7 ms；冷启动 ≤1.5 s。
- [ ] 稳定性：真实库连续播放 4 小时无崩溃、无内存单调增长。
- [ ] 分发：公证包在空用户账户可启动；`spctl` 通过；控制中心在干净系统可用。
- [ ] 回退演练：用备份库重装 Flutter 版，库可打开且收藏/歌单在。

### 8.3 回退办法

| 时点 | 回退动作 | 数据影响 |
|---|---|---|
| M7 前 | 不发布；`client/` 只在开发分支 | 无（生产库未被写） |
| M7 切换后 30 天内 | 重新发布 Flutter DMG（同一 bundle id，同一数据目录）；用切换前备份的库 | 若 MyGo 只加了可空列，drift 补差后可用；若已写 `settings.json` 新键，旧版忽略未知键（宽容解析） |
| 30 天后 | 只有这样才允许提升 `user_version`；回退需回滚库文件 | 依赖备份 |

**不设"自动双跑"**：不做两套客户端同时写同一库的切换开关（冲突面大于收益）。

### 8.4 风险登记

| # | 风险 | 概率/影响 | 缓解 | 验证点 |
|---|---|---|---|---|
| 1 | MyGo 0.x 破坏性 API（26 天 70 个版本，已发生过元素类型变更并配 codemod） | 高 / 中 | 锁精确版本；只升级在里程碑之间；每次升级跑 `go tool mygo migrate-ui` + `mygo vet` + 组件测试 | 每次升级 PR |
| 2 | 上游停更 / bus factor 1 | 中 / 高 | 只用公开文档化 API；内核与 UI 都不依赖 MyGo 内部实现（libmpv 直连、shim 独立）；保留 fork 自养选项 | M0 记录所用 API 清单 |
| 3 | Now Playing 归属（本方案最不确定的一点） | 中 / 高 | 内核与 shim 同进程；S2 先测；降级口径已定 | S2 |
| 4 | LGPL/GPL 合规（mpv/FFmpeg 构建参数） | 中 / 中 | 先读 dylib 构建信息；只动态链接；附许可证与源码获取说明；禁静态链 | spike 第 1 步 |
| 5 | `purego` 稳定性（结构体布局、回调、GC 生命周期） | 中 / 高 | 布局断言测试；崩溃压测；B 作为隔离手段 | S1/S2 |
| 6 | `mygo.Secrets` 2560 B 上限装不下夸克 Cookie | 中 / 中 | 实测长度 → 分片 → dylib Keychain 兜底 | M3 首日 |
| 7 | 无 ORM 导致查询/迁移错误 | 中 / 中 | schema 逐列对齐；迁移前后逐表 `count(*)` + 抽样行哈希比对脚本；上线前只读对比 Flutter 版结果 | M0、M7 |
| 8 | MyGo 是否支持随包携带额外 dylib/二进制（报告未确认） | 低 / 中 | M0 验证；不行则自建 `.app` 组装脚本（编译产物 + `Contents/Frameworks` + `Info.plist` + 签名） | M0 |
| 9 | 公证与嵌套二进制（shim、libmpv、ffmpeg） | 低 / 中 | 逐层签名 + hardened runtime + 必要的 exception；本地 `xcrun notarytool` 预演 | M6 |
| 10 | 无障碍低于现状（读屏） | 高 / 中 | 键盘 100% 可达 + 焦点环 + 语义标签尽量补；发布说明明确；M6 后单列排期 | M6 |
| 11 | 自建图片缓存/取色引入新缺陷 | 中 / 低 | 内容哈希 + LRU 上限 + 可观测命中率；取色失败用中性渐变并打日志 | M5 |
| 12 | 工期低估（换语言 + 换范式） | 高 / 中 | 里程碑可验收、spike 先行、M2/M4 可并行；每里程碑结束复盘偏差 | 每里程碑 |

### 8.5 触发暂停的条件

- §7.4 的"按键完全收不到且 P1 也失败"。
- libmpv 动态库为 GPL 构建且用户不接受 GPL 分发（许可问题不能绕过）。
- MyGo 上游宣布停止维护，或连续两个季度无发布且关键缺陷无人响应（届时是"继续用当前版本"还是"回 Flutter"的产品决策）。

---

## 9. 工作量粗估

| 里程碑 | 内容 | 粗估（人日） |
|---|---|---|
| — | spike（S1/S2/S3） | 3–5 |
| M0 | 骨架、只读数据、`.app` 组装、额外二进制打包验证 | 5–8 |
| M1 | 本地库端到端 + 内核 v1 + 媒体会话 shim（主线） | 14–22 |
| M2 | 内核生产化（9 格式、Range、gapless、循环、失败、预取） | 8–12 |
| M3 | 来源（WebDAV + 夸克扫描/登录/直链） | 12–18 |
| M4 | 界面（令牌、组件、11 个页面、舞台/队列/歌词、命令面板） | 26–38 |
| M5 | 元数据 4 源 + AI + 人工匹配 + 图片缓存与取色 | 8–12 |
| M6 | 签名/公证/DMG/CI/测试体系/无障碍键盘路径 | 6–10 |
| M7 | 双轨验收、数据切换、删除 Flutter 与五平台 CI、文档 | 5–8 |
| — | 测试体系专项（`ui.Tester` + Go 单测，跨里程碑记账） | 8–12 |
| **合计** | **纯开发** | **92–140** |
| — | 0.x 升级储备（每季度 1–2 人日，不计入交付） | 8–12 |
| **合计（含储备）** | | **100–152** |

与调研 116–186 的差异（逐项，避免看起来像"悄悄压缩"）：

| 功能块 | 调研（三桌面） | 本方案（仅 macOS） | 差额原因 |
|---|---|---|---|
| 媒体会话 | 15–30 | 6–10 | 只做 macOS；Windows COM/SMTC 与 Linux D-Bus 随平台消失 |
| UI 重画 | 30–45 | 26–38 | compact（<640）外壳、底部导航、移动手势、安全区在 900 宽最小窗口下不可达，直接砍掉；Hero 只做近似 |
| 播放内核 | 18–30 | 8–12 + M1 集成 | 复用 libmpv，不再补 6 个解码器、不再自建 Range/gapless/结束回调 |
| 数据层 | 8–12 | 5–8 | schema 已定、库文件复用、无旧版 Swift 导入 |
| 来源 | 11–17 | 12–18 | 不变（含夸克三条登录路径与 Cookie 生命周期） |
| 元数据/图片 | 13–20 | 8–12 | 抓取直译；图片管线合并进同一里程碑 |
| 打包/CI | 5–8 | 6–10 | 多出 shim / dylib 的签名与公证 |
| 测试 | 8–12 | 8–12 | 不变 |
| 骨架/装配 | — | 5–8 | 调研未单列 |

风险：若 spike 迫使走 D（原生 AudioToolbox 音频），M1/M2 增加 10–15 人日，总量约 102–155。所有数字仍为**粗估**。

---

## 10. 待用户拍板 / 待确认

1. **播放内核路线**：推荐 C（进程内 libmpv via purego），降级 B，兜底 D。需要用户在 spike 结果出来后拍板一次（方案已给二值判据，不需要主观判断）。
2. **关窗继续播放**（§5.6）为默认行为：是否同意？不同意则保留"关窗即退出"，后台播放只在窗口最小化/被遮挡时成立。
3. **媒体键降级口径**：若 tile 无封面但按键可用，是否接受？（§5.4）
4. **读屏无障碍降级**（§2.4 #47）：接受"M6 后再补"还是必须在切换前达标？后者会让 M6 增加约 5–8 人日。
5. **自动更新器**：MyGo 自带签名更新（Sparkle 式）。现状是手动下载 DMG。是否在 M6 一并接入？（不接入不影响切换）
6. 移动端是否永久不做：按用户两次原话"先只保留 Mac 端"规划；日后回来属新范围，不在本方案内。

---

## 11. 后续实现 PR 的自查清单

- [ ] 没有新增 cgo；`CGO_ENABLED=0 go build ./...` 与 `go test ./...` 通过。
- [ ] 没有改动 `library.sqlite` 的 `user_version`；只加可空列。
- [ ] 日期写文本 ISO-8601（UTC + 微秒 + `Z`）。
- [ ] 封面仍走内容哈希 + 孤儿回收，二进制不入库。
- [ ] 播放失败仍走快照、不抛异常；撤下条件仍是"重新出声且位置前进"。
- [ ] 时长未知仍报 `ready`，不报 `loading`。
- [ ] 单曲循环下发内核；列表循环回绕由控制器重建；顺序播完停在末尾且能再播。
- [ ] 预取仍为 2，且重建期有闸门（不把结果追加到旧队列）。
- [ ] 系统媒体会话仍按 `(id,index,duration)` 去重、500 ms 节流、语义变化立即推。
- [ ] 用户可见错误文案（WebDAV 401/403/429/503、夸克直链失效、授权失效）逐字未变。
- [ ] `assets/opencc/TSCharacters.txt` 与其 Apache-2.0 NOTICE 保留。
- [ ] 第三方动态库为 LGPL 构建、动态链接，NOTICE 与源码获取说明随包分发。
- [ ] 崩溃/退出路径会 `ty_media_clear()`，不留控制中心残留。

---

## 附录 A：行为契约速查（重写时逐条对照）

| 契约 | 现状文件 |
|---|---|
| 引擎接口、失败不抛、快照字段 | `app/lib/playback/playback_engine.dart`、`playback_snapshot.dart` |
| 失败撤下条件、未知时长、缓冲 | `app/lib/playback/media_kit_engine.dart` |
| 队列预取/世代/闸门、循环、播完再播 | `app/lib/app/playback_controller.dart` |
| 系统会话节流与去重键 | `app/lib/playback/tingyu_audio_handler.dart` |
| 扫描结果权威性 | `app/lib/sources/source_adapter.dart`、`local_library_scanner.dart` |
| 数据 schema、迁移补差、时间文本 | `app/lib/data/db/schema.dart`、`database.dart` |
| 封面内容寻址与回收 | `app/lib/data/cover_store.dart` |
| 凭据账号规则与代际 | `app/lib/data/secure_store.dart` |
| WebDAV 错误文案与重试 | `app/lib/sources/webdav/*`、`http_retry.dart` |
| 夸克登录三个坑 | `app/lib/features/sources/quark_web_login_page.dart` |

## 附录 B：本方案的复核命令

```sh
# 基线
git log -1 --format=%H main                     # 8d008a2284c26272c73e26c018d782eca361d662
git status --short

# 现存格式与契约
sed -n '49,60p' app/lib/sources/local/local_library_scanner.dart
grep -n 'libraryPageSize\|libraryFingerprintProvider' app/lib/app/providers.dart
sed -n '141,160p' app/lib/features/library/library_page.dart

# 平台与分发
grep -n MACOSX_DEPLOYMENT_TARGET app/macos/Runner.xcodeproj/project.pbxproj
cat app/macos/Runner/Release.entitlements

# 线上库（只读）
python3 - <<'PY'
import sqlite3, pathlib
p = pathlib.Path.home()/'Library/Application Support/com.halunhaku.tingyu/library.sqlite'
c = sqlite3.connect(f'file:{p}?mode=ro', uri=True)
print('user_version', c.execute('pragma user_version').fetchone()[0])
print('journal', c.execute('pragma journal_mode').fetchone()[0])
print('tables', [r[0] for r in c.execute("select name from sqlite_master where type='table'")])
print('sample', c.execute('select date_added from tracks limit 1').fetchone()[0])
PY
```
