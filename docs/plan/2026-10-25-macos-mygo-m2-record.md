# 听屿 macOS 端 MyGo 迁移 · M2 实施与验收记录（内核生产化）

日期：2026-10-25（Asia/Shanghai）
性质：**M2 实施与验收记录**。本阶段只改 `client/internal/{mpv,player}` 并新增验收工具（`client/internal/{accept,rangesrv}`、`client/cmd/accept`、两个脚本）；**未改 `internal/shell`、`internal/app`、`app/`，未合并 main，未打 tag，未写生产库**。
判据来源：[迁移方案 §6 的 M2 行与 §4.1 / §4.5 / §8.1](./2026-10-25-macos-mygo-migration-plan.md)（**阈值未放宽**）。
上一阶段：[M1 记录](./2026-10-25-macos-mygo-m1-record.md)（本阶段修掉了 M1 遗留的四个内核缺陷，见 §4）
运行说明：[`client/README.md`](../../client/README.md)
机器可读证据：[`2026-10-25-macos-mygo-m2-evidence.json`](./2026-10-25-macos-mygo-m2-evidence.json)（harness 的 `report.json` 原文）

---

## 0. 结论

| # | 验收（方案 §6 M2 行） | 结论 | 一句话证据 |
|---|---|---|---|
| 1 | 9 格式各播 10 秒并 seek 到 50%，逐项记录 | **通过** | 9/9 格式：播放 10.00–10.16 s，seek 目标 7.0 s 落在 7.02–7.05 s，恢复出声 47–62 ms，0 underrun；每格式各自一条 `AO: [coreaudio] …` 设备初始化行（格式/采样率/位深互不相同） |
| 2 | 远端曲目（本地 Range 校验服务）可播可 seek，服务端可见 `Range` 与鉴权头 | **通过** | 7 次请求全部带 `Range`（服务端缺 `Range` 直接 400）、全部 206、全部带鉴权头；seek 到 12 s 后 6 次新请求、恢复 54 ms；服务端日志见 §3.2 |
| 3 | 按曲目下发鉴权头（`on_load`） | **通过** | 带头可播；下一首不带头的**不同** URL 得到 401，服务端记录 `authorization=""`（头没有泄漏） |
| 4 | 专辑连播无可闻空隙（给出测量方法或声学证据） | **通过** | mpv `ao=pcm` 渲染实际输出：**6.000 s 连续波形、0 段 ≥5 ms 的 -60 dBFS 静音、`AO: [` 设备初始化 1 次**、加载 2 个文件 |
| 5 | 循环三态 + 队列契约（`stop → clear → append`、预取） | **通过** | 不循环：completed 后可重播（重新加载 1 次）；列表循环：下标序列 0→1→2→0 且回绕后仍在播放；单曲循环：3 s 曲目位置回绕 2.74 s→0、无新加载、无 completed；换队列后引擎条目 2 条、旧队列残留 0 条 |
| 6 | 断网 / 直链过期 / 401 出现可读提示，恢复后消失，不抛异常不静默 | **通过** | 401→「直链已失效或没有访问权限（HTTP 401）：请重新获取链接或重新登录」；403 同理；断网→「无法连接到服务器：请检查网络后重试」；三者恢复后 `Failure` 均为 nil 且继续出声 |
| 7 | 连播 200 首队列不错位（顺序、当前下标、完成后状态） | **通过** | 观察到 200 首，第 k 首路径与下标都等于 k，结束时 `completed`、`index=199`、`playing=false`；预取深度 ≥2（本次采样到 3） |
| 8 | 倍速与音量；`buffered` 上报；未知时长 ≠ loading | **通过** | 0.5×→0.54 s/s、1.8×→1.66 s/s；音量 0.35/0.8 精确回读；远端 `buffered` 领先播放位置 23.74 s 且从不小于位置；本地 `buffered`≤时长；duration=0 时仍报 `ready`（单测） |
| 9 | `CGO_ENABLED=0 go build ./...`、`go vet`、`go test`、`go test -race`、`gofmt -l` 全干净 | **通过** | 见 §6 |

`client/internal/{shell,app}` 与 `app/` 的**共享文件零改动**，与并行界面 todo 无冲突。

