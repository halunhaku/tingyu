# 听屿 macOS 端 MyGo 迁移 · M0 记录（骨架与只读数据）

日期：2026-10-25（Asia/Shanghai）
性质：**M0 实施与验收记录**。新建 `client/` Go 模块；**未改 `app/`、未改方案正文、未合并 main、未打 tag**。本文件与 `client/`、`docs/screenshots/m0-*.png` 是新增内容。
任务书：[方案 §6 的 M0 行](./2026-10-25-macos-mygo-migration-plan.md)（判据以方案为准，本文不改判据）
代码与运行说明：[`client/README.md`](../../client/README.md)

---

## 0. 结论

M0 五条验收**全部实测通过**：

| # | 验收 | 结论 | 证据 |
|---|---|---|---|
| 1 | 双击 `.app` → 最小窗口 → 侧栏 + 表格列出线上库真实 178 首（用副本） | **通过** | `open -n` 启动日志 178 tracks；窗口 1200×760、最小 900×600（脚本外改 300×200 被夹到 900×600）；截图为真实库副本内容 |
| 2 | 只读证明：启动前后 mtime/校验和不变；代码可见 `mode=ro` | **通过** | 副本前后 mtime `17:27:21.786484000`、sha256 `310526fd…` 完全一致，无 `-wal/-shm/journal`；生产库全程未变；代码用 `sqlite.OpenOptions{ReadOnly:true}`（`SQLITE_OPEN_READONLY`），单测断言写操作返回 `SQLITE_READONLY(8)` |
| 3 | `CGO_ENABLED=0 go build ./...`、`go vet ./...`、`go test ./...`、`-race` | **通过** | 四命令 exit 0，`gofmt -l` 无输出 |
| 4 | 冷启动实测毫秒（M1 阈值 ≤1.5 s 的基线） | **通过** | 热启动 10 次 median **187.5 ms**（min 182.2 / max 253.6）；重新出包后首启 399–428 ms（3/3）；双击 292.8 ms；最冷一次 1424.9 ms |
| 5 | 截图或等价运行时证据证明表格内容 | **通过** | `docs/screenshots/m0-library.png`（窗口截图）、`m0-min-window.png`（900×600）＋ `ui.Tester` 单测断言表头/行文本 |

**给 M1 的基线：** 冷启动 ≈ 0.19 s（热）/ 0.40–0.43 s（刚出包后首启，签名与页缓存冷）；离 1.5 s 阈值仍有 3.5 倍以上余量。主要成本是 MyGo/AppKit 初始化与首帧（热路径 0.19 s 中的大部分）以及冷场景的 pre-main（观测 0.45–0.55 s），不是数据读取（178 首只读查询 5–15 ms）。

---

## 1. 环境

| 项 | 值 |
|---|---|
| 机器 / 系统 | MacBook Air（Apple Silicon，arm64），macOS 27.2（build 26B118） |
| Go | go1.27.3 darwin/arm64（`CGO_ENABLED=0`） |
| UI 框架 | `github.com/egoist/mygo v0.6.4`（精确版本，方案 §3.1） |
| SQLite | MyGo 官方插件 `plugins/sqlite`（purego + 预编译库，无 cgo） |
| 曲库 | `~/Library/Application Support/com.halunhaku.tingyu/library.sqlite`，`user_version=2`，178 首（**只读**；所有运行都指向 `cp` 副本） |

---

## 2. 产物

```bash
cd client
./scripts/bundle.sh
# build/darwin-arm64/听屿.app（12.1 MB）
```

| 项 | 值（`PlistBuddy`/`find` 实测） |
|---|---|
| `CFBundleIdentifier` | `com.halunhaku.tingyu` |
| `CFBundleName` / `CFBundleDisplayName` | `听屿` |
| `CFBundleShortVersionString` | `0.1.0` |
| `LSMinimumSystemVersion` | `12.0` |
| `CFBundleIconFile` | `AppIcon.icns`（由 `resources/icon.png` 1024×1024 生成） |
| 额外二进制 | `Contents/Resources/libmygo-sqlite3.dylib`（随包，ad-hoc 签名，`codesign --verify --strict` 通过） |
| 磁盘镜像 / 公证 | **无**（方案 §6 划给 M6；脚本用 `-skip-dmg`） |

分层（`client/`）：`internal/library` 数据访问（只读、`user_version` 校验、无写路径）／`internal/shell` UI 外壳（侧栏 + `ui.Table`，不碰窗口与数据库）／`internal/app` 应用装配（数据目录、冷启动打点、窗口）／`main.go` 只做入口。

---

## 3. 验收 1：双击启动、最小窗口、真实 178 首

