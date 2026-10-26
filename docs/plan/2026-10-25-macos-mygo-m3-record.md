# 听屿 macOS 端 MyGo 迁移 · M3 实施与验收记录（来源）

日期：2026-10-25（Asia/Shanghai，记录落盘于 2026-10-26）
性质：**M3 实施与验收记录**。本阶段新增 `client/internal/sources`（协议与来源编排）、`client/internal/sourcemock`（本地协议模拟服务）、`client/internal/sourceaccept` + `cmd/sourceaccept` + `scripts/run-m3-accept.sh`（验收 harness），并在 `internal/app`、`internal/shell`、`internal/ui/model`、`internal/ui/pages` 上做了**最小可用**的来源接入与界面（方案 §6 M3 允许）。**未改 `app/`；未合并 main；未打 tag；未写生产库。**
判据来源：[迁移方案 §6 M3 行与 §2.1 / §3.4 / §3.5 / §8.1](./2026-10-25-macos-mygo-migration-plan.md)（**阈值与文案未放宽**）。
上一阶段：[M2 记录](./2026-10-25-macos-mygo-m2-record.md)（远端播放的 Range + 按曲目鉴权头在这里被复用）。
机器可读证据：[`2026-10-25-macos-mygo-m3-evidence.json`](./2026-10-25-macos-mygo-m3-evidence.json)（harness 的 `report.json` 原文）。

---

## 0. 结论

| # | 验收（方案 §6 M3 行 / 本 todo） | 结论 | 一句话证据 |
|---|---|---|---|
| 1 | 加一个 WebDAV 来源 → 120 首入库 | **通过** | Depth:0 连接探测 15 ms；扫描 120 个文件/6 个专辑目录，`已同步（新增 120 / 更新 0 / 移除 0）`，`COUNT(*)` = 120 |
| 2 | 播放远端曲目可播可 seek | **通过** | 起播 0.57 s，seek 到 10 s 落点 10.02 s、随后推进到 10.70 s；mpv 实际 GET 该文件 1 次 |
| 3 | 远端播放复用 M2 的 Range + 按曲目鉴权头（服务端日志可见） | **通过** | 服务端记录 `GET /dav/专辑00/000 歌名000.wav`，`Range: bytes=0-`，`Authorization: Basic …`，`206`，2 880 044 B；Go 侧不中转音频字节 |
| 4 | 夸克扫码登录 → 列目录 → 播放直链成功 | **通过（登录协议为模拟服务验证）** | 扫码前 `waiting` → 手机确认后 `scanned`；Cookie 51 B / 3 项（`__cas`、`__puus`、`__pus`）；列目录入库 4 首；直链 206 出声 0.57 s |
| 5 | 直链过期后自动刷新并继续播放（给出日志） | **通过（加载期过期；播放中过期的行为另见 §4.6 / §8）** | 切歌时首次加载 403 → `sources: quark direct link rejected … refreshing` → 新直链 `link-5` 206（11 520 044 B）→ 出声 0.83 s |
| 6 | Cookie 失效 → 出现"重新登录"入口，登录后恢复；不静默失败 | **通过** | WebDAV 401 与夸克 401 均得到 `needLogin=true` + 逐字文案，来源行写入同一句；重新填写/重新扫码后同步恢复，曲目数不变 |
| 7 | 取消同步后曲目数不变（前后计数 + 数据库证据） | **通过** | 取消前 120 → 取消后 120；`merge.removed=0`；`SELECT COUNT(*) FROM tracks` = 120；状态 `已取消（保留未扫描曲目；新增 0 / 更新 0）` |
| 8 | 凭据不落明文（Keychain 查询 + 仓库 grep） | **通过** | `security find-generic-password` 命中 `webdav_password_src-webdav`、`quark_cookie_src-quark`；数据目录 0 个文件含明文；仓库只有键名与模拟值，无真实凭据 |
| 9 | `CGO_ENABLED=0` build/vet/test/-race、`gofmt -l` 干净 | **通过** | 见 §6 |
| 10 | 生产库 sha256 前后一致 | **通过** | `310526fd…581fb73` 前后相同（harness 只读指纹，未打开） |