---

## 1. 环境与构建

| 项 | 值 |
|---|---|
| 机器 / 系统 | Apple M4，macOS 27.2（arm64） |
| Go | go1.27.3 darwin/arm64，`CGO_ENABLED=0` |
| 播放内核 | libmpv **mpv 0.36.0**（client API 2.1，LGPL 构建，来自 `media_kit_libs_macos_audio-1.1.4`） |
| 输出设备 | coreaudio（`ao=pcm` 只用于 gapless 的离线渲染测量） |
| 验收 harness | `client/cmd/accept` + `client/internal/accept`，`./scripts/run-m2-accept.sh` |
| 测试媒体 | `./scripts/gen-m2-media.sh` → `build/m2-media`（ffmpeg 生成，**不入库**） |
| 曲库 | 全程用副本 + `TINGYU_DATA_DIR`；生产库 sha256 前后一致（`shasum -c` 通过） |

一次验收运行的形态：25 个 check、约 132 s（含 9 格式各 10 s 的实际播放）。

---

## 2. 改动范围（只内核侧）

| 文件 | 改动 | 为什么 |
|---|---|---|
| `internal/mpv/player.go` | 失败分类与中文文案、`Failure.Kind/Detail/Status`；`start-file` 重置本次加载的日志信号；`Playing` 不再随 `eof` 抖动；`completed` 只由「末项 `end-file(EOF)`」产生；失败后 `Play()` 重新 `playlist-play-index`；`http-header-fields` 切换曲目时**清空**；`Buffered` 钳制到 `[position, duration]`；`AOInits()`/`LogLevel`；删除无用的 `eof` 观察 | M2 的失败快照、gapless 证据、恢复路径 |
| `internal/mpv/failure.go`（新） | `FailureKind`、`FailureMessage`、`loadFailure`：从 FFmpeg 的 `HTTP error 401` 行、连接类错误、解码错误归类 | mpv 自己的错误只有 "Failed to open"，不分类就无法给出可读提示 |
| `internal/player/controller.go` | 解析/追加按「队列世代」串行（`resolveGate`）；`Next()` 在预取未追上时先同步解析一首（最多 2 s，且**不**提前回绕）；`SetRate`；失败带上曲目标题；`Close` 等待在途 goroutine 再销毁内核 | 队列不错位、按钮不「点了没反应」、退出不崩 |
| `internal/rangesrv`（新） | 本地 HTTP 音频服务：强制 Basic 鉴权、**强制带 `Range`**（无 Range 直接 400）、单段 206、`chunked`（无长度）、401/403 模式、断网后可重启、逐请求 JSONL | 验证远端 Range/鉴权与失败恢复，**不中转音频字节**（播放器直连） |
| `internal/accept` + `cmd/accept`（新） | 验收 harness：9 格式、远端、gapless、队列、循环、倍速/音量/buffered | 让每条验收可复现，且驱动的是生产内核 |
| `scripts/gen-m2-media.sh`、`scripts/run-m2-accept.sh`（新） | 生成媒体 / 构建并运行 harness（含 LC_RPATH 与 ad-hoc 签名） | 复现 |

未改：`internal/shell/**`、`internal/app/**`、`app/**`、`client/main.go`、`mygo.json`、`go.mod`。

---

## 3. 逐条验收

### 3.1 九格式矩阵

每个格式：播放到 10 s，再 seek 到该文件时长的 50%。

