# client/：听屿 macOS 客户端（MyGo）

迁移方案 **M1 + M2 + M3 + M4 + 内核数据能力 + M5 + M6** 的实现：M1 是选目录扫描入库、进程内 libmpv 播放、系统媒体会话（Now Playing / 媒体键）、关窗续播；M2 是内核生产化（9 格式矩阵、远端 Range/鉴权、gapless、循环三态、失败快照、倍速/音量、200 首队列）；M3 是远端来源（WebDAV 全链路、夸克扫码登录/目录/直链与过期刷新、同步进度与取消、Keychain 凭据）；M4 是「声档」设计令牌、全部页面、舞台/队列/歌词与命令面板；内核数据能力补上 M4 留下的五个缺口——**收藏写入、歌单读写、来源删除、随机播放、SQL 分页与聚合**；M5 是**元数据与图片**——四源补全（QQ 音乐 / 网易云 / iTunes / LRCLIB）+ 可选 AI 兜底、人工匹配、封面内容寻址缓存与孤儿回收、封面取色接到舞台、歌词逐行/逐字两种渲染；M6 是分发与质量——**内到外签名、DMG、公证流水线、只跑 macOS 的 Go CI、四类契约测试与键盘可达性**；M7 是切换与收尾——**真实曲库切换（默认读写真实目录）、真实数据备份、删除 Flutter 客户端与残留 Windows 工具链、文档收口**，仓库自此只有这一个客户端。

验收记录与逐条证据：[M1 记录](../docs/plan/2026-10-25-macos-mygo-m1-record.md)、[M2 记录](../docs/plan/2026-10-25-macos-mygo-m2-record.md)、[M3 记录](../docs/plan/2026-10-25-macos-mygo-m3-record.md)、[M4 记录](../docs/plan/2026-10-25-macos-mygo-m4-record.md)、[内核数据能力记录](../docs/plan/2026-10-26-macos-mygo-kernel-data-record.md)、[M5 记录](../docs/plan/2026-10-26-macos-mygo-m5-record.md)、[M6 记录](../docs/plan/2026-10-26-macos-mygo-m6-record.md)、[M7 记录](../docs/plan/2026-10-26-macos-mygo-m7-record.md)。

> Flutter 客户端（`app/`）已在 M7 删除，需要回退时从 tag `archive/flutter-macos` 完整找回；下文出现的「与 Flutter 版一致 / 同源 / 逐字一致」都是移植来源的历史说明，不再是活的约束。

