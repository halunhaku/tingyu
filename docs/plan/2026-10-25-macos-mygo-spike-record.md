# 听屿 macOS 端 MyGo 迁移 · 验证小样记录（spike S1/S2/S3）

日期：2026-10-25（Asia/Shanghai）
性质：**验证记录**。本 todo 只做方案 §7 的小样：新建 `spike/` Go 模块，**未改 `app/`、未改方案正文、未合并 main、未打 tag**。本文是新增文件。
任务书：[方案 §7](./2026-10-25-macos-mygo-migration-plan.md)（阈值与放弃条件以该节为准，本文不改判据）
输入调研：[真实 MyGo 项目怎么做音频播放与系统媒体会话](../research/2026-10-25-mygo-audio-in-the-wild.md)
代码与原始证据：[`spike/`](../../spike/)（`spike/README.md` 有逐包说明与复现命令）

---

## 0. 结论

**判定：继续（按方案 C = 进程内 libmpv + purego，媒体会话按 P1 = `purego/objc` 直调）。不触发任何一条 §7.4 的降级/暂停动作。**

一句话依据：进程内 `purego` dlopen 现有 `Mpv.framework`，在 `CGO_ENABLED=0` 下真实出声（离屏录音可证）、Range + 按曲目鉴权头 + gapless + 结束回调全部达标、200 次换队列/seek 无崩溃无竞态；同一进程里 `purego/objc` 让系统把 Now Playing **归给了我们的进程**（mediaremoted 日志为证），五个媒体命令都能收到并且延迟 5–11 ms。

二值口径下有两条 S2 阈值**没有闭环**，需要人工在本机按一次键、拖一次进度条（见 §4 与 §7）：

| # | 阈值 | 二值结论 |
|---|---|---|
| S2-3 | F7/F8/F9 物理按键 → 回调 ≤150 ms | **未闭环**：系统命令通道通了（5 类命令、延迟 5–11 ms、100 次连发 100 次收到），但自动化**无法合成硬件媒体键**，物理按键没人按过 |
| S2-4 | 控制中心拖动进度 → 收到秒数并 seek | **未闭环**：`changePlaybackPosition` 已注册且 enabled，但 `MRMediaRemoteSendCommand` 的两种 seek 注入方式都送不到（其余命令都能送到），拖动只能人工做 |

这两条不是"失败"，是"没法用当前工具自动判"；它们也**不在** §7.4 的停工条件里（那条要求"进程内出声仍无 Now Playing **且**按键也不通"，实测两者都不成立）。

---

## 1. 环境与时间盒

| 项 | 值 |
|---|---|
| 机器 / 系统 | MacBook Air（Apple Silicon，`arm64`），macOS 27.2（build 26B118） |
| Go | go1.27.3 darwin/arm64（`CGO_ENABLED=0`） |
| libmpv | **mpv 0.36.0**，client API `2.1`（`0x20001`）；来自 `media_kit_libs_macos_audio-1.1.4` 的 `Mpv.framework`（x86_64 + arm64 通用） |
| 解码/滤镜 | 随包的 `Avcodec/Avformat/Avutil/Avfilter/Swresample/Swscale` + `Mbedtls/Mbedxcrypto/Mbedx509` |
| 音频设备 | 输出 = `MacBook Air扬声器`（built-in，48000 Hz），另有 `OrayVirtualAudioDevice` |
| 音频链路 | `ao=coreaudio`，`audio-client-name=听屿Spike` |
| 媒体会话 | MediaPlayer.framework，`purego/objc`（P1，无 cgo、无 shim dylib） |
| 观察工具 | 私有 `MediaRemote` + `mediaremoted` 系统日志 + CoreAudio HAL 属性 + `pmset -g assertions` |

时间盒：任务书给 3–5 人日。本次是**单机连续执行**（分阶段实现 + 反复实测），S1 在无 cgo 条件下首次出声约在开工 1 小时内完成，远早于"1.5 人日"的放弃线。