**一句话**：WebDAV 全链路（添加 → 扫描 → 入库 → 远端播放 + seek → 增量与权威删除）在真实协议形状的模拟服务上端到端跑通；夸克的扫码登录、目录分页、直链与过期刷新在**模拟服务**上跑通，**真实夸克服务未被验证**（无账号，且接口非官方公开，见 §8）。

---

## 1. 环境与构建

| 项 | 值 |
|---|---|
| 机器 / 系统 | Apple M4，macOS 27.2（arm64） |
| Go | go1.27.3 darwin/arm64，`CGO_ENABLED=0` |
| 播放内核 | libmpv **mpv 0.36.0**（client API 2.1），与 M2 同一份 `media_kit_libs_macos_audio-1.1.4` 库 |
| 凭据存储 | 登录钥匙串（`mygo.Secrets`，purego 调 Security.framework） |
| 新增依赖 | `github.com/skip2/go-qrcode`（MIT，纯 Go），仅用于把扫码链接画成二维码 |
| harness | `client/cmd/sourceaccept` + `client/internal/sourceaccept`，`./scripts/run-m3-accept.sh` |
| 模拟服务 | 进程内 `httptest`（WebDAV / 夸克），不联网、不需要账号 |
| 曲库 | 每次运行在证据目录新建 `data/library.sqlite`（schema 与线上一致），**不打开生产库** |

一次验收运行的形态：10 个 check、约 3.4 s（模拟服务在 loopback，音频为本地生成的 WAV）。

---

## 2. 改动范围

| 文件/目录 | 改动 | 为什么 |
|---|---|---|
| `internal/sources/{sources,errors,retry,httpclient,creds,smarttitle}.go` | 来源契约、逐字错误文案、退避重试、`scutil --proxy` 映射、Keychain 凭据（含 >2560 B 分片）、`SmartTitleParser` 直译 | M3 的基础层；文案与 `app/lib/sources/*` 逐字一致 |
| `internal/sources/webdav{,_xml}.go` | PROPFIND Depth:1 BFS、Basic、限流、后置 403/429 分支、XML 解析 | 方案 §2.3 #26 / §3.5 |
| `internal/sources/quark_{cookie,session,client,qr,adapter}.go` | Cookie 容器、会话校验、分页列目录、直链 + 5400 s 缓存、扫码登录（申请/轮询/换票） | 方案 §2.3 #27–29 / §3.5 |
| `internal/sources/{manager,recovery,sync}.go` | 适配器缓存（凭据代际）、播放解析、直链过期自动刷新、同步编排（进度/取消/权威性/状态文案） | 方案 §2.3 #30、§6 M3 |
| `internal/sourcemock/*` | WebDAV 与夸克协议模拟服务（PROPFIND/Depth/Basic/Range、夸克 API/CAS/CDN、分页、Cookie、直链轮换、可注入 401/403/503/畸形响应） | 约束要求"用本地模拟服务，但要与真实协议一致并说明依据" |
| `internal/sourceaccept/*`、`cmd/sourceaccept`、`scripts/run-m3-accept.sh` | 验收 harness：120 首 WebDAV、扫码、直链刷新、取消、Keychain、生产库指纹 | 让每条验收可复现 |
| `internal/library/library.go` | `Source` 增加远端字段；`Sources()` 多读 5 列；新增 `UpsertSource`（**只写 `music_sources`，additive**） | 没有它无法持久化远端来源；见 §9 |
| `internal/app/{app,sources,session}.go` | 来源层装配、`PlayTracks` 解析器替换、遥控/UI 动作、后台同步与取消、扫码登录、Recoverer 挂接 | 把 M3 接进真实应用 |
| `internal/mpv/player.go`（仅日志） | 调试日志只打印头**字段名**、URL 查询串替换为 `<redacted>` | "凭据不得写进日志"：原先 `http-header-fields=%q` 会把 Authorization/Cookie 的 base64 值、签名直链的 `?token=` 原样写进启动日志（见 §4.7）。**播放行为未改**（同一轮 M2/M3 验收照旧通过） |
| `internal/shell/shell.go`、`internal/ui/model/sourceform.go`、`internal/ui/pages/{settings,helpers}.go` | 来源表单/进度/重新登录入口的最小界面 | 方案允许的最小登录/进度界面 |
| `internal/ui/model/sourceform_test.go`、`shell_test.go`、`internal/sources/*_test.go` | 口径测试 | 见 §6 |

