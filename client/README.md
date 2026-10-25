# client/：听屿 macOS 客户端（MyGo）

迁移方案 **M1 + M4** 的实现：选目录扫描入库、进程内 libmpv 播放、系统媒体会话（Now Playing / 媒体键）、关窗续播，以及「声档」设计令牌、全部页面、舞台/队列/歌词与命令面板。**不实现远端来源**（WebDAV/夸克，M3）、**不做元数据补全与封面取色**（M5）；**不碰 `app/`、不碰内核包**。

验收记录与逐条证据：[`docs/plan/2026-10-25-macos-mygo-m1-record.md`](../docs/plan/2026-10-25-macos-mygo-m1-record.md)。

```
client/
├── main.go                      进程入口：只调用 internal/app
├── mygo.json                    应用名、bundle id、版本、最低 macOS、出包目录
├── resources/icon.png           1024×1024 图标
├── internal/
│   ├── library/                 SQLite：schema 补差、查询、扫描合并、播放历史、revision
│   ├── scan/                    目录遍历 + 9 格式元数据 + 内容寻址封面
│   ├── mpv/                     purego libmpv 绑定与播放内核
│   ├── player/                  播放控制器（预取/世代/循环/历史）
│   ├── mainq/                   主线程投递（libdispatch）
│   ├── mediasession/            Now Playing / 远程命令 / 封面 / App Nap
│   ├── ui/
│   │   ├── tokens/              「声档」令牌：深浅色、字号、间距、圆角、动效
│   │   ├── model/               视图状态：分页/排序/过滤、专辑/艺术家分组、搜索、LRC、设置
│   │   ├── components/          封面、曲目列表、传输条、舞台/歌词/队列、命令面板
│   │   └── pages/               曲库、收藏、专辑、艺术家、歌单、搜索、舞台、队列、歌词、设置、来源、引导
│   ├── shell/                   外壳：侧栏、页面调度、快捷键、装配 Model
│   └── app/                     装配：窗口、应用菜单、扫描编排、退出
├── scripts/
│   ├── bundle.sh                编译 + 拷贝并签名 libmpv/FFmpeg frameworks + 组装 .app
│   └── measure-coldstart.sh     在库副本上测冷启动（进程启动 → 首帧）
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
- 本阶段只有两处写入：
  1. 扫描合并（`library.MergeScan`）：`sourceId + filePathOrUrl` 对齐，只覆盖文件事实，只有权威扫描才删旧曲；
  2. 播放历史/次数（`recordPlay`）与缺失时长回填（`backfillDuration`）。
- `PRAGMA user_version` 固定 2；迁移只建缺失表/索引、只加可空列。
- 封面仍是内容寻址（FNV-1a，`.png/.jpg`），二进制不入库。

## 播放与媒体会话

- 进程内 libmpv（`purego` dlopen，无 cgo）：`idle=yes`、`vo=null`、`gapless-audio=yes`、`ao=coreaudio`。
- 队列：懒解析 + 预取 2 + 世代号 + armed 闸门；换队列 `stop → playlist-clear → append`；`Get` 完成判定用 `end-file(EOF)` + 末项下标。
- 单曲循环下发给内核（`loop-file=inf`），列表循环由控制器重播已装载队列，顺序播完停在末尾。
- 失败只进快照（不抛异常），只有重新出声且位置前进才撤下。
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

覆盖：只读拒绝、schema 补差、扫描合并语义、revision、播放历史/时长回填、目录遍历、9 格式解析、`mpv_event` 布局、控制器队列/循环/完成/预取世代，以及 M4 的分页闸门、刷新保页、搜索防抖、LRC、专辑/艺术家分组、命令面板、舞台展开/收起、歌词高亮/seek、设置落盘与逐页交互。

## M4 界面

- **令牌**：`internal/ui/tokens` 与 `app/lib/design/tokens` 同源（颜色、13 档字号、4pt 间距、圆角、动效时长）；深/浅两套由 `settings.json` 的 `themeMode` 决定，密度（舒适/紧凑）影响行高、页边距与侧栏宽度。
- **页面**：曲库、收藏（歌曲/专辑两段）、专辑、艺术家、歌单、搜索、舞台、队列、歌词、设置、来源管理、引导。
- **分页**：每页 40；滚动近底或「加载更多」触发，`loading/done` 闸门保证一次一页；行键带行级 revision，元数据写回只重建该行。
- **舞台**：路由级展开/收起（Esc/返回），封面与传输条封面用 MyGo 的 `Match` 共享元素近似 Hero；歌词随播放高亮并可点行 seek，队列侧栏只读可跳播。
- **命令面板**：⌘K；独立查询与 250 ms 防抖；歌曲/专辑/艺术家 + 快捷入口；↑↓/Enter/Esc。
- **快捷键**：⌘K、⌘F、⌘,、⌘1–4、⌘⇧P、⌘L、⌘U、Space、⌘←/→、⌘⇧←/→（±10 s）、⌘↑/↓（音量）；应用菜单含「听屿/播放/前往」。

### 只读与需内核支持

未设置 `TINGYU_DATA_DIR` 时客户端仍只读；M4 的外观偏好只在可写副本下落盘。收藏写入、歌单读写、来源删除、元数据/歌词抓取属于内核或后续里程碑，界面会显示「需内核支持」而不是伪造成功；歌单页因此在数据层就绪前不显示假数据。

### 性能与截图

```bash
MYGO_FRAME_STATS=all ./scripts/measure-scroll.sh
CGO_ENABLED=0 go run ./tools/screenshots -data /tmp/tingyu-copy -out ../docs/screenshots
```

`measure-scroll.sh` 用 10,000 行、全表遍历、`ui.Tester` 与 MyGo 帧统计给出 p50/p95/p99 并导原始采样；截图走同一个 `View`，用 `ui.Render` 以 1200×760 @2× 渲染深/浅两套；偏好写临时目录，库副本只读。

## 本阶段不做

远端来源（WebDAV/夸克，M3）、收藏/歌单/元数据的写路径（需内核）、封面取色与元数据补全（M5）、签名公证与 DMG（M6）、Intel 实机验证、读屏无障碍专项（M6 后）。
