# client/：听屿 macOS 客户端（MyGo）

迁移方案 **M1 + M2 + M3 + M4 + 内核数据能力** 的实现：M1 是选目录扫描入库、进程内 libmpv 播放、系统媒体会话（Now Playing / 媒体键）、关窗续播；M2 是内核生产化（9 格式矩阵、远端 Range/鉴权、gapless、循环三态、失败快照、倍速/音量、200 首队列）；M3 是远端来源（WebDAV 全链路、夸克扫码登录/目录/直链与过期刷新、同步进度与取消、Keychain 凭据）；M4 是「声档」设计令牌、全部页面、舞台/队列/歌词与命令面板；内核数据能力补上 M4 留下的五个缺口——**收藏写入、歌单读写、来源删除、随机播放、SQL 分页与聚合**。**不做元数据补全与封面取色**（M5）；不改 `app/`。

验收记录与逐条证据：[M1 记录](../docs/plan/2026-10-25-macos-mygo-m1-record.md)、[M2 记录](../docs/plan/2026-10-25-macos-mygo-m2-record.md)、[M3 记录](../docs/plan/2026-10-25-macos-mygo-m3-record.md)、[M4 记录](../docs/plan/2026-10-25-macos-mygo-m4-record.md)、[内核数据能力记录](../docs/plan/2026-10-26-macos-mygo-kernel-data-record.md)。

```
client/
├── main.go                      进程入口：只调用 internal/app
├── mygo.json                    应用名、bundle id、版本、最低 macOS、出包目录
├── resources/icon.png           1024×1024 图标
├── internal/
│   ├── library/                 SQLite：schema 补差、分页查询与聚合、收藏/歌单/来源删除、扫描合并、播放历史、revision
│   ├── scan/                    目录遍历 + 9 格式元数据 + 内容寻址封面
│   ├── mpv/                     purego libmpv 绑定与播放内核（失败分类、日志信号）
│   ├── player/                  播放控制器（预取/世代/循环/历史/换队列契约）
│   ├── mainq/                   主线程投递（libdispatch）
│   ├── mediasession/            Now Playing / 远程命令 / 封面 / App Nap
│   ├── ui/
│   │   ├── tokens/              「声档」令牌：深浅色、字号、间距、圆角、动效
│   │   ├── model/               视图状态：SQL 分页/排序/过滤、专辑/艺术家/歌单列表、搜索、LRC、设置
│   │   ├── components/          封面、曲目列表、传输条、舞台/歌词/队列、命令面板
│   │   └── pages/               曲库、收藏、专辑、艺术家、歌单、搜索、舞台、队列、歌词、设置、来源、引导
│   ├── shell/                   外壳：侧栏、页面调度、快捷键、装配 Model
│   ├── app/                     装配：窗口、应用菜单、扫描编排、退出
│   ├── sources/                 M3 来源层：WebDAV、夸克（Cookie/扫码/直链）、Keychain 凭据、同步编排、直链刷新
│   ├── sourcemock/              M3 验收用本地协议模拟服务（WebDAV / 夸克，可注入 401/403/503/畸形响应）
│   ├── sourceaccept/            M3 验收 harness（120 首 WebDAV / 扫码 / 直链刷新 / 取消 / Keychain）
│   ├── rangesrv/                M2 验收用 HTTP 服务：强制 Range、校验 Authorization、可切换 401/403/断网
│   └── accept/                  M2 验收 harness（9 格式 / 远端 / gapless / 队列 / 循环 / 倍速音量）
├── cmd/accept/                  M2 验收 harness 入口（不随产品发布）
├── cmd/sourceaccept/            M3 验收 harness 入口（不随产品发布）
├── tools/screenshots/           M4 截图：同一 View 经 ui.Render 渲染各页深/浅
├── scripts/
│   ├── bundle.sh                编译 + 拷贝并签名 libmpv/FFmpeg frameworks + 组装 .app
│   ├── measure-coldstart.sh     在库副本上测冷启动（进程启动 → 首帧）
│   ├── gen-m2-media.sh          ffmpeg 生成 M2 验收媒体（9 格式/gapless/200 首/远端）
│   ├── run-m2-accept.sh         构建并运行 M2 验收 harness，输出 evidence
│   ├── run-m3-accept.sh         构建并运行 M3 验收 harness，输出 evidence
│   └── measure-scroll.sh        M4 10,000 行滚动帧时间与原始采样
└── README.md
```