未改：`internal/{player,scan,mainq,mediasession,rangesrv}`、`app/**`、`client/main.go`、`mygo.json`；`internal/mpv` 只改日志脱敏（见上表），事件/队列/失败快照行为未动；`library` 的既有函数（`MergeScan`、`UpsertLocalSource`、`UpdateSourceSync`、`RecordPlay`、`BackfillDuration`）一行未动。

---

## 3. 逐条验收

### 3.1 WebDAV：添加 → 扫描 → 120 首入库

表单动作与 Flutter 版一致：先用 `Depth: 0` 探测根目录，再保存密码到钥匙串、写来源行、起同步。模拟服务要求 Basic 鉴权、按 DAV: 命名空间返回 `multistatus`（`webdav_xml_parser.dart` 读的元素一一对应），目录树为 6 个专辑目录 × 20 个 WAV。

```
webdav-add   连接探测通过，用时 15ms
webdav-scan  已同步（新增 120 / 更新 0 / 移除 0）；入库 120 首，用时 14ms
             scanned=120 skipped=0 cancelled=false truncated=false
             COUNT(*) = 120
```

目录自身的条目、非音频文件与 `.`/`@`/`#` 开头的隐藏项被跳过且**不**计入 `skipped`；只有解析不了的响应、越出根目录的 href、深目录的 403 等才计入 `skipped`——`skipped>0` 会让快照变成"非权威"，从而不删旧曲（§2.1 #2）。

### 3.2 远端播放：Range + 按曲目鉴权头 + seek

harness 用与 M2 相同的装配（`mpv.NewPlayer` + `player.New`），只把 resolver 换成生产 `sources.Manager.Resolve`。服务端（WebDAV 模拟服务）记录到：

```
GET /dav/专辑00/000 歌名000.wav   Range: bytes=0-   Authorization: Basic …   → 206，2 880 044 B
起播 0.57 s（点击到出声 139 ms）；seek 10 s → 落点 10.02 s → 推进到 10.70 s
```

鉴权头在 `on_load` 钩子里按曲目下发（M2 的 `http-header-fields` 路径），**Go 不代理音频字节**：请求由 libmpv 直连服务发出。

### 3.3 夸克扫码登录（模拟服务）

与 `quark_qr_login.dart` 相同的三步：`getTokenForQrcodeLogin` → 轮询 `getServiceTicketByQrcodeToken`（`50004001` 等待 / `2000000` 出票）→ 用 `service_ticket` 手动跟随 `pan.quark.cn/account/info` 的 302 收 Cookie，并要求 `__pus` 存在：

```
扫码前 waiting → 确认后 scanned；Cookie 51 B / 3 项（__cas、__puus、__pus）
二维码内容 174 字节，含 token= 与 uc_param_str=（短链丢参数那个坑的格式）
```

二维码用 `skip2/go-qrcode` 画进来源页（`ui.NewBitmap`），手机实扫**未验证**（无真实服务，见 §8）。

### 3.4 夸克列目录、直链与过期刷新

列目录按 `_page/_size/_fetch_total` 翻页，`list` 缺字段或总数对不上都按"未取全"处理（不完整快照不删曲）。直链按 fid 缓存 5400 s；过期时用生产 `sources.Recoverer`（与应用同一份代码）刷新：

```
mpv: error: Failed to open http://127.0.0.1:…/cdn/download/file-3?token=link-2
mpv: end-file reason=4 err=-13
sources: quark direct link rejected for "园游会" (HTTP 403, at 0.0s); refreshing
sources: quark: invalidated direct link for file-3
sources: refreshed direct link, replaying "园游会"
→ GET /cdn/download/file-3?token=link-5  Range: bytes=0-  → 206，11 520 044 B，出声 0.83 s
```

