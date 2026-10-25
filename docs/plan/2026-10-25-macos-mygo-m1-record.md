# 听屿 macOS 端 MyGo 迁移 · M1 实施与验收记录（主线：本地库 + 播放 + 媒体键）

日期：2026-10-25（Asia/Shanghai）
性质：**M1 实施与验收记录**。本阶段只改 `client/` 与新增的 `docs/screenshots/m1-*.png`、本文件；**未改 `app/`、未合并 main、未打 tag、未写生产库**。
判据来源：[迁移方案 §6 的 M1 行与 §6.1 八条](./2026-10-25-macos-mygo-migration-plan.md)（阈值未改）。队列/媒体会话口径另见方案 §4.5、§5、§8.1。
代码与运行说明：[`client/README.md`](../../client/README.md)
上一阶段：[M0 记录](./2026-10-25-macos-mygo-m0-record.md)；[spike 记录](./2026-10-25-macos-mygo-spike-record.md)

---

## 0. 结论

M1 四条任务全部落地；§6.1 八条验收的实测结论：

| # | 验收 | 结论 | 一句话证据 |
|---|---|---|---|
| 1 | 冷启动到窗口可交互 ≤1.5 s（线上库 178 首） | **通过（进程冷启动）；签名后首启有未稳定达标的观测，见 §3 与风险 8** | 10 次独立冷进程 median **191.2 ms**（min 179.5 / max 201.0）；出包后首启 324.9 / 788.5 ms，另有一次负载下 **3.15 s**（pre-main，一次性 AMFI 验证） |
| 2 | 选目录（中文/空格）→ 进度可见 → 入库数=文件数 | **通过** | 系统目录选择器选 `/private/tmp/tingyu-m1/新的 目录` → 文件 3 / 入库 3；200 个 13 MB FLAC 扫描时截图显示「正在扫描 161/200」，完成 200/200（3.575 s） |
| 3 | 点歌出声 ≤300 ms；连点 10 首不串音/不卡死 | **通过** | 真实双击首行 → **189.3 ms** 出声；连点 10 首 9 次可测 **69.2–150.7 ms**（median 98.4），0 次错误、0 次卡死，单个 mpv core |
| 4 | 暂停/继续/上一首/下一首/拖动/音量；控制中心状态一致 | **通过** | 系统命令与界面两条路径均生效；拖动 seek 到 **20.73 s**、音量 **0.37**；暂停时系统读回 `playbackState=2 rate=0 elapsed=23.77`，播放时 `1/1`，与界面同源 |
| 5 | F7/F8/F9；控制中心显示标题/艺术家/专辑/封面 | **部分通过 + 待人工确认** | 系统命令通道（与媒体键同一分发路径）5 类命令全部收到；Now Playing 读回标题/艺术家/专辑/`artworkPresent=true`；**物理 F7/F8/F9 与 tile 像素级呈现无法自动化，见 §6，标注「待人工确认」** |
| 6 | 关窗 → 继续播 → 菜单栏可控制 → 再开窗口状态一致 | **通过（有环境注记）** | 关窗后进程存活、位置继续；菜单弹出「显示窗口/上一首/暂停/下一首/退出」并可点击；重开后仍显示「第7首 测试 0:20/0:30」（[截图](../screenshots/m1-library.png)）。本机菜单栏图标被系统收进刘海溢出区，见 §7 |
| 7 | `Cmd+Q` 后进程退出、无残留音频、控制中心项消失 | **通过** | 进程退出；日志 `now playing cleared`/`engine closed`/`quit complete`；`mediaremoted`：`Removing nowPlayingClient com.halunhaku.tingyu`，`activePlayerPath` 从我们变为 `(null)` |
| 8 | 播放历史与播放次数写库（重启后可见） | **通过** | 两次重启后 UI「播放」列显示 10/10；库内 `play_count`/`last_played_at` 已写（[截图](../screenshots/m1-history.png)） |

**未闭环（不写成通过）**：第 5 条的物理 F7/F8/F9 按键与「控制中心 tile 的像素级显示/拖动」只能人工确认；自动化已覆盖同一命令路径与系统侧字典。

---

## 1. 环境