## 构建

```bash
cd client
./scripts/bundle.sh                 # build/darwin-arm64/听屿.app
PLATFORM=darwin/universal ./scripts/bundle.sh
FRAMEWORK_SRC=/path/to/Frameworks ./scripts/bundle.sh
```

脚本做的事：

1. `CGO_ENABLED=0 go tool mygo build -platform … -skip-dmg`；
2. 从 `FRAMEWORK_SRC`（默认 pub 缓存里最新的 `media_kit_libs_macos_audio-*/macos/Frameworks`）复制 `Mpv/Av*/Sw*/Mbed*` 10 个 framework 到 `Contents/Frameworks`，逐个 `codesign -f -s -`；
3. 给主程序加 `LC_RPATH=@executable_path/../Frameworks`，重新签名；
4. 校验 Info.plist、图标、SQLite dylib、libmpv、每个 framework 与 app 签名。

> 必须用 `RTLD_LAZY`：audio-only 的 `Mpv.framework` 缺 libass 符号；framework 未签名时 arm64 上 `dlopen` 报 `missing code signature`。`DYLD_FRAMEWORK_PATH` 对已签名二进制无效（spike §6.3/§6.4）。

直接跑编译产物（开发，仍需 rpath 才能加载 framework）：

```bash
CGO_ENABLED=0 go build -o /tmp/tingyu .
TINGYU_DATA_DIR=/tmp/tingyu-copy /tmp/tingyu
```

## 数据目录与写库边界

- `library.sqlite`：`TINGYU_DATA_DIR` 指向的目录，否则 `~/Library/Application Support/com.halunhaku.tingyu`。
- **未设置 `TINGYU_DATA_DIR` 时客户端只读**：扫描与播放历史都被拒绝，界面提示。这保证开发构建永远不写生产库（方案 §8.1 第 2 条）。
- 开发/验收：`cp library.sqlite /tmp/tingyu-copy/`，封面目录 `covers/` 一并复制（可选）。
- 写入面（全部经 `internal/app` 的 `write()`，只读连接一律拒绝并提示）：
  1. 扫描合并（`library.MergeScan`）：`sourceId + filePathOrUrl` 对齐，只覆盖文件事实，只有权威扫描才删旧曲；
  2. 播放历史/次数（`recordPlay`）与缺失时长回填（`backfillDuration`）；
  3. 来源行（`library.UpsertSource`，M3 新增的 additive 入口，只写 `music_sources`；`UpsertLocalSource` 未改）；
  4. 收藏（`SetFavorite` / `SetFavorites`）：`tracks.is_favorite`，单条或一批在一个事务里；
  5. 歌单（`CreatePlaylist` / `RenamePlaylist` / `DeletePlaylist` / `AddTracksToPlaylist` / `RemovePlaylistItem` / `MovePlaylistItem`）：位置始终压紧成 `0..n-1`，删除歌单靠外键级联清条目、不动曲目；
  6. 删除来源（`DeleteSource`）：曲目 + 歌单条目（级联）+ `music_sources` 行，随后 `scan.CollectOrphanCovers` 只删除**已无任何曲目引用**的内容寻址封面；凭据由调用方一并清除。
- 凭据（WebDAV 密码、夸克 Cookie）只走系统钥匙串（`mygo.Secrets`，purego 调 Security.framework），服务名 `com.halunhaku.tingyu.sources`，账号名沿用 Flutter 版（`webdav_password_<id>` / `quark_cookie_<id>`）；没有明文回退。
- `PRAGMA user_version` 固定 2；迁移只建缺失表/索引、只加可空列。本阶段新增 5 个**排序索引**（`idx_tracks_sort_*`，只影响顺序，不改列、不动版本号），理由见记录 §3。
- 封面仍是内容寻址（FNV-1a，`.png/.jpg`），二进制不入库。