### 1.1 与任务书事实的偏差（以实测为准）

- 任务书说"`app/build/macos/…/Frameworks/` 内含 `Mpv.framework`，可直接复用"。**本工作区没有 `app/build/`**（从未构建过）。改用同一条链路的 pub 缓存产物：`~/.pub-cache/hosted/pub.dev/media_kit_libs_macos_audio-1.1.4/macos/Frameworks`。
  差异：`app/macos/Podfile.lock` 钉的是 `media_kit_libs_macos_audio 1.0.4`，这里是 1.1.4。两者都是同一个 mpv 0.36.0 + LGPL 构建（见 §1.2），对结论无影响，但**打包时要按实际解析版本取库**。
- 任务书要求"尽量用最小 MyGo 窗口承载 S1+S2"。**做到了**：`spike/cmd/spike-app` 是 MyGo v0.6.4 原生窗口，同一进程里跑 mpv 事件循环与 ObjC 回调（§4.5）。

### 1.2 许可核查（方案 §4.2 要求"第一步就读构建信息"）

| 库 | 证据 |
|---|---|
| mpv | 二进制内嵌 `Configuration: -Dgpl=false -Dcplayer=false -Dlibmpv=true ...`，即 LGPL 构建（非 GPL） |
| FFmpeg | `libavcodec license: LGPL version 3 or later` |

结论：可以随闭源应用**动态**分发（保留许可与源码获取说明、允许替换库文件）。这条以前是"待办"，现在有实测证据。

---

## 2. 方法（可复现）

```bash
export PATH=$HOME/sdk/go/bin:$PATH
cd spike
./scripts/gen-media.sh      # ffmpeg 现场合成 24/96、24/48 FLAC 与封面（不入库，sha256 入库）
./scripts/s1-verify.sh      # 阈值 1–7 + 构建/vet/单测，证据落 evidence/s1-<ts>/
./scripts/s2-verify.sh      # S2 全部证据（含 mediaremoted 日志），evidence/s2-<ts>/
MIC=1 LONG=1 ./scripts/s1-verify.sh   # 追加：麦克风回环 + 30 分钟资源采样
```

测试素材（全部 ffmpeg 合成，`testdata/media/checksums.txt` 固化）：

| 文件 | 规格 | 用途 |
|---|---|---|
| `tone96.flac` | 24 bit / 96 kHz / 立体声 / 6 s / 440 Hz | 阈值 1、5、声学回环 |
| `tone48.flac` | 24 bit / 48 kHz / 立体声 / 6 s / 660 Hz | 阈值 1、4 |
| `long96.flac` | 24 bit / 96 kHz / 立体声 / 20 s / 440 Hz | 阈值 3（短文件会被整段缓存，seek 不触发 Range） |
| `short.flac` | 24 bit / 48 kHz / 1.5 s | 阈值 2（结束回调） |
| `album1.flac` / `album2.flac` | 24 bit / 48 kHz / 各 3 s / 1 kHz 与 1.2 kHz | 阈值 5（gapless） |
| `cover.png` | 512×512 | S2 封面 |

远端服务：`spike/internal/httpsrv`，`127.0.0.1:0`，除 OPTIONS 外**所有**请求先校验 `Authorization: Basic`（缺失/错误 → 401），支持 `bytes=a-b` / `a-` / `-n`、越界截断、416、HEAD、路径穿越拒绝，并把每条请求（含 401）以 JSONL 落盘——这就是阈值 3/4 的"服务端日志"。

---

## 3. S1 音频链路（§7.1）

证据目录 `spike/evidence/s1-20261025-170450/`（`s1/report.json`、`stress/report.json`、`acoustic/report.json`、各 `mpv-*.jsonl`、`http-*.jsonl`）。

### 逐条阈值