| 格式 | 时长 | 已播 | seek 目标 | seek 后位置 | 恢复出声 | underrun | 音频设备（AO 行） |
|---|---|---|---|---|---|---|---|
| mp3 | 14.03 s | 10.05 s | 7.01 s | 7.04 s | 61 ms | 0 | `44100Hz mono floatp` |
| flac（24/96） | 14.00 s | 10.00 s | 7.00 s | 7.04 s | 62 ms | 0 | `96000Hz mono s32` |
| m4a（AAC） | 14.02 s | 10.02 s | 7.01 s | 7.03 s | 47 ms | 0 | `44100Hz mono floatp` |
| aac（ADTS） | 14.04 s | 10.02 s | 7.02 s | 7.05 s | 61 ms | 0 | `44100Hz mono floatp` |
| wav | 14.00 s | 10.04 s | 7.00 s | 7.03 s | 62 ms | 0 | `44100Hz mono s16` |
| ogg（Vorbis） | 14.00 s | 10.01 s | 7.00 s | 7.02 s | 56 ms | 0 | `44100Hz stereo floatp` |
| opus | 14.01 s | 10.00 s | 7.00 s | 7.02 s | 50 ms | 0 | `48000Hz mono floatp` |
| aiff | 14.00 s | 10.04 s | 7.00 s | 7.03 s | 61 ms | 0 | `44100Hz mono s16` |
| alac | 14.00 s | 10.16 s | 7.00 s | 7.03 s | 61 ms | 0 | `44100Hz mono s16p` |

每个格式独占一个 mpv core（这样那条 `AO: [coreaudio]` 行只属于这个文件），通过同一个 `PlayTracks` 入口起播；换队列路径由 `queue-replace` 相位单独验证。

### 3.2 远端播放、Range 与按曲目鉴权

测试服务：`internal/rangesrv`，要求 `Authorization: Basic …`、要求请求带 `Range`（缺失即 400，单测 `TestRequireRangeRejectsAPlainGet`），只支持单段 Range，记录每个请求。

鉴权头仍然只能经 `on_load` 钩子下发：mpv 0.36 的 `loadfile` 不接受第 4 个 per-file options 参数（spike 实测 `invalid parameter`），钩子里设 `http-header-fields` 是同一份 libmpv 上 media_kit 的做法。24 s / 96 kHz / 24 bit FLAC（4.0 MB，大于 1 MB 的 demuxer 缓存，所以 seek 必须重新取字节）。

播放与 seek（`remote-play`）：

```
requests=7  rangeRequests=7  partialResponses=6  requestsAfterSeek=6
position=2.03s → seek 12.00s → positionAfterSeek=12.02s, seekResumeMs=54
从起播到累计 2 秒音频用时 2076 ms（含连接、Range 与解码启动）
```

服务端请求日志（`remote-requests.jsonl`，节选）：

```
allow     206 bytes=0-        auth=Basic …  2315372
allow     206 bytes=2043752-  auth=Basic …  1015808
allow     206 bytes=2035353-  auth=Basic …  1818156
allow     206 bytes=4063648-  auth=Basic …  15361
allow     401 bytes=0-        noauth        13        ← 另一首不带头的 URL
forbidden 403 bytes=0-        auth=Basic …  13        ← 直链过期
chunked   200 bytes=0-        auth=Basic …  194617    ← 无 Content-Length
```

按曲目下发鉴权头（`remote-auth`）：**另一个** URL、不带任何头。

```
lastRequestAuthorization=""   lastRequestStatus=401
failure="直链已失效或没有访问权限（HTTP 401）：请重新获取链接或重新登录"
failKind=unauthorized  playingAfterFailure=false
```

> 为什么不复用同一个 URL 测「头没有泄漏」：实测 mpv 在**同一 URI** 被重新加载时会复用已有 demuxer，可能不发新请求（M2 过程中真实踩到，见 §4.5）。换 URL 才是确定性的验证。

### 3.3 gapless（同专辑连播）

方法（两侧证据）：

1. **声学侧**：mpv `ao=pcm` 把实际输出渲染成 WAV（`gapless-rendered.wav`），再分析 ≥5 ms、≤-60 dBFS 的静音段。两首 3 s FLAC 是同采样率同格式、440 Hz（3 s 正好整数周期，边界相位连续），所以边界处任何静音都是真实空隙。
2. **结构侧**：计数 mpv 日志里的 `AO: [coreaudio]` / `AO: [pcm]` 行数——每重建一次音频设备就是一次可闻缝隙的来源；同时确认加载了 2 个文件。

结果：

```
renderedSeconds=6.000  renderedPeakDBFS=-21.06  silenceRuns=0  aoInits=1  filesLoaded=2  completed=true  渲染耗时 18 ms
```

对照（spike 已建立测量灵敏度）：`gapless-audio=no` 时同一方法看到 2 次 `AO:` 重建。

