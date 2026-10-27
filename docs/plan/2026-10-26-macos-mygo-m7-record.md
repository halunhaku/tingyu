# 听屿 macOS 端 MyGo 迁移 · M7 切换与收尾实施与验收记录

> 历史记录：旧 Swift 客户端及其一次性导出工具已从当前工作树清理；下文相关路径描述的是当时的状态。

日期：2026-10-26（Asia/Shanghai）
性质：**M7 实施与验收记录**。本阶段按方案的顺序执行「**打 tag → 备份真实数据 → 真实库切换验收 → 删除 Flutter 与残留工具链 → 文档/CI 收口**」，每一步都实测后才进入下一步。**未合并 main、未打 release、未推送 tag、未写任何凭据、未伪造公证或播放结果**。
判据来源：[迁移方案 §6 的 M7 行、§8.1 双轨规则、§8.2 切换判据](./2026-10-25-macos-mygo-migration-plan.md)；上一阶段：[M6 记录](./2026-10-26-macos-mygo-m6-record.md)。入口文档：[根 README](../../README.md)、[`client/README.md`](../../client/README.md)。

环境：Apple Silicon（arm64），macOS 27.2；Go 1.27.3 darwin/arm64（`CGO_ENABLED=0`）；MyGo v0.6.4；真实曲库 `~/Library/Application Support/com.halunhaku.tingyu/library.sqlite`。

---

## 0. 结论

| # | 验收项（本 todo） | 结论 | 证据 |
|---|---|---|---|
| 1 | tag `archive/flutter-macos` 存在且指向删除前提交 | **通过**（annotated tag → `01f105a`；该提交树内 `app/` 有 252 个文件） | §2 |
| 2 | 备份目录存在、`library.sqlite` 校验和与备份一致 | **通过**（`backups/20261026-115008/`，sha256 `310526fd…1fb73` 双方一致；179 个封面 + `SHA256SUMS`） | §3 |
| 3 | 真实库切换后曲目 178、收藏/歌单/历史条数不变、`user_version` 仍为 2、播放后历史写库 | **通过**（逐表行哈希与备份**完全相同**；两次真实播放各写入 `play_count` 与 `last_played_at`） | §5 |
| 4 | 删除 `app/`、`tools/*.ps1`、`engine-patches/`、`flutter.yml`，仓库无构建引用 | **通过**（共 277 个跟踪文件；构建/脚本/CI 里的 Flutter 引用为 **0**） | §6、§7 |
| 5 | 根 `README.md` 改为「macOS 单端、Go + MyGo」；`client/README.md` 补数据目录与备份 | **通过** | §7.3 |
| 6 | 删除后 `CGO_ENABLED=0` build/vet/test、`-race`、`gofmt -l` 干净；`bundle.sh` 出包并在真实数据上启动播放 | **通过**（全绿；删除后的包在真实库上扫描、出声、写历史、干净退出） | §8 |
| 7 | 只跑 macOS 的 workflow 仍有效 | **通过**（本地逐条等价命令全绿；`macos.yml` 的 paths 只有 `client/**`） | §8.3 |

一句话：**真实曲库已在 MyGo 版上被打开、播放并写回历史，逐表内容与切换前备份逐行一致；Flutter 客户端与残留 Windows 工具链已删除，删除前状态由 tag `archive/flutter-macos` 完整保留；唯一未推送到远端的是这个 tag（按 todo 要求本阶段不推）。**

---

## 1. 执行顺序与失败即停

方案 §6 的 M7 要求「双轨验收、数据迁移、删除」，本 todo 又把顺序钉死。实际执行顺序（每步通过才继续）：

1. **打 tag**：在删除任何文件之前，用当前 tip（含 `app/`）建 `archive/flutter-macos`；
2. **备份真实数据**：`library.sqlite`、`covers/`、`settings.json`（不存在则记录）→ `backups/<timestamp>/`，并逐文件校验；
3. **切换语义 + 验收**：先在真库上启动（只读快照对比），再做一次真实播放，证明历史写库；
4. **删除**：`app/`、`tools/*.ps1`、`tools/engine-patches/`、`tools/win-engine-shims/`、`.github/workflows/flutter.yml`、`.gitattributes`；
5. **文档与 CI 收口**：根 README、`client/README.md`、`DESIGN.md` 状态说明、`macos.yml`、`bundle.sh`/`fetch-frameworks.sh` 的取件方式；
6. **删除后复验**：build/vet/test/`-race`/gofmt/打包/启动/真实库播放。