```
client/
├── main.go                      进程入口：只调用 internal/app
├── mygo.json                    应用名、bundle id、版本、最低 macOS、出包目录
├── resources/icon.png           1024×1024 图标
├── internal/
│   ├── library/                 SQLite：schema 补差、分页查询与聚合、收藏/歌单/来源删除、扫描合并、播放历史、补全写回、revision
│   ├── scan/                    目录遍历 + 9 格式元数据 + 内容寻址封面
│   ├── images/                  M5 图片管线：内容寻址封面库、HTTP 抓取与命中统计、解码/缩放、封面取色
│   ├── metadata/                M5 抓取层：QQ 音乐 / 网易云 / iTunes / LRCLIB、OpenCC、AI 兜底、人工候选
│   ├── enrich/                  M5 编排：在途去重、会话配额、封面落盘、人工匹配、孤儿清理
│   ├── titleparse/              文件名智能解析（来源层与补全共用）
│   ├── mpv/                     purego libmpv 绑定与播放内核（失败分类、日志信号）
│   ├── player/                  播放控制器（预取/世代/循环/历史/换队列契约）
│   ├── ui/
│   │   ├── tokens/              「声档」令牌：深浅色、字号、间距、圆角、动效
│   │   ├── model/               视图状态：SQL 分页/排序/过滤、专辑/艺术家/歌单列表、搜索、LRC（逐行/逐字）、取色缓存、补全面板、匹配弹层、设置
│   │   ├── components/          封面、曲目列表（含封面列）、传输条、舞台/歌词/队列、命令面板、人工匹配弹层
│   │   └── pages/               曲库、收藏、专辑、艺术家、歌单、搜索、舞台、队列、歌词、设置、来源、引导
│   ├── shell/                   外壳：侧栏、页面调度、快捷键、装配 Model
│   ├── app/                     装配：窗口、应用菜单、扫描编排、退出
│   ├── sources/                 M3 来源层：WebDAV、夸克（Cookie/扫码/直链）、Keychain 凭据、同步编排、直链刷新
│   ├── sourcemock/              M3 验收用本地协议模拟服务（WebDAV / 夸克，可注入 401/403/503/畸形响应）
│   ├── sourceaccept/            M3 验收 harness（120 首 WebDAV / 扫码 / 直链刷新 / 取消 / Keychain）
│   ├── m5accept/                M5 验收 harness（20 首无标签补全 / 离线 / 封面缓存 / 取色 / 人工匹配 / 截图）
│   ├── rangesrv/                M2 验收用 HTTP 服务：强制 Range、校验 Authorization、可切换 401/403/断网
│   └── accept/                  M2 验收 harness（9 格式 / 远端 / gapless / 队列 / 循环 / 倍速音量）
├── cmd/accept/                  M2 验收 harness 入口（不随产品发布）
├── cmd/sourceaccept/            M3 验收 harness 入口（不随产品发布）
├── cmd/m5accept/                M5 验收 harness 入口（不随产品发布）
├── tools/screenshots/           M4 截图：同一 View 经 ui.Render 渲染各页深/浅
├── scripts/
│   ├── bundle.sh                编译 + 内到外签名 libmpv/FFmpeg frameworks + 组装 .app（DMG/公证可选）
│   ├── verify-bundle.sh         校验签名/spctl/票据/DMG 挂载/干净 HOME 首启
│   ├── fetch-frameworks.sh      下载固定版本（v0.6.0 + sha256）的 mpv/FFmpeg xcframeworks
│   ├── measure-coldstart.sh     在库副本上测冷启动（进程启动 → 首帧）
│   ├── gen-m2-media.sh          ffmpeg 生成 M2 验收媒体（9 格式/gapless/200 首/远端）
│   ├── run-m2-accept.sh         构建并运行 M2 验收 harness，输出 evidence
│   ├── run-m3-accept.sh         构建并运行 M3 验收 harness，输出 evidence
│   ├── run-m5-accept.sh         M5 质量门（gofmt/vet/test/-race）+ 验收 harness
│   └── measure-scroll.sh        M4 10,000 行滚动帧时间与原始采样
└── README.md
```

## 构建

```bash
cd client
./scripts/bundle.sh                 # build/darwin-arm64/听屿.app
PLATFORM=darwin/universal ./scripts/bundle.sh
FRAMEWORK_SRC=/path/to/Frameworks ./scripts/bundle.sh
FRAMEWORK_SRC=$(./scripts/fetch-frameworks.sh) ./scripts/bundle.sh   # 干净机器/CI：先按钉住版本下载 frameworks
```

脚本做的事：

1. `CGO_ENABLED=0 go tool mygo build -platform … -skip-dmg`（有真身份时同时传 `-sign`，让 MyGo 先签 `Contents/Resources`）；
2. 从 `FRAMEWORK_SRC`（默认 pub 缓存里最新的 `media_kit_libs_macos_audio-*/macos/Frameworks`）复制 `Mpv/Av*/Sw*/Mbed*` 10 个 framework 到 `Contents/Frameworks`；
3. **从内到外**签名：每个 framework 的 Mach-O 二进制 → 每个 `.framework` 包 → 主可执行文件 → `.app`。真身份带 `--options runtime --timestamp`，并**不用 `--deep`**（它会覆盖刚做好的内层签名）；
4. 给主程序加 `LC_RPATH=@executable_path/../Frameworks`，重新签名；
5. 校验 Info.plist、图标、SQLite dylib、libmpv、每个 framework 与 app 签名。

### 发布产物（DMG / 签名 / 公证）

```bash
# 开发：ad-hoc，只够本机跑；Gatekeeper 会拒绝，脚本会明说
./scripts/bundle.sh

# 发布：Developer ID 签名 + 签名 DMG + 公证 + 票据装订 + spctl
SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
NOTARY_PROFILE=notary DMG=1 ./scripts/bundle.sh

# 校验（--require-notarized 让未公证的构建判失败）
./scripts/verify-bundle.sh build/darwin-arm64/听屿.app --launch
./scripts/verify-bundle.sh build/darwin-arm64/听屿-0.1.0.dmg --require-notarized
```

