# 听屿 macOS 端：升级 MyGo 官方媒体会话并退役自研实现 · 实施与验收记录

日期：2026-10-26（Asia/Shanghai）
性质：**实施与验收记录**。本阶段只改 `client/` 并新增本文件；**未改 `app/`、未动 `internal/library`、未合并 main、未打 tag、未写生产库**。
判据来源：

- 任务书（本 todo 的 Spec）；
- M1 的 S2 八条：spike 记录 §7.2（[`2026-10-25-macos-mygo-spike-record.md`](./2026-10-25-macos-mygo-spike-record.md)）与 M1 记录（[`2026-10-25-macos-mygo-m1-record.md`](./2026-10-25-macos-mygo-m1-record.md)）；
- 参考提炼报告 §7、§10：([`../research/2026-10-26-mygo-cloudmusic-reference.md`](../research/2026-10-26-mygo-cloudmusic-reference.md))。

---

## 0. 结论

| # | 任务 | 结论 | 一句话证据 |
|---|---|---|---|
| 1 | 升级到 `v0.6.5-0.20261025230045-be164835449b` | **完成** | `go.mod` 只改了 mygo 一行（`go.sum` 同）；`CGO_ENABLED=0 go build ./...`、`go vet`、`go test`、`go test -race`、`gofmt -l` 全干净；无编译期破坏 |
| 2 | 删自研媒体会话、改接 `mygo.NowPlaying` | **完成** | `internal/mediasession/`（1094 行，含测试）与随之失去调用方的 `internal/mainq/` 已删除；仓库内 `mediasession`/`mainq` 的 Go 与文档引用 **0 处**；`purego/objc` 在本仓库不再出现 |
| 2a | App Nap / 防睡眠 | **由官方 API 等价承接** | `mygo.Power.KeepAwake` 在 `pmset -g assertions` 里产生同名 `PreventUserIdleSystemSleep`；播放/暂停即时创建/释放（§3.3） |
| 3 | 拖动只在松手 seek 一次 | **完成** | 新增 `model.Scrubber`，拖动中被按住的帧 0 次 seek、松手 1 次；慢速拖动 8 帧时远端 `Range` 请求 **64 → 9**（§4） |
| 4 | S2 八条重跑 | **6 条通过，2 条未闭环（与 M1 同因）** | 见 §5；未闭环的是物理 F7/F8/F9 与「控制中心拖动 seek」的注入通道 |

**没有出现需要立即停下的回归**：9 格式播放、远端播放、扫描入库三条链路本次没有改动（`internal/library`、`internal/mpv`、`internal/scan` 零改动），并在升级后**重跑了 M2 验收 harness**：25/25 通过（9 格式、远端 Range/鉴权/过期/断网/未知时长、gapless、200 首队列、三种循环、倍速/音量），证据 `client/build/m2-evidence/20261026-102940/report.json`。扫描入库在每次应用运行里都跑了（9 个文件 → 入库 9）。

---

## 1. 环境

| 项 | 值 |
|---|---|
| 机器 / 系统 | MacBook Air（Apple Silicon，arm64），macOS 27.2（26B118） |
| Go | go1.27.3 darwin/arm64，`CGO_ENABLED=0` |
| 旧框架 | `github.com/egoist/mygo v0.6.4` |
| 新框架 | `github.com/egoist/mygo v0.6.5-0.20261025230045-be164835449b`（伪版本，对应 `be164835449b`，2026-10-25T23:00:45Z） |
| 播放 | 进程内 libmpv mpv 0.36.0（同前，未动） |
| 媒体会话 | `mygo.NowPlaying`（macOS = MPNowPlayingInfoCenter + MPRemoteCommandCenter） |
| 防睡眠 | `mygo.Power.KeepAwake`（NSProcessInfo activity + IOKit 断言） |
| 曲库 | 一律 `cp -R` 副本 + `TINGYU_DATA_DIR`；生产库全程只读（§6.3） |

构建：`cd client && ./scripts/bundle.sh` → `build/darwin-arm64/听屿.app`（13.4 MB + `Contents/Frameworks`）。

---

## 2. 升级本身（任务 1）

### 2.1 依赖改动