## 播放与媒体会话

- 进程内 libmpv（`purego` dlopen，无 cgo）：`idle=yes`、`vo=null`、`gapless-audio=yes`、`ao=coreaudio`。
- 队列：懒解析 + 预取 2 + 世代号 + armed 闸门；换队列 `stop → playlist-clear → append`；完成判定用 `end-file(EOF)` + 末项下标（`eof-reached`/`idle-active` 在曲间与结尾都不可靠，M1 §12.2）。
- 解析与追加在同一世代的 `resolveGate` 上串行：预取与「下一首」点击不会把队列顺序或下标搞错；解析失败的曲目被跳过，不会打断整条队列。
- 「下一首」在预取还没追上时会先同步解析一首（最多等 2 秒），否则引擎没有下一项、按钮像坏了；此时**不会**回绕到第一首。
- 单曲循环下发给内核（`loop-file=inf`），列表循环由控制器重播已装载队列，顺序播完停在末尾并可用 `Play` 重播。
- 失败只进快照（不抛异常，不静默）：`Failure` 带 `Kind`（network/unauthorized/not-found/decode）、`Message`（中文可执行提示）、`Detail`（引擎原文）与 HTTP `Status`。分类依据是 FFmpeg 在 mpv 日志里打的 `HTTP error 401` 等行（mpv 自己的错误只有 "Failed to open"）。恢复后（重新出声）才撤下；失败后 `Play()` 会重新 `playlist-play-index`，所以「网络回来了点播放」能继续。
- 每曲头经 `on_load` 钩子下发 `http-header-fields`；切换到无头的曲目会**清空**该属性，避免上一首的 `Authorization` 泄漏给下一个 URL。
- `Close` 先等在途的预取 goroutine 结束再销毁 mpv core（否则预取会把结果 append 到已销毁的内核）。

## M3 来源（WebDAV / 夸克）

- **WebDAV**：`PROPFIND Depth:1` 广度优先，目录间隔 120 ms，幂等请求退避重试（429/503/5xx）；401/403/429/503 与坚果云 `BlockedTemporarily` 的用户文案与 Flutter 版**逐字一致**；根目录 403 视为凭据/路径问题（给"重新登录"），子目录 403 只跳过该目录并计入 `skipped`（整个快照因此不权威）。
- **夸克**：扫码登录（申请 token → 轮询四态 → `service_ticket` 换 Cookie，要求 `__pus`）、Cookie 容器（解析/去重/`Set-Cookie` 回写钥匙串）、目录翻页（缺页或结构异常 = 未取全）、直链（fid 缓存 5400 s）与播放头。**协议按 Flutter 版解析代码复刻，未在真实账号上验证**（见 M3 记录 §8）。
- **同步**：进度可见、可取消；只有权威快照（未取消、未截断、无跳过）才删旧曲；状态文案与 Flutter 版相同（`已同步 / 已取消 / 部分同步`）。取消后写库仍会完成（写库阶段用独立上下文），因此"取消前 120 首、取消后 120 首"有数据库计数可查。
- **播放**：远端曲目仍是一个 URI + 按曲目的头（WebDAV Basic、夸克 Cookie/UA/Referer），Go 不中转音频字节。夸克直链过期时 `sources.Recoverer` 使缓存失效并重新走 `PlayTracks`（因此 mpv 收到的是**不同 URI**，规避同 URI 复用 demuxer）；每首 30 s 冷却，避免失效登录变成重试循环。
- **重新登录**：鉴权失败会写入来源行并在来源卡片显示 `重新登录`，不会静默空列表。
- **凭据**：Keychain 单条上限 2560 B，夸克 Cookie 超限时按 `<key>#N` 分片存；`credentials-keychain` 验收会读回、用 `security find-generic-password` 查属性、并扫描数据目录确认无明文。日志侧同样不落凭据：播放器的调试行只打印头**字段名**（`mpv: per-track headers [Authorization] …`），URL 的查询串与 userinfo 经 `redactURIs` 变成 `<redacted>`。
- 界面为**最小可用**：来源页的 WebDAV 表单、夸克扫码/粘贴 Cookie、进度条与取消、来源卡片重登录入口。网页内嵌登录（WebView）不在本阶段；**来源删除**已由内核数据能力阶段接通（曲目、歌单条目、共享封面与钥匙串凭据的语义见[该阶段记录](../docs/plan/2026-10-26-macos-mygo-kernel-data-record.md) §2.3）。