### 3.4 循环三态与队列契约

| 模式 | 观测 |
|---|---|
| 不循环 | 播完 `processing=completed`、`playing=false`、`index=1`（末项）；按播放后重新加载 1 次并继续出声（`filesReloaded=1`） |
| 列表循环 | 下标序列 `0 → 1 → 2 → 0`，回绕后 `playing=true`（控制器用 `PlayIndex(0)` 重播已装载队列，不重新解析） |
| 单曲循环 | 3 s 曲目：位置到 2.74 s 后回绕、路径不变、`filesLoadedDelta=0`、无 `completed`（内核 `loop-file=inf`，无缝） |

换队列契约（`queue-replace`）：先播 A 组 3 首，再播 B 组 3 首；切换后引擎 playlist 里 2 条、全部属于新队列（预取随后补到 3），**旧队列残留 0 条**，第一条是 B 的第一首。实现仍是 `pause → stop → playlist-clear → append → playlist-play-index`（`playlist-clear` 会保留当前项，spike §6.2）。

预取：200 首连播期间采样到引擎 playlist 最多领先当前项 **3** 条（预取目标是 2，采样时刻落在两次追加之间时会看到 3）。

### 3.5 失败快照

| 场景 | 快照 | 恢复 |
|---|---|---|
| 401（缺鉴权头） | `kind=unauthorized`、`status=401`、`Message` 为中文可执行提示、`playing=false` | — |
| 403（直链过期） | `kind=unauthorized`、`status=403`、同一句式（带状态码） | 服务恢复 → `Play()` → 出声（位置 0.06 s）、`Failure=nil` |
| 断网（连接被拒） | `kind=network`、「无法连接到服务器：请检查网络后重试」 | 服务重启 → `Play()` → 出声（位置 0.02 s）、`Failure=nil` |
| 本地文件消失 | `kind=not-found`（单测） | — |
| 本地不可解码 | `kind=decode`（单测） | — |

失败不上抛：控制器只把 `Failure` 放进 `Update`；harness 全程没有收到异常。失败撤下的条件仍是「重新出声且位置前进」，与 M1 口径一致。

### 3.6 倍速、音量、buffered、未知时长

| 项 | 实测 |
|---|---|
| 0.5× | 2.0 s 墙钟内位置前进 1.09 s（0.54 s/s；±35% 容差内） |
| 1.8× | 2.0 s 内前进 3.32 s（1.66 s/s） |
| 复位 | `Snapshot.Rate` 回到 1.00 |
| 音量 0.35 / 0.80 | 内核回读 0.35 / 0.80 |
| buffered（本地） | 位置 5.40 s、buffered 11.87 s、时长 14 s；从不小于位置、从不超时长 |
| buffered（远端） | 75 次采样最大领先 23.74 s；`buffered` 结束等于 24 s（时长） |
| 未知时长 ≠ loading | 无 `Content-Length` 的 ADTS 流可播，播放中 `processing=ready`；`duration=0` 时仍 `ready` 由 `internal/mpv` 的 `TestDurationZeroIsReadyNotLoading` 直接锁定 |

> 口径说明：ADTS 容器本身不含时长，但 mpv 会按码率**估算**出 12 s，所以这条活体验收证明的是「缺 `Content-Length` 不影响播放与状态」，真正的 `duration=0` 由单测覆盖。原任务书里的「未知时长」指的就是 `duration<=0` 不能当 loading 依据。

### 3.7 200 首连播

200 段 0.2 s WAV，倍速 2× 跑完 21.2 s。

```
observed=200  queueLength=200  completed=true  indexAtEnd=199  playingAtEnd=false
processingAtEnd=completed  prefetchDepthMax=3  failure=""
```

校验方式：订阅引擎快照，按路径变化记录 `(index, path)`；第 k 个观察的路径必须等于队列第 k 项、下标必须等于 k。任何漏解析、乱序追加、下标漂移都会命中。

---

## 4. 过程中发现并修掉的缺陷（会改变实现口径）