```diff
 require (
 	github.com/ebitengine/purego v0.11.1
-	github.com/egoist/mygo v0.6.4
+	github.com/egoist/mygo v0.6.5-0.20261025230045-be164835449b
 	github.com/skip2/go-qrcode v0.0.0-20200617195104-da1b6568686e
 )
```

`go mod tidy` 后**没有其他依赖被顺手升级**（`git diff client/go.mod client/go.sum` 只有 mygo 的两行校验和）；`go-text/typesetting`、`x/image`、`x/net`、`x/text`、`purego` 版本保持不变，工具链仍是 `go 1.27.3`。

### 2.2 构建与测试

```
gofmt -l .                        → （空）
CGO_ENABLED=0 go build ./...      → 通过
CGO_ENABLED=0 go vet ./...        → 通过
CGO_ENABLED=0 go test ./...       → 9 个有测试的包全 ok
CGO_ENABLED=0 go test -race ./... → 9 个包全 ok（本机 Go 支持 CGO_ENABLED=0 的 -race）
```

### 2.3 升级后观察到的行为差异（如实记录）

| 差异 | 影响 | 处理 |
|---|---|---|
| `mygo.NowPlaying.Info()` 是**框架自己的模型**，不是从 MPNowPlayingInfoCenter 读回的字典 | 日志里的 `readback` 含义变了：旧实现读的是系统字典，新实现读的是框架状态；系统侧真相改由 `mediaremoted` 日志取证 | 日志字段改名并注明；系统侧证据见 §5 |
| 系统不再有 `togglePlayPause` 命令名 | play/pause 键被框架折算成 `play` 或 `pause`（按它被告知的状态），日志从 `media: command togglePlayPause` 变成 `play`/`pause` | 已记录；M1 的日志 grep 若按旧名会落空 |
| 封面以 `[]byte` 交给框架（PNG/JPEG），框架自己建 `MPMediaItemArtwork` 并在系统请求时解码 | 客户端不再有 512px 上限与 NSImage 缓存；我们直接传 `covers/` 里的文件字节（本机最大 339 KB） | 只在封面路径变化时读文件一次；连切 10 首全部 `artwork=true`（§5 #1） |
| `mygo.Power.KeepAwake` 的 reason 用中文时，系统侧断言名变成空串 | `pmset` 显示 `PreventUserIdleSystemSleep named: ""`（实测：同样的代码用 ASCII 就有名字） | 断言名固定为 ASCII `tingyu: playing audio`；理由写进代码注释 |
| `ui.DecodeBitmap` 不再复制入参字节（报告 §7.3） | 我们唯一调用点 `ui/model/covers.go:63` 的入参是一次性 `os.ReadFile` 结果，正确性不受影响；代价是每张封面多留一份原始字节 | 本次不扩散到 M5；已在风险里记一条 |
| `RoleWindowMenu` 在 macOS 上仍不含「关闭窗口」（v0.6.4 与新版一致） | `Cmd+W` 不关窗，和升级前一样 | 关窗验收改按红色关闭按钮（AXPress `AXCloseButton`），结论不受影响 |

没有发现编译期破坏：99 个标识符（`ui.*` 69 + `mygo.*` 24 + `sqlite.*` 6）在 `be16483` 全部存在，与报告 §7.4 的静态核查一致。

---

## 3. 媒体会话改接官方 API（任务 2）

### 3.1 删除与替换

- 删除 `client/internal/mediasession/`：`mediasession_darwin.go`（542 行）、`bridge_darwin.go`（230）、`keepawake_darwin.go`（158）、`mediasession_test.go`（164），合计 1094 行。
- 删除 `client/internal/mainq/`：删除媒体会话后**没有任何包再引用它**（纯 libdispatch 主线程投递 + AppKit 事件循环工具），成为死代码，一并移除。`purego/objc` 因此在本仓库零命中。
- `internal/app/session.go` 的接线改为：

