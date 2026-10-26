# 听屿 macOS 端 MyGo 迁移 · M6 分发与质量实施与验收记录

日期：2026-10-26（Asia/Shanghai）
性质：**M6 实施与验收记录**。本阶段只改 `.github/workflows/`、`client/scripts/`、`client/internal` 的测试与键盘可达性（`internal/shell`、`internal/ui/{components,pages}` 的 `Focusable`）、`client/README.md`、根 `README.md` 与本文件；**未改 `app/`、未改元数据/取色功能、未合并 main、未打 tag、未写生产库、仓库里没有任何凭据**。
判据来源：[迁移方案 §6 的 M6 行、§8.1 双轨规则](./2026-10-25-macos-mygo-migration-plan.md)、[调研 §5](./2026-10-26-mygo-cloudmusic-reference.md)（流程借鉴，未复制 AGPL 代码）。
上一阶段：[M4 记录](./2026-10-25-macos-mygo-m4-record.md)、[内核数据能力记录](./2026-10-26-macos-mygo-kernel-data-record.md)。代码与命令：[`client/README.md`](../../client/README.md)。

---

## 0. 结论

| # | 验收（方案 `:462`） | 结论 | 证据 |
|---|---|---|---|
| 1 | `spctl -a -vv` 通过 | **未通过（缺 Apple Developer 凭据）**：ad-hoc 构建被 Gatekeeper 拒绝；**没有伪造公证通过** | §3.2 / §7 |
| 2 | 空用户账户（或等价干净目录）首次启动无隔离警告 | **部分**：干净 HOME 首启通过（多次运行 483–743 ms 到首帧，均在 M1 冷启动阈值 1.5 s 内）；**加隔离标记的副本被 Gatekeeper 拦截**（未公证），这与 #1 是同一缺口 | §3.3 |
| 3 | DMG 可挂载、可拖入 Applications、包内 `.app` 签名有效 | **通过**（DMG 本身未签名，因为它只有 ad-hoc app；真身份路径已实现） | §3.4 |
| 4 | CI 只跑 macOS：格式化 + `go vet` + 单测 + 构建 +（有凭据时）公证 | **工作流就绪，本地等价命令全绿**；GitHub 上尚未实际跑（本机无 Actions runner） | §4 |
| 5 | 契约测试覆盖队列/循环三态/合并（取消不误删）/直链错误，`-race` 干净 | **通过** | §5 |
| 6 | 键盘路径逐条实测 | **通过**（Tab / 方向键 / 回车 / Esc），另有一处明确保留的缺口：歌词行点选 | §6 |

一句话：**签名顺序、DMG、公证流水线、验证脚本、macOS-only CI、四类契约测试与键盘可达性全部落地并在本机实测；唯一缺的是 Apple Developer 凭据，因此 `spctl` 与「隔离件无警告」两条按实际情况记为未通过，不写成通过。**

---

## 1. 环境与产物

| 项 | 值 |
|---|---|
| 机器 / 系统 | Apple Silicon（arm64），macOS 27.2 |
| Go | go1.27.3 darwin/arm64，`CGO_ENABLED=0` |
| UI | `github.com/egoist/mygo v0.6.4` |
| 本机可用的签名身份 | 只有 `Apple Development: … (MW739WWZ4Q)`；**没有 `Developer ID Application`**，因此无法公证 |
| 产物 | `client/build/darwin-arm64/听屿.app`（13.5 MB）、`client/build/darwin-arm64/听屿-0.1.0.dmg` |
| 签名产物 | `client/build/signed/darwin-arm64/听屿.app`（用 Apple Development 身份走完整签名路径，仅作证据，不入库——`build/` 已被忽略） |

本阶段新增/修改的文件：