| # | 阈值 | 结论 | 支撑数据 |
|---|---|---|---|
| 1 | 两种采样率均出声，无爆音；日志无 audio underrun | **通过** | 96 kHz：日志 `AO: [coreaudio] 96000Hz stereo 2ch s32`，`playback-time` 1.2 s 内推进到 1.708 s，`duration=6`，underrun 计数 **0**，播放期间 CoreAudio 默认输出设备 `deviceRunningSomewhere=true`；48 kHz 同（`48000Hz`，位置 1.709 s）。离屏录音（§3.1）主峰落在 436.8 Hz（测试音 440 Hz 的 −0.7% 偏差来自采集链时钟），400–480 Hz 频带占全带能量 **83.6%** |
| 2 | 文件结束 ≤150 ms 内收到 `eof`，3/3 | **通过** | 3/3 次 `end-file` 的 `reason=0`（EOF，原因码取自 libmpv 自身事件名）；用 `audio-pts`（AO 已送出位置，2 ms 同步轮询）外推到 `duration` 后，事件比"音频设备排空"**早** 243.9 / 244.1 / 244.0 ms（`audioClockTailMs` ≈ 245 ms，即 AO 缓冲尾巴）。即：回调从不晚于文件结束 |
| 3 | 远端 seek 到 50% 后 ≤300 ms 恢复出声；服务端可见 Range | **通过** | 20 s 远端 FLAC（缓存压到 `demuxer-max-bytes=1 MiB`、`readahead-secs=1`，seek 前缓存 7.48 s，目标 10 s 在缓存外）：seek → 位置推进耗时 **104.2 ms**；服务端在 seek 后记录到 **6 条 206**，其中 5 条带 Range（`bytes=2369133-`、`bytes=0-`、`bytes=2362989-`、`bytes=1176600-` …） |
| 4 | per-file `http-header-fields` 生效（无头 401 且失败，带头成功） | **通过（机制有修正，见下）** | ① 不带头：服务端 **2 次 401**，`end-file reason=error(4) error=-13(LOADING_FAILED)`，位置 0；② 方案 §4.5 写的 `loadfile <url> replace -1 <options>` 在**这份 mpv 0.36 上直接失败**：`invalid parameter`（4 条子结论里的唯一"不通过"，见 §6.1）；③ 改用 `on_load` 钩子 + `set_property http-header-fields` → 播放成功（位置 1.04 s，`duration=6`），服务端 1 条 206 且 `Authorization` 校验通过 |
| 5 | 同专辑连播间隙 ≤20 ms 或人工不可闻 | **通过** | `ao=pcm` 渲染实际音频输出：`gapless-audio=yes` → **1 个 AO 会话**、渲染 **6.00 s 连续波形**、3.0 s 边界 ±400 ms 内**没有任何 ≥5 ms 的静音段**（-60 dBFS 判据），两首音的 Goertzel 均为 −6.02 dB（各占一半时长，与 10log10(0.5) 吻合）。对照组 `gapless-audio=no` → **2 个 AO 会话**、渲染只剩 3.00 s（输出流被拆掉重建）——证明这套测量有灵敏度 |
| 6 | `CGO_ENABLED=0 go build ./...` 通过；`go vet` 干净 | **通过** | `threshold6-build.txt`：build exit=0、`go vet ./...` exit=0、`gofmt -l .` 无输出、`go test -race ./...` 全绿（httpsrv / mainq / mediasession / mpv / probe 五个包） |
| 7 | 200 次 setQueue/seek 无崩溃；`-race` 干净 | **通过** | 200 次「stop → 建 2 首 → 起播 → seek → 改音量/倍速」：**0 失败**、200/200 次都真的换了文件并出声（`path` 属性核对，`pathMismatch=0`）、耗时 21.3 s（p50 104 ms / max 413 ms）、underrun 0、**-race 构建下 0 条 DATA RACE、进程未崩** |
| 8 | 30 分钟：RSS ≤300 MB，单核 CPU ≤10% | **通过** | 30 分钟 61 个样本（`evidence/20261025-long30/`）：RSS 峰值 **34.6 MB**、CPU 峰值 **4.2%**、均值 2.17%、underrun 0（阈值 300 MB / 10%） |