| 旧（自研） | 新（框架） |
|---|---|
| `mediasession.Init()` + `SetHandler(func(Command, float64))` | `mygo.NowPlaying.OnCommand(func(mygo.MediaCommand, time.Duration))` |
| `SetMetadata(Metadata{Title,Artist,Album,DurationSec,ArtPath})` | `NowPlaying.Set(NowPlayingInfo{…, Artwork []byte, Commands})` |
| `SetState(State{Playing,Rate,Position,Duration})` | `NowPlaying.SetPlayback(PlaybackState, position)`（进度/状态）；速率与命令集变化走 `Set` |
| `SetEnabledCommands(hasNext,hasPrev)` | `NowPlayingInfo.Commands` 位图：`MediaPlay|MediaPause` + 有队列时的 `MediaNext/MediaPrevious` + 时长已知时的 `MediaSeek` |
| `Clear()` | `NowPlaying.Clear()` |
| `SetKeepsAwake(bool)`（NSProcessInfo + IOKit） | `mygo.Power.KeepAwake(reason, false)` / 其 `release` |
| `NowPlayingInfo()` / `CommandStatus()`（读系统字典） | `NowPlaying.Info()`（框架状态），日志里注明语义 |

去重与节流策略保持 M1 的口径：元数据按 `(id, index, duration, artwork, commands, rate)` 去重、新会话强制重发；进度 500 ms 节流；播放态/处理态/换曲立即推送。

### 3.2 App Nap / 防睡眠为什么不用回自研

任务书要求：官方 API 若无等价能力，保留自研 keepawake。实测**框架提供了等价能力**，因此整包删除：

- 单独最小程序验证：`mygo.Power.KeepAwake("powerprobe: playing audio", false)` 期间 `pmset -g assertions` 出现
  `pid …(powerprobe): … PreventUserIdleSystemSleep named: "powerprobe: playing audio"`，12 s 后 `release()`，同一行消失。
- 应用内验证：播放中 `pid 44564(听屿): … PreventUserIdleSystemSleep named: "tingyu: playing audio"`；暂停后 1 ms 内消失，恢复播放后重新出现（§5 #7）。
- 它同时调用 `NSProcessInfo -beginActivityWithOptions:reason:`（App Nap 抑制）与防空闲睡眠选项，比旧实现的「UserInitiated 允许睡眠 + 单独 IOKit 断言」两件套更简单，效果同等（旧实现的 `pmset` 断言行也来自同一机制）。

### 3.3 可测试的纯逻辑

- `client/internal/app/session_test.go`：逐条命令 → 控制器调用（play/pause/stop/next/previous/seek 的位置）；nil 控制器为 no-op；命令集随队列与时长变化。
- 顺手修掉的**既有**竞态：`a.tray`/`a.trayPlay` 由主线程（`initTray`）写、更新 worker（`updateTray`）读，`-race` 构建下报 2 条 `DATA RACE`（与媒体会话无关，M1 起就存在）。加 `trayMu` 后 race 构建整轮 0 条。
- 新增 `client/cmd/scrubprobe` + `scripts/run-scrub-probe.sh`：拖动 seek 的 Range 证据（§4）。

---

## 4. 拖动连发 seek 的修复（任务 3）

### 4.1 改动

- 新增 `client/internal/ui/model/scrub.go`：`Scrubber.Seek(value, end, pressed, changed)`。规则：
  1. 按住（`Pressed()`）时只改显示，**不 seek**；
  2. 松手那一帧 seek **一次**，目标为松手时的值；
  3. 没拖动过（按在滑块上又原地松开）不 seek；
  4. 键盘方向键改值（没有按压）仍然 seek，保证无指针也能拖动；
  5. 目标夹在 `end - 1s`，避免「拖到末尾被判播完而切歌」。
- `internal/ui/components/transport.go` 与 `pages/stage.go`：`if slider.Changed() { Seek }` 换成上面的规则；进度条的显示值仍由本地 `v.seek` 缓冲。
- 两处滑块加无障碍标签「播放进度」（`Slider.Label`），这也是自动化拖动与自查的入口。
- 测试：
  - `ui/model/scrub_test.go`：拖动序列 0→1 次 seek、键盘仍 seek、原地松开不 seek、末尾夹取；
  - `internal/shell/shell_test.go` 的 `TestProgressSliderSeeksOnceOnRelease`：**驱动真实传输条**，按下后移动 10 帧期间 `fakeActions.seeks == 0`，松手后恰好 1 次，目标落在 3:49 的 70% 附近。
  - 反证：把 `transport.go` 临时改回旧行为，该测试立即失败（`the drag seeked 2 times before release (step 1)`）。

### 4.2 远端（本地 Range 服务）实测