1. **曲间误报 `completed`**：M1 的 `Processing` 在 `eof && idle` 时也算完成，而 `eof-reached` 在 gapless 曲间会短暂为真 —— 不循环模式下会导致整张专辑在第二首之前被暂停。现在完成只由「末项 `end-file(EOF)`」产生，`eof-reached` 观察一并删除（M1 记录 §12.2 的结论这下真正落地）。
2. **失败提示不可读且无法恢复**：M1 直接把 `loading failed: Failed to open http://…` 写进 `Failure.Message`；失败后 `Play()` 只是 `pause=no`，对空闲内核是空操作（死按钮）。现在分类出 `kind/status` + 中文提示，且 `Play()` 会重新 `playlist-play-index`。
3. **`http-header-fields` 从不清空**：切到不带头的曲目时，上一首的 `Authorization` 仍留在内核属性里 —— 实测服务端能看到它被发给下一个 URL。现在每次 `on_load` 都按目标曲目的头设置（无头则置空）。
4. **退出时预取打到已销毁的内核**：gapless 验收时真实触发 `SIGSEGV`（场景是把播放循环与关闭挤在一起）。`Controller.Close` 现在等待在途的预取/事件 goroutine，再 `mpv_terminate_destroy`；预取槽位与 `closed` 在同一把锁里预留，避免 `sync.WaitGroup` 的 Add/Wait 竞争。
5. **同一 URI 重新加载时 mpv 可能复用 demuxer**：这不是我们的缺陷，但会误导验收（以为头没清空）。记录在案：鉴权/换源验收必须换 URL；M3 的直链刷新通常换 URL，若某来源对同一 URL 轮换令牌，需要在 M3 复测。
6. **`Next()` 在预取滞后时不前进**：M1 直接 `playlist-next`，解析没追上时引擎没有下一项，按钮像坏的；早期 M2 版本又会错误地回绕到第一首。现在先同步解析一首（最多等 2 s），只有整条队列都装进引擎才允许回绕。
7. **`Buffered` 未钳制**：`demuxer-cache-time` 可能越过文件末尾或（seek 后）落后于位置，进度条会出现「缓冲超过时长」。现在钳制到 `[position, duration]`。

---

## 5. 与方案口径的对照

| 方案要求 | 本阶段处理 |
|---|---|
| 阈值不放宽 | 9 格式 10 s / seek 50%；远端 seek ≤300 ms（实测 54 ms）；队列 200 首；gapless「≤20 ms 或人工不可闻」（实测渲染静音段 0 个） |
| gapless 跨格式/跨采样率不保证（§4.1、§2.2 #14） | 验收只声明同专辑、同采样率、同格式；`gapless-scope` 检查把该口径显式写进报告 |
| 单曲循环必须下发内核（§2.2 #17） | `loop-file=inf`；实测位置回绕且无新加载 |
| 队列重建不打断/不残留（§2.2 #16、§4.5） | `stop → clear → append`，逐项验证残留 0 条 |
| 失败不抛异常、只有重新出声且位置前进才撤下（§2.2 #19） | 保持 M1 规则；失败分类只影响文案 |
| 未知时长 ≠ loading（§2.2 #20） | 规则保留（`duration<=0` 不作 loading 依据），并由单测锁定 |
| 鉴权头按曲目、Go 不中转音频字节（§4.1、§3.5） | `on_load` 下发 `http-header-fields`；音频由播放器直连服务，Go 侧不发额外网络请求，只在失败时读 mpv 已输出的日志行判因 |

---

## 6. 自动化检查

```
cd client
gofmt -l .                        # 无输出
CGO_ENABLED=0 go build ./...      # ok
CGO_ENABLED=0 go vet ./...        # ok
CGO_ENABLED=0 go test ./...       # ok
CGO_ENABLED=0 go test -race ./... # ok
```

新增回归测试（都在真实契约上，不测文案装饰）：