```
.github/workflows/macos.yml          新增：只跑 macOS 的 Go CI（flutter.yml 未动）
client/scripts/bundle.sh             扩展：内到外签名、可选 DMG、可选公证 + 票据装订 + spctl
client/scripts/verify-bundle.sh      新增：签名/spctl/票据/DMG 挂载/干净 HOME 首启校验
client/scripts/fetch-frameworks.sh   新增：固定版本 + sha256 的 mpv/FFmpeg xcframeworks（CI/干净机器）
client/internal/shell/contract_test.go   新增：四类契约测试（ui.Tester + 真库）
client/internal/shell/keyboard_test.go   新增：Tab/方向/回车/Esc 路径
client/internal/player/controller_test.go 补：循环三态第三段（off → all）
client/internal/player/shuffle_test.go    修：测试自身的前缀读取竞态（见 §5.3）
client/internal/shell/shell.go、internal/ui/{components,pages}  自定义可点行加 Focusable；
                                      队列页与专辑/艺术家详情的列表绑定选择项 + 回车播选中行
client/README.md、README.md、本文件     文档
```

---

## 2. 流水线

### 2.1 签名顺序（调研 §5.5）

`mygo build` 只签 `Contents/Resources`（`cmd/mygo/resources.go`），**不碰 `Contents/Frameworks`**；`codesignArgs` 还会用 `--deep`，所以顺序必须是「先让 MyGo 签、再复制 framework、再从内到外重签、最后只签外层 app，绝不用 `--deep`」：

1. `go tool mygo build -platform … -skip-dmg [-sign "$SIGN_IDENTITY"]`；
2. 复制 10 个 framework 到 `Contents/Frameworks`；
3. 每个 framework：Mach-O 二进制 → `.framework` 包；
4. 主可执行文件（加完 `LC_RPATH` 之后）→ `.app`；
5. 真身份下每一步都带 `--options runtime --timestamp`；entitlements 只给可执行文件与 app（当前为空，`CGO_ENABLED=0`、无 JIT）。

签名函数在失败时会打印 `codesign` 的原始错误并重试一次（`--timestamp` 依赖 Apple 的时间戳服务，第一次运行就遇到一次瞬时失败，脚本当时把错误吞了；现在不会）。

### 2.2 DMG

`DMG=1` 时用 `hdiutil create -format UDZO` 造镜像，内含 `听屿.app` 与指向 `/Applications` 的符号链接；有真身份时再 `codesign --timestamp` 签镜像本身。同一命令重复执行都产出可挂载、可拖入 Applications 的镜像（内容一致；`hdiutil` 会写入时间元数据，镜像字节不保证逐字节相同，这里不声称 bit-for-bit 可复现）。

### 2.3 公证与票据

`NOTARY_PROFILE=<keychain profile>` 时：`notarytool submit --wait --output-format json` → 只有 `status=Accepted` 才继续，否则打印 `notarytool log` 并失败 → `stapler staple` **DMG 与裸 app** → `stapler validate` 两者 → `spctl -a -vv --type execute`。没有真身份时脚本在开头就拒绝公证：

```
$ NOTARY_PROFILE=notary ./scripts/bundle.sh
bundle: notarization needs a Developer ID identity; set SIGN_IDENTITY (or macos.signingIdentity)
exit=1
```

### 2.4 校验脚本

`verify-bundle.sh` 对 `.app` / `.dmg` 分别检查：`codesign --verify --deep --strict`、逐个 framework、`codesign -dv --verbose=4`（身份/团队/hardened runtime/票据）、`spctl`、`stapler validate`；镜像还检查 `hdiutil verify`、只读挂载、`/Applications` 链接、镜像内 app 的签名；`--launch` 用临时 `HOME` 与 `TINGYU_DATA_DIR` 启动到首帧，`--quarantine` 先给副本打 `com.apple.quarantine` 再启动。`--require-notarized` 会把「未公证」判为失败，供 CI 使用。

---

## 3. 验收 1–3：实测输出

### 3.1 构建

```
$ cd client && DMG=1 ./scripts/bundle.sh
bundle: 听屿 0.1.0 (com.halunhaku.tingyu), minimum macOS 12.0, darwin/arm64, ad-hoc signature
  ✓ Compiled darwin/arm64  1.1s
  ✓ Signed 听屿.app  22ms
bundle: build/darwin-arm64/听屿.app (frameworks from …/media_kit_libs_macos_audio-1.1.4/macos/Frameworks)
bundle: build/darwin-arm64/听屿-0.1.0.dmg
  signature                    ad-hoc (not distributable; pass SIGN_IDENTITY)
```