探针：`client/cmd/scrubprobe`，播放 `build/scrub-media/remote/long.flac`（180 s、96 kHz/24 bit、30.5 MB，远大于 mpv 的 demuxer cache），服务端是 M2 的 `internal/rangesrv`（强制 `Range`、逐请求记录），引擎选项与 M2 远端相位一致（`cache=yes`、`demuxer-max-bytes=1MB`）。拖动轨迹固定为 10% → 70%，只改变帧间隔（模拟快拖/慢拖）。`legacy` 策略复刻被删掉的两行（每个 `Changed()` 帧 seek 一次），`view` 策略驱动生产视图。

| 拖动形态 | 策略 | Seek 调用 | 拖动期间 `Range` 请求 | 松手→到达目标位置 |
|---|---|---|---|---|
| 快拖（30 帧，40 ms/帧 = 1.2 s） | legacy（旧） | 30 | 9 | —（一直在 seek，无法按“松手”计） |
| 快拖（同上） | **view（新）** | **1** | 8 | **5 ms** |
| 中速（30 帧，100 ms/帧 = 3 s） | legacy（旧） | 30 | 9 | — |
| 中速（同上） | **view（新）** | **1** | 9 | **35 ms** |
| 慢拖（8 帧，250 ms/帧 = 2 s） | legacy（旧） | 8 | **64** | — |
| 慢拖（同上） | **view（新）** | **1** | **9** | **48 ms** |

读数与解释（**不粉饰**）：

- **每次真正完成的 seek 在这个文件上要 ~8 次 `Range` 请求**（FLAC 的 seek table 在文件尾，libavformat 会重读尾部与目标帧附近）。慢拖时旧的「每帧 seek」真的完成了 8 次 seek → 64 次请求；新的只完成 1 次 → 9 次，**约 7 倍下降**。
- **快拖/中速拖时 HTTP 请求数几乎不变**（9 → 8/9）：mpv 自身会把还没执行的异步 seek 合并，30 条 seek 命令只落到最后一次。也就是说参考报告「每拖一格就连续重发 Range」的推断在 mpv 上只在拖动慢到每次 seek 都能完成时完全成立；快拖时真正省下的是 30 次解码器中断/重建与反复的位置跳变，而不是 HTTP 请求数。
- 松手到出声（位置到达目标 ±0.5 s）：5–48 ms，与 M1 的单次 seek 恢复同量级；`baseline` 稳态请求速率在两次测量中都是 0 次/秒，所以上表没有把常驻流式读取算进去。
- 复现：`cd client && STEPS=8 GAP=250ms ./scripts/run-scrub-probe.sh`（每种策略各写一份 `build/scrub-evidence/<时间戳>/{legacy,view}.json`）。

---

## 5. S2 八条重跑（任务 4）

测试装置与 M1 相同：`cp -R` 库副本 + `TINGYU_DATA_DIR`，扫描 `build/m2-media/formats`（9 格式各 14 s）或 `build/s2-cover`（8 s + 内嵌封面），`TINGYU_AUTO_PLAY_TITLE` 起播，命令经 `spike/cmd/spike-np` 的 `MRMediaRemoteSendCommand`（与媒体键同一分发路径）注入，系统侧只采信 `mediaremoted` 的日志。