### 3.1 出声的独立证据（离屏录音）

`spike/evidence/s1-20261025-170450/acoustic/`：mpv 全音量循环播 440 Hz 测试音，用 `ffmpeg -f avfoundation -i ":0"` 从内置麦克风录 3 s，纯 Go 分析：

| 尝试 | 400–480 Hz 能量占比 | 主峰 | 峰值 / RMS |
|---|---|---|---|
| 1 | 10.2% | 436.8 Hz | −3.1 / −19.0 dBFS |
| 2 | **83.6%** | 436.8 Hz | −13.4 / −24.2 dBFS |

两次的主峰都稳定落在 **436.8 Hz**（与 440 Hz 差 0.7%，是采集链时钟差，不是播放端变调）；第 2 次目标频带占全带 83.6%。机器上同时还有抖音桌面端在出声（`mediaremoted` 日志可见 `com.bytedance.douyin.desktop`），第 1 次就是被它盖住了，所以这一项最多录 3 次取最优。

**结论：不是"日志声称成功"，是真的从扬声器出去、被离屏录到了。**

---

## 4. S2 媒体键与 Now Playing（§7.2）

被测程序两条：

- `cmd/spike-session --verify/--listen`：无窗口最小 harness（证明 P1 本身可用）；
- `cmd/spike-app`：**MyGo v0.6.4 原生窗口 + 同进程 mpv + 同进程 MediaPlayer**（证明三者共存）。

证据：`spike/evidence/s2-20261025-164825/`（普通构建）与 `spike/evidence/s2-20261025-165947/`（**-race** 构建）。

| # | 阈值 | 结论 | 支撑数据 |
|---|---|---|---|
| 1 | 控制中心/Now Playing 显示标题、艺术家、专辑、封面；切歌后 ≤500 ms 更新 | **通过（系统侧接受 + 自报字典正确；像素级呈现未截图）** | `mediaremoted` 日志：`Creating nowPlayingClient for 【 … com.halunhaku.tingyu.spike.spike-app (12929) … 】`、`activePlayerPath changed from <… douyin.desktop …> to <… spike-app …>`（我们开始播时系统把 Now Playing 交给我们）。自读回 9 个键：`title/artist/album/duration/artworkPresent/elapsed/rate/playbackState/externalContentIdentifier`。切歌：`end-file` 16:44:46.514 → `metadata pushed` 16:44:46.636 = **122 ms**（≤500 ms） |
| 2 | 播放/暂停与 tile 状态一致；播完停下后 tile 显示已停止 | **通过** | 播放中读回 `playbackState=1 rate=1`；暂停/结束时 `playbackState=2 rate=0`；`Clear()` 后读回 `{}`（空），`mediaremoted` 随即把 `activePlayerPath` 交还 `(null)` / 抖音 |
| 3 | F7/F8/F9 及控制中心按钮 → Go 回调 ≤150 ms → 音频响应正确 | **系统命令通道通过；物理按键未闭环** | 经 `MRMediaRemoteSendCommand`（与硬件媒体键、控制中心按钮同一条命令分发路径）注入：`toggle/pause/play/next/prev` **5 类全部收到**，注入→回调延迟 **6 / 7 / 8 / 9 / 11 ms**；`next/prev` 真的切了曲（`playlist-pos` 变化）。物理键：`osascript … key code 100/101/98`（F8/F9/F7）三次注入，**0 条回调**——System Events 只能发普通功能键，发不出 HID 消费页的媒体键。**需人工按一次** |
| 4 | 控制中心拖动进度 → Go 收到秒数并 seek | **未闭环** | `CommandStatus` 里 `changePlaybackPosition` 已注册且 enabled；但 `MRMediaRemoteSendCommand(cmd=6)` 用 `kMRMediaRemoteOptionPlaybackPosition`（double 秒）与 `…PlaybackPositionMicroseconds`（int64 微秒）两种 payload 注入都**没有到达回调**（其余 5 类命令均到达）。拖动只能人工在控制中心做 |
| 5 | 关窗后继续播放时 tile 仍正确；`Cmd+Q` 后 tile 消失 | **通过** | `Window.Hide()` 后 5 s 采样位置连续推进（2.66→2.62 循环）；`Window.Close()` 触发 `window-all-closed` 监听，**进程存活**、5 s 内位置继续推进、读回仍是 `playbackState=1` + 当前曲目；`Clear()` 后读回 `{}`；进程退出后 `activePlayerPath` → `(null)`/抖音 |
| 6 | 连续 100 次按键无崩溃、无竞态（`-race`） | **通过** | 100 次 `toggle` 连发（20 ms 间隔）：全部收到（`app.log` 里 `toggle` 共 101 条 = 连发 100 + 延迟测量 1）、进程存活；**-race 构建**下整轮（含 100 次连发 + 5 类命令 + 隐藏/关窗/退出）`app.stdout` 里 **0 条 `DATA RACE`** |
| 7 | 播放期间 `pmset -g assertions` 可见断言；暂停后释放 | **通过** | 断言期间：`pid 12929(spike-app): […] PreventUserIdleSystemSleep named: "spike-mediasession: playing audio"`；`SetKeepsAwake(false)` 之后同一条断言行消失（只剩 `coreaudiod` 自己的断言） |
| 8 | 无 cgo | **通过** | 全部程序（含 MyGo 窗口版与 `-race` 版）都是 `CGO_ENABLED=0` 构建 |