- `NOTARY_PROFILE` 是用 `xcrun notarytool store-credentials notary --keychain <keychain>` 存进钥匙串的档案名；凭据**不进仓库、不进日志**。
- 公证顺序：签名 app → 造 DMG → 签 DMG → `notarytool submit --wait` → `stapler staple` DMG **和** app（更新装的是裸 app）→ `stapler validate` → `spctl -a -vv --type execute`。
- 没有真身份时脚本拒绝公证（不会伪造通过）；ad-hoc 构建会显式打印「not distributable」。
- `verify-bundle.sh --quarantine` 会把副本标记成下载件再启动，模拟首次打开：未公证的构建会被 Gatekeeper 拦下，这正是需要凭据的原因。

> 必须用 `RTLD_LAZY`：audio-only 的 `Mpv.framework` 缺 libass 符号；framework 未签名时 arm64 上 `dlopen` 报 `missing code signature`。`DYLD_FRAMEWORK_PATH` 对已签名二进制无效（spike §6.3/§6.4）。

直接跑编译产物（开发，仍需 rpath 才能加载 framework）：

```bash
CGO_ENABLED=0 go build -o /tmp/tingyu .
TINGYU_DATA_DIR=/tmp/tingyu-copy /tmp/tingyu
```

## 数据目录、备份与写库边界