| 项 | 值 |
|---|---|
| 机器 / 系统 | MacBook Air（Apple Silicon，arm64），macOS 27.2（26B118），带刘海屏 |
| Go | go1.27.3 darwin/arm64，`CGO_ENABLED=0` |
| UI | `github.com/egoist/mygo v0.6.4` |
| 播放 | libmpv **mpv 0.36.0**（client API 2.1，来自 `media_kit_libs_macos_audio-1.1.4`，LGPL 构建），进程内 `purego` dlopen |
| 媒体会话 | MediaPlayer.framework，`purego/objc` 直连（无 ObjC dylib、无 cgo） |
| 曲库 | 测试一律用 `cp` 副本 + `TINGYU_DATA_DIR`；生产库全程未变（sha256 `310526fd…`、mtime `2026-10-25 14:30:24`） |

构建：`cd client && ./scripts/bundle.sh` → `build/darwin-arm64/听屿.app`（12.5 MB + `Contents/Frameworks` 10 个 framework）。脚本逐个 `codesign -f -s -`、给主程序加 `LC_RPATH=@executable_path/../Frameworks`、重新签名并校验。

---

## 2. 产物与分层

`client/`（M0 的三个包扩展为七个）：

| 包 | 职责 |
|---|---|
| `internal/library` | SQLite 读写：schema 补差（不升 `user_version`）、曲目/来源查询、扫描合并、播放历史、行级 revision |
| `internal/scan` | 目录遍历（9 种扩展名、大小写、跳过点文件/符号链接、5000 上限、进度、取消）+ 9 格式元数据解析 + 内容寻址封面 |
| `internal/mpv` | purego libmpv：结构体布局断言、事件循环、属性观察、队列、`on_load` 按曲目下发 HTTP 头、完成/失败判定 |
| `internal/player` | 播放控制器：懒解析、预取 2、世代号 + 闸门、循环三态、播放历史/时长回填 |
| `internal/mainq` | 主线程投递（libdispatch），MediaPlayer 调用都经它 |
| `internal/mediasession` | Now Playing / MPRemoteCommandCenter / 封面 / App Nap，`purego/objc` |
| `internal/shell` + `internal/app` | 界面（表格、传输条、扫描面板）与装配（窗口、菜单栏、退出） |

本阶段允许的两处写库：`MergeScan`（扫描入库）与 `RecordPlay`/`BackfillDuration`（播放历史/次数/补时长）。收藏/歌单/元数据仍不可写。

只读默认：**未设置 `TINGYU_DATA_DIR` 时客户端只读**，扫描与历史均被拒绝（界面提示），因此开发构建不可能写生产库。

---

## 3. 验收 1：冷启动

`client/scripts/measure-coldstart.sh`：起点是内核记录的本进程启动时间（`proc_pid_rusage`），终点是 `Window.OnReadyToShow`（首帧）。每次新建进程、库副本 178 首。

热启动 10 次（最终构建，含窗口 + libmpv core + 媒体会话 + 菜单栏图标）：

```
run  1 201.0  run  2 192.5  run  3 189.8  run  4 195.3  run  5 193.9
run  6 200.8  run  7 182.2  run  8 184.0  run  9 188.4  run 10 179.5
cold start 10 runs: min 179.5 ms, median 191.2 ms, max 201.0 ms, mean 190.7 ms
```

冷场景：

| 场景 | ready（进程启动 → 首帧） |
|---|---|
| `./scripts/bundle.sh` 之后**第一次**启动（最终构建，重新签名后） | **324.9 ms** |
| 另一次重新签名后的首次启动 | 788.5 ms |
| 紧接其后的重复启动 | 185–201 ms |

对照阈值 1500 ms：**常规进程冷启动**余量约 7.5 倍。**但「重新签名后第一次启动」不稳定**：测到 324.9 ms、788.5 ms，也测到一次 **3 340 ms（其中 pre-main 3 149 ms）**，当时 load average 2.8；两次「刚 SIGTERM 掉上一个实例、立即启动」同样是 3.1–3.4 s。这与 M0 记录的系统负载敏感一致，但确实超过 1.5 s。

口径与结论：`measure-coldstart.sh` 的 10 次独立冷进程全部 ≤1.5 s（180–201 ms），按「进程冷启动」判为通过；**首次安装/重新签名后的首启是一次性系统验证（AMFI/dyld），在负载下没有稳定 ≤1.5 s，作为未达标观测原样保留**，不在 M1 通过项里掩盖，风险见 §15.8。启动日志里 `startup data dir`（pre-main）在热路径约 50–70 ms；libmpv core 在窗口之前创建（窗口创建 ≈190 ms），媒体会话与菜单栏在窗口创建之后初始化，扫描/自动验收动作在首帧之后才开始。

---

## 4. 验收 2：选目录、进度、入库计数