服务端日志显示旧 token `link-2` 被拒 1 次（403）、新 token `link-5` 成功（206）。**刷新走的是控制器的 `PlayTracks` 公共入口，因此 mpv 收到的是不同 URI**——这正是 M2 §4.5 记录的"同 URI 重载可能复用 demuxer"的规避方式，本次复测成立（两次 URI 的 token 不同，第二次真的发起了新请求）。

### 3.5 凭据失效 → 重新登录

| 来源 | 失效文案（逐字） | 入口 | 恢复 |
|---|---|---|---|
| WebDAV 401 | `WebDAV 认证失败，请检查账号和应用专用密码` | 来源卡片显示 `重新登录`（`model.SourceError`），同时写入 `music_sources.sync_status` | 重填密码（凭据代际 +1，缓存适配器失效）后 `已同步` |
| 夸克 401 | `夸克网盘登录凭据已失效，请重新登录` | 同上；扫码或粘贴 Cookie 都走同一校验路径 | 重新扫码后 `已同步`，曲目 4 → 4 |

两处都**没有把失败吞成空列表**：曲目数在失败前后不变（4 → 4 / 120 → 120），失败文案保留在来源行里，重启后仍能看到。

### 3.6 取消同步不误删

```
取消前 120 首 → 取消后 120 首；merge.removed=0；库内总行数 120
状态：已取消（保留未扫描曲目；新增 0 / 更新 0）
SELECT COUNT(*) FROM tracks = 120
```

`ScanResult.Cancelled` 使 `Authoritative()` 为 false，`MergeScan(..., removeMissing=false)` 只更新/新增、不删除；已发现的曲目仍会写入（与 Flutter 版一致）。写库阶段用**脱离取消信号的上下文**（30 s 上限）执行：取消的是枚举，不是本地合并，否则取消那一刻的 `context canceled` 会让整次合并失败、丢失已扫描结果（本轮真实踩到，见 §4.2）。

### 3.7 凭据不落明文

- Keychain 服务 `com.halunhaku.tingyu.sources`（验收用 `.acceptance`）；账号名沿用 Flutter 版：`webdav_password_<sourceId>`、`quark_cookie_<sourceId>`。
- `security find-generic-password -s <service> -a webdav_password_src-webdav` 与 `… -a quark_cookie_src-quark` 均命中（`security` 只查属性，不加 `-w`，不打印密码）。
- 读回：WebDAV 密码 15 B、夸克 Cookie 56 B；数据目录（含 `library.sqlite`）逐文件扫描，明文命中 **0**。
- 夸克 Cookie 可能超过 `mygo.Secrets` 的 2560 B 上限：按 `<key>#0..#n` 分片 + `<key>` 清单，读时拼接；单测覆盖 6.5 KB Cookie 的写入/读回/缩短后清理旧分片（实测通过）。
- 不保留 Flutter 版的 0600 明文回退（方案 §2.1 #7）。
- 仓库 grep：只有键名常量与模拟值（`__pus=mock-session` 等），没有任何真实账号、Cookie 或令牌（见 §6）。
- **日志侧**：之前 mpv 的调试行会把 `http-header-fields` 的**值**（Authorization 的 base64、Cookie）与签名直链原样写进启动日志，违反"凭据不得写进日志"；现在只打印头字段名、URL 查询串显示为 `<redacted>`（§4.7）。验收日志里因此只有：

  ```
  mpv: per-track headers [Authorization] for http://127.0.0.1:…/dav/…
  mpv: per-track headers [Accept,Cookie,Origin,Referer,User-Agent] for http://127.0.0.1:…/cdn/download/file-1?<redacted>
  ```

  真实 `.app` 播放远端 WebDAV 曲目时同样是这一行（`play: sound after 195.3 ms for "歌名000" (index=0)`）。

---

## 4. 过程中发现并修掉的问题（会改变口径）

