# client/：听屿 macOS 客户端（MyGo）

这是迁移方案 M0 的骨架（方案 §6）：一个 Go 模块、可重复出包的 `.app`、只读打开线上曲库、`ui.Table` 外壳。**不实现播放、扫描入库、媒体键**（M1），**不碰 `app/`**。

```
client/
├── main.go                      进程入口：只调用 internal/app
├── mygo.json                    应用名、bundle id、版本、最低 macOS、出包目录
├── resources/icon.png           1024×1024 图标位（占位图）
├── internal/
│   ├── library/                 数据访问：只读打开 + user_version 校验 + 读曲目
│   ├── shell/                   UI 外壳：侧栏 + ui.Table（不含窗口与数据库）
│   └── app/                     应用装配：数据目录、冷启动打点、窗口
├── scripts/
│   ├── bundle.sh                编译 + 组装 .app + 校验 Info.plist/图标/dylib/签名
│   └── measure-coldstart.sh     在库副本上测冷启动（进程启动 → 首帧）
└── README.md
```

## 构建

```bash
cd client
./scripts/bundle.sh                 # build/darwin-arm64/听屿.app
PLATFORM=darwin/universal ./scripts/bundle.sh
```

脚本做的事：`CGO_ENABLED=0 go tool mygo build -platform … -skip-dmg`（MyGo CLI 见 `go.mod` 的 `tool` 指令），然后读取 `mygo.json` 校验 `CFBundleIdentifier=com.halunhaku.tingyu`、`LSMinimumSystemVersion=12.0`、`CFBundleName=听屿`、`AppIcon.icns`、`libmygo-sqlite3.dylib`，最后 `codesign --verify`。签名是 ad-hoc（方案 §6.1 的签名/公证在 M6）。

直接跑编译产物（开发）：

```bash
CGO_ENABLED=0 go build -o /tmp/tingyu .
TINGYU_DATA_DIR=/tmp/tingyu-m0 /tmp/tingyu
```

## 数据目录与只读保证

- `library.sqlite` 位置：`TINGYU_DATA_DIR` 指向的目录，否则 `~/Library/Application Support/com.halunhaku.tingyu`（`internal/library.DataDir`）。
- **开发/验收一律指向副本**（方案 §8.1 第 2 条）：`cp library.sqlite /tmp/tingyu-m0/`，再设 `TINGYU_DATA_DIR=/tmp/tingyu-m0`。
- 只读的三道保证：
  1. `internal/library.Open` 用 `sqlite.OpenOptions{ReadOnly: true}`，MyGo 的 SQLite 插件把它翻成 `SQLITE_OPEN_READONLY`（`plugins/sqlite/database.go` 的 flags `0x1`）；
  2. 整个 `internal/library` 只发 `PRAGMA user_version` 与 `SELECT`，没有任何 `Execute`/`Transaction` 调用，包注释即契约；
  3. `library_test.go` 在只读连接上执行 `CREATE TABLE`，断言返回 `sqlite.Error` 且 `Code == 8`（`SQLITE_READONLY`）。
- 缺文件不创建、`user_version != 2` 不迁移，只在窗口里报错。

## 冷启动

```bash
./scripts/bundle.sh
RUNS=10 ./scripts/measure-coldstart.sh
```

打点：`TINGYU_STARTUP_LOG=<file>` 打开启动日志（双击 `.app` 时 stderr 无处可去）。时间点：

| 打点 | 含义 |
|---|---|
| `data dir` | main 开始（`process start` 由 `proc_pid_rusage(RUSAGE_INFO_V2).ri_proc_start_abstime` 经 `mach_timebase_info` 换算，purego 直调，无 cgo） |
| `library read` | 只读打开 + 读出全部曲目（M0 是 178 首） |
| `window created` | `mygo.NewWindow` 返回（最小 900×600） |
| `ready` | `Window.OnReadyToShow`：首帧已画，作为"可交互" |
| `focused` | 窗口获得焦点 |

实测（本机 Apple Silicon / macOS 27.2，库副本 178 首）：热启动 10 次 **min 182.2 ms / median 187.5 ms / max 253.6 ms**；重新出包后首启 399–428 ms（3 次）；双击（`open -n`）292.8 ms；最冷的一次（首次生成 bundle 后立刻启动）1424.9 ms。方法、逐次原始值与分解见 `docs/plan/2026-10-25-macos-mygo-m0-record.md`。

## 与 spike/ 的关系

`spike/`（在分支 `tds/conv-01a1721f-…`，尚未合入 main）验证的是 libmpv/媒体键；M0 不搬运它的代码，只沿用两条已证实的做法：

| 项 | spike | client（本目录） |
|---|---|---|
| Go 版本/构建 | go1.27.3，`CGO_ENABLED=0` | 同 |
| purego | dlopen libmpv、MediaPlayer | 仅 `internal/app/process_darwin.go` 读进程启动时间，生产分层独立 |
| 打包 | 手写 `scripts/bundle.sh`（frameworks、LC_RPATH、ad-hoc 签名） | `mygo.json` + `mygo build`，SQLite dylib/图标/plist/签名由官方 CLI 落盘，仓库脚本只做校验 |
| 数据层 | 无 | `internal/library`（只读、`user_version` 校验、无写路径） |
| UI | `spike` 里没有 `cmd/spike-app` 的源码（README 提到，commit 里缺） | MyGo `ui` 原生外壳：侧栏 + `ui.Table` |
| 播放/媒体键 | S1/S2 原型 | **不实现**，M1 |

## 本阶段不做

播放、队列、媒体键、Now Playing、扫描入库、封面、搜索、其它页面（侧栏标 `M4`）、签名/公证/DMG（M6）、写库与迁移（M1/M7）。窗口状态持久化（`StateKey`）也留到页面成形后。