一旦某步失败就停在原地报告；本次没有触发停止。

---

## 2. 删除前的 Flutter 快照：tag `archive/flutter-macos`

```text
$ git rev-parse archive/flutter-macos
c8d9e82d7e6857d815a7634001f42eaed23e6164      # annotated tag 对象
$ git rev-parse 'archive/flutter-macos^{}'
01f105a8a3c7397a0866bf7cc27b60bc1a506ae9      # 删除前提交（M5 的 PR #18 合并点）
$ git ls-tree -r --name-only archive/flutter-macos -- app | wc -l
252
$ git show archive/flutter-macos:app/pubspec.yaml | head -4
name: tingyu
description: "听屿：连接本地文件夹、WebDAV 私人云与夸克网盘的 macOS 音乐播放器。"
publish_to: 'none'
version: 2.0.0-preview+5
```

tag 是 **annotated**（附注 tag），正文写明回退命令与「此处之后 `app/` 被删除」。只建 tag，**没有建 release**。

> **关于「`git show --stat` 能看到 `app/`」这条口径**：删除前的 tip 是一个 **merge commit**（`01f105a`，PR #18 合并），`git show --stat` 展示的是「相对第一父提交的合并差异」，因此只列 `client/` 的改动、不列 `app/` —— 这不代表 tag 里没有 `app/`。等价且不依赖父提交形态的取证有三条：
>
> 1. `git ls-tree -r --name-only archive/flutter-macos -- app` → 252 个文件；
> 2. `git show archive/flutter-macos:app/pubspec.yaml` → 完整的 `tingyu 2.0.0-preview+5` 工程描述；
> 3. 最后一次改动 `app/` 的提交是 `1ff8592`（2026-10-25 15:32 `refactor(app): shrink Flutter client to macOS-only`），`git show --stat 1ff8592 | grep app/` 能看到全部改动；且 **两个提交的 `app/` 树哈希相同**（`git rev-parse HEAD:app` = `git rev-parse 1ff8592:app` = `cd551c54…b6e4`），证明 tag 指向的树里 `app/` 与最后一次修改时逐字节一致。
>
> 删除提交落地后，删除量可直接看：`git diff --stat archive/flutter-macos HEAD -- app`（252 files changed）。本阶段实际删除量见 §6。

### 找回 Flutter 版（具体命令）

```bash
# 完整工作区（推荐：可以直接 flutter run）
git worktree add /tmp/tingyu-flutter archive/flutter-macos
cd /tmp/tingyu-flutter/app && flutter pub get && flutter run -d macos

# 只取客户端目录
git archive --format=tar archive/flutter-macos app/ | tar -x -C /tmp

# 单文件
git show archive/flutter-macos:app/lib/main.dart
```

tag 的本地对象是 `c8d9e82`，指向提交 `01f105a`。**本 todo 不推送它**；要长期保留（远端仓库/克隆消失也还在），在一个有写权限的克隆里执行：

```bash
git push origin archive/flutter-macos
```

推送前请先确认那个克隆里有这个 tag（`git tag -l 'archive/*'`）；平台只会推送本会话的分支，不会带 tag。

---

## 3. 切换前备份

```bash
DATA="$HOME/Library/Application Support/com.halunhaku.tingyu"
B="$DATA/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$B"
cp -p "$DATA/library.sqlite" "$B/library.sqlite"
cp -Rp "$DATA/covers" "$B/covers"
[ -f "$DATA/settings.json" ] && cp -p "$DATA/settings.json" "$B/settings.json"
```