用 LaunchServices 走双击同一条路径（环境变量经 `launchctl setenv` 传入，避免碰生产库）：

```bash
launchctl setenv TINGYU_DATA_DIR /tmp/tingyu-open-check     # 内含 library.sqlite 副本
launchctl setenv TINGYU_STARTUP_LOG /tmp/tingyu-open-check/startup.log
open -n client/build/darwin-arm64/听屿.app
```

启动日志：

```
startup data dir           33.1ms since process,     0.3ms since main
library: 178 tracks from /tmp/tingyu-open-check/library.sqlite (read-only, user_version 2)
startup library read       47.6ms since process,    14.8ms since main
window: 1200x760, minimum 900x600
startup window created    197.5ms since process,   164.7ms since main
startup ready             292.8ms since process,   260.0ms since main
```

最小窗口是运行时验证，不是只读配置：用 System Events 把窗口改成 300×200，CoreGraphics 窗口列表读回 **900×600**：

```
$ osascript -e 'tell application "System Events" to tell process "听屿" to set size of window 1 to {300, 200}'
$ swift windows.swift
18258   听屿   听屿   ["Width": 900, "X": 135, "Y": 52, "Height": 600]
```

截图：

- `docs/screenshots/m0-library.png`：1200×760，侧栏「听屿 / 曲库（选中）/ 收藏 / 专辑 / 艺术家 / 歌单 / 搜索 / 设置（后 5 项标 M4）」＋表头「曲名 / 艺术家 / 专辑 / 时长」＋**178 首**与真实行（一路向北、伊斯坦堡、印第安老斑鸠… 周杰伦，时长 4:54 等）。
- `docs/screenshots/m0-min-window.png`：900×600 最小窗口下的同一界面。

表内数据来自线上库副本（`shasum` 与生产库相同），不是编造：`一路向北 / 周杰伦 / J III MP3 Player / 4:54`、`伊斯坦堡 / 周杰伦 / Jay / 3:29` 等可直接与 `sqlite3` 查询对照。

---

## 4. 验收 2：只读

**代码层**（三道）：

1. `client/internal/library/library.go` 的 `Open`：
   ```go
   db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{ReadOnly: true})
   ```
   MyGo 插件在 `plugins/sqlite/database.go` 把 `ReadOnly` 翻成 `SQLITE_OPEN_READONLY`（`flags = 0x00000001 | 0x00010000`）。
2. 包内只有 `PRAGMA user_version` 与 `SELECT`；没有任何 `Execute`/`Transaction` 调用（整包 grep 可证）。缺文件不创建，版本不符不迁移。
3. `library_test.go` 的 `TestWriteIsRejectedByTheReadOnlyConnection` 在只读连接上执行 `CREATE TABLE`，断言 `*sqlite.Error` 且 `Code == 8`（`SQLITE_READONLY`）。

**文件层**（副本，启动前后）：

```
== before run ==
mtime=2026-10-25 17:27:21.786484000 +0800 size=737280
310526fdbac4e7dd9615c4d124bb28049146f87f4bce00629ed8f10b4581fb73  /tmp/tingyu-m0-proof/library.sqlite
== after run ==
mtime=2026-10-25 17:27:21.786484000 +0800 size=737280
310526fdbac4e7dd9615c4d124bb28049146f87f4bce00629ed8f10b4581fb73  /tmp/tingyu-m0-proof/library.sqlite
== journal files (expect none) ==
none
```

生产库全程未被指向，验收结束时：

```
mtime=2026-10-25 14:30:24.933160219 +0800 size=737280
310526fdbac4e7dd9615c4d124bb28049146f87f4bce00629ed8f10b4581fb73
```

——与开工时记录的值完全一致（开工：`2026-10-25 14:30:24.933160219`，同一 sha256）。`library.sqlite` 只有 `delete` 日志模式，没有 `-wal` 残留需要处理。

---

## 5. 验收 3：构建、vet、测试、race

```
== gofmt -l ==
(无输出)
== CGO_ENABLED=0 go build ./... ==
ok
== go vet ./... ==
ok
== go test ./... ==
?   	github.com/halunhaku/tingyu/client	[no test files]
?   	github.com/halunhaku/tingyu/client/internal/app	[no test files]
ok  	github.com/halunhaku/tingyu/client/internal/library	3.136s
ok  	github.com/halunhaku/tingyu/client/internal/shell	3.139s
== go test -race ./... ==
?   	github.com/halunhaku/tingyu/client	[no test files]
?   	github.com/halunhaku/tingyu/client/internal/app	[no test files]
ok  	github.com/halunhaku/tingyu/client/internal/library	1.136s
ok  	github.com/halunhaku/tingyu/client/internal/shell	1.175s
```