```bash
./scripts/run-m3-accept.sh     # 10 个 check：WebDAV 120 首 + 远端播放/seek + 扫码 + 直链刷新 + 取消 + Keychain
```

## M2 验收 harness

```bash
./scripts/gen-m2-media.sh                 # ffmpeg → build/m2-media（不入库）
./scripts/run-m2-accept.sh                # 全部相位，证据在 build/m2-evidence/<时间戳>/
./scripts/run-m2-accept.sh -phases remote # 单相位：formats|remote|gapless|queue|loops|controls
```

harness 直接驱动生产的 `internal/mpv` + `internal/player`（与应用同一套装配，只是没有窗口），逐项写出 `report.json` 与服务端请求日志。它会真的出声（coreaudio）；gapless 相位改用 mpv 的 `ao=pcm` 把实际输出渲染成 WAV，再分析静音段与 `AO: [` 设备重建次数。
- Now Playing / 远程命令：`purego/objc` 直连 MediaPlayer；`(id,index,duration)` 去重，进度 500 ms 节流；播放时持有 App Nap 抑制，退出清空。
- 关窗继续播放；`App.OnWindowAllClosed` 保留进程，菜单栏有「显示窗口/上一首/播放暂停/下一首/退出」；`Cmd+Q` 走 `OnBeforeQuit` 清 Now Playing、关 mpv、关库。

## 运行与验收辅助变量

| 变量 | 作用 |
|---|---|
| `TINGYU_DATA_DIR` | 库副本目录；**未设置 = 只读** |
| `TINGYU_STARTUP_LOG` | 启动/运行日志落盘（双击 `.app` 时 stderr 无处可去） |
| `TINGYU_AUTO_SCAN_DIR` | 首帧后扫描该目录（与「添加目录…」同一路径） |
| `TINGYU_AUTO_PLAY_TITLE` / `TINGYU_AUTO_PLAY_INDEX` | 扫描后按标题/下标起播（与双击同一 `PlayTracks`） |
| `TINGYU_STRESS_PLAYS` | 连点 N 首本地曲目（间隔 120 ms） |
| `TINGYU_REPEAT` | `all` / `one` / `off` |
| `TINGYU_POPUP_TRAY_MS` | 到时弹出菜单栏菜单 |
| `TINGYU_AUTO_QUIT_MS` | 到时 `App.Quit()`（与 Cmd+Q 同一路径） |

## 冷启动

```bash
./scripts/bundle.sh
RUNS=10 ./scripts/measure-coldstart.sh
```

实测（Apple Silicon / macOS 27.2，库副本 178 首）：10 次独立冷进程 **min 179.5 / median 191.2 / max 201.0 ms**。重新签名后的**首次**启动是系统一次性验证，测到 325 / 789 / 3 340 ms（最后一次 load 2.8，pre-main 3 149 ms）——不计入常规冷启动，但见 M1 记录风险 8。

## 测试

```bash
CGO_ENABLED=0 go build ./... && CGO_ENABLED=0 go vet ./...
go test ./... && go test -race ./...
```

覆盖：只读拒绝、schema 补差、扫描合并语义、revision、播放历史/时长回填、目录遍历、9 格式解析、`mpv_event` 布局、控制器队列/循环/完成/预取世代/并发追加顺序/关闭时等待预取、扫描进度与双击播放的界面断言；M2 新增失败分类（HTTP 状态、断网、解码、本地缺失）、未知时长 ≠ loading、buffered 钳制、Range/鉴权测试服务的 401/403/chunked/断网语义；M4 新增分页闸门、刷新保页、搜索防抖、LRC、专辑/艺术家分组、命令面板、舞台展开/收起、歌词高亮/seek、设置落盘与逐页交互；M3 新增 WebDAV 解析/文案/取消、夸克分页与不完整目录、扫码四态、直链刷新与冷却、取消不删曲、凭据分片与 Keychain、来源表单与重新登录入口。