### 3.2 `spctl`（验收 1：**未通过**）

```
$ spctl -a -vv --type execute build/darwin-arm64/听屿.app
build/darwin-arm64/听屿.app: rejected
exit=3

$ spctl -a -t open --context context:primary-signature -vv build/darwin-arm64/听屿-0.1.0.dmg
build/darwin-arm64/听屿-0.1.0.dmg: rejected
source=no usable signature
exit=3
```

原因不是签名坏了，而是**没有 Developer ID 身份可签**（`codesign -dv` 显示 `Signature=adhoc`、`TeamIdentifier=not set`）。`codesign --verify --deep --strict` 通过，10 个 framework 逐个通过。期望值（公证后）是 `source=Notarized Developer ID`，写在脚本的判定里。

### 3.3 干净目录首启（验收 2：**部分**）

干净 `HOME` + 空数据目录，直接启动（未打隔离标记，即本机构建）：

```
== first launch from an empty HOME (/var/folders/…/tingyu-firstrun-0HuGMJ)
ok    the app started: startup ready             742.8ms since process,   482.6ms since main
```

模拟「下载来的」副本（`com.apple.quarantine`）则被 Gatekeeper 拦下——这正是未公证构建的真实结果：

```
ok    marked the copy as downloaded (com.apple.quarantine)
== first launch from an empty HOME (/var/folders/…/tingyu-firstrun-8WpjB2)
FAIL  the app did not reach its first frame (exit 143); startup log:
      (no log)
      the copy was quarantined: Gatekeeper holds or kills a build it has no ticket
      for, which is what an ad-hoc or not-yet-notarized build gets. With NOTARY_PROFILE
      the same check must pass; until then this is the honest result.
```

### 3.4 DMG（验收 3：**通过**）

```
$ ./scripts/verify-bundle.sh build/darwin-arm64/听屿-0.1.0.dmg
ok    the image holds 听屿.app
ok    codesign --verify --deep --strict      （镜像内的 app）
ok    Avcodec.framework verifies … Swscale.framework verifies
ok    the image holds the /Applications drag target
ok    libmpv ships inside the image
      the image has no signature (ad-hoc builds are not signed)
result: not notarized — acceptable for development, not for distribution
exit=0
```

`hdiutil verify` 通过、只读挂载后逐项检查、随后自动卸载（`mount | grep tingyu-mount` 计数为 0）。

### 3.5 真身份签名路径（证明 flags，不冒充 Developer ID）

用本机唯一的 `Apple Development` 身份跑同一条流水线（`SIGN_IDENTITY=… DMG=1 OUT=build/signed`）：

```
CodeDirectory … flags=0x10000(runtime) hashes=761+3 location=embedded
Authority=Apple Development: … (MW739WWZ4Q)
Authority=Apple Worldwide Developer Relations Certification Authority
Timestamp=Oct 26, 2026 at 10:48:07
TeamIdentifier=32T4L6PN3X
```

即 hardened runtime 与安全时间戳确实被下发，10 个 framework 与 app 全部 `codesign --verify --deep --strict` 通过。它仍不是 Developer ID，`spctl` 依旧拒绝；这一条只用来证明签名代码路径，不写成公证通过。

---

## 4. 验收 4：CI（工作流就绪 + 本地等价输出）

`.github/workflows/macos.yml`：`runs-on: macos-14`，单 job：