1. **WebDAV 响应根元素必须是 `multistatus`**：Dart 解析器按 `descendants` 找 `response`，一个"格式正确的 HTML 错误页"会被读成**空目录**，而空且权威的快照会删光该来源的所有曲目。Go 侧要求根元素为 `multistatus`，否则按不可解析计 `skipped`（非权威）。这是对 Flutter 行为的**有意收紧**，理由见方案 §2.1 #2。
2. **取消同步时合并没有执行**：第一版直接用扫描的 `ctx` 做合并，取消后 SQLite 查询返回 `context canceled`，已发现的曲目全部丢失。现在写库阶段用 `context.WithoutCancel` + 30 s 上限的独立上下文；扫描取消只停止枚举。
3. **同一来源的适配器缓存必须跟凭据版本走**：WebDAV 密码与夸克 Cookie 都存在适配器里；重新登录后必须重建，否则会一直用旧凭据请求。`Manager` 的指纹包含 `Credentials.Epoch()`（对应 Flutter 的 `credentialEpoch`）。
4. **直链刷新必须换 URI**：M2 记录过"同 URI 重载可能复用 demuxer"；`Recoverer` 用 `PlayTracks` 重新解析（失效缓存后必然是新签名 URL），不依赖 mpv 重读同一 URI。
5. **Cookie 写回要串行**：夸克几乎每个响应都 `Set-Cookie`（`__puus` 轮换）；会话合并后同步写回钥匙串，避免并发写入互相覆盖。
6. **播放中的 403 不产生 `Failure`**：过期发生在当前曲目**已开始播放**之后时，mpv 只在日志里打 `Seek failed`，继续用已缓冲的数据播放，控制器的失败快照不会出现——因此"自动刷新"在**加载期**过期时触发（本次验收用这条确定性路径）；播放中途过期的实际表现与限制写入 §8，不假装验证过。
7. **凭据会进日志**（本轮发现并修复）：`internal/mpv` 的调试行原本打印 `http-header-fields=%q`，把 `Authorization: Basic …`、`Cookie: …` 的完整值写进 `TINGYU_STARTUP_LOG`；`mpv: state … path=` 与 mpv 的 `error:` 行还会带出签名直链的 `?token=`。现在日志只打印头**字段名**，所有 URL 查询串与 userinfo 经 `redactURIs` 记为 `<redacted>`；新增两条单测锁定（§6）。这是日志改动，播放行为不变。
8. **来源行持久化缺口**：`internal/library` 原本只有本地来源的写入函数，远端来源无处落库。新增了**一个 additive 函数** `UpsertSource` 与 `Source` 的远端字段（`Sources()` 多读 5 列），既有函数语义一行未改；这份改动进入 §9 的"需数据层支持"清单，供并行数据层 todo 接管或保留。

---

## 5. 与方案口径的对照

| 方案要求 | 本阶段处理 |
|---|---|
| §2.1 #2 只有权威扫描才删旧曲 | `ScanResult.Authoritative()` = 未取消 ∧ 未截断 ∧ 无跳过；直接映射到 `MergeScan(removeMissing)` |
| §2.1 #26 WebDAV 文案逐字不变 | 401/403/429·503（含 `BlockedTemporarily` 两条）与"服务器返回错误"逐字保留；单测锁定 |
| §2.1 #27 扫码登录 | 申请/轮询/换票三段 + `__pus` 校验；网页内嵌登录未做（§8） |
| §2.1 #29 深度/数量上限、截断原因 | WebDAV 8/5000、夸克 5/5000；截断原因分别为"目录层级超过 N 层 / 达到 N 首上限 / 目录未取全 / 服务端返回了无法解析的目录内容" |
| §2.3 #30 进度、取消、权威性、错误、重登录 | `Syncer` + 界面进度条/取消按钮 + 来源卡片"重新登录" |
| §3.4 凭据：Keychain、2560 B 分片、代际 | `mygo.Secrets`（purego，不写明文）；分片；`Epoch`；键名沿用 |
| §3.5 网络：超时、复用、取消、系统代理、重试 | 每来源 `*http.Client`；`scutil --proxy` 映射（PAC 不评估，见 §8）；幂等请求退避重试 |
| §3.5 鉴权头按曲目、Go 不中转字节 | `Playable.Headers` → `on_load` → `http-header-fields`；服务端日志为证 |
| §8.1 双轨期规则 | 未提升 `user_version`；开发/验收不碰生产库；凭据不迁移、由用户重填 |

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

日志脱敏改动后重跑了 M2 harness（同一份内核、25 项）：**25/25 passed**（`build/m2-evidence/20261026-090145/report.json`），M3 harness 10/10。