| 项 | 结果 |
|---|---|
| 备份目录 | `~/Library/Application Support/com.halunhaku.tingyu/backups/20261026-115008/` |
| `library.sqlite` sha256（源 / 备份） | `310526fdbac4e7dd9615c4d124bb28049146f87f4bce00629ed8f10b4581fb73`（**一致**） |
| 备份库自检 | `PRAGMA integrity_check` = `ok`；`user_version` = 2；`tracks` = 178 |
| 封面 | 179 个 `covers/*.jpg`，共 31 MB（含 1 张无引用孤儿，与切换前一致） |
| `settings.json` | **不存在**（客户端用默认外观时从不创建它；备份记录为空，不是漏备） |
| 追加证据 | 备份目录内 `SHA256SUMS`（185 行：库 + 179 封面 + 3 份 SQL 快照 + 2 份运行日志）、`SQL-before.txt`、`SQL-interim.txt`、`SQL-after.txt`、`switch-run1.log`、`switch-run2.log` |

恢复（退出 App 后执行）：

```bash
DATA="$HOME/Library/Application Support/com.halunhaku.tingyu"
B="$DATA/backups/20261026-115008"
cp -p "$B/library.sqlite" "$DATA/library.sqlite"
rm -rf "$DATA/covers" && cp -Rp "$B/covers" "$DATA/covers"
# 需要时：cp -p "$B/settings.json" "$DATA/settings.json"
```

---

## 4. 切换语义：真实目录默认读写，只读变成显式选择

M7 之前，客户端「未设置 `TINGYU_DATA_DIR` 就只读」，这是双轨期的保护（方案 §8.1 第 2 条）。切换到真实库后如果照旧，**双击打开正式包的进程永远写不了任何东西**（扫描、收藏、历史、补全都不落库），这等于没切换。因此本阶段把默认反转为：

| 场景 | 打开方式 |
|---|---|
| 正式运行（默认） | 真实数据目录，**读写** |
| 开发/验收指向副本 | `TINGYU_DATA_DIR=/path/to/copy`，读写该副本 |
| 只看不动（含真实库） | `TINGYU_READ_ONLY=1`，只读打开选中的库 |

改动点：

- `client/internal/library/library.go`：新增 `ReadOnly()`（识别 `1/true/yes/on`），包注释与 `DataDir()` 注释改写为 M7 事实；
- `client/internal/app/app.go`：`prepare()` 默认 `OpenWritable`，`TINGYU_READ_ONLY` 时才 `Open`；启动日志打印 `read-write` 或 `read-only (TINGYU_READ_ONLY)`；
- 只读提示文案（`app`、`sources`、`metadata`、设置页、引导页、错误态）统一为「本次以 TINGYU_READ_ONLY=1 打开，不能…；去掉该变量后重试」；
- `client/internal/library/library_test.go` 新增 `TestReadOnlyIsAnExplicitOptIn`，把「默认可写、只读必须显式」钉进测试。

> 口径说明：方案 §8.1 第 2 条（开发期不写生产库）没有取消，而是从「默认」改成「显式开关 + 测试守护」。切换判据 §8.2 里的「真实库连续播放」本来就要求写真实库，二者在 M7 汇合。

---

## 5. 真实库切换验收

### 5.1 启动：读写打开、178 首、`user_version` 2

删除任何文件之前，用 `bundle.sh` 产出的包直接启动（不设 `TINGYU_DATA_DIR`，即真实目录）：

```bash
cd client
./scripts/bundle.sh
APP="build/darwin-arm64/听屿.app/Contents/MacOS/听屿"
TINGYU_ENRICH_AUTO=0 TINGYU_STARTUP_LOG=/tmp/m7/run1.log TINGYU_AUTO_QUIT_MS=5000 "$APP"
```

```text
library: 178 tracks / 26 albums / 3 artists / 0 playlists from /Users/halunhaku/Library/Application Support/com.halunhaku.tingyu/library.sqlite (read-write, user_version 2)
playback: libmpv Mpv client API 2.1
startup ready             783.2ms since process,   545.3ms since main
app: quit complete
```

> `TINGYU_ENRICH_AUTO=0` 是验收专用：自动补全会按设计对真实库发起网络抓取并写回标题/封面，那会污染前后对比。正式运行默认是开启的。