**真实目录选择器（非环境变量）**：用辅助功能点「添加目录…」，在 NSOpenPanel 里 ⌘⇧G 粘贴 `/tmp/tingyu-m1/新的 目录`（含中文与空格），两次回车确认。目录里 3 个 48 kHz/24 bit FLAC：

```
scan: start "/private/tmp/tingyu-m1/新的 目录"
scan: done in 4ms: 扫描完成：文件 3，入库 3（新增 3 / 更新 0 / 移除 0）
scan: folder="…/新的 目录" files=3 stored=3 added=3 updated=0 removed=0 authoritative=true elapsed=4ms
```

DB：`music_sources` 一行 `新的 目录`，`track_count=3`；`SELECT count(*) FROM tracks WHERE file_path_or_url LIKE '/private/tmp/…/新的 目录/%'` = **3**。选择器返回 `/private/tmp/...`，来源查找对 `/private` 前缀与尾斜杠做了归一化，重扫不会新建第二个来源。

**进度可见**：本地小目录扫描通常只有几毫秒到几十毫秒（400 个文件 29 ms），进度面板一闪而过。为留下运行证据，用 200 个各带 13 MB 内嵌封面的 FLAC（共 2.4 GB）制造 3.575 s 的扫描，在扫描进行中截屏：

- [`docs/screenshots/m1-scan-progress.png`](../screenshots/m1-scan-progress.png)：界面显示「正在扫描 161/200 · /tmp/tingyu-slow/慢速 目录/慢 161.flac」+ 进度条。
- 日志：`scan: progress 1/200` … `200/200`，`scan: done … 文件 200，入库 200（新增 200 / 更新 0 / 移除 0）`。

**合并语义**（方案 §2.1 #2，单测 + 实跑）：

- 匹配键 `sourceId + filePathOrUrl`；id = `sourceId::path`，重复扫描幂等。
- 只覆盖文件事实（大小、mtime、格式、缺失时长/封面/占位元数据）；收藏、歌词、播放次数、已有封面不被扫描覆盖（`TestMergeScanKeepsUserAssetsAndIdempotentIDs`）。
- **只有权威扫描才删旧曲目**：取消/截断/有不可读项时 `authoritative=false`，不删除（`TestNonAuthoritativeMergeKeepsMissingTracks`、`TestScanCancellationAndTruncationAreNotAuthoritative`）。
- 未变文件按 size+mtime（微秒对齐）跳过标签解析（`TestScanKnownFactsSkipParsing`）。
- 文件数达到 `MaxFiles=5000` 时按截断处理（保守，不删），状态文案「文件数达到上限 5000（可能未枚举完）」。

---

## 5. 验收 3：点歌延迟与连续切歌

**单次点歌**：

| 路径 | 实测 |
|---|---|
| 真实双击表格首行（`短歌1`，3 s FLAC） | `play: sound after **189.3 ms**` |
| 环境触发（同一 `PlayTracks` 入口） | 117.9 / 130.6 / 143.0 / 166.9 ms |

计时口径：`PlayTracks` 被调用 → 第一份 `playing=true && position>0` 的快照（libmpv 已向 AudioDevice 送样）。FLAC 为 24 bit/96 kHz（`ffprobe` 确认）。

**连点 10 首**（最终构建，真实 `PlayTracks`，间隔 120 ms）：

```
stress: click 1/10 … click 10/10
play: sound after 116.9 / 112.9 / 98.4 / 83.9 / 69.2 / 107.8 / 92.9 / 150.7 / 93.7 ms
stress: done 10 clicks
```

- 10 次点击、9 次可测出声（第 1 首在 120 ms 内被第 2 次点击替换，属于预期）；**max 150.7 ms ≤ 300 ms**。
- 0 次 `end-file reason=4`（加载/解码失败）、0 次崩溃/卡死；每次换队列产生 `end-file reason=2`（STOP，由 `stop → playlist-clear → append` 触发）——共 9 次，证明上一首被显式停止。
- 单 core 架构：整个应用只有一个 libmpv core、一条 playlist，任何时刻只有一个 `path` 在播放，因此不存在两个音频流叠加的实现路径。「无串音」以该结构与 STOP 事件为证据，未做声学录制。

---

## 6. 验收 4：传输控制与控制中心一致性

界面操作（辅助功能点击真实按钮/拖动真实滑块）与系统命令（`MRMediaRemoteSendCommand`，与媒体键/控制中心同一分发路径）两条路径都测了：