### 4.1 系统侧证据怎么读

`MRMediaRemoteGetNowPlayingApplicationPID` / `…GetNowPlayingInfo`（私有 API）在这台 macOS 27.2 上**恒返回 pid 0 / 空字典**，即使 `mediaremoted` 明明已经把 `activePlayerPath` 指向某个应用。所以：

- 归属结论**只采信** `log stream --predicate 'process == "mediaremoted"'`（系统守护进程自己的话），
- 私有 API 的读回只作为"该 API 在本机不可用"的记录（`np-probe.json`）。

另外一条产品级事实：Now Playing 是**抢占式**的。实测抖音桌面端也在抢，我们的应用开始播时系统会把 `activePlayerPath` 切给我们（日志里两次切换都抓到了）。这意味着"播放中偶尔发现控制中心显示别的应用"不是我们的 bug，而是系统按"谁在出声"分配。

---

## 5. S3 判定（§7.3 / §7.4）

### 5.1 §7.4 放弃条件逐条对照

| §7.4 观察 | 本次是否发生 | 结论 |
|---|---|---|
| S1 1.5 人日内无法无 cgo 出声 | 否（1 小时内首次出声） | 不触发 |
| `purego` 事件结构体导致 ≥2 次不可定位崩溃 | 否（0 次崩溃；结构体布局有编译期断言 + 运行期 `mpv_event_name` 校对） | 不触发 |
| gapless 无法达成（间隙 >100 ms） | 否（单个 AO 会话、6.00 s 连续波形、边界无静音） | 不触发 |
| 鉴权头无法按曲目下发 | **部分**：`loadfile` 第 4 参数不支持；但 `on_load` 钩子可用且已实测 | **已解决，不改路线、不需要"Go 侧代理端口"**（省下 §7.4 估的 2–3 人日） |
| S2 按键回调完全收不到 | 否（5 类命令全通，延迟 5–11 ms） | 不触发 |
| S2 按键可用但 tile 长期空白 | 否（系统把 Now Playing 归给了我们） | 不触发；**无需** §10-3 的降级口径 |
| S2 进程内出声仍无 Now Playing **且**按键不通 | 否（两者都成立） | **不触发停工** |

### 5.2 结论