| 步骤 | 内容 |
|---|---|
| 触发 | push/PR 的 `client/**` 与 workflow 自身；`workflow_dispatch` |
| 质量门 | `gofmt -l .`（有输出即失败）→ `go vet ./...` → `go test -race -count=1 ./...` |
| 框架 | `scripts/fetch-frameworks.sh`：`libmpv-xcframeworks v0.6.0` 的 GitHub release 包（版本与 sha256 抄自 `media_kit_libs_macos_audio 1.1.4` 的 `macos/Makefile`），**不装 Flutter、不依赖 runner 的 pub 缓存**；校验失败即停 |
| 构建 | `PLATFORM=darwin/universal DMG=1 ./scripts/bundle.sh` |
| 签名/公证 | 仅当仓库 Secrets 齐全：临时钥匙串导入 p12 → `notarytool store-credentials notary` → `SIGN_IDENTITY` / `NOTARY_PROFILE` 传给脚本 |
| 校验 | `verify-bundle.sh` app + dmg；公证路径下追加 `--require-notarized` |
| 产物 | DMG 作为 artifact 上传（7 天） |

Flutter 的 `flutter.yml` **一行未改**（M7 才删，§8.1 规则 1）。

本地等价命令（macOS runner 上的步骤逐条对应）：

```
$ cd client
$ gofmt -l .
(no output)
$ go vet ./...
ok
$ go test -race -count=1 ./...
ok  …/internal/library  7.571s
ok  …/internal/mediasession  1.383s
ok  …/internal/mpv  1.351s
ok  …/internal/player  1.514s
ok  …/internal/rangesrv  1.409s
ok  …/internal/scan  1.414s
ok  …/internal/shell  5.966s
ok  …/internal/sources  2.074s
ok  …/internal/ui/model  1.412s
$ DMG=1 ./scripts/bundle.sh        # exit 0
$ ./scripts/verify-bundle.sh <app> --launch          # exit 0
$ ./scripts/verify-bundle.sh <dmg>                   # exit 0
```

CI 的构建步骤逐字照跑（universal + 独立下载的 frameworks）：

```
$ FRAMEWORK_SRC=$(./scripts/fetch-frameworks.sh) PLATFORM=darwin/universal DMG=1 OUT=build/ci ./scripts/bundle.sh
bundle: build/ci/darwin-universal/听屿.app (frameworks from build/frameworks)
bundle: build/ci/darwin-universal/听屿-0.1.0.dmg
exit=0
$ lipo -archs build/ci/darwin-universal/听屿.app/Contents/MacOS/听屿
arm64 x86_64
$ ./scripts/verify-bundle.sh build/ci/darwin-universal/听屿.app --launch
ok    codesign --verify --deep --strict
ok    the app started: startup ready             702.5ms since process,   279.0ms since main
$ ./scripts/verify-bundle.sh build/ci/darwin-universal/听屿-0.1.0.dmg
ok    the image holds 听屿.app
ok    the image holds the /Applications drag target
ok    libmpv ships inside the image
```

**未做的部分**：没有在 GitHub Actions 上实际跑过（本机无法执行 runner），所以「CI 在 GitHub 上变绿」这句话不写。工作流 YAML 已用 Ruby 的 YAML 解析器读取通过（11 个步骤）；`actionlint` 本机未安装。

---

## 5. 验收 5：契约测试（`ui.Tester` + 真 SQLite 库）

新文件 `client/internal/shell/contract_test.go`，每个用例都过真实窗口（`ui.Tester`）与真实库（`newLibrary` 建临时 SQLite 并走 `MergeScan`），不 mock 数据层：

| 契约 | 测试 | 断言 |
|---|---|---|
| **队列** | `TestEnterOnARowQueuesTheWholeListFromIt` | 键盘 Enter 播放第 2 行 → `PlayTracks` 收到整张列表且 `start=1`；队列顺序为「点的那首 + 余下」；队列页显示「当前播放 / 接下来 1 首」与两首曲目 |
| **循环三态** | `TestLoopButtonCyclesAllThreeStates`（窗口）＋ `TestEnterCyclesTheLoopButtonItself`（键盘）＋ `TestCycleRepeatSendsOneToTheEngine`（内核） | 列表循环 → 单曲循环 → 不循环 → 列表循环，标签与状态一致；内核 `loop-file` 只在单曲循环为真；补上了此前缺的 `off → all` 一段 |
| **扫描合并（取消不误删）** | `TestACancelledScanMergeKeepsTracksAndUserWrites` | 取消后只报告 1 首、`authoritative=false` → `Removed=0`；没扫到的曲目仍在；收藏标记仍在；歌单条目仍在；窗口刷新后两行都还在 |
| **直链错误分类** | `TestDirectLinkFailuresReadAsDifferentSentences` | 401 / 403 / 404 / 网络 / 解码五类各自一句可执行中文，互不重复，且都出现在窗口里 |