| 测试 | 锁定的行为 |
|---|---|
| `mpv.TestFailureMessagesAreActionable` | 每种失败给出不同、可执行的提示；HTTP 状态出现在提示里 |
| `mpv.TestLoadFailureReadsFFmpegsHTTPStatus` | 401/403/404/连接被拒/DNS/解码 从日志正确归类 |
| `mpv.TestLocalFailureDistinguishesMissingFromUndecodable` | 本地缺失 vs 不可解码 vs 远端未定 |
| `mpv.TestDurationZeroIsReadyNotLoading` | `duration=0` 仍 `ready`；缓存等待才是 `buffering`；空队列 `idle` |
| `mpv.TestCompletionOnlyComesFromEndFileAtTheLastEntry` | 曲间不报完成 |
| `mpv.TestBufferedIsClampedToTheDuration` | 缓冲不越界、不后退到位置之前 |
| `player.TestNextResolvesBeforeAdvancing` | 预取滞后时「下一首」仍前进 |
| `player.TestNextDoesNotHangBehindAStuckPrefetch` | 点击最多等 2 s，且不提前回绕 |
| `player.TestConcurrentPrefetchKeepsQueueOrder` | 6 个并发追加者不会乱序/重复 |
| `player.TestCloseWaitsForThePrefetch` | 关闭等待在途预取，引擎关闭后不再有 SetQueue/Append/Play |
| `player.TestEngineFailureGetsTheTrackTitle` | 失败带上曲目标题，重新出声后撤下 |
| `rangesrv.*` | 鉴权、单段 Range/206、**无 Range 即 400**、401/403/chunked、断网后重启、目录穿越 |

应用层冒烟（真实 `.app`，库副本）：

```
playback: libmpv Mpv client API 2.1
scan: done in 19ms: 扫描完成：文件 2，入库 2（新增 0 / 更新 0 / 移除 0）   ← 同一目录二次扫描是幂等的
play: sound after 178.1 ms for "第二首"（mp3）
play: sound after 119.0 ms for "测试 曲目"（24/96 FLAC，第一次冒烟）
进程退出码 0；生产库 sha256 校验通过（未被写）
```

---

## 7. 复现

```bash
cd client
./scripts/gen-m2-media.sh                   # ffmpeg → build/m2-media（14 s ×9、gapless 3 s×2、200×0.2 s、远端 24 s）
./scripts/bundle.sh                         # 提供 libmpv/FFmpeg frameworks
./scripts/run-m2-accept.sh                  # 全部 25 个 check
./scripts/run-m2-accept.sh -phases remote   # 单相位：formats|remote|gapless|queue|loops|controls
```

输出：`build/m2-evidence/<时间戳>/report.json`、`remote-requests.jsonl`、`gapless-rendered.wav`（均不入库）。本记录引用的报告已复制为 [`2026-10-25-macos-mygo-m2-evidence.json`](./2026-10-25-macos-mygo-m2-evidence.json)。

---

## 8. 剩余风险（如实）

1. **「无可闻空隙」是渲染波形 + 设备重建计数的证据**，没有做麦克风回环录音；本机听感未单独打分（spike 做过麦克风回环，同一实现）。
2. **同一 URI 重新加载**：mpv 可能复用 demuxer、不触发新的 `on_load`（§4.5）。对「同一文件重播」无影响（头不变）；对「同一 URL 换令牌」有风险，需 M3 在真实直链刷新路径复测。
3. **失败归依赖 FFmpeg 的日志行**（`HTTP error NNN`、连接类文案）。若将来的 libmpv/FFmpeg 构建不再打这些行，提示会退化回「播放失败：<引擎原文>」，不会更糟但也不分类。mpv 自己的错误字符串只有 "Failed to open …"（0.36 实测），状态码只出现在 FFmpeg 的日志行里。
4. **只测 macOS 27.2 arm64**；Intel 未实跑。远端实验都在 loopback，真实网络延迟/丢包下的失败时延未测（M3 的来源层负责超时与重试）。
5. **200 首的连播用 2× 倍速、0.2 s 短文件**，验证的是队列/下标/完成状态，不是长时间稳定性；M1 的 10 连点与 spike 的 200 次压测仍是对应的稳定性证据。
6. **`Failure` 目前只有内存态**，不落盘、不弹通知；界面显示仍由 M4 的 shell 呈现（`Message` 已是可直接展示的中文句子）。
7. **倍速测量**用位置推进近似（2 s 窗口），实际 0.54 / 1.66 s/s 略偏离 0.5 / 1.8，属于 mpv 变速的启动与采样误差，不是路由问题。