### 5.2 播放与历史写库

**为什么不是直接播库里那 178 首**：这 178 首全部是 `quark://` 远端曲目（`SELECT substr(file_path_or_url,1,8), count(*)` → `quark:// 178`）；方案 §3.4 规定**凭据不迁移、只重填**，而 Go 客户端的钥匙串服务 `com.halunhaku.tingyu.sources` 里没有条目（`security find-generic-password -s com.halunhaku.tingyu.sources` → `could not be found`），所以播放真实远端曲目必须先由用户重新扫码登录。**没有绕过凭据去伪造一次"播放"**。

替代方案（同样是真实库、真实播放、真实写库）：用同一台机器生成的 2 个 6 秒 FLAC 作**验收夹具**，走应用的正常路径「扫描目录 → 入库 → 双击式起播」：

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=6" -metadata title="M7 Switch Tone" \
  -metadata artist="Tingyu Acceptance" -metadata album="M7 Acceptance" -c:a flac /tmp/m7/media/01-m7-tone.flac
# （02 同理，523.25 Hz）

TINGYU_ENRICH_AUTO=0 TINGYU_STARTUP_LOG=/tmp/m7/run2.log \
TINGYU_AUTO_SCAN_DIR=/tmp/m7/media TINGYU_AUTO_PLAY_TITLE="M7 Switch Tone" \
TINGYU_AUTO_QUIT_MS=20000 "$APP"
```

```text
library: 178 tracks … (read-write, user_version 2)
scan: done in 8ms: 扫描完成：文件 2，入库 2（新增 2 / 更新 0 / 移除 0）
accept: title "M7 Switch Tone" matched "M7 Switch Tone"
play: sound after 264.9 ms for "M7 Switch Tone" (index=0)
mpv: end-file reason=0 err=0          # 第一首自然播完，gapless 进第二首
app: quit complete
```

历史确实写进了真实库（`play_count` 与 drift 的 UTC 微秒格式 `last_played_at`）：

```text
title               play_count  last_played_at
------------------  ----------  ---------------------------
M7 Switch Tone      2           2026-10-26T03:53:12.677345Z
M7 Switch Tone Two  2           2026-10-26T03:53:18.482928Z
```

（夹具连播两轮 ⇒ 各 2 次；`play_count` 求和 37 → 41，有播放历史的曲目 15 → 17。）

### 5.3 夹具清理

夹具是临时的。按生产 `library.DeleteSource` 的同一顺序删（先曲目、再来源；`playlist_items` 走外键级联），事务内完成：

```sql
PRAGMA foreign_keys=ON;
BEGIN;
DELETE FROM tracks WHERE source_id='src-1792986780541865';
DELETE FROM music_sources WHERE id='src-1792986780541865';
COMMIT;
```

清理后 `tracks` 回到 178、`music_sources` 回到 1；夹具的两首曲目连同它们的历史行一起消失（它们不属于原库）。

### 5.4 切换前后数据库对比

| 指标 | 切换前（= 备份库） | 播放验收中（夹具在库） | 清理后（最终） |
|---|---|---|---|
| `tracks` | 178 | 180 | **178** |
| 收藏 `is_favorite=1` | 0 | 0 | **0** |
| 歌单 `playlists` | 0 | 0 | **0** |
| 歌单条目 `playlist_items` | 0 | 0 | **0** |
| 有播放历史 `last_played_at IS NOT NULL` | 15 | 17 | **15** |
| `sum(play_count)` | 37 | 41 | **37** |
| `music_sources` | 1 | 2 | **1** |
| `PRAGMA user_version` | 2 | 2 | **2** |
| `PRAGMA integrity_check` | ok | ok | **ok** |

逐表行哈希（`SELECT * FROM <t> ORDER BY rowid | shasum -a 256`，最终库 vs 备份库）：

```text
tracks           SAME   0443094560873adcb92e4424efcfd9b2337f392840e9454d04673f039fa67861
music_sources    SAME   4e31a4dae39c1781045a15a82a87de9f194be715735b938969b907985af97e1b
playlists        SAME   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855   # 空表
playlist_items   SAME   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855   # 空表
```

即：**MyGo 版在真实库上完成了一次完整的「打开 → 扫描 → 播放 → 写历史 → 退出」，而库的持久内容与切换前逐行完全一致**（除了验收夹具的读写，最终被清理干净）。用户原来的 178 首、15 首播放历史与 37 次计数一个字节没变。

> 收藏与歌单的真实条数都是 0（这个库从来没有收藏/歌单），所以对比是 0 = 0。写入能力由内核数据能力阶段的单测/端到端用例覆盖（`internal/library`、`internal/shell`），本阶段没有为了"有数字"去制造收藏或歌单。

### 5.5 删除后复验（同一真实库）

删除 `app/` 与工具链、并用 `fetch-frameworks.sh` 重新取件、重新打包后，再跑一遍同样的真实库播放（`run3`）：

```text
library: 178 tracks / 26 albums / 3 artists / 0 playlists … (read-write, user_version 2)
scan: done in 3ms: 扫描完成：文件 2，入库 2（新增 2 / 更新 0 / 移除 0）
accept: title "M7 Switch Tone" matched "M7 Switch Tone"
play: sound after 158.7 ms for "M7 Switch Tone" (index=0)
app: quit complete
```

同样是扫描 → 出声 → 写历史 → 干净退出，清理后逐表行哈希仍与备份 **SAME**。

### 5.6 本阶段没有验证的

- **真实夸克曲目的播放**：需要用户重新扫码登录（凭据不迁移）。M3 记录已说明夸克协议未在真实账号上验证，本阶段不改变这个结论。
- **公证**：本机只有 Apple Development 身份，没有 Developer ID，`spctl` 仍是 `rejected`（与 M6 记录一致，不伪造）。
- **`settings.json`**：真实目录里从来没有这个文件；备份/恢复路径已按「存在才复制」实现。

---

## 6. 删除清单（不可逆操作）

### 6.1 删了什么

| 路径 | 跟踪文件数 | 说明 |
|---|---|---|
| `app/` | **252** | Flutter macOS 客户端（`lib/`、`macos/`、`test/`、`assets/`、`pubspec.*`）；删除 60,659 行 |
| `tools/*.ps1` | **15** | Windows 截图/引擎/无障碍/质量脚本（`bootstrap-windows-engine`、`build-windows-engine`、`compare-png`、`p4-quality`、`p4-runtime-visual`、`p6a-automated-acceptance`、`p6a-runtime-matrix`、`repair-windows-engine-deps`、`windows-*` 8 个） |
| `tools/engine-patches/` | **6** | Windows Flutter 引擎补丁与说明（4 个 patch/配置 + README + requirements） |
| `tools/win-engine-shims/` | **2** | Windows 引擎构建用的 `git.bat`、`python3.bat` |
| `.github/workflows/flutter.yml` | **1** | Flutter 的 analyze/test/build/release 流水线（147 行） |
| `.gitattributes` | **1** | 只服务于已删除的 `tools/engine-patches/*.patch`（Windows 补丁字节稳定性） |
| **合计** | **277** | `git diff HEAD --numstat` 汇总：**63,906 行删除**（`app/` 60,659 · `tools/` 3,097 · `flutter.yml` 147 · `.gitattributes` 3），无新增 |

**没有删**：`docs/`（全部历史档案与两份调研/方案）、`legacy-swift/`（SwiftUI 旧版，冻结）、`tools/legacy-export/`（旧 SwiftData 曲库的一次性导出工具，属 legacy 工具而非 Flutter 构建）、`spike/`（S1/S2 验证小样）、`client/`。

### 6.2 怎么找回

```bash
# Flutter 客户端（252 个文件，含 macos 工程）
git worktree add /tmp/tingyu-flutter archive/flutter-macos

# 只恢复某几类文件（另一个提交/分支上也一样）
git checkout archive/flutter-macos -- app/
git checkout archive/flutter-macos -- tools/
git checkout archive/flutter-macos -- .github/workflows/flutter.yml .gitattributes
```

注意 `git checkout <tag> -- app/` 会把文件放回工作区（并进入暂存区），需要时再决定是否提交；直接从 tag 浏览用 `git show archive/flutter-macos:app/pubspec.yaml`。

---

## 7. 残留引用清理与 `grep` 证据

### 7.1 构建/脚本/CI：Flutter 引用为 0

```bash
$ grep -rn -i "flutter\|app/lib" --include='*.sh' --include='*.yml' --include='*.yaml' --include='*.json' --include='*.ps1' \
    --exclude-dir=docs --exclude-dir=build .
(no output)
```

两处**功能性**依赖被一并移除：

- `client/scripts/bundle.sh` 原来从 `~/.pub-cache/.../media_kit_libs_macos_audio-*/macos/Frameworks` 兜底找 libmpv；删除 Flutter 后这条路不复存在。现在默认用 `scripts/fetch-frameworks.sh` 下载到 `build/frameworks`（版本 + sha256 钉住），**没有就报错并给出命令**，不再隐式依赖 pub 缓存。
- `client/scripts/fetch-frameworks.sh` 的注释改为「钉住的 LGPL mpv 0.36 + FFmpeg 构建」，来源说明指向 spike 记录 §1.2。

### 7.2 文档

- **根 `README.md` 重写**：项目入口 `client/`、Go + MyGo、macOS 单端；构建与运行、目录结构、数据目录/备份/找回、里程碑索引（M0–M7 + 调研）、平台状态表、CI。截图换成 Go 客户端的 `m4-*.png`。
- **`client/README.md`**：新增/改写「数据目录、备份与写库边界」（真实目录、`TINGYU_READ_ONLY`、备份与恢复、M7 外链）、环境变量表、CI 段落；顶部声明 Flutter 已删、文中的「与 Flutter 版一致」都是历史说明。
- **`DESIGN.md`**：顶部加 M7 状态说明——本文是 Flutter 时期的「声档」设计契约，`lib/**`、`flutter test`、`tools/windows-*.ps1` 均为历史路径；现行实现是 `client/internal/ui/tokens`。
- **`docs/`**：按约束**原样保留**（迁移方案、M0–M7 记录、审计、调研、P4/P5 证据）。它们里面的 `app/lib`、`flutter test`、`tools/*.ps1` 是历史档案的一部分，不被任何脚本执行。

### 7.3 代码注释

`grep -rin flutter client --include='*.go'` 仍有 **87 处 / 43 个文件**，全部是**移植来源注释**（例如「the Flutter client's LRU size」「app/lib/data/db/schema.dart 的 drift 类型」「与 Flutter 版同一套 24px / 12 色相桶」）。它们不是构建引用，删掉会让「这一行为什么长这样」失去依据，因此**保留**。

> 验收口径偏差的说明：todo 写的是「仓库内 `grep -ri flutter` 只剩文档里的迁移历史说明（不得有构建引用）」。实测口径是：**构建/脚本/CI/配置里 0 处**（§7.1），文档与根目录说明里是有意保留的历史（§7.2），Go 源码注释里 87 处是移植 provenance（§7.3）。这样处理是为「不为了过 grep 而抹掉真实历史」，而不是放过构建引用——构建引用已经清零。

---

## 8. 删除后复验

### 8.1 质量门（`client/`，删除后重跑）

```bash
$ CGO_ENABLED=0 go build ./...        # 无输出
$ CGO_ENABLED=0 go vet ./...          # 无输出
$ gofmt -l .                          # 无输出
$ CGO_ENABLED=0 go test ./...         # 全部 ok（app/enrich/images/library/metadata/mpv/player/rangesrv/scan/shell/sources/titleparse/ui/model）
$ CGO_ENABLED=0 go test -race -count=1 ./...   # 全部 ok
```

`internal/library` 新增的 `TestReadOnlyIsAnExplicitOptIn` 通过；`-race` 下 `library` 17.7 s、`shell` 14.2 s，无数据竞争。

### 8.2 打包与启动（CI 里同一条路径）

```bash
$ ./scripts/fetch-frameworks.sh
fetch-frameworks: downloading v0.6.0 into build/frameworks
build/frameworks

$ ./scripts/bundle.sh
bundle: 听屿 0.1.0 (com.halunhaku.tingyu), minimum macOS 12.0, darwin/arm64, ad-hoc signature
bundle: build/darwin-arm64/听屿.app (frameworks from build/frameworks)
  signature                    ad-hoc (not distributable; pass SIGN_IDENTITY)

$ ./scripts/verify-bundle.sh build/darwin-arm64/听屿.app --launch
ok    the app started: startup ready            2835.3ms since process,  2041.8ms since main
result: not notarized — acceptable for development, not for distribution

# 与 CI 完全相同的形态（universal + DMG）
$ PLATFORM=darwin/universal DMG=1 OUT=build/ci ./scripts/bundle.sh
bundle: build/ci/darwin-universal/听屿.app (frameworks from build/frameworks)
bundle: build/ci/darwin-universal/听屿-0.1.0.dmg
$ ./scripts/verify-bundle.sh build/ci/darwin-universal/听屿.app
$ ./scripts/verify-bundle.sh build/ci/darwin-universal/听屿-0.1.0.dmg
ok    the image holds the /Applications drag target
ok    libmpv ships inside the image
```

首启 2.8 s 是运行在空 HOME + 全新数据目录、且系统对该二进制做首次校验的一次性开销（M1 记录里的同一现象）；常规冷启动见 `client/README.md` 的 10 次测量。

### 8.3 CI 复核

`macos.yml` 只触发 `client/**` 与自身，步骤为 `gofmt -l` → `go vet` → `go test -race` → `fetch-frameworks.sh` → `bundle.sh` → `verify-bundle.sh`，**不引用 `app/`**，删除后逐条在本地等价跑通（上面 §8.1/§8.2）。仓库现在只有这一个 workflow。

---

## 9. 逐条验收（对照 todo 的「验收」）

| # | 要求 | 结果 |
|---|---|---|
| 1 | tag 存在且指向删除前提交（`git show --stat` 能看到 `app/`） | 通过（tag `c8d9e82` → `01f105a`；`git ls-tree` 252 个 `app/` 文件；`--stat` 在 merge 提交上的口径见 §2） |
| 2 | 备份目录存在、`library.sqlite` 校验和与备份一致 | 通过（§3） |
| 3 | 切换后曲目 178、收藏/歌单/历史条数与删除前一致（SQL 对比）、`user_version` 2、播放写库 | 通过（§5；逐表行哈希与备份 SAME） |
| 4 | 删除后 build/vet/test、`-race`、`gofmt -l` 干净；`bundle.sh` 出包并在真实数据上启动播放 | 通过（§8.1/§8.2/§5.5） |
| 5 | `grep -ri flutter` 只剩文档历史说明（不得有构建引用） | 构建/脚本/CI **0 处**；文档与代码注释的历史说明保留（口径见 §7.3） |
| 6 | CI workflow 仍能通过本地等价命令 | 通过（§8.3） |
| 7 | 顺序：tag → 备份 → 切换验收 → 删除 | 按此执行，未颠倒（§1） |
| 8 | 不删 `docs/`、不删 `legacy-swift/`；不在未备份时写真实库；不合并 main、不打 release | 全部遵守；tag 未推送远端（§2） |

---

## 10. 未做与后续

- **tag 推送**：本 todo 明确不推。建议在合并前/后由用户在一个有写权限的克隆里 `git push origin archive/flutter-macos`，否则 tag 只存在于本地仓库。
- **夸克重新登录**：真实远端曲目要等用户重新扫码；登录后应再跑一次「播放真实远端曲目 → 历史写库」的实机验收（本阶段因凭据未迁移无法做）。
- **`user_version` 30 天冻结**：切换后 30 天内不改版本号（方案 §8.1 第 3 条）；要加不可空列或改语义，排到 30 天之后。
- **收藏/歌单为 0**：真实库确实没有收藏与歌单；写入能力由测试覆盖，不是本阶段缺失。
- **公证**：仍缺 Developer ID 凭据，`spctl` 未通过（与 M6 一致）。