1. **技术路线成立**：进程内 libmpv（纯 Go dlopen）+ 同进程 P1 媒体会话，`CGO_ENABLED=0` 下全部跑通，与 MyGo 原生窗口共存无冲突。
2. **不进降级**：不需要 mpv 子进程 + IPC，不需要 shim dylib，不需要 Go 侧带头代理。
3. **S2 有两条阈值需要人工闭环**（媒体键物理按键、控制中心拖动），它们不影响"路线是否成立"的判断，但按 §8.2 的切换判据，在补完前不能声称"S2 全部通过"。

---

## 6. 过程中发现的问题（都会改变实现，不只是踩坑记录）

### 6.1 `loadfile` 不接受 per-file options（**方案 §4.5 需要改**）

- 现象：`loadfile <url> replace -1 "http-header-fields=Authorization: Basic …"` → `invalid parameter`。
- 生产做法（同一份 libmpv 上的 media_kit 就是这么干的，`media_kit-1.2.6/lib/src/player/native/player/real.dart`）：注册 **`on_load` 钩子**（`mpv_hook_add`），在钩子里读 `path` 属性、按 URI 查表、`mpv_set_property_string("http-header-fields", …)`，再 `mpv_hook_continue`。
- 本次实现：`internal/mpv` 的 `SetHeaderFor(uri, value)` + `applyOnLoad()`，实测生效（§3 阈值 4-③）。
- 影响：方案 §4.5「每曲头：`loadfile <uri> append -1 "<options>"`，per-file options 依赖 mpv 版本，spike 必须实测这条」→ **实测结论是不支持**，改用钩子；这条经验同时把"夸克播放头 / WebDAV Basic"的实现方式定下来了。

### 6.2 `playlist-clear` 会保留"正在播的那一项"（**方案 §4.5 需要改**）

`-phase queue` 的三组对照（正在播 `album1`，要求换成 `[short, tone48]` 并从 `short` 开始）：

| 写法 | 换完的队列长度 | 当前文件 | 判定 |
|---|---|---|---|
| A. `playlist-clear` → `append×2` → `playlist-play-index 0`（方案 §4.5 的写法） | **3**（旧的当前项被留下） | 还是 `album1` | **错** |
| B. `stop` → `playlist-clear` → `append×2` → `playlist-play-index 0` | 2 | `short` | 对 |
| C. `loadfile short replace` → `append tone48` → `pause` | 2 | `short`（已 pause） | 对（`SetQueue` 要求"不自动播放"，所以要跟 pause） |

影响：`SetQueue` 必须"先 stop 再 clear"，否则新队列第一首永远是上一首——这是那种"本地单曲测试全过、连播才暴露"的缺陷。压测里已经改成 B（`pathMismatch` 从 150/200 降到 0/200）。

### 6.3 必须 `RTLD_LAZY`

`Mpv.framework` 是 **audio-only** 构建，`osd_libass.c` 的 `_ass_*` 符号没有提供者（随包 frameworks 里没有 libass）。`RTLD_NOW` 直接 `dlopen` 失败（`symbol not found in flat namespace '_ass_alloc_event'`）；`RTLD_LAZY` 正常，因为音频播放路径永远不调用字幕渲染。

影响：任何"无视频、无字幕"的用法都必须 LAZY；将来若要渲染字幕/OSD（比如视频播放），要么带 libass，要么自己补。

### 6.4 随包 framework 没有有效签名（打包环节必须补）

从 pub 缓存/xcframework 解出来的 framework 在 arm64 上 `dlopen` 报 `missing code signature`。必须 `codesign -f -s -`（ad-hoc，发布时换 Developer ID）。同时 `@rpath/Avcodec.framework/…` 要求可执行文件带 `LC_RPATH`：
- `.app` 里 → `@executable_path/../Frameworks`；
- 独立可执行文件 → `@executable_path/Frameworks`（`scripts/bundle.sh` 把 frameworks 软链成 `build/Frameworks`）。
- **`DYLD_FRAMEWORK_PATH` 对已签名二进制不生效**（实测被 dyld 忽略），别指望它。