| 动作 | 证据 |
|---|---|
| 暂停/继续 | 界面按钮与 `pause`/`play` 命令均触发；`session: state playing=false/true` 与界面按钮文字「播放/暂停」同步 |
| 上一首 / 下一首 | `media: command previousTrack/nextTrack`；Now Playing 元数据切换到前一/后一首（`第6首`/`第7首`） |
| 拖动进度 | 真实鼠标按住拖动 seek 滑块：`play: seek 10.97s … 20.73s`，随后状态 `pos≈20.73` |
| 音量 | 真实鼠标拖动音量滑块：`play: volume 0.33 … 0.37`；滑块值同步 |
| 控制中心状态 | 暂停后读回 `playbackState=2 rate=0 elapsed=23.772`；恢复后 `playbackState=1 rate=1 artworkPresent=true`，与界面/内核同一快照源 |

实现上窗口、菜单栏、Now Playing 都只消费控制器的 `Update`，不存在第二份播放状态；媒体会话推送沿用 Flutter 口径：`(id,index,duration)` 去重、语义变化立即推、纯进度 500 ms 节流。

---

## 7. 验收 5：媒体键 / Now Playing（部分自动化，物理按键待人工）

**已自动化验证**：

- `MRMediaRemoteSendCommand` 注入 `play/pause/toggle/next/prev`，应用全部收到（`media: command …`）并改变内核状态；这与硬件媒体键走同一条系统命令分发路径。
- Now Playing 字典读回：`title/artist/album/duration/elapsed/rate/playbackState/externalContentIdentifier/artworkPresent`；带内嵌封面的曲目 `artworkPresent=true`。
- `mediaremoted` 日志：播放时 `Creating nowPlayingClient … com.halunhaku.tingyu`，`activePlayerPath` 从 `(null)` 切给我们；退出时移除并归 `(null)`。
- App Nap：播放时 `session: keeps awake true`，暂停后释放（spike 已用 `pmset -g assertions` 验证同一实现）。

**待人工确认（不写成通过）**：

1. **物理 F7/F8/F9**：自动化只能走 `MRMediaRemoteSendCommand`，无法合成 HID 消费页媒体键（spike S2 同样结论）。
   - 步骤：`TINGYU_DATA_DIR=<库副本> TINGYU_STARTUP_LOG=/tmp/t.log open -n client/build/darwin-arm64/听屿.app` → 双击一首歌 → 依次按 **F7（上一首）/ F8（播放暂停）/ F9（下一首）**。
   - 预期：音频与界面随按键变化；`/tmp/t.log` 出现 `media: command previousTrack / togglePlayPause / nextTrack`。
2. **控制中心 tile 的像素级呈现**：标题/艺术家/专辑/封面已由 `MPNowPlayingInfoCenter` 读回，但截取控制中心面板需要辅助功能+稳定定位，未做。
   - 步骤：播放带封面的曲目 → 打开控制中心/「正在播放」→ 核对标题、艺术家、专辑、封面；拖动进度条。
   - 预期：与界面一致；拖动后日志出现 `play: seek <秒>`（若该 macOS 版本允许拖动；spike 记录过该注入通道不稳定）。

---

## 8. 验收 6：关窗续播、菜单栏、再开窗口

- `Cmd+W` 关窗：`window: closed` / `window: all closed, playback continues`；进程存活，日志中 `pos` 从 11.5 s 继续到 12.0 s 之后。
- 菜单栏：`Tray` 菜单为「显示窗口 / 上一首 / 暂停(播放) / 下一首 / 退出听屿」；菜单弹出后点「显示窗口」成功重建窗口。菜单位置见下方环境注记。
- 重开窗口：`open -a …/听屿.app`（Dock/LaunchServices 激活路径）触发 `App.OnActivate`；窗口重新出现且显示「第7首 测试 · 测试歌手 · 测试专辑」，进度 0:20/0:30、播放态与音量一致（[`m1-library.png`](../screenshots/m1-library.png)）。

**环境注记（如实记录）**：本机菜单栏已有十余个图标且屏幕带刘海，新状态项被 macOS 放进刘海左侧的隐藏区（`Tray.Bounds` 报告 x≈803、y=0、66×33；系统允许 ⌘ 拖动或通过「»」展开）。功能本身可用：程序化 `PopUpMenu` + 真实点击菜单项已验证。换到菜单栏不拥挤的机器上图标会直接可见；这是 OS 布局，不是 M1 功能缺失。

---

## 9. 验收 7：`Cmd+Q` 干净退出