- `library.sqlite`：`TINGYU_DATA_DIR` 指向的目录，否则 `~/Library/Application Support/com.halunhaku.tingyu`（**M7 起这就是真实曲库，客户端默认读写它**）。
- 只读现在是显式选择：`TINGYU_READ_ONLY=1` 打开库但不写它（扫描、收藏、歌单、补全写回、封面清理全部被拒绝并提示）。开发/验收要看真实库又不想动它时用它。
- 开发/验收要**写**时：`TINGYU_DATA_DIR=/tmp/tingyu-copy`，库里 `cp library.sqlite /tmp/tingyu-copy/`，`covers/` 一并复制。
- 备份与退回：M7 切换前把 `library.sqlite`、`covers/`、`settings.json`（存在才复制）备份到 `~/Library/Application Support/com.halunhaku.tingyu/backups/<timestamp>/`，校验和与切换前后对比见 [M7 记录](../docs/plan/2026-10-26-macos-mygo-m7-record.md)。恢复：退出 App，`cp -p backups/<timestamp>/library.sqlite "$HOME/Library/Application Support/com.halunhaku.tingyu/library.sqlite"`，封面目录同理。
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
./scripts/run-scrub-probe.sh               # 拖动 seek 的 Range 请求对比（legacy/view 两种策略）
./scripts/run-m3-accept.sh     # 10 个 check：WebDAV 120 首 + 远端播放/seek + 扫码 + 直链刷新 + 取消 + Keychain
```

## M2 验收 harness

```bash
./scripts/gen-m2-media.sh                 # ffmpeg → build/m2-media（不入库）
./scripts/run-m2-accept.sh                # 全部相位，证据在 build/m2-evidence/<时间戳>/
./scripts/run-m2-accept.sh -phases remote # 单相位：formats|remote|gapless|queue|loops|controls
```

harness 直接驱动生产的 `internal/mpv` + `internal/player`（与应用同一套装配，只是没有窗口），逐项写出 `report.json` 与服务端请求日志。它会真的出声（coreaudio）；gapless 相位改用 mpv 的 `ao=pcm` 把实际输出渲染成 WAV，再分析静音段与 `AO: [` 设备重建次数。
- Now Playing / 远程命令：框架的 `mygo.NowPlaying`（`Set`/`SetPlayback`/`OnCommand`/`Clear`）；`(id,index,duration,封面)` 去重，进度 500 ms 节流；播放时用 `mygo.Power.KeepAwake` 持有 App Nap/防睡眠断言（`pmset` 里是 `PreventUserIdleSystemSleep`），退出清空。
- 关窗继续播放；点击 Dock 图标重新打开窗口。系统「正在播放」提供播放控制；`Cmd+Q` 退出应用。

## 运行与验收辅助变量

| 变量 | 作用 |
|---|---|
| `TINGYU_DATA_DIR` | 覆盖数据目录（指向库副本）；未设置 = 真实目录 |
| `TINGYU_READ_ONLY` | `1`/`true`/`yes`/`on`：本次运行只读，不写选中的库 |
| `TINGYU_STARTUP_LOG` | 启动/运行日志落盘（双击 `.app` 时 stderr 无处可去） |
| `TINGYU_AUTO_SCAN_DIR` | 首帧后扫描该目录（与「添加目录…」同一路径） |
| `TINGYU_AUTO_PLAY_TITLE` / `TINGYU_AUTO_PLAY_INDEX` | 扫描后按标题/下标起播（与双击同一 `PlayTracks`） |
| `TINGYU_STRESS_PLAYS` | 连点 N 首本地曲目（间隔 120 ms） |
| `TINGYU_REPEAT` | `all` / `one` / `off` |
| `TINGYU_AUTO_QUIT_MS` | 到时 `App.Quit()`（与 Cmd+Q 同一路径） |

## CI

`.github/workflows/macos.yml`（只跑 macOS）：`gofmt -l` → `go vet` → `go test -race` → `fetch-frameworks.sh`（固定版本 + sha256） → `bundle.sh`（universal + DMG）→ `verify-bundle.sh`。有 Apple 凭据（`MACOS_CERTIFICATE` 等 6 个仓库 Secrets）时导入临时钥匙串并签名 + 公证，缺凭据时如实降级为 ad-hoc 并在校验步骤说明，不假装公证过。M7 起仓库只有这一个 workflow（`flutter.yml` 已删除）。

## 键盘

Tab 依次到达侧栏导航、侧栏来源/歌单、曲库表格、传输条按钮、页面卡片与列表行；方向键在表格/列表/命令面板内移动；Enter 激活（播当前行、打开导航、切换循环）；Esc 关闭命令面板与舞台。契约与实测见 `internal/shell/keyboard_test.go` 与 [M6 记录](../docs/plan/2026-10-26-macos-mygo-m6-record.md)。

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

M5 新增：四个抓取源的响应解析与占位词过滤、LRCLIB/网易云歌词兜底、OpenCC 逐字转换、AI 回复清洗与错误分类、离线静默语义（`Offline` 与"本地文件名清理"独立）、补全编排的在途请求去重/会话配额/封面失败不阻塞其他字段、`library` 补全写回的最小写入与 revision/revision-row 断言、人工匹配重开连接后仍在、`images` 的内容寻址/孤儿保留共享封面/取色灰兜底与深浅对比度/命中率与失败记忆、歌词 `SpreadWords` 的文本还原/单调时间轴/`WordProgress`、`shell` 的设置页元数据面板与匹配弹层渲染/点击。

## M4 界面

- **令牌**：`internal/ui/tokens` 与 `app/lib/design/tokens` 同源（颜色、13 档字号、4pt 间距、圆角、动效时长）；深/浅两套由 `settings.json` 的 `themeMode` 决定，密度（舒适/紧凑）影响行高、页边距与侧栏宽度。
- **页面**：曲库、收藏（歌曲/专辑两段）、专辑、艺术家、歌单、搜索、舞台、队列、歌词、设置、来源管理、引导。
- **分页**：每页 40，来自 SQL 的 `LIMIT/OFFSET`（曲库/收藏/歌单/搜索用 `TracksPage`，专辑/艺术家用一次 `GROUP BY` 聚合），不再把整表读进内存；滚动近底时按「读到的行 + 2 页」请求一次窗口，翻页只追加新行（`OFFSET=已加载`），所以长列表滚动不是二次方；页面查询在后台 goroutine 上执行、每帧轮询一次，帧里只做切片替换（扫描持写锁时也不会卡住界面）。行键带行级 revision，元数据写回只重建该行；歌单可能收录同一首两次，其行键额外带行号。
- **随机播放**：控制器状态（`SetShuffle`），与循环三态独立；新队列把选中曲目放首位、其余随机；播放中切换只重排「尚未交给引擎」的那一段（前缀不动、不打断当前曲），关闭时按原始列表顺序还原（按重数还原，重复曲目不丢）。
- **舞台**：路由级展开/收起（Esc/返回），封面与传输条封面用 MyGo 的 `Match` 共享元素近似 Hero；歌词随播放高亮并可点行 seek，队列侧栏只读可跳播。
- **命令面板**：⌘K；独立查询与 250 ms 防抖；歌曲/专辑/艺术家 + 快捷入口；↑↓/Enter/Esc。
- **快捷键**：⌘K、⌘F、⌘,、⌘1–4、⌘⇧P、⌘L、⌘U、Space、⌘←/→、⌘⇧←/→（±10 s）、⌘↑/↓（音量）；应用菜单含「听屿/播放/前往」。

## M5 元数据与图片

- **四个真实抓取源**：QQ 音乐（主元数据 + 封面）、网易云（歌词/封面兜底）、iTunes Search（封面最后兜底）、LRCLIB（歌词主来源）。四个都无需账号；接口形状与 Flutter 版 `sources/scraper/*` 一致，繁体歌词经 OpenCC 逐字转简体（同一份 `TSCharacters.txt` 表）。
- **AI 兜底（可选）**：OpenAI 兼容 `/chat/completions`；四源都认不出文件名时清洗标题/艺术家/专辑并重试一次。密钥只存系统钥匙串（账户 `tingyu_ai_settings`，与 Flutter 版同名），不写 `settings.json`、不进日志（只打 `****后四位`）；未配置时整段静默跳过。
- **补全编排**：同一首曲目的自动/播放/单曲触发共用一次在途请求（`internal/enrich` 的 in-flight map）；自动补全每会话最多 60 首；扫描完成与启动各触发一次自动 pass（`TINGYU_ENRICH_AUTO=0` 可关）；封面下载失败只记日志，其余字段照常落库。
- **人工匹配**：曲目右键「匹配元数据…」或舞台上的同名按钮打开弹层：候选（QQ + 网易云，去重）可点击「采用」填入，标题/艺术家/专辑可手改，应用后走同一条 `ApplyEnrichment` 写回并立即刷新列表与舞台；重开进程后仍在。
- **封面缓存**：与 Flutter 版 `CoverStore` 逐字节一致的 FNV-1a 内容寻址命名（`internal/scan/cover.go` 是唯一实现），远程封面下载后落盘、相同内容不重复写；删除来源/曲目后按 `ReferencedCovers` 清理孤儿，共享封面保留。设置页给出命中率、写入/命中/清理计数。
- **封面取色**：`internal/images/palette.go` 直译 `app/lib/features/player/stage_palette.dart` 的规则（24 px 缩略图、12 个色相桶、饱和度/亮度门限、灰封面回退、深浅两套饱和度/亮度钳制、35% canvas 压平、正文 ≥7:1 对比度），LRU 64、键为「文件名 + mtime + 主题」。舞台的 160° 渐变改用主/次色；取色关闭、无封面、灰封面或解码失败时回退 M4 的中性令牌渐变（外观不变）。
- **歌词**：LRCLIB（带时间轴，优先）→ 网易云兜底；解析后把行时长按字宽分摊到每个汉字/拉丁词（`SpreadWords`），所以行级 LRC 也能逐字着色。歌词组件提供「逐行 / 逐字」两种渲染，逐字高亮是播放位置的纯函数（seek 前后画面一致）。
- **立即刷新**：补全写回走 `library.ApplyEnrichment`，每次写入都递增全局与行级 revision；列表/舞台在下一帧按 revision 重读，不需要重启（验收里同一进程前后截图对比）。

### 只读与写入边界

`TINGYU_READ_ONLY=1` 时客户端只读：扫描、收藏、歌单、来源删除、补全写回、人工匹配、封面清理全部被拒绝并给出提示，既不写选中的库也不伪造成功；不加这个变量时真实曲库可写（M7 切换后的常态）。M4 记录里「需内核支持」的五项（收藏写入、歌单读写、来源删除、随机播放、SQL 分页）在内核数据能力阶段全部接通；M5 的元数据匹配与歌词抓取在本阶段接通。

### 性能与截图

```bash
MYGO_FRAME_STATS=all ./scripts/measure-scroll.sh
CGO_ENABLED=0 go run ./tools/screenshots -data /tmp/tingyu-copy -out ../docs/screenshots
```

`measure-scroll.sh` 用 10,000 行、全表遍历、`ui.Tester` 与 MyGo 帧统计给出 p50/p95/p99 并导原始采样；截图走同一个 `View`，用 `ui.Render` 以 1200×760 @2× 渲染深/浅两套；偏好写临时目录，库副本只读。

## 本阶段不做

歌词翻译、艺术家头像、动图 WebP 封面（只取静态帧，动图返回解码失败并回退占位）、**真实的公证通过**（流水线与本地可验证部分已就绪，缺 Apple Developer 凭据，见 [M6 记录](../docs/plan/2026-10-26-macos-mygo-m6-record.md) §7）、Intel 实机验证、读屏无障碍专项（M6 后）。写操作只有确认后的破坏性动作（删除歌单、删除来源）走二次确认弹窗，其余即时生效。