新增回归测试（都锁定行为，不测界面装饰）：

| 测试 | 锁定的行为 |
|---|---|
| `sources.TestSmartTitleParserMatchesTheDartRules` | 文件名解析与 Dart 版逐例一致 |
| `sources.TestWebDAVScanReadsTheWholeTree` | 嵌套目录 120 首、进度回调、权威性 |
| `sources.TestWebDAVScanReportsRejectedCredentials` | 401/403/503 + `BlockedTemporarily` 的逐字文案与 `Kind` |
| `sources.TestWebDAVScanStopsOnCancel` | 取消后保留已发现曲目、不权威 |
| `sources.TestParseMultistatusKeepsLastValuesAndDropsEmptyHrefs` | 命名空间、后写覆盖、空 href、非 multistatus 报错 |
| `sources.TestQuarkScanWalksFoldersAndSkipsNonAudio` | 目录遍历、`quark://<fid>`、专辑占位 |
| `sources.TestQuarkScanPaginatesLargeFolders` | 250 项翻页取全 |
| `sources.TestQuarkIncompleteListingIsNotAuthoritative` | 总数不符 / 结构异常都按截断 |
| `sources.TestQuarkExpiredCookieIsAReLogin` | 401 与缺 Cookie 都是可重登录的鉴权错误 |
| `sources.TestQuarkDirectLinkRefreshAndPlaybackHeaders` | 直链 403 → 刷新 → 新链接 206；播放头齐全 |
| `sources.TestQuarkQRLoginFlow` / `…Cancel` | 二维码内容格式、四态、换票 Cookie |
| `sources.TestSyncCancelKeepsEveryTrack` | 取消前后计数不变、库里 120 行、状态文案 |
| `sources.TestSyncAuthoritativeSnapshotDeletesVanishedTracks` | 权威快照删 1 首 |
| `sources.TestSyncTruncatedSnapshotKeepsUnscannedTracks` | 深度截断不删 |
| `sources.TestSyncCredentialFailureNeedsLoginAndRecovers` | 重登录入口 + 凭据代际重建适配器 |
| `sources.TestSyncQuarkExpiredCookieMarksTheSource` | 夸克失效写回来源状态、曲目不变 |
| `sources.TestRecovererRefreshesAnExpiredDirectLinkOnce` | 刷新一次、冷却、非夸克/非 401 不触发 |
| `sources.TestKeychainShardsLongSecrets` | 6.5 KB 分片写入/读回/缩短清理 |
| `mpv.TestHeaderLogNamesDoNotLeakCredentials` | 日志只有头字段名，不含 Basic/Cookie 值 |
| `mpv.TestRedactedDirectLinksKeepTheHostAndDropTheSignature` | 直链签名不进日志，路径保留；本地路径不变 |
| `model.TestSourceForm*` | 表单不预填凭据、关闭清空、错误驱动重新登录 |
| `shell.TestSourcesPageShowsRemoteFormsAndRelogin` | 远端卡片、进度+取消、重新登录、两种表单 |

真实应用冒烟（`.app` + 库副本，本地模拟 WebDAV；无真实账号）：

```
library: 124 tracks from /tmp/tingyu-m3-copy/library.sqlite (read-write, user_version 2)
play: request "歌名000" (http://127.0.0.1:18080/dav/a/song001.wav) index=4
sources: resolve "歌名000" via http://127.0.0.1:18080/… (1 headers)
mpv: per-track headers [Authorization] for http://127.0.0.1:18080/dav/a/song001.wav
play: sound after 195.3 ms for "歌名000" (index=0)
```

同一窗口里点播缺少凭据的夸克曲目时：

```
play: failed "以父之名": 夸克网盘登录凭据已失效，请重新登录
```

即：远端曲目在真实窗口里可播（带按曲目鉴权头），凭据缺失得到可读文案与"重新登录"入口，不崩溃、不静默；日志里没有凭据值。

---

## 7. 复现

```bash
cd client
./scripts/bundle.sh             # 提供 libmpv/FFmpeg frameworks
./scripts/run-m3-accept.sh      # 10 个 check，证据在 build/m3-evidence/<时间戳>/
```