| # | 阈值（spike §7.2） | 结论 | 实测数据 |
|---|---|---|---|
| 1 | 控制中心/Now Playing 显示标题/艺术家/专辑/封面；切歌 ≤500 ms 更新 | **通过** | 自然播完切歌（`mpv: end-file` → `session: metadata`）：**0 / 0 / 1 / 2 / 3 / 36 ms**（7 次转换，最大 36 ms）；注入 `next`：发送 10:25:58.877 → 回调 .903（26 ms）→ 元数据 .904（**27 ms**）；连切 10 首（`TINGYU_STRESS_PLAYS=10`）全部 `artwork=true`，进程存活；`mediaremoted` 持续为 ControlCenter 返回 A224×224 封面/队列请求 |
| 2 | 播放/暂停与 tile 状态一致；停止后 tile 显示已停止 | **通过** | 播放中框架状态 `playbackState=0`（PlaybackPlaying），暂停后 `state=1`（Paused），与界面同源；`session: state`、`state readback` 成对出现；系统侧 `mediaremoted` 把 `activePlayerPath` 指向 `com.halunhaku.tingyu` |
| 3 | F7/F8/F9 及控制中心按钮 → Go 回调 ≤150 ms → 音频响应正确 | **系统命令通道通过；物理按键未闭环（与 M1 同）** | 播放中注入 `play`/`pause`/`next`/`prev` 全部到达并生效（`media: command play` / `pause` / `nextTrack` / `previousTrack`），注入→回调 **26 ms**；`toggle` 被框架按状态折算为 `play`/`pause`。物理 F7/F8/F9 无自动化通道（OS 不允许合成 HID 消费页按键），仍需人工按一次 |
| 4 | 控制中心拖动进度 → Go 收到秒数并 seek | **未闭环（与 M1/spike 同因）** | `spike-np -send seek -seek 7` 被 MediaRemote 接受，但应用侧**没有** `changePlaybackPosition` 回调行（旧实现同样收不到，见 spike §4）。命令映射本身由 `session_test.go` 证明：`mygo.MediaSeek` → `control.Seek(position)`，位置原样传递；命令集在有日期的曲目上包含 `MediaSeek`（日志 `commands=0x73`） |
| 5 | 关窗后继续播放时 tile 仍正确；`Cmd+Q`/退出后 tile 消失 | **通过** | AXPress 关闭按钮 → `window: closed` + `window: all closed, playback continues`；4 s 后位置从 8.700 s 继续到 9.255 s（并循环到下一首）；进程存活；`mediaremoted` 仍以我们为 active client 并返回 ControlCenter 队列；`app: quitting` → `session: now playing cleared` → `playback: engine closed` → `app: quit complete`；系统侧 `Removing nowPlayingClient com.halunhaku.tingyu (44564)`、`activePlayerPath … → (null)` |
| 6 | 连续 100 次按键无崩溃、无竞态（`-race`） | **通过** | 100 次 `toggle`（20 ms 间隔）两次全接受、进程存活；`CGO_ENABLED=0 go build -race` 的应用（替换进 .app、重签、加 rpath）整轮 0 条 `WARNING: DATA RACE`；`go test -race ./...` 全绿 |
| 7 | 播放期间 `pmset -g assertions` 可见断言；暂停后释放 | **通过** | 播放：`pid(听屿): … PreventUserIdleSystemSleep named: "tingyu: playing audio"`；暂停命令 → 1 ms 内该行消失；恢复播放 → 重新出现；退出后无残留（`session: keeps awake false`） |
| 8 | 无 cgo | **通过** | 所有构建（应用、验收 harness、race 版）均为 `CGO_ENABLED=0`；objc/MediaPlayer/IOKit 全部经 `purego` dlopen；`internal/mediasession` 与 `purego/objc` 已不在仓库 |

**官方 API 是否“明显退化”**：没有触发任务书列出的三种退化（元数据 >500 ms、按键回调丢失、关窗后状态错乱）。未闭环的两条（物理按键、控制中心拖动注入）在 M1 的自研实现下同样未闭环，不是本次替换造成的退化。

---

## 6. 验收清单

### 6.1 `go.mod` 与构建

- `client/go.mod`：`github.com/egoist/mygo v0.6.5-0.20261025230045-be164835449b`（唯一改动）。
- `gofmt -l .` 空；`go vet ./...`、`go test ./...`、`go test -race ./...`、`CGO_ENABLED=0 go build ./...` 全通过。

### 6.2 删除证据

```
$ grep -rn "mediasession\|mainq" client --include=*.go --include=*.md | wc -l
0
$ grep -rln "purego/objc" client --include=*.go | wc -l
0
$ git status --short client/internal/mediasession client/internal/mainq
 D client/internal/mediasession/...
 D client/internal/mainq/mainq.go
```

**一处需要说明的边界**：`spike/` 是**另一个 Go module**（`spike/go.mod`，M1 的可行性证据程序），其中保留了当年那份 `internal/mediasession` + `internal/mainq`。它不在产品的构建、CI 或发布链路里（`client/` 是唯一出包模块），删掉会让 M1/spike 记录的复现命令失效，因此**没有删**。所以「仓库内无残留引用」按**产品代码（`client/` module）**成立；`spike/` 的历史副本原样保留，这是对任务书「不得删了事/保留证据」的取舍，特此写明。