对应的内核半边（已存在，本阶段未重复实现）：`internal/player/queue_test.go`（预取顺序、并发）、`internal/mpv/failure_test.go`（HTTP 状态 → 分类）、`internal/sources/sync_test.go`、`internal/library/library_test.go`。

### 5.1 `-race`

`go test -race -count=1 ./...` 全绿（§4 输出）。新测试连跑 5 次全部通过：

```
$ go test ./internal/shell -run '<10 个新用例>' -count=5
--- PASS ×50（10 个用例 ×5 次，含队列/详情两处新增键盘用例）
ok  …/internal/shell  1.178s
```

### 5.2 为什么「自定义行」要加 `Focusable`

MyGo 只把 `flagFocusable` 的元素放进 Tab 顺序（`ui/runtime.go` 收集 `focusOrder`），而 `OnClick` 只设 `flagClickable`——点击可用、键盘不可达。两类修法：

1. **自定义可点行/卡片加 `.Focusable()`**（共 18 处）：侧栏导航、侧栏来源与歌单行、表格排序表头、专辑/艺术家/歌单/搜索卡片、搜索各分组行、设置分区；以及不在列表里的整行——队列页「当前播放」行、舞台的队列预览行、搜索「全部」视图的歌曲行（后两者是有界列表，行数受 8/5 限制）。
2. **列表本身做 Tab 停靠点**（与曲库表格同一模型）：队列页「接下来」、专辑详情、艺术家详情原本 `Selected = nil`，列表不可聚焦。现在 `State.QueueList()` / `State.DetailList()` 绑定选择项（`queueSelected` / `detailSelected`，默认 -1，打开新详情时重置），列表内方向键选择、回车经 `Submitted()` 从选中行起播。曲库表格行不加每行停靠点：列表已是停靠点，每行一个反而把 Tab 变成逐行跋涉。

### 5.3 `-race` 暴露的一处测试竞态（不是产品缺陷）

`TestShuffleOffRestoresTheSequentialOrder` 在 `-race` 下随机失败：测试在预取 goroutine 仍在推进 `resolvedNext` 时读取「前缀长度」，随后 `SetShuffle` 用的是更大的 `from`，比较时下标错位。产品行为正确（前缀不动、尾部按原列表恢复）。修法是在测试里先取 `resolveGate`（等住在途解析、挡住下一次），读前缀、关随机、再放行——没有为测试改动产品代码，断言一条没删。

### 5.4 键盘可达性修复后不回归

18 处 `.Focusable()` 与两处列表选择绑定只影响焦点顺序、焦点环与列表内选中行，不改布局；`ui.Tester` 的既有页面测试（`internal/shell` 全量）与 `-race` 全量都通过。

---

## 6. 验收 6：键盘路径逐条实测

| 操作 | 结果 | 测试 |
|---|---|---|
| Tab 到达侧栏「收藏」，回车 | 打开收藏页（`PageFavorites`） | `TestTabReachesTheSidebarAndEnterOpensThePage` |
| Shift+Tab | 回到侧栏上一个停靠点，不会跳出键盘可达范围 | 同上 |
| Tab 到达曲库表格 → ↓ | 选中第 0 行；再 ↓ 到第 1 行 | `TestArrowKeysChooseATrackAndEnterPlaysIt` |
| 回车（表格内） | 从选中行起播，队列为整张列表 | 同上 + `TestEnterOnARowQueuesTheWholeListFromIt` |
| Tab 到达传输条循环按钮 → 回车 ×3 | 列表循环 → 单曲循环 → 不循环 → 列表循环，标签同步 | `TestEnterCyclesTheLoopButtonItself`、`TestLoopButtonCyclesAllThreeStates` |
| 方向键（命令面板） | ↑↓ 移动选中项；回车执行（既有测试） | `TestPaletteOpensFiltersAndPlays` |
| Esc（命令面板） | 关闭 | `TestEscapeClosesThePaletteAndTheStage` |
| Esc（舞台） | 收起回上一页 | 同上 |
| Tab 到达队列页「接下来」列表 → ↓ → 回车 | 从选中行起播（`PlayTracks` 的 `start = 1 + 选中行`） | `TestQueuePageRowsTakeTheKeyboard` |
| Tab 到达专辑详情曲目列表 → ↓ → 回车 | 从选中行起播，`start` 等于选中行 | `TestAlbumDetailRowsTakeTheKeyboard` |
| 歌单行内输入 | 回车提交、Esc 取消（既有测试） | `TestPlaylistCreateRenameAndDeleteThroughTheWindow` |