输出：`report.json`、`webdav-requests.json`、`quark-requests.json`、`log.txt`（均不入库；`report.json` 已复制为本记录旁的 evidence 文件）。

---

## 8. 剩余风险与未验证项（如实）

1. **夸克没有真实账号验证**。所有夸克结论都来自按 Flutter 版行为复刻的本地模拟服务：端点路径、查询参数、`status`/`code` 语义、三种直链响应形状、Cookie 流程都取自 `app/lib/sources/quark/*` 的解析代码，**不是官方文档**（也没有）。真机上可能不同（风控、UA、客户端 ID、换票跳转）。本阶段**不声称**这些在真实服务上验证过。
2. **网页内嵌登录未实现**（方案 §2.3 #28）。MyGo 的 `WebView`/`Cookies` 面向应用自有前端页面，外部登录页 + Cookie 读回未在本阶段验证；界面提供**扫码登录**与**粘贴 Cookie**两条可用路径。扫码登录的二维码**未被手机实扫**（无真实服务），只验证了内容格式与协议状态机。
3. **播放中途直链过期**：见 §4.6。已开始播放后 mpv 不把 403 上报为失败，会继续用缓冲数据；"刷新并续播"的确定性证据来自加载期过期。若将来需要播放中途也能自愈，需要内核层暴露 seek/读错误（属 M2 内核范畴，本阶段未改）。
4. **WebDAV 只在模拟服务上验证**：真实服务（坚果云、群晖、反代）的 XML 细节、限流、重定向未实测；但文案、`BlockedTemporarily` 分支、越界 href 与深度/数量上限都有单测。
5. **系统代理只映射 `scutil --proxy` 的 HTTP/HTTPS**：PAC 不评估、SOCKS 不支持（Go 标准库限制）；`HTTP(S)_PROXY` 环境变量优先。
6. **界面是最小可用**：来源页新增表单/进度/重登录入口，未做视觉打磨；密码框为普通输入框（明文可见），与 Flutter 版的一致体验留给后续界面阶段。
7. **未做来源删除**：`删除来源` 仍提示"需内核支持"（M4 §7 第 6 条）；凭据删除入口也未接（`Credentials` 已具备删除方法）。
8. **未在 Intel / 更低 macOS 上实跑**，与本迁移其它阶段相同。
9. **Keychain 项按应用签名归属**：换签名后系统可能要求重新授权读取；验收服务名独立，正常构建用 `com.halunhaku.tingyu.sources`。

---

## 9. 需数据层支持（供并行 `internal/library` todo）

本阶段对 `internal/library` **只做了两处 additive 改动**，既有函数与语义未动：

1. `Source` 新增字段 `WebDAVURL / WebDAVUsername / WebDAVRootPath / QuarkFolderFID / QuarkAccountName`；`Sources()` 多读这 5 列（`music_sources` 早就有这些列）。若有其它读取方，多列不影响其行为。
2. 新增 `UpsertSource(ctx, Source)`：只写 `music_sources`（任意 kind），用于持久化远端来源；`UpsertLocalSource` 保持原样。数据层若接管来源 CRUD，请保留同名同语义，或提供等价入口并通知 M3 侧改调用点。
3. 仍需数据层提供（本阶段未做）：**来源删除**（删 `music_sources` 行 + 曲目 + 歌单引用 + 对应 Keychain 项）与**批量删除后的凭据清理**；M4 §7 第 6 条已记录该缺口。

---

## 10. 约束合规

- 只做来源接入：未改视觉设计（新增界面为最小可用并在此标注）；未做元数据补全（M5）；未改播放内核行为（`internal/player` 一行未动；`internal/mpv` 仅有日志脱敏，事件/队列/失败快照未改，M2 的 25 项验收仍通过）。
- 真实账号凭据未写进仓库、日志或测试夹具；测试与验收全部用本地模拟服务，模拟依据写明（复刻 Flutter 解析器，非官方文档）。
- 未写生产库：`shasum -a 256` 前后同为 `310526fd…581fb73`；harness 的 `report.json` 内 `production_sha256_before/after` 相同。
- 未改 `app/`；未合并 main；未打 tag；未执行破坏性 git 操作。