内核数据能力新增：SQL 过滤/排序/分页与 10,000 行页查询耗时、专辑/艺术家聚合、`EXPLAIN QUERY PLAN` 的索引断言、歌单全链路（建/加/改名/排序/移出/级联删除）与位置压紧、收藏写入与重开连接后的持久化、删除来源的计数与封面孤儿回收、随机播放的顺序/还原/与循环共存；`internal/shell` 的端到端用例直接点击按钮、用**独立的 SQLite 连接**读回数据作为证据（收藏与取消、歌单全链路、来源删除、随机播放）。

## M4 界面

- **令牌**：`internal/ui/tokens` 与 `app/lib/design/tokens` 同源（颜色、13 档字号、4pt 间距、圆角、动效时长）；深/浅两套由 `settings.json` 的 `themeMode` 决定，密度（舒适/紧凑）影响行高、页边距与侧栏宽度。
- **页面**：曲库、收藏（歌曲/专辑两段）、专辑、艺术家、歌单、搜索、舞台、队列、歌词、设置、来源管理、引导。
- **分页**：每页 40，来自 SQL 的 `LIMIT/OFFSET`（曲库/收藏/歌单/搜索用 `TracksPage`，专辑/艺术家用一次 `GROUP BY` 聚合），不再把整表读进内存；滚动近底时按「读到的行 + 2 页」请求一次窗口，翻页只追加新行（`OFFSET=已加载`），所以长列表滚动不是二次方；页面查询在后台 goroutine 上执行、每帧轮询一次，帧里只做切片替换（扫描持写锁时也不会卡住界面）。行键带行级 revision，元数据写回只重建该行；歌单可能收录同一首两次，其行键额外带行号。
- **随机播放**：控制器状态（`SetShuffle`），与循环三态独立；新队列把选中曲目放首位、其余随机；播放中切换只重排「尚未交给引擎」的那一段（前缀不动、不打断当前曲），关闭时按原始列表顺序还原（按重数还原，重复曲目不丢）。
- **舞台**：路由级展开/收起（Esc/返回），封面与传输条封面用 MyGo 的 `Match` 共享元素近似 Hero；歌词随播放高亮并可点行 seek，队列侧栏只读可跳播。
- **命令面板**：⌘K；独立查询与 250 ms 防抖；歌曲/专辑/艺术家 + 快捷入口；↑↓/Enter/Esc。
- **快捷键**：⌘K、⌘F、⌘,、⌘1–4、⌘⇧P、⌘L、⌘U、Space、⌘←/→、⌘⇧←/→（±10 s）、⌘↑/↓（音量）；应用菜单含「听屿/播放/前往」。

### 只读与写入边界

未设置 `TINGYU_DATA_DIR` 时客户端只读：扫描、收藏、歌单、来源删除全部被拒绝并给出提示，既不写生产库也不伪造成功。M4 记录里「需内核支持」的五项（收藏写入、歌单读写、来源删除、随机播放、SQL 分页）在本阶段全部接通；仍显示「需内核支持」的只剩 M5 的元数据匹配与歌词抓取。

### 性能与截图

```bash
MYGO_FRAME_STATS=all ./scripts/measure-scroll.sh
CGO_ENABLED=0 go run ./tools/screenshots -data /tmp/tingyu-copy -out ../docs/screenshots
```

`measure-scroll.sh` 用 10,000 行、全表遍历、`ui.Tester` 与 MyGo 帧统计给出 p50/p95/p99 并导原始采样；截图走同一个 `View`，用 `ui.Render` 以 1200×760 @2× 渲染深/浅两套；偏好写临时目录，库副本只读。

## 本阶段不做

元数据匹配与歌词抓取的写回、封面取色（M5）、签名公证与 DMG（M6）、Intel 实机验证、读屏无障碍专项（M6 后）。写操作只有确认后的破坏性动作（删除歌单、删除来源）走二次确认弹窗，其余即时生效。