测试覆盖的是有回归价值的面：只读连接拒绝写入（错误码）、`user_version` 不符拒绝打开、缺文件不创建、曲目列映射与排序、`DataDir` 的 `TINGYU_DATA_DIR` 覆盖、视图在 `ui.Tester` 里能列出侧栏/表头/行文本/路径、错误态文案、时长格式。

---

## 6. 验收 4：冷启动

**方法**（`client/scripts/measure-coldstart.sh` + `TINGYU_STARTUP_LOG`）：

- **起点 = 进程启动**，不是 main 第一条语句：`proc_pid_rusage(pid, RUSAGE_INFO_V2)` 的 `ri_proc_start_abstime`（`sys/resource.h` 中 `rusage_info_v2` 偏移 80）经 `mach_timebase_info` 换算，`purego` 直调 libproc/libSystem，无 cgo。失败则退回 main 打点并在日志标注。
- **终点 = 首帧**：`Window.OnReadyToShow`（MyGo 文档：显示 Content 的窗口"画完第一帧"即就绪）记为 `ready`；`OnFocus` 另记 `focused`（观测值通常晚 10–20 ms）。
- 每次运行都复制线上库到临时目录，`TINGYU_DATA_DIR` 指过去；测量脚本不接触生产库。
- 每次运行都新起进程，测前不存在旧实例；退出用 `kill`（不写库，无退出钩子）。

**热启动 10 次**（`RUNS=10 ./scripts/measure-coldstart.sh`）：

```
run  1    253.6 ms
run  2    186.9 ms
run  3    190.1 ms
run  4    188.1 ms
run  5    182.2 ms
run  6    185.9 ms
run  7    189.9 ms
run  8    183.6 ms
run  9    186.9 ms
run 10    191.7 ms
cold start 10 runs: min 182.2 ms, median 187.5 ms, max 253.6 ms, mean 193.9 ms
```

其它场景：

| 场景 | ready（进程启动 → 首帧） | 备注 |
|---|---|---|
| `./scripts/bundle.sh` 之后第一次启动，连续 3 次重新出包各测 1 次 | **399.2 / 409.5 / 428.4 ms** | 新 bundle 首次执行，dyld/AMFI/页缓存冷；同类冷场景观测到 pre-main 453.5 ms（见下一行） |
| 双击路径 `open -n`（热） | **292.8 ms** | 启动日志见 §3 |
| 重新出包后首启，系统被全屏游戏占满 GPU 时 | **695.2 ms** | 同一份代码，pre-main 453.5 ms；说明冷启动对系统负载敏感 |
| 构建完成后**最冷**一次 | **1424.9 ms** | 首次生成 bundle 后立刻启动（首次注册 bundle）；仍 <1.5 s，但已贴近阈值 |
| 该次之前 main 已耗时 551 ms | 同一 run | 说明 pre-main（dyld + 包 init + MyGo 字体/AppKit 初始化）在冷场景占主导 |

一次热启动的分解（双击路径）：

| 阶段 | 累计 | 增量 |
|---|---|---|
| 进程启动 → main | 33.1 ms | 33.1 ms |
| 只读打开 + 178 首查询 | 47.6 ms | 14.5 ms |
| 窗口创建返回 | 197.5 ms | 149.9 ms（MyGo 应用就绪 + AppKit 窗口） |
| 首帧（ready） | 292.8 ms | 95.3 ms |
| 获得焦点 | ~303 ms | ~10 ms |

结论：M0 的基线 **p50 187.5 ms、刚出包后首启 399–428 ms、最坏观测 1424.9 ms（首次注册 bundle + 负载）**；M1 的 1.5 s 阈值在热路径余量充足，但"首次冷启动"要盯 pre-main（dyld + 包 init + MyGo/AppKit 初始化），不能只看 main 之后的阶段；验收时应固定机器负载并注明是否首次出包。

---

## 7. 验收 5：运行时证据

| 证据 | 位置 |
|---|---|
| 1200×760 实际窗口截图 | `docs/screenshots/m0-library.png` |
| 900×600 最小窗口截图 | `docs/screenshots/m0-min-window.png` |
| 窗口尺寸的独立读数 | CoreGraphics `CGWindowListCopyWindowInfo`：`["Width": 900, "Height": 600]`（请求 300×200 后） |
| 表格内容断言（真实表头、行、计数、路径） | `internal/shell/shell_test.go` 用 `ui.NewTester` 渲染同一 `View`，`HasText` 全部命中 |
| 曲目数 178 | 启动日志 `library: 178 tracks …` + 截图「178 首」 |

未锁屏，截图是实拍当前桌面窗口（`screencapture -l <windowid>`），未用占位图。

---

## 8. 与 `spike/` 的差异（以及一处任务书事实偏差）

