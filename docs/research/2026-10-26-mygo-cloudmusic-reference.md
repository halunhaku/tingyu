# 调研：从 `mygo-cloudmusic` 提炼可借鉴做法（只借鉴思路，不复制代码）

日期：2026-10-26
性质：**只读调研**。没有改 `client/`、没有改 `app/`、没有合并、没有打 tag。本文是本分支相对 `main` 的唯一改动。
许可证立场：对方是 **AGPL-3.0**，本文**不含任何其代码片段**（连小段引用也避免），只写做法、数据结构、流程、测试思路与数值常量，并给出源码路径与链接作为佐证。理由与边界见 §8。

核查基准：

- 对方仓库 [`egoist/mygo-cloudmusic`](https://github.com/egoist/mygo-cloudmusic)，本文全部行号钉在 commit [`556379a`](https://github.com/egoist/mygo-cloudmusic/tree/556379a473d7a9a32e1b4138f190d3e62807ed95)（`0.1.12`，2026-10-26T01:04:36Z，即调研当时最新）。仓库元数据（`gh api repos/egoist/mygo-cloudmusic`）：13 star、1 fork、AGPL-3.0、建于 2026-10-25T11:41Z、最后推送 2026-10-26T01:17Z、7 875 KB。所有路径都相对于该 commit 的仓库根。
- 对方钉的框架版本：`github.com/egoist/mygo v0.6.5-0.20261025230045-be164835449b`（见 [`go.mod`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/go.mod)），即 MyGo commit `be164835449b0f21ae9e3d080fad79cff6b8fdc5`（下称 `be16483`，2026-10-25T23:00:45Z，提交信息「Show the update window of a background check as Sparkle does (#775)」）。
- 我方基准：`client/` 钉 `github.com/egoist/mygo v0.6.4`（`client/go.mod:7`）；`app/`（Flutter）为现役实现；M5/M6 未做（`docs/plan/2026-10-25-macos-mygo-migration-plan.md:461-462`）。

---

## 0. 结论速览

| 问题 | 答 | 证据强度 |
|---|---|---|
| 这个仓库有参考价值吗？ | **有，但价值集中在两处：一是它把 MyGo 新版的能力用得很满（媒体会话、帧预算、缓存、取色），二是一份可直接照抄结构的 macOS 签名/公证/发布流水线。**它的音频内核路线（纯 Go 解码）对我们完全不可用 | 高（逐文件读过，见 §2、§6） |
| 最该立刻抄的一条是什么？ | **MyGo `be16483` 起框架自带 `mygo.NowPlaying`（三端原生媒体会话，PR #654 已合并且正是它用的东西）。升到这个版本后，我们自研的 `client/internal/mediasession/`（非测试约 930 行 purego/objc）在 API 层面已无必要** | 高（源码 + PR + compare，见 §7） |
| 对我们的播放器最有价值的单点改进？ | **拖动进度只在松手时 seek 一次**（它是这样，我们不是）。我们每拖一格就 `Seek` 一次，远端来源（夸克直链/WebDAV）等于连续重发 Range 请求 | 高（`client/internal/ui/components/transport.go:110`、`client/internal/ui/pages/stage.go:159` vs 它 `internal/app/ui_player.go:31-60`） |
| M5（元数据与图片）能借到什么？ | 取色算法的**结构**（缩到 24×24 → HSV 分桶 → 按 s²·v 加权 → 灰均值兜底）、模糊封面的参数（48×48、3 次盒糊、饱和度×1.5）、封面淡入的双态（加载中 0、就绪即 1）、图片缓存「留数据不留像素」的内存策略 | 中高（`internal/app/artwork.go` 全文） |
| M6（签名/公证/打包）能借到什么？ | **几乎整条流水线**：`release.yml`（tag → 校验版本 → draft release → keychain → `mygo build -upload`）、`RELEASING.md` 的 7 步 runbook、`mygo.json` 的 `macos.signingIdentity` / `macos.notarize.keychainProfile`。**但嵌套 framework 的签名/公证它没有答案**（它没有 `Contents/Frameworks`），这一段得我们自己补 | 高（工作流 + 它的 `mygo.json` + 我读 MyGo 的 `cmd/mygo` 源码） |
| 它的做法有哪些**不能照抄**？ | 纯 Go 解码只到 MP3/FLAC（我们 9 格式）；没有 PCM 就拿不到频谱/律动；音量均衡依赖网易云的逐曲响度字段（我们没有）；缓存靠"自己下"（我们的字节由 libmpv 自己取）；雾效果依赖它的 GPU shader 与主题体系 | 高（见 §6） |
| 我们要不要为了复用它的代码改 AGPL？ | **不改**（按 Spec 的默认）。本文全部内容在「做法」层面可合法借鉴 | — |
| MyGo 从 v0.6.4 升到 `be16483` 的风险？ | 按签名**零处破坏**（我们用到的 99 个标识符在新版全在；`mygo/audio` 我们根本没 import）。真实成本是供应链：它**没有 tag**，只能钉伪版本 | 中高（静态穷举，未做真实编译，见 §7.4） |

一句话：**这个仓库是一份「MyGo 新版怎么把产品做完整」的样板，不是「音频内核怎么写」的样板。** 对我们最有价值的三条依次是：换掉自研媒体会话（升版）、拖动只在松手 seek、M6 的发布流水线与嵌套签名方案。

---

## 1. 先纠正三处与 Spec 不符的事实

Spec 是 2026-10-26 当天核验的，但有三处与代码/API 不符。按「事实以代码为准」处理：

1. **「我们钉 v0.6.3」不成立**：`client/go.mod:7` 是 `github.com/egoist/mygo v0.6.4`，`client/go.sum:3-4` 也是 v0.6.4；`docs/plan/2026-10-25-macos-mygo-migration-plan.md:49` 写的 v0.6.3 是方案起草时的口径，已被 M0 的实现超过。本文一律以 **v0.6.4** 为基线比较。
2. **「它没有做系统 Now Playing/媒体键」不成立**。Spec 的检索结论「`MPNowPlaying` 0 命中」本身是对的——它**不直接**调 `MPNowPlayingInfoCenter`——但它用的是框架 API：`internal/player/player.go:80-110` 调 `mygo.NowPlaying.OnCommand(...)` 与 `mygo.NowPlaying.Set(mygo.NowPlayingInfo{...})`、`SetPlayback(...)`、`Clear()`。而 `mygo.NowPlaying` 在 macOS 上就是 `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` 的封装（`be16483` 的 `internal/darwin/nowplaying.go:91`），Windows 走 SMTC、Linux 走 MPRIS。**它是做了三端媒体会话的，只是没自己写 ObjC。** 这条恰恰是我们最该看的（§7）。
3. **star 数**：Spec 记 12，今日 API 报 13。不影响结论，仅记录口径。

另外两处需要说明的差异（不是错，是范围）：

- 它是**网易云音乐客户端**：曲库、音质档、登录、评论都来自网易云；我们是**本地 + WebDAV + 夸克**的三来源播放器。所以"功能重合"只到播放器体验层，不涉及来源层。
- 它的 M6 对应物不是"只做签名"：我们的 M6 是「签名、公证、DMG、CI、`ui.Tester` 测试、无障碍键盘路径」（方案 §6），本文按这个更大的口径写。

---

## 2. 逐项对照

判定口径：**已具备**＝我们现有代码已覆盖且不弱于它；**值得借鉴**＝思路或参数可落到我们具体文件（标「部分」的只借其中一层，不照搬整体）；**不适用**＝路线不同，抄了会走回头路。行号：它指向 §0 的 `556379a`，我们指向本仓库当前 `main`。

### 2.1 功能面

| 能力 | 它怎么做（文件:行） | 我们现状 | 判定 |
|---|---|---|---|
| 系统媒体会话 / 媒体键 | 框架 API：`internal/player/player.go:80-110` → MyGo `NowPlaying` | 自研 `client/internal/mediasession/`（purego/objc，非测试约 930 行） | **已具备**（升版后可删除，见 §7.5） |
| 扫码登录 | `internal/netease/auth.go:133-171`（网易云 QR） | `client/internal/sources/quark_qr.go`（夸克扫码） | **已具备**（服务不同，流程同构） |
| 边下边播 | `internal/player/stream.go:27-310`（download + 阻塞读） | libmpv 自己取流 + `internal/sources/recovery.go` 重签直链 | **值得借鉴**（缓存层，§3.1） |
| 本地缓存（上限/清理/用量） | `internal/player/cache.go`、`internal/app/cache.go`、`internal/app/ui_settings.go:123-147` | 无 | **值得借鉴**（§3.1） |
| 音质档切换（标准/较高/极高/无损/Hi-Res） | `internal/netease/netease.go:332-381`（`Levels`、`SongURL`） | 不适用：来源没有"音质档"概念，同一文件只有一个版本 | **不适用** |
| 音量均衡 | `internal/player/player.go:494-518`（ReplayGain 数学 + 预增益） | 无 | **值得借鉴（部分）**（§3.3） |
| 暂停/继续淡入淡出 | `internal/player/fade.go` 全文（180 ms 出、260 ms 入、8 ms tick） | 无 | **值得借鉴**（§3.4） |
| 拖动进度消音 | `internal/app/ui_player.go:31-60`：拖动只改显示值，**松手才 seek**，且不 seek 到末尾 | `client/internal/ui/components/transport.go:110`、`client/internal/ui/pages/stage.go:159`：**`Changed()` 就 seek** | **值得借鉴（P0）**（§3.2） |
| 队列与进度恢复 | `internal/player/player.go:690-729`（`Session` / `Restore`） | 只有"关窗继续播"（进程内），**退出再开不恢复队列** | **值得借鉴（P0）**（§3.5） |
| 随机播放 | `internal/player/player.go:273-315`（`order []int` + 洗牌保持当前曲在首位） | **没有**（`client/internal/ui/pages/settings.go:148` 自承"内核控制器尚未提供 shuffle"） | **值得借鉴（P1）**（§3.6） |
| 逐字歌词 + 翻译 | `internal/lyrics/lyrics.go`（`Line`/`Word`、YRC 解析、`SpreadWords`） | 行级 LRC（`client/internal/ui/model/lrc.go:35`），无翻译、无逐字 | **值得借鉴（部分）**（§3.7） |
| 歌词「律动」动画 | `internal/app/ui_stage.go:26-42、152-260`（动画是播放位置的纯函数） | 无（只有行高亮 + 自动滚动） | **值得借鉴**（若做逐字，§3.7） |
| 间奏时显示热评 | `internal/app/ui_quiet.go`（`lyrics.Quiets` 找间隙） | 无评论源 | **不适用**（间隙检测本身可留作 idle 帧预算用，价值低） |
| 封面取色 | `internal/app/artwork.go:229-306` | M5 未做；Flutter 版规则更复杂（`app/lib/features/player/stage_palette.dart`） | **值得借鉴**（算法结构，§3.8） |
| 模糊封面背景 | `internal/app/artwork.go:309-359`（48×48、3 次盒糊、饱和度×1.5） | M5 未做（舞台用令牌渐变） | **值得借鉴**（§3.8） |
| 背景雾 + 低音起伏 | `internal/app/backdrop.go:36-101`（GLSL）+ `:104-107`（30 fps 帧间隔、700 ms 交叉淡入） | 无 | **值得借鉴（部分）**（画布尺寸与淡入策略可借，雾不借，§3.9） |
| 封面淡入 | `internal/app/ui_kit.go:172-192`（就绪即 1、加载中 0） | `client/internal/ui/components/cover.go:17` 直接换图 | **值得借鉴**（§3.10） |
| 刘海迷你播放器 | `internal/app/ui_notch.go`（542 行）+ `internal/app/notch_darwin.go`（125 行） | 无（有菜单栏托盘） | **值得借鉴（P2）**（§3.11） |
| 帧预算测试 | `internal/app/perf_test.go:18-90` | 只有 p95 滚动帧时（`client/internal/shell/perf_test.go:37`），**没有帧预算** | **值得借鉴（P1）**（§3.12） |
| 签名 / 公证 / 发布 | `.github/workflows/release.yml`、`RELEASING.md`、`mygo.json` | `client/scripts/bundle.sh` 只做 ad-hoc 签名；CI 只有 `flutter.yml` | **值得借鉴（M6）**（§5） |
| 自动更新 | `internal/app/updates.go` + `mygo.json` 的 `updates` | 无 | **视 M6 §10 待定**（§5.4） |
| 纯 Go 解码（MP3/FLAC） | `internal/player/stream.go:310-470`（go-mp3 / mewkiz/flac） | libmpv，9 格式（`client/internal/scan/meta.go:28-31`） | **不适用**（§6.1） |
| 频谱可视化 | `internal/player/stream.go:484-609`（自写 FFT 在解码路径上） | 无 | **不适用**（§6.2） |
| 网易云 eapi 加密 / 登录态 | `internal/netease/eapi.go`（161 行）、`auth.go:26-115`（会话文件） | 不适用（来源不同）；M5 只需其**公开**搜索/歌词接口 | **不适用**（§6.3） |
| 凭据存储 | 会话写文件（`auth.go:26-56`） | macOS Keychain（`client/internal/sources/creds.go`） | **已具备**（我们更强） |

### 2.2 工程做法（不进功能表，但对 M5/M6 直接有用）

| 做法 | 它的实现 | 我们现状 | 判定 |
|---|---|---|---|
| 测试哲学成文 | `AGENTS.md`：只测"会坏的行为"、不测标签文案、不依赖墙钟、新 UI 测试跑 `-count=5` | 无成文规则；有等价直觉 | **值得借鉴**（M6） |
| 视图测试：按无障碍标签操作 | `ui.Tester.Find/Click/Press/Move/Release/Key`（`internal/app/scrub_test.go:30-60` 等） | 已用 `ui.NewTester`（`internal/shell/shell_test.go`） | **已具备** |
| 播放器测试的可控主线程 | `internal/app/helpers_test.go` 的测试替身 + `internal/player/player_test.go:14-56` 的 post 队列 | `client/internal/player/controller_test.go:15-110` 的 `fakeEngine` | **已具备**（思路同构） |
| 缓存淘汰的确定性测试 | `internal/player/player_test.go:165-207`（`t.TempDir` + `os.Chtimes` 造"最久未用"） | 无（无缓存） | **值得借鉴**（写缓存时照这个写测试） |
| 帧预算测量 | `internal/app/perf_test.go:44-52`（`FramePending` 计一秒内请求帧数） | 无 | **值得借鉴（P1）** |
| 每项行为一个测试 + 一句注释说明意图 | 全部 `*_test.go` | 部分如此 | **值得借鉴** |

---

## 3. 值得借鉴的十三个落点

每一项写三件事：**它解决了什么** / **它的做法（路径:行）** / **我们落到哪个文件、怎么验**。**不含任何其代码**。

### 3.1 边下边播与本地缓存（最值得做的一次架构级借鉴）

**它解决了什么**：一首无损 30–50 MB，直接读进内存会顶着堆走（它的提交记录里写过：播放时堆 80–130 MB，改完后低于 10 MB）。它把"正在听的字节"放进**缓存目录里的一个文件**，让系统页缓存去扛读取，进程只留一个小窗口；下完就改名进 LRU，下次直接本地打开。

**它的做法**（`internal/player/stream.go:27-310`）：

1. 一个 `download` 结构：`mu + sync.Cond + file + n(已到字节) + size(预期) + done + err + cancel`。读者要第 n 字节时在 cond 上等，写者每写一块就 `Broadcast()`（`:223`）。
2. 下载器把字节写进 `os.CreateTemp(dir, "*.part")`（`internal/player/cache.go:91`）；**磁盘写失败就降级到内存**并放弃缓存（`stream.go:143` `toMemory`）——即"缓存永远不能挡住播放"。
3. 下完（HTTP EOF 且字节数与 `size` 相等）才 `hand()`：**先关文件、再 `os.Rename`、再在新路径重新打开**（`stream.go:158`）。注释写得很实在：Windows 不允许移动已打开的文件。缓存里以 `<id>-<level>.<mp3|flac>` 命名，旁边放同名 `.json` 元数据；`Size` 与实际文件大小不符就丢弃（`cache.go:44-89`）。
4. 读侧**故意只实现 `io.Reader`、不实现 `io.Seeker`**（`stream.go:273`）——因为 go-mp3 看到 Seeker 会把整个文件读一遍去算帧边界，边下边播就废了。seek 改成"按码率把时间换算成字节偏移 + 向前找帧头"（`:398-441`）。
5. 另有 `window`/`peek`（`:246-269`）用于扫 ID3 头、找 FLAC 魔数：不持锁拷贝、按 32 KB 窗口读。
6. 生命周期：`users` 计数（解码流 + 下载协程），最后一个释放者关文件；`.part` 只有在真正"保留"后才清空路径（`stream.go:176-220`）。启动时清理超过 1 小时的 `.part`（`cache.go:207`）。
7. 缓存上限：`limit` 字节，单曲不得超过上限的 1/4（避免一首歌挤掉一堆），淘汰按**最近播放时间**（`os.Chtimes` 在命中时刷新），清理时永不删除刚写入的那一首（`cache.go:91-214`）。设置页给的是 **关闭 / 1 / 2 / 5 / 10 GB** 五档，默认 **2 GB**（`internal/app/settings.go:155-165`、`:57`）。

**我们怎么用**：我们的字节由 libmpv 自己取，所以"缓存"不能照它的读侧抄，要插到 HTTP 层——而这恰好和我们的 `client/internal/rangesrv/` 同构：

- 新增 `client/internal/cache/`（磁盘 LRU，语义照 §3.1 的 3、6、7 条：`.part` → 校验大小 → `Rename` → `.json` 元数据 → 按使用时间淘汰 → 单曲上限 = 容量/4）。
- 新增一个**本地 HTTP 源**：`http://127.0.0.1:<port>/track/<id>`，实现 Range；读请求阻塞到所需字节到达（照它的 cond 语义），后台把远端字节**tee** 进 `.part`，下完转正。libmpv 得到的是一个普通的、可 seek 的本地 URL（我们已经在 `rangesrv` 里证明过 libmpv 会发 Range、会带我们注入的头）。
- 收益排序：① 拖动/重播不再打远端；② 夸克直链过期（`sources/recovery.go`）在"已缓存"情况下直接消失；③ 弱网缓冲可控。
- **风险**：这是新增组件，且位于播放主路径上，一旦阻塞语义写错就是"卡住不出声"。必须用 `internal/accept` 的验收 harness 覆盖（断网、慢速、seek 到未下载区、下载中切歌、容量满、磁盘只读）。我建议**单独立 todo**，不进 M5/M6。

### 3.2 拖动进度只在松手 seek 一次（P0，改动最小、收益立刻可见）

**它解决了什么**：拖动进度条时每一帧都 seek 会连续打断解码、在远端源上等于连续重发 HTTP Range；它还可能拖到末尾触发"播完→下一首"。

**它的做法**（`internal/app/ui_player.go:31-60`）：滑块的值只进本地状态；`InputPointerUp` 时才 `Seek`，且目标是 `min(值, 时长-1s)`——**留 1 秒**，避免"刚拖到末尾就被判定播完"。另有 `TestScrubSeeksOnRelease`（`internal/app/scrub_test.go:14-62`）把三条不变量写死：拖动中位置不动、拖动中不换歌、松手才落在目标附近。

**我们怎么用**：

- `client/internal/ui/components/transport.go:106-118` 与 `client/internal/ui/pages/stage.go:155-167`：把 `if slider.Changed() { Seek }` 改成"仅在 `!slider.Pressed()` 且值有变化时 Seek 一次"，或按它的写法用 `InputPointerUp` 收尾。
- 目标偏移加上 `end - 1s` 夹取（我们目前 `end` 直接取时长）。
- 验收：新增 `internal/shell/shell_test.go` 或 `internal/ui` 层的测试，断言拖动过程中 `fakeActions.seekCalls` 计数为 0、松手后为 1；M2 的远端 Range 证据重跑一遍，确认一次拖动只产生一次 seek 请求。
- **注意一个反例**：它的做法要求"拖动时进度条的显示值来自本地状态"，否则松手瞬间会跳回去。我们 `v.seek` 已经是本地缓冲，条件满足。

### 3.3 音量均衡（部分借鉴：换成 mpv 自带的 ReplayGain）

**它解决了什么**：专辑之间响度差 6–10 dB 是"听着难受"的头号原因。

**它的做法**（`internal/player/player.go:494-518`）：每曲取网易云给的 `gain`（dB）与 `peak`（峰值，1 为满刻度），增益 = `10^((gain+preamp)/20)`，其中 preamp=+4 dB 是"把 ReplayGain 的保守响度抬到日常听感"；再用 `min(g, 1/peak)` 保证不会削波。增益与用户音量相乘后一次性下发（`applyGain`），缺字段就当 1。

**我们怎么用**：我们的来源没有逐曲 `gain/peak`，但我们播的是**文件**，ReplayGain 是写在文件标签里的——mpv 核心自带这套：

- 实测（本机 `media_kit_libs_macos_audio-1.1.4` 的 `Mpv` 二进制）：`replaygain-preamp`、`replaygain-clip`、`replaygain-fallback` 三个选项字符串**存在**；而 `Avfilter` 只有 412 KB（audio-only 裁剪），`loudnorm`/`dynaudnorm` 字符串**未命中**——所以**不要指望用 `af` 滤镜做响度归一**，只用 mpv 的 `replaygain=track|album` 一族 + 我们的标签读取。
- 落点：`client/internal/mpv/player.go:191-210` 的选项表加 `"replaygain": "track"`（或按设置切 `no|track|album`）+ `"replaygain-clip": "yes"`；设置页加一行开关；`client/internal/scan` 已经能读 ID3/FLAC 标签，缺 ReplayGain 时静默不启用。
- 验收：两首人工构造的 ±6 dB 测试音（`client/scripts/gen-m2-media.sh` 已在用 ffmpeg 造媒体）在开启前后测量输出电平差；无标签文件行为不变。
- **诚实标注**：这一条我没在本机跑过 libmpv 的实际行为，只验证了选项字符串存在。落地前先用 `mpv --replaygain=track` 或我们的 M2 harness 实测一次。

### 3.4 淡入淡出（暂停/继续、切歌、seek 周边）

**它解决了什么**：直接 `Pause()` 在核心音频上是一刀切，能听见"咔"；恢复时也是。

**它的做法**（`internal/player/fade.go` 全文 + `player.go:449-492`）：

- 常量：淡出 180 ms、淡入 260 ms（出快入慢，听感更自然）；余弦缓动（`0.5-0.5cos(πt)`），不是线性。
- 一个**独立协程**按 **8 ms** tick 改音量——注释里写清了理由：主线程每步重绘窗口太贵。
- 用**代际计数**丢弃被后一次淡入淡出超越的协程（`gen`），避免两个 ramp 抢同一个音量。
- 音量与增益分两层：`gain`（用户音量 × 曲目增益）和 `level`（0..1 的淡入淡出系数），最终 = 乘积。这样淡入淡出不会污染用户的音量设置。
- 暂停的顺序是"先淡出、再暂停"（回调里才 `Pause`）；继续是"先 `Play`、再淡入"。
- seek 消音：播放中 seek 时**先 `Pause`、等 30 ms、`Seek`、再 `Play`**（`player.go:449-490`），注释说音频播放器暂停本身在 5 ms 内淡完，30 ms 足够跨过一两个缓冲；并处理了"连续两次 seek"（`TestSeekTwicePlaysOn`）。
- 宿主缓冲：`audio.SetLatency(audio.LatencyPlayback)`（`player.go:80`）让混音提前约 250 ms，macOS 换外观等卡顿不会断音。

**我们怎么用**：mpv 侧没有"淡入淡出"选项（`afade` 是滤镜；audio-only 构建里滤镜稀少），但我们可以：

- 在 `client/internal/mpv/player.go` 里给音量加两层：`userVolume` 与 `fadeLevel`，`SetVolume` 只改前者；新增 `fadeTo(level, duration)` 用 8 ms tick 改 mpv `volume` 属性（`setPropertyString` 已有）。
- 暂停：`fadeTo(0,180ms)` → 回调里 `Pause()`；继续：`Play()` → `fadeTo(1,260ms)`。
- seek：我们不需要造"暂停-等待-播放"（mpv 的 seek 不咔），但 **`recovery.go` 的重播路径**可以借这个顺序避免切歌爆音。
- 风险：mpv 的 `volume` 属性是异步生效的，8 ms 改一次可能被 mpv 自己合并；建议 tick 放宽到 10–16 ms 并实测听感。**这条优先级低于 3.2**：它属于打磨，不是缺陷。

### 3.5 队列与进度恢复（P0，用户能感知的缺失）

**它解决了什么**：退出再开，从上次的队列、顺序、位置、电台继续——这是"播放器像播放器"的基本功。

**它的做法**（`internal/player/player.go:690-729`）：

- 一个纯数据 `Session`：`Queue`、`Order`（播放序）、`At`、`Shuffle`、`Repeat`、`Position`（毫秒）、`Radio`（可选）。`Session()` 在没曲目时返回 `false`。
- `Restore` 先**校验**：`len(Queue)==len(Order)`、`At` 在范围内、`Order` 是 `0..n-1` 的一个排列（`seen` 数组查重），任一不满足就整体放弃——**不做部分恢复**，避免坏数据把界面搞崩。
- 恢复时用 `loadSkipping(at, 0, false, position)`：**先按暂停态加载并 seek 到位置**，用户按播放才出声（它注释里叫"picked up again, it fades in"）。
- 位置在加载完成前存在 `pending`，加载完再 `Seek`（避免 seek 落在空播放器上）。
- 持久化时机由视图层控制（`internal/app/session.go`）：播放状态或位置变化后延迟保存，**播放中定期保存，暂停后不再定时**——它还专门有一个测试（`internal/app/session_test.go:11-45`）证明"暂停后不再有定时器唤醒进程"。

**我们怎么用**：

- 我们已有"关窗继续播"（进程内），缺的是**跨进程**。落点：`client/internal/player/controller.go` 增加 `Session()`/`Restore()`（结构照它的字段，校验照它的四条），`client/internal/app/` 在退出前写、启动时读。
- 存哪里：我们已经有 `library.sqlite` 与 `TINGYU_DATA_DIR` 只读边界（`client/README.md` §数据目录）。**建议单独一个小 JSON 放在数据目录**（不进 SQLite），原因：只读模式下不该写库，而"恢复队列"在只读模式下也应该可用（只影响 UI 状态，不碰曲库事实）。
- 校验必须照做：曲库变了（曲目被删）时，`Queue` 里的 ID 可能失效——恢复时要逐条对库，缺失的跳过；`Order` 校验失败就整体不恢复。
- 验收：退出 → 重开 → 断言队列长度、当前曲、位置（±2 s）、循环态；坏 JSON / 曲目被删 / `Order` 非法三种情形都不崩、安静回退到空队列。

### 3.6 随机播放的数据结构（P1，顺带解决我们的一个"没做"）

**它解决了什么**：队列页要按"用户添加的顺序"显示，播放却要按另一个顺序走；开了随机之后，当前这首还要接着播（不能因为洗牌就跳到别处）。

**它的做法**（`internal/player/player.go:273-315`）：

- 两份数据：`queue []Track`（原序，不动）与 `order []int`（`order[k]` = 第 k 个播放的曲目在 queue 里的下标）。`at` 是 order 里的位置。
- 开随机：先洗 `order`，再把当前曲的下标换到 `order[0]`，`at=0`；关随机：`order[i]=i`，`at=当前曲的下标`。
- 队列变化只 append `order`，不影响已排好的播放序；重复项按 ID 去重（`:273-286` `appendTracks`、`:288-296` `shuffleOrder`、`:297-315` `ToggleShuffle`）。
- **对照我们的现状**：`client/internal/player/controller.go:220-312` 走的是另一条路——把 queue **旋转**成"用户点的那首在 `queue[0]`"，并用 `resolvedItem` 单切片保证对齐。这套解决的是"懒解析 + 预取 + 世代"的错位问题，很扎实，但**没有洗牌位**：queue 的物理顺序就是播放顺序。
- **建议**：给 controller 加一层 `order []int`（语义照它），`queue` 保持用户原序；`currentIndex`、预取窗口、`Next/Prev` 全部改成"按 order 取址"。**这会动 M2 的核心契约**（200 首队列不错位、预取跨队列、世代失效），所以：先写测试再改，且必须重跑 `internal/player/queue_test.go` 与 200 首验收。若不想动内核，退一步：只在"开始播放时"把顺序洗好一次性交给引擎（牺牲"队列页显示原序"，但零风险）。

### 3.7 逐字歌词与"动画是播放位置的纯函数"（M5 的歌词管线之后）

**它解决了什么**：行级 LRC 只能整行高亮，看起来"不跟唱"；而逐字歌词的数据源（网易云 YRC）不是所有歌都有。

**它的做法**：

1. 数据模型（`internal/lyrics/lyrics.go:15-35`）：`Line{At, End, Text, Translation, Words, Timed}` + `Word{Text, Start, End}`。`Timed` 标记"词自带时间"还是"按整行均分"。
2. 解析：YRC 的格式是"整行 `[起始,时长]` + 每个词 `(起始,时长,0)词"（`:73-111`）；LRC 一行可带多个时间戳（`:37-71`）；两者都可带翻译行，按时间合并（`:158-163`）。
3. **`SpreadWords`（`:165-206`）是关键**：**没有逐字时间时，把时间按字符宽度分摊到每个词/字上**，CJK 按字、拉丁按词。也就是说：**只要有行级 LRC，就能做出逐字效果**，不需要新数据源。
4. 渲染是**纯函数**：`internal/app/ui_stage.go:26-42` 用"行时间戳作种子的确定性伪随机"决定每个词的散开/旋转/漂移（同一行每次显示位置一致），用一条固定参数的弹簧曲线（`springStep`，随时间 t 解析计算）决定"蹦出来"的进度，**全部由播放位置推导**。注释点明了收益：**seek 到任意位置，画面和正常播放到那里完全一致**。
5. 下一个「需要重绘的时刻」由 `stageNextFrame`（`:152-183`）算出并返回给 UI，实现"不变化就不请求帧"。

**我们怎么用**：

- 我们的数据只有行级 LRC（`client/internal/ui/model/lrc.go:35`；M5 会加 LRCLIB/网易云抓取）。所以**先做 `SpreadWords` 等价物**：把 `client/internal/ui/model/lrc.go` 的 `LyricLine` 扩成带 `Words []Word`，按行时长 + 字符宽度分摊；`client/internal/ui/components/lyrics.go:22` 的当前行改为按"行进度"逐字着色。
- 动画必须写成 `f(播放位置)`，**不要用 `s.Now()` 做相位**（我们现在 `LyricsView` 里用 `s.Now()` 判断"手动滚动 3 秒内暂停自动跟随"，那是交互状态，可以留；但逐字高亮不能用墙钟）。
- 验收：`ui.Tester` 里把播放位置设到 t 与 t'，断言渲染结果**只**由位置决定（同位置重复渲染像素一致）；seek 来回后画面不残留。
- `Timed` 的翻译行合并（`:158-163`）也值得抄：我们现在完全没有翻译概念。

### 3.8 封面取色与背景（M5 的正题）

**它解决了什么**：舞台/播放页要有"从这张封面长出来"的颜色，而不是每个歌手都一个色。

**它的做法**：

1. **取色（`internal/app/artwork.go:251-282`，HSV 换算在 `:283-306`）**：先把封面 `shrink` 到 **24×24**（`:229-250`，分块均值采样，每块最多取 4×4 个点）；转 HSV；丢掉 `s<0.15` 或 `v<0.15` 的像素（近灰/近黑）；按 **18 个色相桶**累加，权重 `w = s²·v`（越鲜艳越算数）；取权重最大的桶的加权平均 RGB；**如果最大权重 < 2（几乎没有彩色像素），退回整图的灰度均值**——灰封面不会得到随机彩色。
2. **模糊背景（`:309-359`）**：`shrink` 到 **48×48**；每像素把饱和度拉 1.5 倍（"像透过有色玻璃的光"）；做 **3 次半径 5 的盒糊**（横向+纵向，边缘 clamp）；输出 48×48 的 RGBA，最终**放大铺满**——因为只有 48×48，放大后的柔化感本身就是效果，且几乎不耗 CPU。
3. **背景策略（`internal/app/backdrop.go:126-200`）**：静止背景**每首歌只画一次**，画进一个"窗口宽度的 1/8"的小画布（`:133`），然后放大显示；GPU 可用且开了雾时才用 1/2 尺寸、30 fps 的 shader 版（`:104`）。**换歌是 700 ms 交叉淡入**，旧背景留在自己的画布上直到淡完（`:107`、`:147-176`）——这样不会出现"先黑一下再出现新背景"。
4. **图片缓存（`:34-116`）**：解码后**GPU 上留像素、CPU 上只留压缩字节**，绘制后 **2 秒**就把像素释放（`artRelease`），下次要用再从字节解码；缓存里 5 分钟没被请求就清（`artKeep`）；并发解码限 8；失败的 URL 也记一笔（避免反复请求）。它的提交信息说这是把"播放时堆 80–130 MB"压到"10 MB 以下"的那次改动。
5. 顺带一个冷知识（`:156-227`）：网易云的封面有时是**动图 WebP**，`image.Decode` 读不了；它自己解析 RIFF 容器，把第一帧重组成一张静态 WebP 再解码。**我们 M5 的多源封面（QQ/网易云/iTunes）会遇到同样的问题**，值得照这个思路写（不是照抄代码）。

**我们怎么用**：

- 取色落点：方案已经指定 `client/internal/images/palette.go`（`docs/plan/2026-10-25-macos-mygo-migration-plan.md:264`），目标是"直译现有规则（丢极端亮度/饱和、聚类主/次色、LRU 64）"。它的 24×24 + 18 桶 + `s²·v` + 灰兜底，是**实现这个规则的一个已上线的具体化**，可以直接作为参数起点；但**我们有两个色**（主/次），它只有一个——次色可以从"权重第二的桶"取，或用 Flutter 版的现有聚类（`app/lib/features/player/stage_palette.dart` 才是我们的规格来源，别被它覆盖）。
- 模糊背景落点：`client/internal/ui/pages/stage.go:38-45` 现在是令牌渐变；M5 换成"48×48 模糊封面 + 主色深渐变"。`CoverMatch`/`ui.Image` 已有，不需要新 API。
- 淡入落点见 §3.10。
- 灰兜底这条**务必照做**：M5 的风险清单里写了"取色失败用中性渐变并打日志"（方案 `:588`），它的"权重不足→灰度均值"就是"失败"的另一种形态。

### 3.9 背景雾（不建议照抄，只借两个参数）

**它的做法**（`internal/app/backdrop.go:36-101`）：一段 GLSL：5 个八度的值噪声 + 用噪声扭曲坐标（"翻滚"而不是"平移"）+ 低频能量 `Bass` 控制浓度 + 屏幕空间浮尘（hash 网格 + 径向衰减 + 各自相位闪烁）。它只在**实验性设置**里默认关闭，注释也直说"会多用一些电量"。

**我们的判断**：我们的舞台是"声档"令牌系统（`client/internal/ui/tokens/`），为一个可选特效引入 shader 依赖、30 fps 的 GPU 画布、以及与"减少动态效果"偏好的交互，性价比不对。**只借两个可复用的点**：

1. **画到小画布再放大**（1/8 或 1/2），CPU 版只用静态图；这条对 M5 的模糊背景同样成立。
2. **换歌 700 ms 双画布交叉淡入**，旧图保留到淡完。

### 3.10 封面淡入（十行改动，体验提升明显）

**它的做法**（`internal/app/ui_kit.go:172-192`）：一个 320 ms 的动画；组件里先问"这张图就绪了吗"——**图已就绪就 `Jump` 到 1（不播动画），图刚从加载变成就绪就 `AnimateTo` 到 1**。占位符同步用 `1-进度` 反向淡出。它还为这个行为单独写了测试（`internal/app/fade_test.go`），断言"加载中 0、三分之一处介于 0 和 1、淡完 1、一开始就就绪则立刻 1"。

**我们怎么用**：`client/internal/ui/components/cover.go:17-40` 现在是"有 bitmap 就画图，没有就画占位块"的硬切。

- 加一个 `AnimateTo("cover", 1, 200ms)` + `Jump` 双态。这两个 API 我们**还没用过**（`grep .AnimateTo( / .Jump( ` 零命中），但 v0.6.4 就有；我们已有的动效是 `ui.ElementTransition{Match: ...}`（`client/internal/ui/components/transport.go:48`、`client/internal/ui/pages/stage.go:97`），两者可以共存：`Match` 管跨页共享元素，`Jump/AnimateTo` 管单个元素的首帧。
- 占位符按 `1-进度` 淡出，避免"占位块闪一下再消失"。
- 验收：`ui.Tester` 里模拟"先无图后给图"，断言进度单调、结束时为 1；"一开始就有图"时第一帧就是 1（不能闪）。
- 这是**没有数据依赖**的改动，可以脱离 M5 单独做。

### 3.11 刘海迷你播放器（P2，独立 todo，别塞进 M5/M6）

**它解决了什么**：播放器缩到"看不见但一直在"的形态，比菜单栏托盘更符合 macOS 现在的习惯。

**它的做法**：

- 一个**独立窗口**（`internal/app/ui_notch.go:49-98`）：`mygo.NewWindow` 的 `Panel + Frameless + Transparent + DisableShadow + DisableResize + Hidden`，内容就是一张 `ui.View`；`OnClose` 里 `PreventDefault`（这个窗口永远不真关）。
- **刘海尺寸靠系统量**：`internal/app/notch_darwin.go:17-31` 用 `NSScreen.safeAreaInsets.top` 判断有没有刘海，宽度 = `screen.frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width`。
- **盖过菜单栏与全屏**（`:44-88`）：把窗口 styleMask 改成 `nonactivatingPanel | fullSizeContentView`（它注释解释了为什么：MyGo 的窗口都是 titled 的，AppKit 会把 titled 窗口压在菜单栏下面），`setLevel: NSMainMenuWindowLevel + 3`，`setCollectionBehavior` 打开"所有 Space / 全屏辅助 / 不进窗口循环"。
- **点透**：`SetIgnoreMouseEvents(true)` 平时让点击穿过去，悬停展开时才接收。
- **指针追踪**：自己加一个 `NSTrackingArea`（`:`60-87`），因为 MyGo 只在应用激活时跟踪指针，而刘海永远在别的应用上方。
- **只在可能需要时轮询**：`poll()` 按"当前是否展开/是否在 greeted 状态"决定下次何时再查（`:246-312`），静止时不花 CPU。

**我们的判断与用法**：我们客户端已有菜单栏托盘（`mygo.NewTray`，`client/internal/app/` 的托盘菜单），刘海播放器不是 M5/M6 的内容，也不在现方案里。**如果要做的唯一正确做法是照它的三段式**：量刘海 → 抬窗口层级 → 自己管指针与点透。代价是 100–150 行 purego/objc（我们 `internal/mediasession/bridge_darwin.go` 已有同类基础设施可复用）。建议单独立 todo，不要混进 M5/M6。

### 3.12 性能测试：帧预算（P1，M6 的"`ui.Tester` 测试"正好该加这个）

**它解决了什么**：播放时很多视图会"每帧都请求重绘"，CPU 与电量悄悄上去；功能测试看不出来。

**它的做法**（`internal/app/perf_test.go:18-90`）：

- 用 `ui.NewTester` 把视图装在 1200×800 的虚拟窗口里，播放器**持在某个位置**（`Hold(pos)`）。
- `framesAt`：推进 1 秒，然后按 1/60 s 步进 60 次，每次问 `FramePending()`；**统计"这一秒里视图主动要求的帧数"**。
- 断言："播放在播、页面在播放器下面"时 ≤ 3 帧/秒；"舞台在两句歌词之间"时 ≤ 12 帧/秒。
- 另一个测试（`TestBackdropFadeEnds`）证明：换歌的 700 ms 交叉淡入**淡完就停**，不会变成一个永久动画（它断言"旧背景画布被置空"）。
- 它自己也承认局限：`Tester` 只统计不依赖定时器的帧（注释里说"其余交给 `MYGO_FRAME_STATS` 的帧日志"）。

**我们怎么用**：

- `FramePending`/`NewTester` 在 **v0.6.4 就有**（`~/go/pkg/mod/github.com/egoist/mygo@v0.6.4/ui/headless.go:438`），不需要升版。
- 落点：扩 `client/internal/shell/perf_test.go`（现在只有 p95 滚动），新增：
  - `TestIdleAsksForFewFrames`：无播放、曲库页 → 每秒 ≤ 2 帧；
  - `TestStageAsksForFewFrames`：舞台 + 歌词 → 每秒 ≤ 12 帧（我们舞台有渐变与 Hero 近似，先测再定阈值）；
  - `TestCoverFadeEnds`：封面淡入结束后不再请求帧。
- 验收：三个测试进 CI（M6），阈值写进 M6 的验收标准；**如果实测超标，先修节流再改阈值**——阈值是契约，不是调参。

### 3.13 可拖拽 / 可甩动的封面（可选，P2）

**它解决了什么**：舞台上的封面不只是图——可以按着它倾斜、甩出去换歌，让"下一首"有一个手感。它的测试把这套手势写成契约（`internal/app/cover_test.go`：左甩换下一首、右甩换上一首、甩得太短弹回原曲、触控板两指横扫等效）。

**它的做法**（`internal/app/ui_cover.go`，约 400 行）：

- 拖拽用 `ui.Draggable`（`:122`）跟手；松手时按位移/速度判定"甩出去"还是"弹回"，两套弹簧参数（甩动 480 ms / bounce 0.18，滑入 520 ms / bounce 0.12，`:80-83`）。
- 倾斜与光泽：用一段 shader 画"一个圆角方块的模糊阴影"，**自己在 shader 里圆角**（`ui/shader`），因为用 clip 会在每帧倾斜时重新栅格化（`:59-85`）。这一条对我们**不适用**（§6.5：我们的 UI 是令牌体系，不为一张封面引入 shader）。
- **"减少动态效果"偏好下退化**（`:189`）：不倾斜、不甩，换歌改成交叉淡入——这是**我们必须照做的部分**，如果将来加手势。
- 切歌时旧封面滑出、新封面从另一侧滑入（`ui.Motion`，`:106-120`），与我们已有的 `ui.ElementTransition{Match: ...}` 不是一回事，需要手写。

**我们怎么用**：`client/internal/ui/pages/stage.go:97` 的封面目前只有 `Match` 过渡，没有手势。若要做：只做"水平拖拽 + 弹簧回位/甩出换歌 + reduce-motion 退化为淡入"，**不要做倾斜与光泽**。落点 `client/internal/ui/components/cover.go` + `pages/stage.go`，用 `ui.Draggable`/`Animation{Spring:...}`（v0.6.4 都有）。收益是手感，不是缺陷修复，**排在 M5/M6 之后**。

---

## 4. M5（元数据与图片）可借鉴点

M5 的验收是"对 20 首无标签曲目触发补全 → 标题/封面/歌词落库并在列表与舞台立即刷新；离线静默跳过不弹错"（方案 `:461`）。对照它的实现：

| M5 子项 | 它的对应物 | 可借鉴 | 落点 |
|---|---|---|---|
| 多源抓取编排 | `internal/netease/{Search,SongDetails,Lyrics}`（`internal/netease/netease.go:274-410`） | **接口形状**：搜索→取详情→取歌词三步分开，每步可单独失败；搜索结果的 `privileges` 要二次确认（它注释里写"搜索把整个曲库标成下架，详情才准"）——我们是"多源降级"，同理：**候选可信度不能只看搜索命中，要再取一次详情** | `client/internal/metadata/`（新） |
| 图片 CDN 缩放 | `Sized(pic, n)`（`:410-417`）：在 URL 上加 `?param=NxN` | **形参化尺寸**：列表 60 px、舞台 600 px 各取一份，不要一张 3000×3000 的原图走全程 | 抓取层 |
| 动图封面 | `internal/app/artwork.go:156-227`（rip 出第一帧） | 我们 M5 会碰到同样的"WebP 动图/AVIF"坑；**思路**：解码失败时按 RIFF 结构找第一帧，而不是直接放弃 | `client/internal/images/` |
| 取色 | `dominantColor`（`:251-306`） | 24×24、18 桶、`s²·v` 权重、灰兜底（§3.8） | `client/internal/images/palette.go` |
| 模糊背景 | `blurImage`（`:309-359`）+ 小画布（`backdrop.go:133`） | 48×48、3×box(5)、饱和 1.5、放大铺满 | `client/internal/images/` + `pages/stage.go` |
| 封面缓存 | `artCache`（`:34-116`） | ① 失败也缓存（带时间戳）② 5 分钟未用即清 ③ 并发上限 8 ④「GPU 留像素、CPU 留字节」——**我们已升级到 `be16483` 后可以用 `Bitmap.ReleasePixels()` 做到 ④** | `client/internal/ui/model/covers.go` |
| 列表/舞台即时刷新 | 它的 `Changed` 回调 + `Invalidate` | 我们已有 `revision`（`client/internal/library/library.go`）与 `SetTracks`，M5 落库后递增即可 | 已有 |
| 离线静默 | 它的 `Fetch` 错误被 `artCache` 记成 `failed`，不弹错 | 照做：M5 的抓取失败只进日志与"未匹配"状态 | — |
| 歌词源 | `Lyrics()`（`:384-409`）：LRC + 翻译 + YRC 三次取值 | 我们的 LRCLIB 有翻译字段、网易云有 YRC；**解析层先做成 §3.7 的数据模型**，源后接 | `client/internal/ui/model/lrc.go` |

**一条 M5 的顺序建议**：先做 §3.10（封面淡入）与 §3.8 的取色纯函数（有 Flutter 版可直接对拍），再做抓取编排。理由是取色/淡入可以被离线图片测试驱动，抓取编排要联网，先把"不需要网络的 80%"锁死。

---

## 5. M6（签名/公证/打包）可借鉴点

M6 的验收是"`spctl -a -vv` 通过；空机器安装启动无隔离警告；CI 只跑 macOS：格式化 + `go vet` + 单测 + 构建 + 公证"（方案 `:462`）。

### 5.1 它的发布流水线（结构可整段照搬）

`.github/workflows/release.yml`（81 行）的骨架：

1. 触发：`push: tags: ["v*"]`；`permissions: contents: write`（草稿 release 与上传）。
2. `draft-release` job（ubuntu）：
   - **先校验 tag 与 `mygo.json` 的 `version` 一致**：用一行 shell 把 `GITHUB_REF_NAME` 与 `v` + `jq -r .version mygo.json` 对比，不等就失败——防"tag 打了 0.2.0、包里是 0.1.12"。**这一条我们没有，必须抄**。
   - 不存在就 `gh release create --draft --verify-tag --title "$TAG" --generate-notes`。
3. `build` job，矩阵：macOS（`macos-latest`，`darwin/arm64,darwin/amd64`）、Windows、Linux（其注释解释了为什么 Windows 在 ubuntu 上构建——MyGo 交叉编译 + NSIS）。
4. macOS 专属步骤：**证书与公证凭据进临时 keychain**，然后 `go tool mygo build -platform … -upload`。
   - 具体步骤：`security create-keychain -p <rand>` → `set-keychain-settings -lut 21600` → `unlock-keychain` → base64 解 `MACOS_CERTIFICATE` 成 p12 → `security import ... -P ... -T /usr/bin/codesign` → `rm` p12 → `security set-key-partition-list -S apple-tool:,apple: -s` → `security list-keychains -d user -s <kc> login.keychain` → `security default-keychain -d user -s <kc>` → **`xcrun notarytool store-credentials notary --keychain <kc> --apple-id … --team-id … --password …`**。
   - 要点：公证凭据是**以 profile 名（`notary`）存进 keychain** 的，`mygo.json` 的 `macos.notarize.keychainProfile` 就填这个名字；`-T /usr/bin/codesign` 让 codesign 免交互用私钥；`set-key-partition-list` 是"无人值守签名"的关键（少了这一步，CI 上 codesign 会弹授权框然后失败）。
   - 环境变量：`GH_TOKEN`（上传）、`MYGO_UPDATER_PRIVATE_KEY`（若启用更新，见 §5.4）。
5. `mygo build` 的语义（我读了 `be16483` 的 `cmd/mygo`）：构建与**签名**发生在同一步（`cmd/mygo/build.go:300`；`codesignArgs` 在生产身份时自动加 `--options runtime --timestamp`，`cmd/mygo/bundle.go:348-361`）；`-upload` 把产物传到**`mygo.json` 里 version 对应的那个 tag 的 release**（工作流注释专门提醒：不是"启动工作流的 tag"）。

### 5.2 它的 `RELEASING.md`（runbook 可整段照搬）

7 步，每步一条命令、一个可观察的结果：

1. 提交 → `go test ./internal/...`。
2. 只在 `mygo.json` 里改 `version`，提交信息**就叫版本号**（`0.1.8`）——这样 `git log --oneline` 就是发布史。
3. `git tag v0.1.8 && git push origin main v0.1.8`。
4. 等 CI：`gh run watch "$(gh run list --workflow release.yml -L1 --json databaseId -q '.[0].databaseId')" --exit-status`；**失败就不发布，先修**。
5. 发布草稿并标 latest：`gh release edit v0.1.8 --draft=false --latest`。
6. **验证更新源**（启用更新时）：把 release 的 `latest/download/update-<os>-<arch>.json` 取下来看版本——注意文件名带 **`os-arch`**，因为每个平台/架构各有一份。
7. 网站要重新部署（它读 latest release 预渲染）。

**我们该抄的**：第 2 步的"版本号即提交信息"、第 4 步的 `--exit-status`（不然 `watch` 永远成功）、第 5 步"草稿 + 手动 latest"、**以及"发布前必须 `spctl` 验过"**（它没有这条，因为它有公证；我们的验收里有，别丢）。

### 5.3 它的 `mygo.json`（我们缺的键）

它的（脱敏后）：

- `macos.signingIdentity`: `Developer ID Application: <名字> (<TEAMID>)` —— 真身份。
- `macos.notarize.keychainProfile`: `"notary"` —— 与 §5.1 的 `store-credentials` 名字对齐。
- `updates`: `publicKey`（更新源签名公钥）+ `github`（`owner/repo`）。
- `linux.categories` / `linux.comment` / `linux.webview: false`。

我们的（`client/mygo.json`）目前只有 `name/identifier/version/copyright/out/macos.minimumSystemVersion/macos.signingIdentity`，且 `signingIdentity` 是 `"-"`（ad-hoc）。**M6 要加的键**：`macos.signingIdentity` 换真身份（建议通过 `-sign` 参数传入而**不写进仓库**，见 §5.5）、`macos.notarize.keychainProfile`。（`updates` 视 §5.4 决定。）

### 5.4 自动更新：借结构，别急着接

它的做法：`internal/app/updates.go` 用 MyGo 的 `plugins/updater` + `plugins/updater/native`，启动后不久检查一次、之后每天一次，原生对话框（中文）+ 后台下载、`updater.OnChange` 驱动设置页刷新；更新包用 `MYGO_UPDATER_PRIVATE_KEY` 签。方案 §10 的问题 5 还没定（"是否在 M6 一并接入"），所以：**本文只记录做法，不作为 M6 必做项**。如果要做，`updates.publicKey` 生成与私钥托管（CI secret）是额外一步，且要处理"降级攻击/证书轮换"。

### 5.5 嵌套 framework：**它帮不了我们，这是 M6 最大的自建工作**

它没有 `Contents/Frameworks`（纯 Go、无 cgo、无第三方 dylib；MyGo 自己的附属二进制放在 `Contents/Resources`，由框架的 `signNestedCode` 一并签），所以它的流水线**没有**"签名并公证第三方框架"的经验。我们的情况：

- 现状：`client/scripts/bundle.sh` 在 `mygo build -skip-dmg` 之后，把 10 个 framework（`Mpv/Avcodec/Avfilter/Avformat/Avutil/Mbedcrypto/Mbedtls/Mbedx509/Swresample/Swscale`）从 pub 缓存复制到 `Contents/Frameworks`，**逐个 `codesign -f -s -`（ad-hoc）**，加 `LC_RPATH`，再 ad-hoc 签主程序与 .app，最后校验。
- 我读了 `be16483` 的签名实现：`codesignArgs` 对真身份会加 `--options runtime --timestamp`；但 **`signNestedCode` 只遍历 `Contents/Resources`**（`cmd/mygo/resources.go:714-770`），**不碰 `Contents/Frameworks`**。也就是说：`mygo build` 无论用什么身份，都不会给我们复制进去的 framework 盖章——这一步永远是我们的（`bundle.sh` 已经在做，只是用 ad-hoc）。
- **M6 的正确顺序**（把 `bundle.sh` 扩一条 release 路径）：
  1. `go tool mygo build -platform darwin/universal -skip-dmg -sign "$DEVELOPER_ID"`（先让 MyGo 用真身份签一次；这一步的签名稍后会被覆盖，但能保证 Info.plist/entitlements 一致）；
  2. 复制 frameworks；
  3. **从内到外**逐层签名：每个 framework 的 Mach-O 二进制 → 每个 `.framework` 包 → 主可执行文件 → `.app`；**都要 `--options runtime --timestamp`**，**不要用 `--deep`**（Apple 已不推荐，且会盖掉我们刚做好的内层）；
  4. 必要时 `--entitlements`（我们目前不需要额外 entitlement：`CGO_ENABLED=0`、无 JIT、无网络服务端）；
  5. `hdiutil` 造 DMG → `codesign --timestamp -s "$DEVELOPER_ID" 镜像` → `xcrun notarytool submit --keychain-profile notary --wait` → `xcrun stapler staple` **镜像与 .app 都要 staple**（MyGo 的 `cmd/mygo/dmg.go:119-127` 与 `:250` 就是"票也 staple 到 app，因为更新装的是裸 app"）；
  6. 验收：`codesign --verify --deep --strict`、`spctl -a -vv`（期望 `source=Notarized Developer ID`）、空机器（或 `xattr -d com.apple.quarantine` 模拟）双击启动、`stapler validate`。
- **风险点**（M6 要逐条试）：① 第三方 LGPL 框架重签后签名是否仍有效（要 `--preserve-metadata` 吗？一般不要，重签即可）；② 10 个 framework 里有的带 `.symlinks`/`Resources`，`--deep` 不推荐后要自己保证不漏；③ libmpv 从 `@rpath` 加载，公证后路径不变（我们已有 rpath 校验）；④ 若将来把 framework 放进 `macos.resources`，会被 `signNestedCode` 自动签，但 rpath 语义不对——**别为了省事走这条**。

### 5.6 CI：我们现在只有 `flutter.yml`

`.github/workflows/flutter.yml` 的触发路径是 `app/**`，`client/` 完全没有 CI。M6 要新增一条 macOS-only 的 Go 工作流：

- 触发：`push/PR` 且 `paths: client/**`、`docs/**`（只改文档不必跑）；`workflow_dispatch`。
- 步骤：`setup-go`（读 `client/go.mod` 的 `go 1.27.3`）→ 格式检查（`gofmt -l` 或 `go vet`）→ `go test ./internal/...`（带 `-count=1`；新 UI 测试在本机跑 `-count=5` 查抖动，CI 跑一次）→ `bundle.sh` 构建 → **仅在 tag 上**：公证 + 上传（照 §5.1）。
- **可以借它的矩阵写法**，但**不要借 Windows/Linux**：我们是 macOS 单端（README 首屏就写了），矩阵只有一行。
- 一条实测过的教训值得写进工作流注释：`client/scripts/bundle.sh` 需要 pub 缓存里的 frameworks，CI 上要显式给出 `FRAMEWORK_SRC`（脚本已支持），不能指望 `~/.pub-cache` 有 media_kit。

---

## 6. 差异与风险：哪些不能照抄

### 6.1 纯 Go 解码 vs libmpv：**不要回退**

它只支持 MP3/FLAC（`internal/player/openStream` 按魔数二选一），因为 `go-mp3` 与 `mewkiz/flac` 是仅有的成熟选择；网易云的"无损/Hi-Res"恰好也只发这两种。我们 9 格式（`mp3/flac/m4a/aac/wav/ogg/opus/aiff/alac`，`client/internal/scan/meta.go:28-31`），其中 **AAC/ALAC/M4A 没有任何纯 Go 方案**（前一份调研 `docs/research/2026-10-25-mygo-audio-in-the-wild.md` 已核实：13 个真实应用里没有一例）。所以：**它的解码与缓存读侧对我们不可移植**，只有"缓存/见 §3.1"这一层值得借。

### 6.2 没有 PCM，就没有它的频谱/律动

它的可视化建立在"解码后的 float32 采样"上：`internal/player/stream.go:484-609` 在解码路径里顺手做 1024 点 FFT、24 个对数频段、提前 1 秒测好，视图按帧号查表（刘海播放器的波形、进度条烟雾、舞台律动都吃这个）。

我们用 libmpv 的 `vo=null` 音频-only 构建，**拿不到解码后的 PCM**（要么改用 `--ao=pcm` 落文件再读——延迟与磁盘 I/O 都不划算；要么写 mpv 的音频滤镜插件——远超收益）。结论：**律动/频谱相关的一切（含刘海里的波形、进度条烟雾）不要照抄**；如果将来真要做可视化，走"读 WAV 分析/离线预分析"或直接接受没有。

### 6.3 音量均衡依赖它的数据源

它的 `gain/peak` 来自网易云 `player/url` 接口（`internal/netease/netease.go:317-334`）。我们没有这个字段，只能靠文件标签里的 ReplayGain（§3.3）。**不要**为了对齐它而自己去算响度（需要完整解码 + EBU R128，代价远超收益）。

### 6.4 缓存的插入点不同

它是"App 自己下、自己解"，所以缓存在解码器下面；我们是"libmpv 自己取"，缓存只能插在 HTTP 层（§3.1）。**照抄它的 `download` 到我们的代码里会得到一个没人调用的组件**——这是最容易犯的错。

### 6.5 UI 体系不同，别把 shader/自绘搬进来

它的 UI 大量使用 `ui/shader`、`ui.Canvas`、`ui.Path` 直接画（封面 3D 倾斜、光泽、烟雾、刘海形状都是自绘）。我们的 `client/internal/ui/` 是"声档令牌 + 组件"体系（`DESIGN.md`），Flutter 版才是我们的设计规格来源。**只借参数（颜色、时长、缓动），不借绘制代码**；否则 M4 已经验收过的视觉会漂移。

### 6.6 它的"来源"与我们的不同

网易云的 eapi 加密、扫码登录、歌单/每日推荐、评论、电台——这些在我们的来源模型里没有对应物（我们是本地/WebDAV/夸克）。M5 只应借用它的**公开**接口形状（搜索/详情/歌词/图片缩放），**不要**引入它的 eapi 会话体系。

---

## 7. MyGo 版本差异：v0.6.4 → `be16483`

这是本次调研**最有行动价值**的一节：它用上了框架的新能力，而我们钉的版本还没有。

### 7.1 `mygo.NowPlaying` 进了框架（PR #654 已合并）

- 我方基线 v0.6.4：`NowPlaying`/`MediaCommand`/`PlaybackState` **零命中**（`~/go/pkg/mod/github.com/egoist/mygo@v0.6.4` 全库 grep）。
- `be16483`：公开文件 `nowplaying.go`（341 行，root 包）。

| API | 签名/说明 | 行 |
|---|---|---|
| `mygo.NowPlaying` | `*NowPlayingModule` 单例 | `nowplaying.go:41` |
| `Set(NowPlayingInfo)` | 值传参 | `:106` |
| `SetPlayback(PlaybackState, time.Duration)` | 状态 + 位置 | `:117` |
| `Clear()` | 清空 | `:129` |
| `OnCommand(func(MediaCommand, time.Duration))` | **返回 `off func()`** | `:157` |
| `Control(MediaPlayer)` | 让系统直接驱动播放器 | `:177` |
| `Sync()` / `Info()` | 主动同步 / 读回 | `:217` / `:141` |
| `NowPlayingInfo` | `Title, Artist, Album string`、`Artwork []byte`、`Duration`、`Position`、`Rate float64`、`State`、`Commands` | `:73-90` |
| `MediaCommand` | `MediaPlay/Pause/Stop/Next/Previous/Seek`（无公开 Toggle，按 State 折算） | `:45-58` |
| `PlaybackState` | `PlaybackPlaying(=0)/Paused/Stopped` | `:62-69` |
| `MediaPlayer` 接口 | `Play/Pause/Stop/Playing/Seek/Position/Duration` 七个方法，**任何类型都能实现** | `:93-101` |

- 后端：macOS = `internal/darwin/nowplaying.go:91`（MPNowPlayingInfoCenter + MPRemoteCommandCenter）、Windows = SMTC、Linux = MPRIS。
- 来源核对：`gh api repos/egoist/mygo/pulls/654` → `merged: true`、`merged_at 2026-10-25T10:19:30Z`、merge commit `138c63bf`、21 files +1925/−9。**这条推翻了「PR #654 仍 open」的旧结论。**
- 未使用它时零成本：`linkNowPlaying()` 只在 `apply()` 里调（`:298`），回调未注册直接返回（`:307-309`）。

### 7.2 `audio` 包：新增 `OnEnd` 与 `SetLatency`，`Position` 语义变了

| API | v0.6.4 | be16483 |
|---|---|---|
| `audio.NewPlayer(d Decoder)` | 有（`audio/audio.go:225`） | 有，**签名不变**（`:226`） |
| `Decoder`（`SampleRate/Channels/Read/SetPosition/Len`） | 有（`:44-57`） | 有，**不变** |
| `Player.OnEnd(func()) (off func())` | **无** | 有（`:331`） |
| `SetLatency(Latency)` / `LatencyPlayback` | **无** | 有（`:535` / `:522`） |
| `Player.Position()` 语义 | 混音到的位置 | **听到的**位置（扣掉缓冲，`:364-368`） |

参考项目的用法与版本对应：`SetLatency(LatencyPlayback)`（`internal/player/player.go:80`）与 `out.OnEnd(...)`（`:645`）**必须**新版；`NewPlayer/Seek/Position/Duration/Play/Pause/SetVolume/Close` 两版都有。

**对我们的意义**：我们**完全不 import `mygo/audio`**（音频走 `client/internal/mpv`），所以这一节的变化对我们零影响——但这也说明**它的播放器实现（那 2400 行 `internal/player`）对我们不可复用**：它建立在"App 自己解码、自己混音"的前提上。

### 7.3 `ui` 包与其它：零破坏，三个新东西

- `ui.Tester` 与 `NewTester` 的 **55 个方法两版完全一致** → 帧预算测试（§3.12）**不需要升版**。
- 菜单 API、`mygo.RunOnMain`、`ui/shader`（`Shader/Compile/MustCompile`、内建 `rectSize()`）、`ui.Bitmap/NewBitmap/DecodeBitmap`、`ui.Canvas/Painter/Box/Absolute/Color`：**签名零变化**。
- 新增（无破坏）：`Bitmap.ReleasePixels()`（`ui/bitmap.go:137`）、`Element.Cache/DrawObjects/Hidden`、`Painter.AnimationFrameRate`。
- **一个语义变化要知情**：`DecodeBitmap` 从此**持有入参字节而不拷贝**（`ui/bitmap.go:61-70`），以便释放像素后重解码。我们唯一的调用点是 `client/internal/ui/model/covers.go:63`，入参来自一次性 `os.ReadFile` 且之后不复用 → 正确性无风险；代价是每张封面缓存多留一份原始字节（LRU 上限 96，`covers.go:67-73`，内存大致翻倍）。**若升版，要么接受，要么在缓存里改成"只留字节、用完即时释放像素"的策略（也就顺带拿到了 `ReleasePixels` 的收益）。**

### 7.4 规模与"升级会破坏什么"

- `gh api repos/egoist/mygo/compare/v0.6.4...<be16483 全 SHA>`：`ahead_by: 42`、`total_commits: 42`、**230 个文件、+13648/−1039**（ui 57 文件、internal 79、audio 10、root 18、cmd 26）。**没有重命名/移除的 breaking 线索。**
- 我们依赖的面：`mygo`（4 个文件）、`mygo/ui`（24 个文件）、`mygo/plugins/sqlite`（5 个文件）。逐标识符穷举：我们用到的 `ui.*` 69 个、`mygo.*` 24 个、`sqlite.*` 6 个，**全部在 `be16483` 存在**。
- **结论：按签名零处破坏。**（方法局限见 §9：我们没有做真实编译验证，只做了导出声明穷举 + 逐条读源码；纯语义变化靠人工标注。另：`plugins/sqlite` 两版 `diff -rq` 无差异，零风险。）
- **真实成本在供应链**：最新 tag 仍是 **v0.6.4**，`be16483` 没有 tag，只能钉伪版本 `v0.6.5-0.20261025230045-be164835449b`；框架自身新增直接依赖 `hajimehoshi/go-mp3 v0.3.4`、`jfreymuth/oggvorbis v1.0.5`（会进我们的模块图，虽然我们不用）；`go 1.27.3`、`purego v0.11.1`、`go-text 0.3.5`、`x/image 0.46.0` 等两边完全一致，**无工具链漂移**。

### 7.5 建议：升版，并把自研媒体会话退役（单独立 todo）

- **收益**：`client/internal/mediasession/` 非测试约 930 行（`mediasession_darwin.go` 542 + `bridge_darwin.go` 230 + `keepawake_darwin.go` 158），但**接线处只有一处**（`client/internal/app/session.go:110-130`），所以改造面比行数小得多。整包可以换成"三件套"调用（`Set` / `SetPlayback` / `OnCommand`）。`Control` 会接管 Play/Pause/Stop/Seek 并在 `OnEnd` 上挂 Sync（`nowplaying.go:194-196` 用类型断言 `interface{ OnEnd(func()) func() }`）——**我们用 libmpv，不要用 `Control`**，只用三件套最稳。
- **顺带能拿到的**：凤毛麟角的平台一致性（Windows/Linux 的 MPRIS/SMTC 将来若做）；`Artwork` 直接吃 `[]byte`（我们现在自己在 ObjC 侧建 NSImage）。
- **风险与做法**：① 先只改 `go.mod` 钉伪版本 + `go build ./...` + `go test ./...`（**先不删 mediasession**），确认编译与测试通过；② 再写一个并行适配层（`internal/mediasession/` 保留接口，实现换成 `mygo.NowPlaying`），用 M1 的验收（媒体键 F7/F8/F9、控制中心元数据、关窗续播）逐条对拍；③ 两条都对上后再删旧实现。**不要一步到位删 930 行。**
- **注意**：升版后 `mediasession` 的"封面尺寸上限"与"延迟换图"逻辑，`NowPlaying` 内部已有自己的处理（`Artwork []byte`，`Set` 时 `slices.Clone`），对拍时要专门看"快速连切 10 首"时控制中心是否错图。

---

## 8. 许可证边界（AGPL-3.0）

- 对方的许可证是 **AGPL-3.0**（`gh api repos/egoist/mygo-cloudmusic` 的 `license.spdx_id`）。把它的代码（哪怕函数级）搬进听屿，会把整个听屿传染成 AGPL——**按 Spec 的默认，不做**。
- 本文的合法边界：**做法、数据结构、流程、参数、测试思路**属于"思想与事实"，可以写；**具体表达**（源码行）不可以复制。所以本文：
  - **不整段引用其源码**；出现的只有 MyGo 框架的 API 名（MIT）、Apple 工具的通用命令行、以及被中文转述的流水线参数；
  - 引用的是**路径:行号 + 链接 + 中文转述**，读者要核对就点链接去看原仓库（这是"引用惯例"内的做法，且我们不是在复制）；
  - 数值常量（180 ms、24×24、18 桶、`s²·v`、30 ms、700 ms、48×48、3×box(5)、1/4 容量）当作**事实**引用。
- 落地时的纪律（写给将来实现的人）：**任何从它那里受到的启发，实现必须重写，并且不能"翻译式改写"**（变量名、注释、结构逐行对应仍可能构成衍生作品）。PR 里若引用它，写清"参考了 X 的**做法**，实现独立"。
- MyGo 框架本身是 **MIT**（方案 §1 已核），升版不受此限。

---

## 9. 未查到 / 未验证

| 项 | 状态 | 说明 |
|---|---|---|
| 升版后"真实编译通过" | **未验证** | 只做了导出声明穷举 + 逐条读源码（新版不在本地 module cache，`go get` 需联网）。落地第一步必须 `go build ./... && go test ./...` |
| libmpv 的 `replaygain=track` 在我们这套 audio-only 构建里的**实际行为** | **未验证** | 只验证了选项字符串存在（`Mpv` 二进制里 `replaygain-preamp/clip/fallback` 命中；`Avfilter` 仅 412 KB，`loudnorm`/`dynaudnorm` 未命中）。落地前用 M2 harness 实测一次 |
| mpv `volume` 属性 8–16 ms 一次的高频设置是否被合并/丢帧 | **未查到** | 淡入淡出的实现细节要在本机试听 + 测 `volume` 回读 |
| 它的刘海播放器在**无刘海屏**、**多显示器**、**全屏应用**下的真实表现 | **未查到** | 代码里有一套 `virtual`/`greet`/`pin` 兜底，但我们没实机跑过；若要做 P2，先跑它的 release 看行为 |
| 它是否在 CI 上真正跑过 release.yml | **未查到** | 仓库有 `v0.1.12` 等 tag 与 release，但 `gh run list` 未取证（只读调研，没有翻它的 Actions 历史） |
| 它的 `updates.publicKey` 私钥托管方式 | **未查到** | 只看到 CI 读 `MYGO_UPDATER_PRIVATE_KEY` |
| 我们的 M6 是否需要 entitlement | **未验证** | 目前 `CGO_ENABLED=0`、无 JIT/无网络服务端，理论上不需要；但 libmpv 从 `@rpath` dlopen 在 hardened runtime 下的行为要实测（可能需要 `com.apple.security.cs.disable-library-validation`）。**这是 M6 最可能的坑，提前记下** |

---

## 10. 可执行清单

按"改动大小 ÷ 收益"排序。P0 = 现在就该做；P1 = 下一个迭代；P2 = 排期另议。

| # | 优先级 | 动作 | 落点（我们的文件） | 验收 |
|---|---|---|---|---|
| 1 | **P0** | 拖动进度只在松手 seek 一次，且不 seek 到末尾 | `client/internal/ui/components/transport.go:106-118`、`client/internal/ui/pages/stage.go:155-167` | 拖动中 `seekCalls==0`；松手 `==1`；M2 远端 Range 证据只多一次请求 |
| 2 | **P0** | 队列与进度跨进程恢复（含校验与坏数据回退） | `client/internal/player/controller.go`（新增 `Session/Restore`）+ `client/internal/app/` | 重开后队列/当前曲/位置/循环态一致；坏 JSON、曲目被删、`Order` 非法三种不崩 |
| 3 | **P0** | 升 MyGo 到 `be16483`（伪版本），先只编译+测试 | `client/go.mod` | `go build ./... && go test ./...` 全绿；不改任何业务代码 |
| 4 | **P1** | 媒体会话换成 `mygo.NowPlaying` 三件套，旧实现作废 | `client/internal/mediasession/` + `client/internal/app/` 的订阅处 | M1 的媒体键/控制中心/关窗续播逐条对拍；连切 10 首不错图；然后删旧实现 |
| 5 | **P1** | 帧预算测试（空闲/舞台/封面淡入结束） | `client/internal/shell/perf_test.go` | 空闲 ≤2 帧/s、舞台 ≤12 帧/s、淡入结束不再请求帧 |
| 6 | **P1** | 封面淡入（Jump/AnimateTo 双态）+ 占位符反向淡出 | `client/internal/ui/components/cover.go:17-40` | 先无图后有图：进度单调到 1；一开始有图：第一帧即 1 |
| 7 | **P1** | 随机播放：`order []int` 播放序（先写测试，再动 controller） | `client/internal/player/controller.go` | `queue_test.go` 与 200 首验收重跑；队列页仍显示原序 |
| 8 | **P1** | M5 起步：取色纯函数 + 模糊封面 + 灰兜底 | 新增 `client/internal/images/`；`client/internal/ui/pages/stage.go:38-45` | 与 Flutter 版对拍 20 张封面（主/次色差 ≤ 阈值）；灰封面得到中性色 |
| 9 | **P2** | 远端流磁盘缓存（本地 Range 源 + tee + LRU） | 新增 `client/internal/cache/`；与 `client/internal/rangesrv/` 同构 | 断网/慢速/seek 未下载区/容量满/磁盘只读五种场景；重播零远端请求 |
| 10 | **P2** | 音量均衡（mpv `replaygain-*`） | `client/internal/mpv/player.go:191-210` + 设置页 | ±6 dB 测试音前后电平差；无标签文件行为不变 |
| 11 | **P2** | 淡入淡出（音量双层 + 8–16 ms ramp） | `client/internal/mpv/player.go` | 暂停/继续/切歌无可闻爆音（人工听 + 波形对比） |
| 12 | **P2** | 逐字歌词（`SpreadWords` 等价 + 位置纯函数动画） | `client/internal/ui/model/lrc.go`、`components/lyrics.go:22` | 同位置重复渲染一致；seek 后无残留 |
| 13 | **P2** | 刘海迷你播放器（单独立 todo） | 新增 `client/internal/ui/notch/` | 有/无刘海屏、多显示器、全屏应用；静止时零轮询 |
| 14 | **M6** | 发布流水线：tag 触发 → 版本一致性校验 → draft release → keychain → 构建 | `.github/workflows/client.yml`（新） | tag 与 `mygo.json` 不一致时立即失败；draft 生成 |
| 15 | **M6** | 嵌套 framework 的真签名 + 公证 + staple | `client/scripts/bundle.sh`（新增 `--release`）+ `client/mygo.json` | `spctl -a -vv` 显示 Notarized Developer ID；空机器无隔离警告；`stapler validate` |
| 16 | **M6** | CI：macOS-only（gofmt/vet/test/bundle，tag 上公证） | `.github/workflows/client.yml` | 只跑 macOS；`client/**` 触发；`FRAMEWORK_SRC` 显式给 |
| 17 | **M6** | 测试纪律成文（照它的 `AGENTS.md` 的"只测会坏的行为"） | `client/README.md` 或 `client/AGENTS.md` | 新 UI 测试本机 `-count=5` 无抖动；不依赖墙钟 |
| 18 | **P2** | 封面拖拽/甩动换歌（不做倾斜与光泽，reduce-motion 退化为淡入） | `client/internal/ui/components/cover.go`、`client/internal/ui/pages/stage.go:97` | 左甩下一首、右甩上一首、短甩弹回；减少动态效果下只淡入 |

**建议的 todo 拆分**（避免一个 todo 装太多）：

- **A（P0，半天）**：#1 + #6（都是视图层小改，可一起验收）
- **B（P0，1–2 天）**：#2 队列恢复
- **C（P0/P1，1 天）**：#3 升版（只编译与测试，不动业务）
- **D（P1，2–3 天）**：#4 媒体会话退役（依赖 C）
- **E（P1，1 天）**：#5 + #17 测试底座（M6 的一部分提前做）
- **F（P1，2–3 天）**：#7 随机播放（依赖 `queue_test.go` 加固）
- **G（M5，独立）**：#8 取色与封面（M5 的 1/3）
- **H（P2，独立）**：#9 远端缓存（最大的一次架构改动，单独验收）
- **I（M6，独立）**：#14/#15/#16 发布流水线

**依赖关系**：C（升版）→ D（媒体会话退役）；E（测试底座）与 F（随机播放）独立；G（取色/封面）不依赖 M5 的其他部分，**可以先做**（取色只需本地封面，不需要抓取管线）；H（远端缓存）依赖 `rangesrv` 的既有契约。F 与 C 无冲突，但 F 会动 controller，建议排在 D 之前，避免与媒体会话改造交叉。

---

## 附录 A：我们读过它的哪些文件（证据地图）

链接都钉在 [`556379a`](https://github.com/egoist/mygo-cloudmusic/tree/556379a473d7a9a32e1b4138f190d3e62807ed95)。

| 文件 | 行数 | 用来回答什么 |
|---|---|---|
| [`go.mod`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/go.mod) | 23 | 依赖、无 mpv/无 cgo、MyGo 伪版本 |
| [`mygo.json`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/mygo.json) | 21 | M6 的签名/公证/更新配置形状 |
| [`RELEASING.md`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/RELEASING.md) | 38 | M6 的 runbook |
| [`.github/workflows/release.yml`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/.github/workflows/release.yml) | 81 | M6 的流水线（keychain/公证/上传） |
| [`AGENTS.md`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/AGENTS.md) | 28 | 测试哲学 |
| [`internal/player/player.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/player/player.go) | 729 | 播放器状态机、队列/顺序、seek、淡入淡出、均衡、Session、媒体会话接入 |
| [`internal/player/stream.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/player/stream.go) | 609 | 边下边播、阻塞读、seek 换算、自写 FFT |
| [`internal/player/cache.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/player/cache.go) | 214 | 磁盘 LRU、上限、`.part` 契约 |
| [`internal/player/fade.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/player/fade.go) | 108 | 淡入淡出（8 ms tick、代际） |
| [`internal/lyrics/lyrics.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/lyrics/lyrics.go) | 266 | LRC/YRC、逐字分摊、间隙检测 |
| [`internal/app/artwork.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/app/artwork.go) | 359 | 取色、模糊、图片缓存、动图封面 |
| [`internal/app/backdrop.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/app/backdrop.go) | 281 | 背景画布、雾 shader、交叉淡入 |
| [`internal/app/ui_kit.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/app/ui_kit.go) | 329 | 封面淡入、通用绘制 |
| [`internal/app/ui_player.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/app/ui_player.go) | 435 | 进度条（松手 seek）、音量、传输条 |
| [`internal/app/ui_stage.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/app/ui_stage.go) | 262 | 律动歌词（位置纯函数） |
| [`internal/app/ui_notch.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/app/ui_notch.go) | 542 | 刘海播放器窗口与指针 |
| [`internal/app/notch_darwin.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/app/notch_darwin.go) | 125 | 刘海尺寸、窗口层级、点透 |
| [`internal/app/perf_test.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/app/perf_test.go) | 90 | 帧预算测试 |
| [`internal/app/session.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/app/session.go) | 95 | 会话持久化时机 |
| [`internal/app/ui_settings.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/app/ui_settings.go) | 229 | 设置项（缓存/均衡/刘海/实验） |
| [`internal/netease/netease.go`](https://github.com/egoist/mygo-cloudmusic/blob/556379a473d7a9a32e1b4138f190d3e62807ed95/internal/netease/netease.go) | 434 | M5 的公开接口形状（搜索/详情/歌词/图片尺寸） |
| `internal/app/*_test.go` | 25 个、2 231 | 测试写法（交互按标签、帧预算、缓存淘汰） |

## 附录 B：本报告用到的我方位置

| 位置 | 用途 |
|---|---|
| `client/go.mod:7` | 我方 MyGo 版本（v0.6.4） |
| `client/internal/mpv/player.go:191-210` | mpv 选项表（M6/均衡/淡入淡出落点） |
| `client/internal/player/controller.go:220-312` | 队列/预取/世代契约（随机播放改造对象） |
| `client/internal/sources/recovery.go` | 直链过期重播（缓存收益的对照物） |
| `client/internal/mediasession/` | 自研媒体会话（升版后可退役） |
| `client/internal/ui/components/transport.go:106-118`、`client/internal/ui/pages/stage.go:155-167` | 拖动即 seek（P0 改造点） |
| `client/internal/ui/model/covers.go:43-80` | 封面缓存（M5 改造点） |
| `client/internal/ui/components/cover.go:17-40` | 封面绘制（淡入改造点） |
| `client/internal/ui/model/lrc.go:35-128` | 行级歌词解析（逐字改造点） |
| `client/internal/scan/meta.go:28-31` | 9 格式矩阵 |
| `client/internal/shell/perf_test.go:37` | 现有 p95 滚动测试（帧预算扩展点） |
| `client/scripts/bundle.sh`、`client/mygo.json` | M6 的落点 |
| `.github/workflows/flutter.yml` | 现有 CI（只覆盖 `app/**`） |
| `docs/plan/2026-10-25-macos-mygo-migration-plan.md:461-462` | M5/M6 的验收口径 |

---

## 附：一句话给 Planner

> 这份调研**不改变** M5/M6 的范围，只往里塞了具体做法：M5 的取色/模糊/淡入有了参数与算法，M6 的流水线与嵌套签名有了可照搬的结构与必须自建的部分。**唯一需要单独立项的是「升 MyGo 到 `v0.6.5-0.20261025230045-be164835449b` 并把媒体会话交给框架」**——它不在 M5/M6 里，但做完能删掉 930 行自研 ObjC 桥，且风险已量化（按签名零破坏，供应链需联网钉伪版本）。