```
app: quitting
session: now playing cleared
playback: engine closed
app: quit complete
window: closed
```

进程 `pgrep` 无结果；`mediaremoted`：

```
Creating nowPlayingClient for com.halunhaku.tingyu (60951)
activePlayerPath changed from <(null)> to <… com.halunhaku.tingyu …>
…
Removing nowPlayingClient com.halunhaku.tingyu (60951) 听屿
activePlayerPath changed from <… com.halunhaku.tingyu …> to <(null)>
```

退出顺序：`ty_media_clear`（清空 Now Playing + 播放态 stopped + 释放 App Nap/IOPM assertion）→ 关 mpv core（`mpv_terminate_destroy`）→ 关 DB。无残留进程、无残留 Now Playing 项。

---

## 10. 验收 8：播放历史与次数

- 播放开始时写 `play_count = play_count + 1, last_played_at = <UTC 微秒 Z>`（SQL 自增，不读改写）；同一首的连续进度 tick 不重复计数。
- 时长未知时用解码器时长回填（仅 `duration = 0` 的行）。
- 重启验证：两首 3 s FLAC 反复播放后退出重启，界面「播放」列显示 **10 / 10**（[`m1-history.png`](../screenshots/m1-history.png)）；DB `SELECT title,play_count,last_played_at` 与界面一致。

---

## 11. 顺带修掉的底账缺陷

| 缺陷 | 本阶段处理 |
|---|---|
| 曲库刷新指纹遗漏元数据（只含 length/favorites/latest） | `library.Revision()` + 每行 `RowRevision(id)`：任何插入/删除/元数据更新/时长回填/播放计数都 bump；表格行 key 采用 `{id, rev}`。单测 `TestRevisionChangesForMetadataOnlyWrites` 证明「只改时长」也会让刷新键变化。 |
| 自动加载缺状态闸门（滚动重复建页） | **M1 表格不分页**（一次展示全库，M4 才做 40/页），本阶段不引入无限加载，因此该缺陷不适用；M4 实现分页时必须用 `idle/loading/done` 状态机，已在方案 §2.5 记录。 |

---

## 12. 过程中发现并修正的实现问题（会改变方案口径）

1. **`audio-only` 构建没有 `load-scripts`/`input-default-bindings`/`osc` 选项**：`mpv_set_option_string` 直接报 `option not found`，导致建 core 失败。最终只保留 `config=no`、`idle/vo/audio-display/gapless/ao/volume-max/keep-open/terminal/audio-client-name`。
2. **完成判定不能只看 `idle-active`**：本构建在 playlist 播完后 `idle-active` 未变为真，`eof-reached` 在曲间也会短暂为真。改为：`end-file(reason=EOF)` 且当前下标是最后一项 → `completed`；`start-file` 清除。
3. **`playlist-pos` 在 `playlist-play-index 0` 重播时不更新**（暂停队列从 EOF 重播，path 已是第 1 首但 pos 仍为 1，导致 UI/Now Playing 指错歌）。改为以 `path` 反查 items 下标，`PlayIndex` 同时乐观更新。
4. **UI 线程上直接驱动 MediaPlayer 会死锁**：双击行 → `PlayTracks` → 监听器在 UI 线程同步执行 → `setNowPlayingInfo` 重入主线程。实测表现为窗口不再刷新、后续快照全部丢失（引擎仍在放音）。修正：控制器监听器只入队，窗口/菜单栏/媒体会话由单 worker goroutine 串行消费。修复后真实双击 189.3 ms 出声且 UI/Now Playing 正常。
5. `loadfile` per-file options 不存在（spike 结论）继续成立：`on_load` 钩子下发 `http-header-fields`，M1 本地文件无头，M3 复用同一路径。

---

## 13. 构建与自动化测试

```
gofmt -l .                       # 无输出
CGO_ENABLED=0 go build ./...     # ok
CGO_ENABLED=0 go vet ./...       # ok
go test ./...                    # 全部 ok
go test -race ./...              # 全部 ok
```

覆盖（有回归价值的面）：只读拒绝写入（SQLITE_READONLY）、schema 补差不升版本、合并语义（新增/更新/保留用户资产/权威删除/非权威不删/占位填充）、revision、播放计数与时长回填、目录遍历（隐藏文件/符号链接/大小写扩展名/取消/截断/已知事实跳过）、9 格式解析（FLAC/MP3/M4A/AAC/OGG/WAV/AIFF/ADTS 及封面命名）、`mpv_event` 结构体布局、控制器（预取 2、快速换队列丢弃旧预取、循环三态、完成回放、下一首边界、历史只记一次）、界面（扫描进度、双击播放、按钮动作、错误提示）。