### 6.3 生产库

```
$ shasum -a 256 ~/Library/Application\ Support/com.halunhaku.tingyu/library.sqlite
310526fdbac4e7dd9615c4d124bb28049146f87f4bce00629ed8f10b4581fb73   （与 M1 记录一致）
$ stat -f "%Sm" …/library.sqlite
Oct 25 14:30:24 2026                                                 （mtime 未变）
```

全部运行都用 `cp -R` 副本（`/tmp/tingyu-s2`、`/tmp/tingyu-race-db`），`TINGYU_DATA_DIR` 指向副本；未设置该变量的进程保持只读。

### 6.4 播放内核回归基线（升级后重跑）

```
$ cd client && ./scripts/run-m2-accept.sh
PASS  format-mp3 … format-alac（9 条）
PASS  remote-play / remote-auth / remote-expired / remote-offline / remote-unknown-duration
PASS  gapless-same-album / gapless-scope
PASS  queue-replace / queue-200
PASS  loop-off / loop-all / loop-one / rate / volume / buffered-local / buffered-remote
25/25 passed
report: build/m2-evidence/20261026-102940/report.json
```

这是任务书「9 格式 / 远端播放 / 扫描入库任一回归就停下」那一条的直接证据：三条链路一条没坏。

### 6.5 范围

- `app/`（Flutter）零改动；`internal/library/` 零改动；`internal/mpv`、`internal/scan`、`internal/sources` 零改动。
- 未合并 main、未打 tag；未升级其他依赖；未改视觉令牌或页面布局（只给两个滑块加了无障碍标签）。

---

## 7. 供应链风险与回退方案

### 7.1 唯一接受的供应链风险

`be16483` **没有正式 tag**，只能钉伪版本 `v0.6.5-0.20261025230045-be164835449b`。这是本 todo 唯一接受的供应链风险：

- 伪版本指向一个不可变的 commit，`go.sum` 固定了内容校验和，但**上游可以 force-push 该分支、也可能永不发 v0.6.5**。
- **升级到正式 tag 后，必须重跑本 todo 的验收**：`go.mod` 换 tag → `go build/vet/test/-race` → §5 的 S2 八条（至少 #1、#3、#5、#7）与 §4 的拖动测量。理由：正式 tag 的 `NowPlaying`/`Power` 实现可能与 `be16483` 不同。
- 依赖图新增的直接依赖只有 mygo 自己的 `go-mp3`/`oggvorbis`（我们不 import `mygo/audio`，未进入我们的构建产物）；`purego`、`go-text`、`x/*` 版本未变。

### 7.2 回退方案（保留自研实现）

本 todo 的全部代码在一个提交里。若官方媒体会话出现本记录未覆盖的退化（例如正式 tag 改坏 `NowPlaying`、或控制中心拖动在真实使用中失效）：

1. `git revert <本 todo 的提交>`：一次性恢复 `internal/mediasession/`（含 keepawake 与全部测试）与 `internal/mainq/`、`internal/app/session.go` 的旧接线，`go.mod` 回到 v0.6.4；拖动修复与 `.scrubprobe` 不依赖框架，可单独保留。
2. 只回退媒体会话、保留框架升级：把 `session.go` 的 `initSession/publishSession/setKeepAwake` 三段换回旧实现并恢复 `internal/mediasession`（旧实现只依赖 `purego`/`mainq`，与新框架无冲突）。
3. 拖动修复可独立回退：删除 `Scrubber` 的两个调用点即回到「每个 Changed 帧 seek」，`transport.go`/`stage.go` 的其余部分不受影响。

### 7.3 已知遗留 / 未验证