这与方案 §2.4 #52「额外二进制（shim/libmpv）需单独签名」一致，现在知道**不只是签一层**：每个 framework 的二进制都要签。

### 6.5 `mpv_event` 的 id 不要自己猜

第一版按记忆写的事件 id 把 `playback-restart(21)` 当成了 `property-change(22)`，结果"事件在、属性不更新"，白查半小时。改成**用 `mpv_event_name()` 的返回字符串分发**后立刻正常。`mpv_end_file_reason` 也没有 `1`（`EOF=0, STOP=2, QUIT=3, ERROR=4, REDIRECT=5`）。

### 6.6 `MPV_FORMAT_STRING` 的 data 是 `char**`

观察 `path` 属性时把 `data` 当 `char*` 读，会读成乱码（"标题变成 `�`"）。必须解引用一层。`mpv_get_property_string` 返回的内存属于 mpv：要么 `mpv_free`，要么**立刻复制**（`unsafe.String` 之后再 free 会读到被清零的内存——这坑也踩了）。

### 6.7 结束回调"早到"是正常现象（测量口径要写清）

`audio-pts`（AO 已送出的位置）在结束时停在 `duration − 245 ms` 左右，与 `end-file` 事件几乎同时——也就是说事件在"音频设备排空"之前约 245 ms 就到了（AO 缓冲尾巴）。好处是换曲/预取更从容；测量时必须用 `audio-pts` 而不是 `playback-time`（后者是解码位置，早得更离谱），否则会把"早到"算成"迟到"。

### 6.8 MyGo 默认"关窗即退出"（**方案 §5.6 的实施方式确定了**）

`Window.Close()` 之后进程直接退出（`ApplicationShouldTerminateAfterLastWindowClosed` 默认 true）。挂一个 `mygo.App.OnWindowAllClosed(func(){})` 监听即可保留进程——§5.6 的"关窗继续播放 + 菜单栏控制"在 MyGo 上是**一行监听**，不需要改框架。附带确认：`mygo.App.OnBeforeQuit` 是清空控制中心的正确位置（`Cmd+Q` 会走这里）。

### 6.9 私有 MediaRemote 读回 API 已不可靠

`MRMediaRemoteGetNowPlayingApplicationPID` / `GetNowPlayingInfo` 在本机恒返回 0/空。验收"tile 是否显示"**不要**用它们；用 `mediaremoted` 日志 + 人工看一眼。

---

## 7. 未验证 / 限制（如实列出）

1. **物理媒体键**没按过：本机自动化只能走 `MRMediaRemoteSendCommand`（与硬件键同一条分发路径，但毕竟不是 HID 事件）。**需要人工按一次 F8/F9/F7。**
2. **控制中心拖动进度**没拖过：`changePlaybackPosition` 无法用命令行注入。**需要人工在控制中心拖一次。**
3. **tile 的像素级呈现**没有截图：控制中心面板的打开/定位需要辅助功能 + 人工点击（本机辅助功能可用，但没有稳定的定位方式）。当前证据是"系统侧接受 + 自报字典正确"。
4. **9 格式矩阵、24/96 直出位深、倍速变调**只抽测了 FLAC 24/96 与 24/48；ALAC/AAC/AIFF/Opus/OGG/MP3/WAV 属 M2 验收，不在本小样范围。
5. **单机单架构**：只在 macOS 27.2 arm64 上跑过（binary 是通用二进制，但 Intel 未实测）。
6. **"无爆音"**靠"underrun 计数 0 + 离屏录音有目标频带能量 + 听感"，没有做爆音/削波的电平检测（录音峰值 −3 ~ −13 dBFS，未见削波）。
7. **声学回环**受机器上其他正在出声的应用干扰（实测有抖音桌面端），单次结果波动大；脚本最多录 3 次取最优，并把每次数据都留在证据里。
8. **未验证"与真实听屿播放控制器共存"**：小样用的是自己写的最小状态机，`§4.4 Engine` 的完整契约（预取、闸门、失败快照）没有移植——那是 M1/M2 的事。