**明确保留的缺口**：歌词页的行点选（`internal/ui/components/lyrics.go`）只在指针上可用——它所在的 `ui.List` 没有 `Selected`，因此不进 Tab 顺序；键盘替代是舞台的进度滑杆（可聚焦）与 `⌘⇧←/→` 快进 10 s。读屏（VoiceOver）语义仍是简化版，按方案 §2.4 第 47 行留到 M6 之后单列日程。

---

## 7. 需要用户提供什么（公证的唯一缺口）

本机与仓库里都没有 `Developer ID Application` 证书，因此 `notarytool` 一次也没有真正提交过。要补齐 #1/#2：

| 需要 | 用途 | 存放方式 |
|---|---|---|
| Apple Developer Program 账号的 **Team ID** | 证书与公证档案 | 仓库 Secrets `NOTARY_TEAM_ID`（以及 CI 里 `MACOS_SIGNING_IDENTITY` 的身份后缀） |
| **Developer ID Application** 证书（`.p12` + 导出密码） | 签名（Apple Development 不能用于分发） | Secrets `MACOS_CERTIFICATE`（base64）、`MACOS_CERTIFICATE_PASSWORD` |
| 签名身份的完整名称，如 `Developer ID Application: 名字 (TEAMID)` | `codesign -s` | Secret `MACOS_SIGNING_IDENTITY`（**不写进 `mygo.json`**） |
| Apple ID 与 **App 专用密码**（或 App Store Connect API Key） | `notarytool` | Secrets `NOTARY_APPLE_ID`、`NOTARY_PASSWORD` |

凭据只进团队的 Secrets（仓库 Settings → Secrets and variables → Actions，或平台的 Secrets 页面），**不要发在对话里、不要提交进仓库、不要写进日志**——流水线本身已经按此实现（临时钥匙串、`-T /usr/bin/codesign`、`set-key-partition-list`、结束即删）。

凭据到位后，完成验收只需两步，无需改代码：

```bash
# 本机（凭据已在钥匙串）
SIGN_IDENTITY="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=notary DMG=1 ./scripts/bundle.sh
./scripts/verify-bundle.sh build/darwin-universal/听屿-0.1.0.dmg --require-notarized
# CI：把 6 个 Secrets 加到仓库，推 client/** 即可；公证路径会自动打开 --require-notarized
```

---

## 8. 未做与风险

- **公证未执行**：`spctl`、隔离件首启两条按实际情况记为未通过（§0 #1/#2）；流水线、错误处理与判定已就绪。
- **GitHub Actions 未实际运行**：本机没有 runner；只验证了 YAML 可解析与全部步骤的本地等价命令。首次真正的 CI 运行仍需在推分支后观察。
- **Intel 实机未测**：`darwin/universal` 交叉编译与 lipo 由 MyGo 完成，本机只有 arm64 可跑。
- **DMG 非 bit-for-bit 可复现**：`hdiutil` 写入时间元数据；内容（app、framework、链接）与签名过程可重复。
- **`--timestamp` 需要网络**：脚本重试一次；MyGo 自身的签名若在该处失败会使构建失败（上游行为），CI 重跑一次即可。
- **读屏语义**：仍是简化版（方案已接受该回归）；键盘可达性与焦点环是本阶段保证的部分。