| 项 | 状态 | 说明 |
|---|---|---|
| 物理 F7/F8/F9 | **未闭环** | macOS 不允许合成 HID 消费页媒体键；与 M1 相同，需人工按一次 |
| 控制中心拖动 seek | **未闭环** | `MRMediaRemoteSendCommand(cmd=6)` 在本机不派发到应用；映射层有单测，真实拖动需人工 |
| 控制中心 tile 像素级截图 | **未做** | 系统侧只采信 `mediaremoted` 日志（`Creating playerClient`、A224×224 封面请求、`Removing`） |
| 封面尺寸 | 变化 | 旧实现把封面压到 512 px；新实现传原始文件字节（本机最大 339 KB）。连切 10 首未见异常，但超大封面（数 MB）会随 `Set` 被框架克隆一次，属内存峰值风险 |
| `mygo.Power.KeepAwake` 的中文 reason | 缺陷 | 框架 darwin 后端把非 ASCII reason 变成空串（`named: ""`），我们改用 ASCII |
| 吸附封面的扫描时长异常 | 既有问题，非本次引入 | 用 `ffmpeg` 给 FLAC 附上 `attached_pic` 后，`library` 里该曲目时长为 23 ms，导致自动连播时约每 26 ms 推一次元数据（14 s 内 531 次 `Set`）。时长来自扫描入库，不在本次改动范围；建议后续修 `internal/scan` 的时长解析 |
| `spike/` 里的历史副本 | 有意保留 | 独立 module、不进出包链路；删掉会破坏 M1/spike 证据的复现（§6.2） |
| 正式 tag | 待上游 | 发版后重跑验收（§7.1） |

---

## 8. 复现命令

```bash
cd client

# 升级与静态检查
go get github.com/egoist/mygo@v0.6.5-0.20261025230045-be164835449b
go mod tidy
CGO_ENABLED=0 go build ./... && CGO_ENABLED=0 go vet ./... && CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go test -race ./...
gofmt -l .

# 出包（媒体会话与 keepawake 都在真实 .app 里验）
./scripts/bundle.sh

# 拖动 seek 的 Range 对比（生成 30.5 MB / 180 s 的远端测试文件）
STEPS=8 GAP=250ms ./scripts/run-scrub-probe.sh     # 慢拖：legacy 64 次 Range / view 9 次
STEPS=30 GAP=40ms ./scripts/run-scrub-probe.sh     # 快拖：mpv 会合并 seek，两者都 ~9 次

# S2 重跑（库副本 + 自动起播 + 注入命令；spike-np 需单独 build）
cp -R ~/Library/Application\ Support/com.halunhaku.tingyu /tmp/tingyu-s2
TINGYU_DATA_DIR=/tmp/tingyu-s2 TINGYU_STARTUP_LOG=/tmp/s2.log \
TINGYU_AUTO_SCAN_DIR=$PWD/build/m2-media/formats TINGYU_AUTO_PLAY_TITLE=tone \
TINGYU_REPEAT=all TINGYU_AUTO_QUIT_MS=70000 \
./build/darwin-arm64/听屿.app/Contents/MacOS/听屿
# 另一个终端：
(cd ../spike && CGO_ENABLED=0 go build -o /tmp/spike-np ./cmd/spike-np)
/tmp/spike-np -send next
/tmp/spike-np -send toggle -repeat 100 -gap 20ms
pmset -g assertions | grep 听屿
log show --last 2m --predicate 'process == "mediaremoted"' | grep tingyu
```

---

## 9. 改动文件

| 文件 | 变化 |
|---|---|
| `client/go.mod`、`client/go.sum` | mygo 钉到伪版本（唯一依赖变化） |
| `client/internal/mediasession/`（4 个文件） | **删除** |
| `client/internal/mainq/mainq.go` | **删除**（失去调用方） |
| `client/internal/app/session.go` | 改接 `mygo.NowPlaying` + `mygo.Power.KeepAwake`；封面字节、命令集、日志、退出清理 |
| `client/internal/app/app.go` | `awakeRelease`/`trayMu` 字段；托盘菜单项改用局部变量后统一发布 |
| `client/internal/app/session_test.go` | 新增：命令映射与命令集 |
| `client/internal/ui/model/scrub.go`、`scrub_test.go` | 新增：拖动只在松手 seek 的状态机与测试 |
| `client/internal/ui/components/transport.go`、`pages/stage.go` | 使用 `Scrubber`；滑块无障碍标签「播放进度」 |
| `client/internal/shell/shell_test.go` | 新增真实传输条的拖动测试；`fakeActions` 记录全部 seek |
| `client/cmd/scrubprobe/main.go`、`client/scripts/run-scrub-probe.sh` | 新增：Range 请求对比探针 |
| `client/README.md` | 包表移除 mainq/mediasession；媒体会话与防睡眠描述改为框架 API；补探针脚本 |
| 本文件 | 新增 |