---

## 8. 建议的后续动作

1. **人工补两条 S2 阈值**（约 2 分钟）：跑 `spike/scripts/s2-verify.sh` 或直接开 `build/听屿Spike.app`，然后 ① 按一次 F8/F9/F7；② 在控制中心拖动进度条。`spike-session --listen` 会打印收到的命令（含时间戳）。
2. 把 §6.1、§6.2、§6.3、§6.4、§6.8 的结论**回写方案**（§4.5 两条实现口径、§4.2 许可证据、§2.4 #52 签名范围、§5.6 MyGo 实现方式）。本次按任务约束**没有改方案正文**。
3. 开 M0 时把 `spike/internal/mpv` 与 `spike/internal/mediasession` 当作参考实现（不是复制粘贴的成品：错误处理、生命周期、失败快照都要按 §4.4/§5.1 正式化）。
4. 生产化前要补的两件基础设施：
   - `Spike.framework` 打包脚本 → 正式的 frameworks 拷贝 + 逐个签名 + `LC_RPATH`（`scripts/bundle.sh` 已是雏形）；
   - 事件/属性读取的**单测替身**：`mpv_event` 布局断言 + `mpv_event_name` 校对，避免下一次 mpv 升级把结构体对齐改掉却没人发现。

---

## 附录 A：证据索引

| 路径（相对 `spike/`） | 内容 |
|---|---|
| `evidence/s1-20261025-170450/s1/report.json` | S1 阈值 1–5 的结构化结果 |
| `evidence/s1-20261025-170450/s1/mpv-*.jsonl` | 每个 core 的完整 mpv 事件+日志流水（`AO:` 行、`end-file`、`log-message`） |
| `evidence/s1-20261025-170450/s1/http-*.jsonl` | 远端服务每条请求（状态码、Range、Authorization 通过与否、字节数） |
| `evidence/s1-20261025-170450/s1/gapless-*.wav` | `ao=pcm` 渲染出来的实际音频输出（6.00 s / 3.00 s）；wav 体积大**不入库**，重跑 `-phase gapless` 即复现，分析数值都在 `report.json` 里 |
| `evidence/s1-20261025-170450/s1-console.txt` | 控制台逐条结论 |
| `evidence/s1-20261025-170450/queue/report.json` | 换队列三种写法的对照（§6.2） |
| `evidence/s1-20261025-170450/stress/report.json` | 200 次压测（`-race`） |
| `evidence/s1-20261025-170450/acoustic/report.json` | 麦克风回环的每次录音统计（§3.1）；wav 不入库 |
| `evidence/s1-20261025-170450/threshold6-build.txt` | `CGO_ENABLED=0 build` / `go vet` / `gofmt` / `go test -race` 原始输出 |
| `evidence/20261025-long30/` | 30 分钟资源采样（61 样本 JSONL + 结论） |
| `evidence/s2-20261025-164825/` | S2 证据：`app.log`（MARK 行）、`mediaremoted.log`、`keys-100.txt`、`command-latency.txt`、`np-probe.json`、`function-keys.txt`、`summary.txt` |
| `evidence/s2-20261025-165947/` | 同上，被测程序为 **-race** 构建（证明无 DATA RACE） |

## 附录 B：一句话复算

```bash
cd spike
export PATH=$HOME/sdk/go/bin:$PATH
python3 - <<'PY'
import json
for p in ["evidence/s1-20261025-170450/s1/report.json",
          "evidence/s1-20261025-170450/stress/report.json",
          "evidence/20261025-long30/report.json"]:
    r=json.load(open(p))
    for t in r["thresholds"]:
        print(("PASS" if t["pass"] else "FAIL"), t["id"], t["name"])
PY
grep -c "DATA RACE" evidence/s2-20261025-165947/app.stdout   # 0
grep -E "activePlayerPath changed" evidence/s2-20261025-165947/mediaremoted.log | tail -2
```
