# 调研：真实 MyGo 项目怎么做音频播放与系统媒体会话

日期：2026-10-25
性质：**只读调研**。没有改任何应用代码、没有写原型、没有合并分支、没有打 tag。本文是本仓库唯一改动。
核查基准：

- MyGo 最新发布 [`v0.6.4`](https://github.com/egoist/mygo/releases/tag/v0.6.4)（2026-10-25T07:38:35Z，commit [`6255ea4`](https://github.com/egoist/mygo/tree/6255ea40139d06e0762a7c4a32626148ba410478)）；上一版 [`v0.6.3`](https://github.com/egoist/mygo/releases/tag/v0.6.3)（commit [`1524290`](https://github.com/egoist/mygo/tree/15242900157b77228d35ca071f43e94a11bc90a0)）。
- 输入文档 [`docs/research/2026-10-25-mygo-feasibility.md`](./2026-10-25-mygo-feasibility.md)（MyGo 能力边界的那份）。
- 听屿：本仓库 `app/`（Flutter，播放走 `media_kit`/`media_kit_libs_audio`，见 `app/pubspec.yaml:21-22`；macOS 侧由 pod `media_kit_libs_macos_audio 1.0.4` 携带播放框架，见 `app/macos/Podfile.lock:3`）。

> **前置更正（不影响结论，但影响线索）**：Spec 提到的方案文档 `docs/plan/2026-10-25-macos-mygo-migration-plan.md` 在本仓库任何分支上都不存在（`docs/plan/` 目录本身不存在，全仓库 grep 无命中）。因此本文按 Spec"方案推荐"段落工作：进程内 libmpv + purego 为推荐、libmpv 子进程 + JSON IPC 为退路、纯 Go 解码与 AudioToolbox shim 不作 v1、媒体会话自写 400–500 行 ObjC C-ABI shim dylib。

---

## 0. 结论速览

| 问题 | 答 | 证据强度 |
|---|---|---|
| 真实用 MyGo 的公开项目多吗？ | **不少**：GitHub 代码检索命中 **232 个**依赖 `github.com/egoist/mygo` 的 `go.mod`（去重后；抓到 206 份原文），其中至少 **12 个是音频/媒体类真实应用**，5 个实现了 macOS Now Playing | 高（可复跑，见 §10） |
| 别人音频怎么做的？ | 六种路径都有人在生产里用：`mygo/audio`、`mygo/audio`+自写 Decoder、纯 Go 解码+自写输出、**ffmpeg 子进程**、**mpv 子进程 + JSON IPC**、**libmpv 进程内（cgo）**；**没有**任何项目用纯 Go 解 AAC/ALAC | 高（逐个读代码，见 §3） |
| 系统媒体会话有人做成过吗？Mac 端呢？ | **有，而且三端都有人做成**：macOS Now Playing / 媒体键至少 5 个项目自写实现；MPRIS 6 个；Windows SMTC 4 个。**全部是纯 Go 直调 ObjC（`purego/objc` 或纯 Go 库 `go-macos/objc`），没有 cgo、没有 shim dylib** | 高（见 §4） |
| 上游 issue #654 进展？ | 它其实是一个 **PR**（不是纯 issue）：[#654](https://github.com/egoist/mygo/pull/654) **open、未合并**，+1925/−9、21 个文件，head 分支 `claude/project-thread-6ao7bz`，最后一次活动是 2026-10-23T00:48Z 的 CI 机器人评论。`main`（v0.6.4）**没有**任何 NowPlaying 代码 | 高（API + 源码检索，见 §4.3） |
| "纯 Go 调不了 ObjC"这个前提成立吗？ | **不成立**。`purego/objc` 提供 `objc.NewBlock`、`objc.RegisterClass`、`objc.Send[T]`；MyGo 自己就用 `objc_msgSend` 调 AppKit/Metal；5 个第三方应用据此调通 MediaPlayer.framework（4 个直接用 `purego/objc`，1 个用第三方纯 Go 库 `go-macos/objc`） | 高（源码，见 §5） |
| "MyGo 禁 cgo" 对应用成立吗？ | **框架自身无 cgo（`CGO_ENABLED=0`），应用可以用 cgo**：`XueJie1/godrome` 用 cgo 链 libmpv，CI 里 `CGO_ENABLED: '1'` 直接出包 | 中高（构建配置，见 §6.1） |
| 四条路线推荐 | **B（进程内 libmpv + purego）维持，但媒体会话从"shim dylib"改为"自写 purego/objc 包"；C（mpv 子进程 + IPC）作为退路，两者都有真实先例；A 不足以覆盖听屿 9 种格式；D 的前提已证伪，无先例，排除** | 见 §8 |

一句话：**媒体会话这块，"别人已经做成过"是硬事实——macOS 端的实现量约 170–400 行 Go，不需要 cgo、也不需要 shim dylib。音频内核这块没有现成的 MyGo 答案，但两种 mpv 路线都有人把产品跑起来了。**

---

## 1. 证据边界、方法与样本量

### 1.1 我怎么找的项目

| 检索 | 查询 | 结果 |
|---|---|---|
| 依赖清单 | GitHub 代码检索 `"github.com/egoist/mygo" filename:go.mod` | **234 原始命中 → 232 个唯一 (仓库, 路径)**；逐份下载成功 **206** 份 go.mod（26 份拉取失败：仓库私有/已删/空仓库） |
| 直接 import 音频包 | `"mygo/audio" language:go NOT is:fork` | **56 个文件**，去重后 **13 个仓库**（含上游自己、含 1 个 MyGo 分叉 `oneo-me/onevra`） |
| 媒体会话交叉比对 | 分别检索 `MPNowPlayingInfoCenter`、`MPRemoteCommandCenter`、`org.mpris.MediaPlayer2`、`SystemMediaTransportControls`（`language:go`），与 232 个依赖仓库求交 | **macOS Now Playing 5 个、MPRIS 6 个、SMTC 4 个** |
| libmpv 交叉比对 | `libmpv language:go` 与依赖仓库求交 | **1 个**（godrome） |
| dylib/FFI 先例 | `libmpv purego`、`mpv_render_context_create language:go`、`libavcodec purego`、`"libmpv" Dlsym` | 库级先例若干（§6.4） |
| 上游状态 | PR/issue #654 元数据与评论、`v0.6.4` 源码全量检索 `nowplaying\|MPRemoteCommandCenter\|MPRIS\|SystemMediaTransportControls` | 零命中 |

### 1.2 我实际读了多少代码

不是只靠检索命中数下判断：**逐仓库 `git clone --depth 1` 并逐文件阅读了 13 个应用**（mixmusic、quaver-astra、meiro、yt-music-player、Aurelia、godrome、AudioSmith、lark、MyVNC、baidunetgo、motrix-mygo、Voicemore、WinExplorer 中与音频/媒体会话相关的那部分），以及上游 `v0.6.3` 全源码（`audio/`、`internal/darwin/`、`internal/gpu/`）和 `gen2brain/go-mpv`。

每条结论都给出 **commit 固定的文件链接**。所有仓库元数据（star、最近提交）取自 2026-10-25 当日的 GitHub API。

### 1.3 样本量为什么够（也说明哪里不够）

- **"有没有人在 MyGo 里做成媒体会话"这个问题，样本量充足**：5 个独立项目、三种 callback 写法、三端齐全，且都不是玩具（mixmusic 111★ 在发版、meiro 35★、AudioSmith 51★、quaver 在打包 Linux/Windows/macOS 发行包）。这条不需要"样本太少"的免责。
- **"哪种音频内核更适合听屿"这个问题，样本只能算中等**：真正带完整格式矩阵（FLAC/AAC/ALAC/Opus…）+ 网络流 + gapless 的只有 mpv 系（quaver、godrome）与 ffmpeg 系（meiro、AudioSmith）几个；而且**没有一个是和听屿同量级的产品**（都更小、更年轻，最多 star 111）。所以 §8 给的是"用别人踩过的坑收窄选项"，不是"照抄某项目"。
- **未验证项**逐条列在 §9，包括我唯一没法用代码证实的一条（"打包成 `.app` 才有 Now Playing"，来自 quaver 的代码注释）。

---

## 2. 谁在用 MyGo（区分官方示例 / 作者自用 / 第三方真实应用）

### 2.1 官方示例（**不是**生产应用，仅作 API 用法参考）

MyGo 仓库 `examples/` 有 32 个目录，用到音频的是 3 个，全部只依赖 `mygo/audio`：

| 示例 | 音频用法 | 链接 |
|---|---|---|
| `piano` | 合成器：自写 `Decoder` + `audio.NewPlayer` | [examples/piano/synth.go@v0.6.3](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/examples/piano/synth.go) |
| `farm` | 音效 `DecodeSound` | [examples/farm/sound.go@v0.6.3](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/examples/farm/sound.go) |
| `mayoi` | 背景音 | [examples/mayoi/sound.go@v0.6.3](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/examples/mayoi/sound.go) |

### 2.2 作者自己的项目（dogfood，也不当作第三方证据）

`egoist/kero`、`egoist/gorex`、`egoist/godiff`、`egoist/lorca` 的 go.mod 都依赖 mygo；它们不是"别人在用"，本文只用于说明生态存在，不当证据。

### 2.3 第三方真实应用（本文的主证据）

按"与音频/媒体会话相关"筛选，逐个读过代码的：

| 项目 | 是什么 | mygo | 最近提交（2026-10-25 查） | 音频路线 | 媒体会话 |
|---|---|---|---|---|---|
| [fzn0x/mixmusic](https://github.com/fzn0x/mixmusic) ⭐111 MIT | Spotify + YouTube Music 双源桌面播放器（mac/win/linux） | v0.6.2 | `45b01da` 2026-10-24 | **自研引擎**（Opus）+ 自写 AudioQueue 输出（purego） | **三端自写** |
| [Team-Quaver/quaver-astra](https://github.com/Team-Quaver/quaver-astra) ⭐1 AGPL | Quaver Music 第三方客户端（含国内音源） | v0.6.3 | `98c1fb7` 2026-10-24 | **mpv 子进程 + JSON IPC**，发行包随包 mpv | **三端自写** |
| [elianiva/meiro](https://github.com/elianiva/meiro) ⭐35 GPL | YouTube Music 客户端（mac/win/linux） | v0.6.3 | `95e7858` 2026-10-24 | **ffmpeg 子进程解码** + `oto/v3` 输出 | **三端自写** |
| [xlanstar/yt-music-player](https://github.com/xlanstar/yt-music-player) MIT | YT Music 客户端（桌面 UI + TUI 双入口） | v0.6.3 | `2d35858` 2026-10-24 | **`mygo/audio` 输出 + 自写 WebM/Opus Decoder** | macOS + Linux |
| [j4ckxyz/Aurelia](https://github.com/j4ckxyz/Aurelia) ⭐2 MIT | Jellyfin 音乐播放器（三桌面） | v0.3.5 | `dcc74a4` 2026-10-09 | **内置 oto 分叉**（AudioQueue 驱动）+ 纯 Go mp3/flac | **三端自写** |
| [XueJie1/godrome](https://github.com/XueJie1/godrome) MIT | Navidrome/Subsonic 客户端 | v0.2.15 | `6f9926d` 2026-10-18 | **libmpv 进程内（cgo）** | MPRIS |
| [hehehai/AudioSmith](https://github.com/hehehai/AudioSmith) ⭐51 AGPL | 配音/转写/有声书工作站（macOS） | v0.5.5 + 自带 mygo 分叉（`third_party/mygo`） | `48e8d89` 2026-10-25 | **`mygo/audio` + 自写 Decoder**，ffmpeg 子进程做编码，AVFoundation（purego）取麦克风 | 未查到 |
| [ca-x/lark](https://github.com/ca-x/lark) ⭐15 AGPL | Web 音乐播放器的桌面客户端（gRPC 后端） | v0.6.2 | `9a3c068` 2026-10-23 | **`mygo/audio` + 自写 gRPC `io.ReadSeeker`** | 未查到 |
| [si-mods/MyVNC](https://github.com/si-mods/MyVNC) ⭐5 GPL | 纯 Go VNC 客户端（转发 QEMU 音频） | v0.5.5 | `03d3c0f` 2026-10-25 | **`mygo/audio`**（自己解 PCM 喂 `Decoder`） | 未查到 |
| [pengstem/baidunetgo](https://github.com/pengstem/baidunetgo) | 百度网盘客户端（试听） | v0.6.3 | `f97f3ad` 2026-10-24 | **`mygo/audio`** | 未查到 |
| [wherexml/Voicemore](https://github.com/wherexml/Voicemore) | macOS 听写 | v0.4.8 | `b4067da` 2026-10-24 | **`mygo/audio`**（播放录音） | 未查到 |
| [mcxen/WinExplorer](https://github.com/mcxen/WinExplorer) | Windows 文件管理器 | v0.5.5 | `7bf6d6b` 2026-10-25 | **`mygo/audio`**（媒体预览） | 未查到 |
| [missuo/motrix-mygo](https://github.com/missuo/motrix-mygo) ⭐55 | Motrix（aria2）原生 Go 界面 | v0.5.1 | `01b43e5` 2026-10-15 | 无音频 | — |

补充（只从依赖面确认，未读代码）：[nexmoe/DayBee](https://github.com/nexmoe/DayBee) ⭐423（长时录音 + 转写，用 `gen2brain/malgo`）、`codingEzio/T-Moonbounce`（`oto/v3` + `go-mp3`）、`AstraFoundry/Arion`、`narusenia/transflowy`（`malgo`）。

### 2.4 生态画像（206 份 go.mod 的样本统计）

依赖的 MyGo 版本分布（`v0.0.0` 与伪版本为本地 replace/未发版）：

| 版本 | 仓库数 |
|---|---:|
| v0.5.5 | 60 |
| v0.6.3 | 38 |
| v0.6.2 | 17 |
| v0.6.0 | 14 |
| v0.4.8 | 14 |
| v0.5.1 | 9 |
| 其余 v0.2.x–v0.6.4 / 伪版本 | 54 |

读法：**生态正跟着 0.x 高频换代**（v0.5.5 + v0.6.x 合计 129/206，跨度只有两周多），且 **`ebitengine/purego` 出现在全部 206 份 go.mod 中（其中 57 份是直接依赖）**——它就是 MyGo 平台层（`internal/darwin`、`internal/gpu`、`audio`、官方 sqlite 插件）的 FFI 底座，也因此是应用侧唯一"框架默许、无需额外授权"的系统框架调用途径。

音频相关库分布（同一 206 份样本，"出现"含间接依赖，两列都列出以免夸大）：

| 依赖 | 出现 | 直接依赖 | 含义 |
|---|---:|---:|---|
| `ebitengine/oto` | 3 | 2 | 自带跨平台输出（Aurelia、meiro） |
| `hajimehoshi/go-mp3` | 5 | 3 | 纯 Go MP3 解码 |
| `mewkiz/flac` | 3 | 3 | 纯 Go FLAC 解码 |
| `jfreymuth/pulse` | 4 | 1 | 纯 Go PulseAudio（Linux 输出） |
| `gen2brain/malgo` | 3 | 3 | miniaudio 绑定（**cgo**） |
| `pion/opus` | 1 | 1 | 纯 Go Opus 解码（yt-music-player） |
| `godbus/dbus` | 21 | 7 | MPRIS/通知/托盘，不等于音乐应用 |

> 注意：`godbus` 里多数是系统集成（通知、托盘、D-Bus 单实例），**不能**读成音乐播放器；真正的音乐/音频播放器是 §2.3 那 13 个里的 12 个（motrix-mygo 无音频）。

---

## 3. 音频实现方式（六种，全有真实代码）

### 3.1 路线对照表

| 方式 | 代表项目 | 关键文件 | 优 | 劣（项目自己写的理由/我从代码看到的） |
|---|---|---|---|---|
| ① 只用 `mygo/audio` | lark、MyVNC、baidunetgo、Voicemore、WinExplorer | [lark `desktop/native_audio.go:13-16`](https://github.com/ca-x/lark/blob/9a3c06814d56e3bf2b8b11d547b3d7c895d9a7f6/desktop/native_audio.go#L13-L16) | 零成本 | 只 WAV/MP3/Vorbis、48 kHz 重采样、无 gapless、无 `OnEnd` |
| ② `mygo/audio` 输出 + 自写 `Decoder` | yt-music-player、AudioSmith、MyVNC、lark | [yt-music-player `internal/audio/engine.go:11,43-47`](https://github.com/xlanstar/yt-music-player/blob/2d35858c96388681e777a0f2671cbc34ec32d38a/internal/audio/engine.go#L11-L47) | 复用混音器/输出/音量；格式自己控 | 仍受 48 kHz/立体声与无 `OnEnd` 限制（yt-player 自己轮询结束） |
| ③ 纯 Go 解码 + 自带输出（oto/AudioQueue） | mixmusic（Opus）、Aurelia（mp3/flac） | [mixmusic `internal/audio/audio.go:1-5`](https://github.com/fzn0x/mixmusic/blob/45b01dace502cecbd690d60bb81d683da9cd5aa7/internal/audio/audio.go#L1-L5)、[`internal/audio/output/output_darwin.go:1-10`](https://github.com/fzn0x/mixmusic/blob/45b01dace502cecbd690d60bb81d683da9cd5aa7/internal/audio/output/output_darwin.go#L1-L10) | 无 cgo、无外部依赖、延迟与 gapless 可控（双 deck 交叉淡入） | 解码器要自己写/移植：mixmusic 直接移植了 libopus（`internal/opus/`，C 源码逐函数翻译，带 libopus 许可证） |
| ④ **ffmpeg 子进程解码** | meiro、AudioSmith | [meiro `player/player.go:603`](https://github.com/elianiva/meiro/blob/95e7858fd91a08539927e29e6d7c366c0923f465/player/player.go#L603)、[AudioSmith `internal/ffmpeg/ffmpeg.go:1-6`](https://github.com/hehehai/AudioSmith/blob/48e8d89b6d129e907f4380b93aba214b6c6dc308/internal/ffmpeg/ffmpeg.go#L1-L6) | 全格式、seek 便宜、无 cgo | 要用户装/随包 ffmpeg；管道式 seek 要重启解码；AudioSmith 明说 ffmpeg 只补 "AVFoundation 缺的 MP3/Opus/FLAC" |
| ⑤ **mpv 子进程 + JSON IPC** | quaver-astra | [`internal/audio/mpv.go:1-14`](https://github.com/Team-Quaver/quaver-astra/blob/98c1fb7d114a046811f5b57f99d0f01a0adb95b3/internal/audio/mpv.go#L1-L14) | 全格式 + gapless + 缓冲 + seek 一次拿走；后端与 UI 解耦；**不破坏交叉编译** | 多一个进程；要随包 mpv/让用户装；IPC 时序（项目用了 loadGen 代次机制防串档） |
| ⑥ **libmpv 进程内（cgo）** | godrome | [`internal/player/native.go:1-10`](https://github.com/XueJie1/godrome/blob/6f9926d9330205976601c3a5dabc0eb6a071384c/internal/player/native.go#L1-L10) | 全格式、进程内、事件/属性监听完整 | cgo：`CGO_ENABLED=1`、不能交叉编译、要装 libmpv（见 §6.1） |

### 3.2 两个值得直接抄的做法

1. **"自写 `io.ReadSeeker` 顶替 HTTP 流"是社区的标准动作，不是难点。**
   - yt-music-player 自写带预读/分块的 HTTP Range 源（[`internal/audio/source.go:17-30`](https://github.com/xlanstar/yt-music-player/blob/2d35858c96388681e777a0f2671cbc34ec32d38a/internal/audio/source.go#L17-L30)），并有 stall/续播处理（`engine.go:14-27` 的 stall 余量、宽限与恢复阈值）。
   - lark 更极端：把 **gRPC 流**包成 `io.ReadSeeker`（`desktop/native_audio.go:50-147`，`openAt/Read/Seek/Close` 四个方法），直接喂给 `mygo/audio.OpenStream`。
   - 结论：听屿的 WebDAV/夸克直链，只要实现 `Read/Seek` 就能接 MyGo 音频包——**这条路已被验证两次**。
2. **gapless/交叉淡入不是等上游，而是自己开两个 deck。** mixmusic 引擎是"两 deck + 每 deck 一个解码器 + 淡入淡出 + 只有 5 ms 的 pause 淡变"，明确对标它原来的 Web Audio 播放器（[`internal/audio/engine.go:33-58`](https://github.com/fzn0x/mixmusic/blob/45b01dace502cecbd690d60bb81d683da9cd5aa7/internal/audio/engine.go#L33-L58)）。

### 3.3 WebView 前端 `<audio>`

**未查到**有 MyGo 应用把播放交给前端的 `<audio>`：样本里查到的 `<audio>` 只出现在 AudioSmith 的测试替身（`internal/dub/dubtest/`、`internal/engine/enginetest/`）。理论上 MyGo 的 WebView 模式（官方示例与 PR #654 里都提到"Browsers: the page's Media Session"）可以让页面自己播放并拥有 Media Session，但**没有应用样本**，本文不作推荐。

---

## 4. 系统媒体会话（关键结论）

### 4.1 有人做成过，而且是三端都做成过

| 项目 | macOS（MediaPlayer） | Linux（MPRIS） | Windows（SMTC） | macOS 实现行数 |
|---|---|---|---|---|
| mixmusic | ✅ purego + `purego/objc` | ✅ `org.mpris.MediaPlayer2` | ✅ | **379 行**（[`nowplaying_darwin.go`](https://github.com/fzn0x/mixmusic/blob/45b01dace502cecbd690d60bb81d683da9cd5aa7/internal/nowplaying/nowplaying_darwin.go)） |
| quaver-astra | ✅ 自写 objc 桥 | ✅ 404 行 | ✅ 751 行 | **394 + 217 行**（[`nowplaying_darwin.go`](https://github.com/Team-Quaver/quaver-astra/blob/98c1fb7d114a046811f5b57f99d0f01a0adb95b3/internal/smedia/nowplaying_darwin.go)、[`objc_darwin.go`](https://github.com/Team-Quaver/quaver-astra/blob/98c1fb7d114a046811f5b57f99d0f01a0adb95b3/internal/smedia/objc_darwin.go)） |
| meiro | ✅ 用 `github.com/go-macos/objc` | ✅ | ✅ | **273 行**（[`systemmedia/session_darwin.go`](https://github.com/elianiva/meiro/blob/95e7858fd91a08539927e29e6d7c366c0923f465/systemmedia/session_darwin.go)） |
| yt-music-player | ✅ purego + `purego/objc` | ✅ | ❌（`controls_other.go` 明确写了"Windows 的即 SMTC，尚未实现"） | **172 + 136 行**（[`nowplaying_darwin.go`](https://github.com/xlanstar/yt-music-player/blob/2d35858c96388681e777a0f2671cbc34ec32d38a/internal/audio/nowplaying_darwin.go)） |
| Aurelia | ✅ purego + `purego/objc` | ✅ | ✅ | **212 行**（[`nowplaying_darwin.go`](https://github.com/j4ckxyz/Aurelia/blob/dcc74a4b71d029c76afc27f99ac925acc8aa50e7/nowplaying_darwin.go)） |
| godrome | 未查到 | ✅ | 未查到 | — |

**结论：媒体会话在 MyGo 里"被做成过"，macOS / Windows / Linux 三端都有人做成，且全都不是上游提供的。** 这直接回答 Spec 的问题"媒体会话在 MyGo 里有没有人做成过，做成的是哪一端"：有，三端都有；macOS 端至少 5 个独立实现。

实现量级（重要，用于修正 400–500 行的估算）：**macOS 端 172–394 行，加上共用的 objc 小桥 0–217 行**；若用第三方 `go-macos/objc` 则连桥都不用写（meiro 273 行全包）。**没有一个是 shim dylib**，全是进程内 purego 调 `objc_msgSend`。

### 4.2 三种回调/线程写法，都有生产验证

1. **Block 回调（`objc.NewBlock` + `addTargetWithHandler:`）** —— mixmusic：
   - 命令注册 [`nowplaying_darwin.go:209-233`](https://github.com/fzn0x/mixmusic/blob/45b01dace502cecbd690d60bb81d683da9cd5aa7/internal/nowplaying/nowplaying_darwin.go#L209-L233)；
   - 主线程投递靠框架自带的 `mygo.RunOnMain`（[`internal/app/controls.go:67`](https://github.com/fzn0x/mixmusic/blob/45b01dace502cecbd690d60bb81d683da9cd5aa7/internal/app/controls.go#L67)），每个 ObjC 调用都包在 `withPool`（`LockOSThread` + `objc_autoreleasePoolPush/Pop`）里，见 `:141-148`；
   - 封面走 `MPMediaItemArtwork initWithBoundsSize:requestHandler:`，handler 是 Block，由系统在**自己的线程**回调，所以实现里用 `m.mu` 保护并在块内 retain/autorelease（`:331-343`）。
2. **运行时注册 ObjC 类 + selector（`objc.RegisterClass` + `addTarget:action:`）** —— yt-music-player：
   - 注册一个 `NSObject` 子类 `YTMCommandObserver`，每个命令一个方法（[`nowplaying_darwin.go:68-92`](https://github.com/xlanstar/yt-music-player/blob/2d35858c96388681e777a0f2671cbc34ec32d38a/internal/audio/nowplaying_darwin.go#L68-L92)），命令经 `sync.Map` 路由回引擎（`:121` 一带）。
3. **用第三方纯 Go ObjC 库** —— meiro：`github.com/go-macos/objc v0.11.2`（`go.mod:11`；该库自述 "Pure-Go CGO=0 … (purego)"，`go.mod` 只依赖 `purego v0.11.2`），代码里只写 `objc.ID`/`objc.Block`，不关心 `msgSend` 变体。

线程共识（三个项目一致）：**MediaPlayer 的调用与命令回调都在主线程**，所以要么把整个调用序列投递到 `mygo.RunOnMain`，要么自己 `dispatch_async(dispatch_get_main_queue())`（quaver 的 [`objc_darwin.go:63-80`](https://github.com/Team-Quaver/quaver-astra/blob/98c1fb7d114a046811f5b57f99d0f01a0adb95b3/internal/smedia/objc_darwin.go#L63-L80)，且在解析失败时退化为同步回写）。

### 4.3 上游 #654 的真实状态

- 它是 **PR**（`pull_request != null`），不是纯 issue：[egoist/mygo#654](https://github.com/egoist/mygo/pull/654)。
- 状态：**open / merged=false**，`+1925 −9`，21 个文件，head 分支 `claude/project-thread-6ao7bz`，`created_at 2026-10-23T00:30Z`，`updated_at 2026-10-23T00:48Z`。
- 唯一的后续评论是 Cloudflare 预览机器人的部署记录（`cloudflare-workers-and-pages[bot]`），**没有人审、没有后续 push**。
- 设计内容（PR 正文）与本文实测一致：macOS 用 `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` + `MPMediaItemArtwork`；Windows `SystemMediaTransportControls` + `ISystemMediaTransportControlsInterop::GetForWindow`；Linux GDBus 导出 MPRIS；并计划给 `audio.Player` 加 `OnEnd`、给 `NowPlaying.Control(p)` 接 `MediaPlayer`。
- **`main`（v0.6.4）里没有任何 NowPlaying 代码**：全量检索 `nowplaying|MPRemoteCommandCenter|MPRIS|SystemMediaTransportControls` 零命中（v0.6.3 与 6255ea4 各查一次）。
- 有没有 fork 拿它改？**未查到**：我读的 5 个实现里没有一处引用 #654 或其 API 形状（各自独立写的），也没有在 issue/PR 里挂 fork 链接。

**读法**：上游方案已经写好、且在"待合并"状态停了两天；但**它没有挡住任何人**——社区在它出现之前/之外就已经各自做完了。听屿若迁 MyGo，媒体会话不必等 #654（可以到时候直接用它，或抄社区实现）。

---

## 5. 调系统框架的先例（purego / ObjC / cgo）

### 5.1 先例一览

| 先例 | 调什么 | 组织方式 | 位置 |
|---|---|---|---|
| **MyGo 自身**（第一方，最有说服力） | AppKit、Metal、AudioToolbox、GameController、Carbon 热键、WebKit | `internal/darwin/objc.go` 定义 `objc_msgSend`/`_stret`/`_super` 的类型化变体；`internal/darwin/*.go` 每模块一个文件；`plugins/game/gamepad/gamepad_darwin.go` 演示 `Dlopen(libobjc)` + autorelease pool | [`internal/darwin/objc.go@v0.6.3`](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/internal/darwin/objc.go)、[`plugins/game/gamepad/gamepad_darwin.go:33-50`](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/plugins/game/gamepad/gamepad_darwin.go#L33-L50) |
| **MyGo 自身**（音频） | **AudioToolbox（AudioQueue）** | `purego.Dlopen` 框架 + `RegisterLibFunc` 六个入口 + `purego.NewCallback` 回调；队列自己线程回 buffer | [`audio/output_darwin.go:62-86`](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/audio/output_darwin.go#L62-L86) |
| mixmusic | MediaPlayer + Foundation + AppKit | 单文件、类型化 `msgSend` 变量、`sync.Once` 载入、`RunOnMain` 投递 | `internal/nowplaying/nowplaying_darwin.go` |
| quaver-astra | MediaPlayer + libobjc + libdispatch | 独立 `objc_darwin.go` 小桥 + `nowplaying_darwin.go` 业务；`dispatch_async` 主队列 | `internal/smedia/objc_darwin.go` |
| yt-music-player | MediaPlayer | 独立 `objc_darwin.go`（136 行）+ `RegisterClass` 观察者 | `internal/audio/objc_darwin.go` |
| Aurelia | MediaPlayer | 单文件 212 行，`atomic.Uintptr` 存封面句柄 | `nowplaying_darwin.go` |
| AudioSmith | **AVFoundation**、AppKit、Carbon、CoreGraphics、HIServices | `internal/dictation/system_darwin.go`；注释明写 "through purego (as MyGo's internal/darwin does): no cgo"；`AVCaptureDevice` 权限查询/请求（`:340`、`:380`），Carbon 热键 `purego.NewCallback`（`:405`） | [`internal/dictation/system_darwin.go`](https://github.com/hehehai/AudioSmith/blob/48e8d89b6d129e907f4380b93aba214b6c6dc308/internal/dictation/system_darwin.go) |
| godrome | **libmpv（C 库，不是 ObjC）** | 唯一的 cgo 先例，见 §6.1 | `internal/player/native.go` |

### 5.2 社区总结出的坑（都能在代码里指到）

1. **主线程**：MediaPlayer 的 info 与 command 都在主线程产生/消费。两条可行解：`mygo.RunOnMain`（框架自带，同步、可在任意 goroutine 调，[`loop.go:82-86`](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/loop.go#L82-L86)）或自己 `dispatch_async`。
2. **autorelease pool**：每次进入 ObjC 都要 `LockOSThread` + `objc_autoreleasePoolPush/Pop`，否则临时 NSString/NSNumber 会攒到线程退出（mixmusic `withPool`、MyGo gamepad 同款）。
3. **Block 的所有权**：`addTargetWithHandler:` 会 copy block，自己那份要 `Release()`；`MPMediaItemArtwork` 的 `requestHandler` 会在**别的线程**被调，块内要加锁 + 返回 autoreleased 的 retain 副本（mixmusic `:331-343`）。
4. **`objc_msgSend` 需要类型化变体**：float 参数、结构体返回（`CGSize`）必须用不同签名甚至 `objc_msgSend_stret`；MyGo 的 `internal/darwin/objc.go` 与各应用都各自枚举了自己要的几个变体——**这是最容易踩的坑，也是最该直接抄的一段**。
5. **"打包才显示"**：quaver 的实现注释记录——系统只对带 `CFBundleIdentifier` 的应用投影 Now Playing，`./quaver-astra` 裸跑可能在控制中心看不到，打包成 `.app` 后正常（见 [`nowplaying_darwin.go:7-11`](https://github.com/Team-Quaver/quaver-astra/blob/98c1fb7d114a046811f5b57f99d0f01a0adb95b3/internal/smedia/nowplaying_darwin.go#L7-L11)）。**未独立验证**，但对听屿（本来就要签名的 `.app`）无影响。

### 5.3 `//go:cgo_import_dynamic` / `syscall`

- `//go:cgo_import_dynamic`：在 232 个依赖仓库与 MyGo 源码里**未查到**使用。
- `syscall.NewCallback`：MyGo 在 Windows D3D11 路径用（`internal/gpu/d3d11/d3d11.go:657`）；应用侧未见用于媒体。
- 时下社区统一走 `purego`（`Dlopen`/`Dlsym`/`RegisterLibFunc`/`NewCallback`）+ `purego/objc`。

---

## 6. 嵌入 libmpv / mpv / ffmpeg 的先例

### 6.1 libmpv 进程内（cgo）—— godrome

- 结构：`internal/player/{bridge.h,bridge.c,mpv_client.h,native.go,player.go}`——**C 小包装 + Go 侧 worker goroutine 独占 libmpv**（`player.go:38` 注释 "Engine owns libmpv on one worker. UI methods only enqueue work."，命令走 channel）。
- 选项与事件：`gd_option`/`gd_observe`/`gd_wait(timeout)`；监听 `time-pos/duration/pause/paused-for-cache/seeking`（[`native.go:56-77`](https://github.com/XueJie1/godrome/blob/6f9926d9330205976601c3a5dabc0eb6a071384c/internal/player/native.go#L56-L77)）。
- 构建：`.github/workflows/{check,release}.yml` 里 `CGO_ENABLED: '1'`，本机构建，**不做交叉编译**。
- 代价（项目自述与构建配置一致）：用户需自行安装 libmpv（`native.go:43` 的错误文案就是"请按 README 安装系统动态库"）；只能在目标平台上构建。
- 完整事件/属性/均衡器（`af` 滤镜链）：`equalizer.go:92` 用 `af` 参数实现 EQ。

**这是"进程内 libmpv"在 MyGo 生态里唯一的成品证据**——用的是 cgo，不是 purego。

### 6.2 mpv 子进程 + JSON IPC —— quaver-astra

- 自述理由（[`mpv.go:3-11`](https://github.com/Team-Quaver/quaver-astra/blob/98c1fb7d114a046811f5b57f99d0f01a0adb95b3/internal/audio/mpv.go#L3-L11)）：要交叉编译到 linux/{amd64,arm64,loong64}、windows/{amd64,arm64}、darwin/arm64，**cgo 会破坏交叉编译**；mpv 二进制可随包分发；IPC 让后端与 UI 完全解耦。
- 做法：`mpv --no-video --idle --input-ipc-server`，Windows 走命名管道（`ipc_windows.go`），Unix 走 socket（`ipc_other.go`）；命令 id + 观察循环 + `loadGen` 代次防串档；状态"只信 mpv"（位置/时长/暂停/播完全问它）。
- 打包：`internal/audio/bins.go` 定义查找顺序（显式路径 → `QAA_MPV_DIR` → 随包 → PATH），`scripts/stage-mpv.sh` + `scripts/package-macos.sh` 把 mpv 塞进发行包（macOS 是 `mpv.app/Contents/MacOS/mpv`），Linux 用 pkgforge AppImage 展开 + 包内 loader。
- 结论：**"Go 应用 + 随包 mpv 子进程"在 macOS/Windows/Linux 三端都被这个项目跑通了，且保住了交叉编译。**

### 6.3 ffmpeg 子进程解码 —— meiro / AudioSmith

- meiro：`yt-dlp -f bestaudio -g` 取直链 → `ffmpeg -vn -f s16le -acodec pcm_s16le` 输出裸 PCM 管道 → `oto/v3` 播放（[`player/player.go:603`](https://github.com/elianiva/meiro/blob/95e7858fd91a08539927e29e6d7c366c0923f465/player/player.go#L603)、`:818`）；seek 是"杀掉 ffmpeg 从新位置重启"（`playback.go:508` 注释）。
- AudioSmith：macOS 优先 **AVFoundation**（自带引擎走 `media.encode`），ffmpeg 只补它缺的 MP3/Opus/FLAC（`internal/ffmpeg/ffmpeg.go:1-6`），并要求用户配置 ffmpeg 路径（`internal/settings/setup.go:28-31`）。

### 6.4 libmpv 的 **purego** 先例（库级，关键）

- [`gen2brain/go-mpv`](https://github.com/gen2brain/go-mpv)（MIT，61★，`a1e5b69` 2026-06-30）：同时提供 cgo 与 **nocgo/purego** 两条构建路径。
  - [`purego_darwin.go:1-30`](https://github.com/gen2brain/go-mpv/blob/a1e5b695def02d1953839f282e9e12a1ca18968f/purego_darwin.go#L1-L30)：`//go:build (!cgo || nocgo) && darwin`，`purego.Dlopen("libmpv.dylib")` / `libmpv.2.dylib`。
  - `client_nocgo.go` / `render_nocgo.go`：**连 `mpv_render_context_create` 这条渲染回调路径都有 purego 版**（用 `purego.NewCallback` 做 `mpv_render_update_fn`/`wakeup`）。
  - 同系分支：[`aynakeya/go-mpv`](https://github.com/aynakeya/go-mpv)（22★，也有 `client_nocgo.go`）。
- 应用级（非 MyGo）：[`Thelost77/pine`](https://github.com/Thelost77/pine)（Audiobookshelf 终端播放器，`internal/player/libmpv.go` + `libmpv_unix.go`，1★，2026-10-24）用 purego 直接驱动 libmpv；[`uidbz/tie-gui`](https://github.com/uidbz/tie-gui) 用 `Dlsym` 自己绑。
- 纯 Go FFmpeg 绑定（若想绕开 libmpv 直接用 libavcodec）：[`bstkhq/go-ffmpeg-ffi`](https://github.com/bstkhq/go-ffmpeg-ffi)、[`obinnaokechukwu/ffgo`](https://github.com/obinnaokechukwu/ffgo)（均 purego，26 条命中）。

**这意味着路线 B（进程内 libmpv + purego）在"库"这一层是成立的**：不加 cgo、能 dlopen、能收事件、能拿到渲染回调。**缺的是"MyGo 应用里这么干"的样本**（见 §8）。

### 6.5 跨框架参考（明确标注：不是 MyGo 实践）

- mpv 子进程/IPC 的通用 Go 库：[`dexterlb/mpvipc`](https://github.com/dexterlb/mpvipc)（41★）、`diniamo/gopv`。
- libmpv 在别的 Go GUI 里：`i3wangyi/lightTube`（Gio + libmpv）、`depeter/jellycouch`（Ebitengine + libmpv）、`uidbz/fyne-mpv-video`（Fyne + libmpv）、`pauloo27/tuner`（Termbox TUI + libmpv）。
- 这些只能说明"Go 里贴 libmpv 有成熟套路"，**不能**充当 MyGo 的证据。

---

## 7. MyGo 自身的音频实现（macOS）与"会不会抢设备"

### 7.1 源码事实（`v0.6.3` / `1524290`）

| 项 | 事实 | 位置 |
|---|---|---|
| 输出后端 | **AudioToolbox 的 Audio Queue**，`purego.Dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")`，`RegisterLibFunc` 绑 6 个 `AudioQueue*` 函数 | [`audio/output_darwin.go:62-86`](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/audio/output_darwin.go#L62-L86) |
| 设备 | **默认输出设备**，跟随系统切换（`AudioQueueNewOutput(..., runLoop=0, mode=0, ...)`，即回调走队列自己的线程，**不要求主线程/主 RunLoop**） | 同上 `:95-123` |
| 缓冲 | 4 × 512 帧（每缓冲 ≈10.7 ms），先填满 4 个再 `AudioQueueStart`，避免开局欠载 | `:38-43`、`:138-147` |
| 回调 | `purego.NewCallback` 造一个 C 回调，经 `atomic.Pointer[aqDevice]` + `chan *audioQueueBuffer` 把空 buffer 交回写线程 | `:56-60`、`:76-84` |
| 采样格式 | 固定 **48 kHz / 立体声 / float32**（所有播放器重采样到它） | [`audio/audio.go:32-37`](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/audio/audio.go#L32-L37) |
| 格式注册 | `audio.RegisterFormat(name, magic, open func(io.ReadSeeker) (Decoder, error))` | [`audio/audio.go:73`](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/audio/audio.go#L73) |
| 结束回调 | **没有 `OnEnd`**（全 `audio/` 检索零命中）；`Playing()` 变 false 要轮询 | — |
| 空闲省电 | 5 秒无播放关设备 | [`audio/output.go:19-20`](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/audio/output.go#L19-L20) |
| 混音 | Go 内混音器（voices + 5 ms 渐变 + 重采样），**单一输出设备实例** | [`audio/mixer.go`](https://github.com/egoist/mygo/blob/15242900157b77228d35ca071f43e94a11bc90a0/audio/mixer.go)、`audio/output.go` |

### 7.2 自建 `MPNowPlayingInfoCenter` 会不会与它冲突？

**不会抢设备，理论上也不会冲突。** 三条依据：

1. **macOS 上没有 `AVAudioSession`**，也就是没有 iOS 那套"谁拥有音频会话"的概念。Apple 文档的可用平台里 `AVAudioSession` 只列 iOS/iPadOS/Mac Catalyst/tvOS/visionOS/watchOS，**没有 macOS**（[Apple 文档元数据](https://developer.apple.com/documentation/avfaudio/avaudiosession)）；Aurelia 内置的 oto 也在代码里写了同一句："`setupSessionNotifications` is a no-op on macOS: AVAudioSession does not exist there"（[`internal/oto/session_macos.go:19-21`](https://github.com/j4ckxyz/Aurelia/blob/dcc74a4b71d029c76afc27f99ac925acc8aa50e7/internal/oto/session_macos.go#L19-L21)）。
2. **`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` 是纯元数据与控制面**（macOS 10.12.2+，[MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)、[MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)），不打开音频设备、不接管输出。它们只向系统的"正在播放"服务登记信息、接收媒体键事件。
3. **有现实反证**：5 个项目都在同一条播放链路上同时用音频后端与 MediaPlayer 桥（quaver 的音频在 mpv 子进程，其余在进程内），且都在发版（§4.1）。若会互相抢设备，这些产品不可能同时提供"能听"和"控制中心能显示"。

**唯一要注意的耦合点**：MyGo 的 `audio` 与自建桥都要在主线程之外小心调用，而 MediaPlayer 要求主线程——用 `mygo.RunOnMain` 即可，二者不冲突（mixmusic 就是这么接的）。

---

## 8. 四条路线：用别人的实践证据判断

### A. 纯 Go 解码器

**证据**
- 成立的部分：Opus（mixmusic 移植 libopus、yt-music-player 用 `pion/opus`）、MP3（`hajimehoshi/go-mp3`）、FLAC（`mewkiz/flac`）、Vorbis（MyGo 自带）、WAV（自带）都有人跑起来。
- **不成立的部分**：**没有任何项目用纯 Go 解 AAC / ALAC**（232 仓库样本内零命中）。最接近的是 AudioSmith——它在 macOS 上用 **AVFoundation** 解 AAC/M4A、用 ffmpeg 补 MP3/Opus/FLAC，正因为它不肯自己解。
- 另外，纯 Go 解码路线的项目都**自己写了输出层**（mixmusic、Aurelia），因为 MyGo 的 48 kHz 固定格式 + 无 `OnEnd` 不够用。

**判断**：覆盖听屿的 9 种格式（含 m4a/aac/alac/aiff）**没有先例**；要做就是"自己写两三个解码器 + 自己写输出 + 自己写 gapless"的复合工程，风险与工期都高于方案里"补 6 种格式"的估算。**不作 v1。**

### B. 进程内 libmpv + `purego`（方案当前推荐）

**支持证据**
- purego 侧：MyGo 自己用 purego 调 AudioToolbox/Metal/AppKit/GameController，`audio/output_darwin.go` 就是"纯 Go dlopen 系统 C 库 + C 回调"的成品；应用侧 4 个项目直接用 `purego/objc`、1 个用纯 Go 库 `go-macos/objc` 调 MediaPlayer。
- libmpv 侧：`gen2brain/go-mpv` 的 **nocgo/purego 构建**证明 `dlopen(libmpv.dylib)` + 事件回调 + 渲染回调在 Go 里可行（§6.4）。
- 打包侧：听屿的 `.app` 里**本来就有** `Mpv.framework` 与 FFmpeg 框架（`media_kit_libs_macos_audio` 1.0.4 随包，`app/macos/Podfile.lock:3`），所以"随包分发 libmpv"对听屿是零新增成本，且不必让用户装任何东西——这是 godrome（要装 libmpv）与 quaver（随包 mpv 二进制）都不具备的优势。

**风险（必须点明）**
- **"purego 版 libmpv 跑在 MyGo 应用里"没有任何样本**。库级有先例，应用级没有。未验证的具体点：`.app` 内的 `Mpv.framework` 用绝对路径 `dlopen` 是否稳（`@rpath` 在纯 Go 二进制里不自动生效）；`mpv_wait_event` 的阻塞等待要独占 goroutine；`mpv_render_context` 若只做音频可完全不用；LGPL 合规（动态链接 + 可替换，需在"关于"页提供来源与替换方式）；`Mpv.framework` 是 media_kit 的构建产物，版本与符号名要实测。
- 结论：**方向对、缺一次 spike**。

### C. libmpv 子进程 + JSON IPC

**支持证据（最强的一条是"别人已经这么发版了"）**
- quaver-astra：三平台发行包 + 随包 mpv + JSON IPC，自述理由正是"cgo 破坏交叉编译、mpv 可独立安装、后端与 UI 解耦"（§6.2）。
- 通用库成熟：`dexterlb/mpvipc`（41★）可少写一层。
- 对听屿的好处：与听屿现有 `media_kit`（也是 libmpv）行为最接近，seek/gapless/全格式一次拿到；**不需要**动 `Mpv.framework` 的 dlopen 细节。

**代价**
- 多进程 + IPC 状态机（quaver 用 `loadGen` 治串档，说明这块有真实坑）；macOS 上要么随包 `mpv.app/Contents/MacOS/mpv`（quaver 做法，可行），要么依赖用户安装；签名/公证要覆盖嵌套可执行文件（`mpv.app` 里再签名），这是听屿发布流程的新增项。
- 对"单文件小体积"的卖点有影响（mpv 二进制约 40–60 MB 量级，未在本文实测）。

### D. 原生 AudioToolbox shim（自写 ObjC + C-ABI dylib）

**前提被证伪，且无先例。**
- 方案写"纯 Go 调不了 ObjC，所以要 shim dylib"——**错**。`purego/objc` 提供 `NewBlock`/`RegisterClass`/`Send[T]`，4 个应用直接用它、1 个用第三方纯 Go objc 库，都调通了 MediaPlayer；MyGo 自己用 `objc_msgSend` 调 AppKit/Metal（§5）。
- "AudioToolbox 需要 shim"——**也不需要**：MyGo 的 `audio/output_darwin.go` 就是纯 Go 直接 `dlopen` AudioToolbox 并 `RegisterLibFunc` 调 `AudioQueue*`（§7.1）。
- 232 仓库样本中**没有任何项目**使用自写 shim dylib（`//go:cgo_import_dynamic` 零命中，dylib 打包零命中）。
- 保留意见：若将来需要"真正的 ObjC 类实现 + 跨进程/跨语言回调"或必须绕开 purego 的调用约定限制，shim 仍是选项；但**对听屿的媒体会话，它是多余的一层**（还要多一份签名、多一份 xcframework 维护）。

### 8.1 推荐

| 层 | 推荐 | 依据 |
|---|---|---|
| **系统媒体会话** | **自写 Go 包，purego + `purego/objc`，主线程用 `mygo.RunOnMain`；规模按 250–400 行估** | 5 个成品先例；**不需要 cgo、不需要 shim dylib**；Spec 里"400–500 行 ObjC shim"可以砍掉（净省一层构建/签名） |
| **播放内核（macOS 单端）** | **维持 B：进程内 libmpv + purego**，并把 C 作为**同等成熟的退路**保留；A 不在 v1 考虑；D 排除 | B 的库级先例 + 听屿已随包 `Mpv.framework`（零新增分发成本）；C 有 MyGo 应用级成品先例（quaver），若 spike 发现 dlopen 在 `.app` 内不稳，直接切 C |
| **媒体会话要不要等 #654** | **不等**。自己写；#654 合并后可整块换掉（API 形状与社区实现高度相似） | #654 是 open PR、两天无进展；社区 5 个实现均在它之外独立完成 |
| **格式/流式/gapless** | 全交给 libmpv，不自研解码器、不自写 `ReadSeeker` | 自写 `ReadSeeker` 虽有多例（yt-player、lark），但 gapless + 全格式仍要另做，属重复投入 |

### 8.2 若走 B，给听屿的最小验证清单（建议 1–3 天）

1. 从现有 `.app` 里取出 `Mpv.framework`，用 purego `Dlopen` 绝对路径加载，建 `mpv_create`/`mpv_initialize`，播一首 **本地 ALAC/m4a** 与一首 **HTTP Range 的 FLAC**，看 CPU 与 seek。
2. 用 `mpv_observe_property("eof-reached"/"time-pos"/"duration")` + `mpv_wait_event` 跑通"播完自动下一首"（这正是 MyGo `audio` 缺的 `OnEnd`）。
3. 同一进程里加 §4 风格的 Now Playing（可直接参考 mixmusic 379 行那版），验证控制中心显示 + 媒体键 + 进度条拖动，且与播放并存不冲突。
4. 检查 LGPL 合规：`Mpv.framework` 可替换、来源与许可证写进"关于"。
5. 若 1 卡住（dlopen/符号/线程），立刻切 C：`mpv --no-video --idle --input-ipc-server` + 随包 `mpv.app`（可直接照 quaver 的结构）。

---

## 9. 未查到 / 未验证（不用推测填补）

| 项 | 状态 |
|---|---|
| 用 `//go:cgo_import_dynamic` 调系统框架的 MyGo 项目 | **未查到**（232 仓库 + 上游源码） |
| 在 MyGo 应用里用 **purego 驱动 libmpv** 的成品 | **未查到**（只有库级 `gen2brain/go-mpv`、非 MyGo 的 `Thelost77/pine`） |
| 纯 Go 解 AAC / ALAC / AIFF 的项目 | **未查到** |
| 用自写 ObjC shim **dylib** 做媒体会话的项目 | **未查到**（全是进程内 purego/objc） |
| 用 WebView 前端 `<audio>` 做播放的 MyGo 应用 | **未查到**（`<audio>` 仅见于 AudioSmith 测试替身） |
| GitHub "Used by / dependents" 页面 | **无法抓取**（`/network/dependents` 返回 197 KB HTML，解析后只剩本仓库自身；列表疑似需要登录/JS）→ 改用代码检索枚举（232 个） |
| MyGo 官方 showcase / 真实应用列表 | **不存在**（官网只有 docs/examples/benchmarks） |
| "系统只对带 `CFBundleIdentifier` 的应用投影 Now Playing" | **未独立验证**（来源：quaver 的代码注释） |
| `Mpv.framework` 在纯 Go 进程里用绝对路径 dlopen 的稳定性 | **未验证**（本次为只读调研，未写原型；`gen2brain/go-mpv` 用的是系统 `libmpv.dylib`，非 .app 内 framework） |
| 232 个仓库是否都是 fork / 是否都在活跃维护 | **未逐个核实**（只对 §2.3 的 13 个取过 API 元数据，`fork=false`） |
| 26 份 go.mod 下载失败的原因 | 未区分（私有仓库 / 已删 / 空仓库） |

---

## 10. 复核命令

```bash
# 1) 依赖 MyGo 的仓库（需要已登录的 gh，代码检索）
gh api -X GET search/code -f q='"github.com/egoist/mygo" filename:go.mod' -f per_page=100 --jq '.total_count'
for p in 1 2 3; do
  gh api -X GET search/code -f q='"github.com/egoist/mygo" filename:go.mod' \
    -f per_page=100 -f page=$p --jq '.items[] | "\(.repository.full_name)\t\(.path)"'
done | sort -u | wc -l        # 应得 232

# 2) 直接 import 音频包的项目
gh api -X GET search/code -f q='"mygo/audio" language:go NOT is:fork' \
  -f per_page=100 --jq '.items[] | .repository.full_name' | sort | uniq -c | sort -rn

# 3) 与媒体会话求交（各自检索后再与本仓库列表 comm -12）
gh api -X GET search/code -f q='MPNowPlayingInfoCenter language:go'        --jq '.total_count'   # 43
gh api -X GET search/code -f q='MPRemoteCommandCenter language:go'         --jq '.total_count'   # 72
gh api -X GET search/code -f q='org.mpris.MediaPlayer2 language:go'        --jq '.total_count'   # 465
gh api -X GET search/code -f q='SystemMediaTransportControls language:go'  --jq '.total_count'   # 134

# 4) 上游状态
gh api repos/egoist/mygo/pulls/654 --jq '{state,merged,updated_at,additions,deletions,changed_files,head:.head.ref}'
gh api repos/egoist/mygo/releases/latest --jq '{tag_name,published_at}'   # v0.6.4 / 2026-10-25T07:38:35Z
git clone --depth 1 --branch v0.6.3 https://github.com/egoist/mygo /tmp/mygo && \
  cd /tmp/mygo && git grep -il "nowplaying\|MPRemoteCommandCenter\|MPRIS\|SystemMediaTransportControls" -- '*.go'   # 应无输出

# 5) MyGo 的 macOS 音频后端（AudioQueue / purego）
sed -n '60,90p' /tmp/mygo/audio/output_darwin.go

# 6) 应用侧看一眼媒体会话实现
git clone --depth 1 https://github.com/fzn0x/mixmusic /tmp/mixmusic && \
  sed -n '1,20p' /tmp/mixmusic/internal/nowplaying/nowplaying_darwin.go
git clone --depth 1 https://github.com/Team-Quaver/quaver-astra /tmp/qa && \
  sed -n '1,15p' /tmp/qa/internal/audio/mpv.go
```

---

## 11. 直接可抄的样本（若要落地，按这个顺序读）

1. **媒体会话（macOS，最少代码）**：[`xlanstar/yt-music-player` 的 `internal/audio/objc_darwin.go` + `nowplaying_darwin.go`（136 + 172 行）](https://github.com/xlanstar/yt-music-player/tree/2d35858c96388681e777a0f2671cbc34ec32d38a/internal/audio)——最短，且演示了 `RegisterClass` 写法。
2. **媒体会话（macOS，最完整）**：[`fzn0x/mixmusic` 的 `internal/nowplaying/`](https://github.com/fzn0x/mixmusic/tree/45b01dace502cecbd690d60bb81d683da9cd5aa7/internal/nowplaying)——含封面异步抓取、`MPMediaItemArtwork` handler、diff 推送策略。
3. **mpv 子进程全套**：[`Team-Quaver/quaver-astra` 的 `internal/audio/mpv.go` + `bins.go` + `scripts/stage-mpv.sh`](https://github.com/Team-Quaver/quaver-astra/tree/98c1fb7d114a046811f5b57f99d0f01a0adb95b3/internal/audio)——连"随包 mpv 怎么放"都给了。
4. **libmpv 进程内（cgo 参考）**：[`XueJie1/godrome` 的 `internal/player/`](https://github.com/XueJie1/godrome/tree/6f9926d9330205976601c3a5dabc0eb6a071384c/internal/player)——C 小包装 + worker goroutine 的线程模型。
5. **purego 版 libmpv**：[`gen2brain/go-mpv` 的 `purego_darwin.go`/`client_nocgo.go`](https://github.com/gen2brain/go-mpv/tree/a1e5b695def02d1953839f282e9e12a1ca18968f)——路线 B 的技术底座。
6. **`mygo/audio` 的正确扩展方式**：[`yt-music-player` 的 `internal/audio/source.go` + `opus.go`](https://github.com/xlanstar/yt-music-player/tree/2d35858c96388681e777a0f2671cbc34ec32d38a/internal/audio)——自写 `Decoder` + HTTP Range 源，若最终不走 mpv，这是最省事的形态。