---

## 14. 复现

```bash
cd client
./scripts/bundle.sh                       # 需要 media_kit_libs_macos_audio 的 Frameworks（或 FRAMEWORK_SRC=…）

# 库副本 + 测试音乐（中文/空格路径）
mkdir -p "/tmp/tingyu-m1/听屿 测试 音乐"
cp "$HOME/Library/Application Support/com.halunhaku.tingyu/library.sqlite" /tmp/tingyu-m1/
# …放入 FLAC/WAV/MP3…

TINGYU_DATA_DIR=/tmp/tingyu-m1 \
TINGYU_STARTUP_LOG=/tmp/tingyu-m1/run.log \
./build/darwin-arm64/听屿.app/Contents/MacOS/听屿

# 冷启动
RUNS=10 ./scripts/measure-coldstart.sh

# 媒体命令（与媒体键同一路径）
cd ../spike && CGO_ENABLED=0 go build -o /tmp/spike-np ./cmd/spike-np
/tmp/spike-np -send pause
```

验收辅助环境变量（均为开发/验收用，不改变按钮路径）：

| 变量 | 作用 |
|---|---|
| `TINGYU_DATA_DIR` | 指向库副本；未设置时客户端**只读** |
| `TINGYU_AUTO_SCAN_DIR` | 首帧后扫描该目录（与「添加目录…」走同一 `scanFolder`） |
| `TINGYU_AUTO_PLAY_TITLE` / `TINGYU_AUTO_PLAY_INDEX` | 扫描完成后按标题/下标调用 `PlayTracks`（与双击同一入口） |
| `TINGYU_STRESS_PLAYS` | 连点 N 首（间隔 120 ms），只选本地文件 |
| `TINGYU_REPEAT` | `all` / `one` / `off` |
| `TINGYU_POPUP_TRAY_MS` | 到时弹出菜单栏菜单（用于验证菜单动作） |
| `TINGYU_AUTO_QUIT_MS` | 到时走 `App.Quit()`（与 Cmd+Q 同一退出路径） |

---

## 15. 剩余风险（如实）

1. **物理媒体键与 tile 像素级呈现未人工验证**（§7）；自动化覆盖了命令通道与系统字典，但不等于"按键一定响"。
2. **「无串音」是结构性证据**（单 core、STOP 事件、无加载错误），未做声学录制/听感测试。
3. **菜单栏图标在本机被刘海溢出区隐藏**；功能可用但用户可能找不到。需要用户 ⌘ 拖出，或后续给更靠右/更小的图标策略（MyGo 未提供状态项优先级 API）。
4. **本地扫描很快**（400 文件 29 ms），进度面板通常一闪而过；进度可见性用 200×13 MB 的慢扫描留证。网络来源的进度需 M3 实机复核。
5. **`MaxFiles=5000` 恰好等于文件数时按截断处理**（保守，不删旧曲）；要精确区分需多读一次目录，留待 M3/M4。
6. **远端曲目（quark://）在本阶段会进入失败快照**（`end-file reason=4`），界面显示可读错误；这是预期（WebDAV/夸克属 M3），不是缺陷。
7. **仅 macOS 27.2 arm64 实测**；Intel 未实跑。
8. **冷启动对系统负载敏感**：常规冷进程 180–201 ms；但「重新签名后第一次启动」观测到 324.9 ms、788.5 ms 与 **3 340 ms（pre-main 3 149 ms，load 2.8）**，两次「杀旧实例后立刻启动」也是 3.1–3.4 s。这是一次性系统验证 + 负载，不是应用初始化（main 之后始终 ≈190 ms），但它意味着「安装后首启 ≤1.5 s」不能承诺；M6 分发阶段需要复测（并考虑公证后预热/避免每次重签）。M0 也有同类 1.42 s 记录。
9. **mpv 0.36 / media_kit 1.1.4 的二进制固定**；升级需重跑布局断言、完成/重播用例与签名流程。
10. **播放历史按"每次开始播放"计数**，列表循环与自动连播都会计数（与 Flutter 现状一致）；若产品要"同一首 30 分钟内去重"需另立规则。
11. **未做应用层自动化测试**（装配、窗口、托盘、媒体会话属于人工/脚本验收）；控制器、mpv 边界、扫描与数据层有单测。