任务书说 spike 已合入 main。**事实：`spike/` 只在分支 `tds/conv-01a1721f-0e91-7195-a767-234fc1fb1e66` 的 `23db404`，不是本分支/main 的祖先**；且该 commit 的目录里没有 README 提到的 `cmd/spike-app`、`scripts/*.sh` 源码（README 与记录文档在 commit 里，代码只含 `spike-np` 与 `internal/{mpv,mediasession,mainq,httpsrv,probe}` 的一部分）。本 todo 因此**没有依赖 spike 的构建产物**，只读了它的记录与方法，没有整段复制：

| 项 | spike | `client/`（本 todo） |
|---|---|---|
| 目标 | 进程内 libmpv + 媒体键验证 | M0 骨架：只读库 + UI 外壳 |
| purego 用法 | dlopen libmpv / MediaPlayer | 仅 `internal/app/process_darwin.go` 读 `proc_pid_rusage`（冷启动起点） |
| 打包 | 手写 bundle 脚本（frameworks、LC_RPATH、ad-hoc） | `mygo.json` + `go tool mygo build`（plist/图标/dylib/签名由官方 CLI 产出），`scripts/bundle.sh` 只做校验 |
| 数据层 | 无 | `internal/library`：只读、版本校验、无写路径 |
| UI | 无 `spike-app` 源码 | `ui` 原生外壳：侧栏 + `ui.Table` |
| 播放/媒体键 | S1/S2 原型 | 不实现（M1） |

---

## 9. 方案风险登记的两项回填

**§8.4 #2（上游停更 / bus factor 1：M0 记录所用 API 清单）**：

| 包 | 使用的 API |
|---|---|
| `mygo` | `App.WhenReady`、`App.Run`、`NewWindow(WindowOptions{Title,Width,Height,MinWidth,MinHeight,Content})`、`Window.OnReadyToShow`、`Window.OnFocus` |
| `mygo/ui` | `View`、`Context.Root/Theme`、`Row/Column/Box/Spacer/Text/Textf`、`Table`、`ListState{Key,Label}`、`TableColumn{Title,Width,Align}`、Element 的 `Fill/AlignItems/Grow/Width/Height/Padding/Radius/Background/TextColor/FontSize/Bold/SingleLine/Center/Gap/Children`、`NewTester/Texts/HasText` |
| `mygo/plugins/sqlite` | `Open(ctx, path, OpenOptions{ReadOnly})`、`DB.Query`、`DB.Close`、`Error{Code,ExtendedCode}` |
| `purego` | `Dlopen`、`Dlsym`、`SyscallN`（仅冷启动打点） |

**§8.4 #8（能否随包携带额外二进制：M0 验证）**：**实测了插件 dylib 这条路径**。`mygo build` 把 `mygo-plugin.json` 声明的 `libmygo-sqlite3.dylib` 放进 `Contents/Resources/` 并随 app 签名，`codesign --verify --strict` 通过，运行时从 bundle 内加载（`sqlite.LibraryPath` 先找 app resources）。这证明"bundle 内额外 dylib + 一起签名"可行；M1 的 libmpv/`native` shim 走 `resources/darwin-*` 或插件声明还要在 M1 首日实测（方案 §8.4 #8 的自建脚本仍是兜底，不因本条删除）。

---

## 10. 已知限制（留给后续里程碑，不是 M0 缺口）

- 表格一次读全库（178 首）；分页 40/页与 10,000 行性能是 M1/M4 的事。
- 侧栏除「曲库」外都是占位（标 M4），点击无行为。
- 无播放、无媒体键、无 Now Playing、无扫描入库、无封面/搜索/歌单。
- 签名是 ad-hoc，未公证、无 DMG（M6）。
- 未做窗口状态持久化（`StateKey`），M4 页面成形后再加。

---

## 11. 复现

```bash
cd client
CGO_ENABLED=0 go build ./... && CGO_ENABLED=0 go vet ./... && go test ./... && go test -race ./...
./scripts/bundle.sh

# 验收数据（副本！）
mkdir -p /tmp/tingyu-m0
cp "$HOME/Library/Application Support/com.halunhaku.tingyu/library.sqlite" /tmp/tingyu-m0/
shasum -a 256 /tmp/tingyu-m0/library.sqlite; stat -f '%Sm %z' /tmp/tingyu-m0/library.sqlite
TINGYU_DATA_DIR=/tmp/tingyu-m0 TINGYU_STARTUP_LOG=/tmp/tingyu-m0/startup.log \
  ./build/darwin-arm64/听屿.app/Contents/MacOS/听屿
# 另开窗口：截屏、核对表格与「178 首」
RUNS=10 ./scripts/measure-coldstart.sh
```
