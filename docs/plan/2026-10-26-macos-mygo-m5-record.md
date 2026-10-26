# 听屿 macOS 端 M5 记录：元数据与图片

日期：2026-10-26（Asia/Shanghai）
性质：**实现记录 + 验收证据**。本阶段对应方案 §6 的 M5 行（`docs/plan/2026-10-25-macos-mygo-migration-plan.md:461`）。
基线：`tds` 工作分支（相对 `main`），未合并、未打 tag；生产库只读。
约束遵循：不改 `app/`、不改签名/公证/CI/打包（并行 M6 todo）、不改播放内核、不改视觉设计语言（只把取色接到既有舞台）、`user_version` 保持 2、只加可空列/索引。

## 0. 结论

方案 §6 M5 的六项全部落地并有实测证据，验收脚本 `client/scripts/run-m5-accept.sh` 的 12 项检查全绿：

| # | M5 子项 | 状态 | 落点 |
|---|---|---|---|
| 1 | 元数据补全（4 源 + AI 兜底） | **已完成**（4 源实网实测；AI 兜底实现并单测，未用真实密钥跑通，见 §7） | `client/internal/metadata/`、`client/internal/enrich/` |
| 2 | 人工匹配（确认/改写并写回，重启仍在） | **已完成** | `client/internal/ui/components/match.go`、`client/internal/app/metadata.go`、`library.ManualMatch` |
| 3 | 封面缓存（内容寻址 + 孤儿回收 + 进列表与舞台） | **已完成**（复用 M1 的 `scan.CoverName/SaveCover/CollectOrphanCovers`，新增抓取、计数与列表封面列） | `client/internal/images/`、`client/internal/ui/components/table.go` |
| 4 | 封面取色（供舞台、含兜底） | **已完成** | `client/internal/images/palette.go`、`client/internal/ui/model/coverpalette.go`、`client/internal/ui/pages/stage.go` |
| 5 | 歌词（获取 + 逐行/逐字两种渲染） | **已完成**（LRCLIB 主、网易云兜底；行级 LRC 摊成逐字） | `client/internal/metadata/lrclib.go`、`netease.go`、`client/internal/ui/model/lrc.go`、`components/lyrics.go` |
| 6 | 补全后列表与舞台立即刷新（不重启） | **已完成**（写入递增 revision，下一帧重读；同进程前后截图） | `library.ApplyEnrichment`、`model.Invalidate` |

## 1. 验收方法（可复现）

```bash
cd client
./scripts/run-m5-accept.sh              # gofmt + build + vet + test + test -race，再跑验收 harness
./scripts/run-m5-accept.sh -tracks 20   # 同上（默认 20）
./scripts/run-m5-accept.sh -skip-network
```

harness（`client/internal/m5accept`）**只读生产库**：把 `~/Library/Application Support/com.halunhaku.tingyu/` 下的 `library.sqlite` 与 `covers/` 复制到 `build/m5-accept/<时间戳>/data/`，在副本上把 20 首完整曲目降级成「扫描到无标签文件」的形态（文件名式标题、`未知艺术家`/`未知专辑`、无封面、无歌词），然后走产品同一条管线（`metadata.Enricher` → `enrich.Service` → `library.ApplyEnrichment`）。20 首按艺术家轮转选取（周杰伦 / 张碧晨 / 陈粒 等，覆盖 10 张以上专辑）。

证据目录（本次运行 `build/m5-accept/final4/`，已归档）：
- `docs/plan/2026-10-26-macos-mygo-m5-evidence.json`（harness 报告原文，含 `db-before`/`db-after` 的关键计数）
- `docs/screenshots/m5-before-library.png`、`m5-after-library.png`、`m5-after-stage.png`、`m5-after-stage-dark.png`、`m5-after-stage-words.png`、`m5-settings-metadata.png`、`m5-match-dialog.png`、`m5-gray-cover.png`

## 2. 验收逐条（12 项，全部通过）

| 检查 | 结果 | 证据 |
|---|---|---|
| `m5.production-read-only` | 通过 | 开始时记录生产库 sha256 与 `user_version=2`；结束时复查 |
| `m5.copy` | 通过 | 副本 = `library.sqlite` + `covers/`；生产目录只被读取 |
| `m5.schema-version` / `m5.copy-schema-version` | 通过 | 副本 `user_version` 始终为 2（未提升、未加不可空列） |
| `m5.enrich` | 通过 | 处理 20、变更 20、失败 0；标题 20、封面 20、歌词 20；**20/20 与原始标题完全一致**；HTTP 请求 48 次 |
| `m5.ui-refresh` | 通过 | 补全前列表显示无标签标题、补全后同一进程的列表与舞台显示新标题；`revision 0→20`；7 张截图（含逐字渲染） |
| `m5.cover-cache` | 通过 | 下载 6、命中 19（**命中率 76%**）、写入 6、字节 853,059；5 次热命中**未发新请求** |
| `m5.orphan-covers` | 通过 | 预清理历史孤儿 22 个；删除测试来源后候选封面 2 个，本轮清理 **1** 个；共享封面保留、独占封面删除 |
| `m5.offline` | 通过 | 离线 3/3、失败 0、封面与歌词均未写入、UI 错误条为空 |
| `m5.manual-match` | 通过 | 写回后**用新的只读连接重开**，标题/艺术家/专辑/封面/歌词全部仍在 |
| `m5.palette` | 通过 | 同一封面：深色 `#1D1615→#0F1417`（对比 16.2:1），浅色 `#E9DEDA→#DAE6E9`（13.7:1）；灰封面回退中性渐变 |
| `m5.production-unchanged` | 通过 | 生产库 sha256 `310526fdbac4e7dd…` 前后一致，`user_version` 2 |

覆盖率计数（副本，SQL `COUNT(*)`）：

| 指标 | 补全前 | 补全后 |
|---|---|---|
| 曲目 | 178 | 178 |
| `artist = 未知艺术家` | 20 | **0** |
| 有封面 `cover_art_path` | 158 | **178** |
| 有歌词 | 158 | **178** |

## 3. 20 首无标签曲目：数据库前后对比

标题来自「文件名式标题」（`NN. 艺术家-歌名-专辑`），降级后 `artist=未知艺术家`、`album=未知专辑`、封面/歌词为 NULL。补全后（同一份副本）：

| # | 补全前标题 | 补全后标题 | 艺术家 | 专辑 | 封面文件 | 歌词字节 |
|---|---|---|---|---|---|---|
| 1 | `01. 周杰伦-一路向北-J III MP3 Player` | 一路向北 | 周杰伦 | J III MP3 Player | `69d759041827d648.jpg` | 103 |
| 2 | `02. 张碧晨-守月-守月` | 守月 | 张碧晨 | 守月 | `315be0a0aec808c6.jpg` | 1459 |
| 3 | `03. 陈粒-清透-贴近大地` | 清透 | 陈粒 | 贴近大地 | `7530df2392cacf66.jpg` | 1296 |
| 4 | `04. 周杰伦-伊斯坦堡-Jay` | 伊斯坦堡 | 周杰伦 | Jay | `588d48213df9541f.jpg` | 1266 |
| 5 | `05. 周杰伦-印第安老斑鸠-Jay` | 印第安老斑鸠 | 周杰伦 | Jay | `588d48213df9541f.jpg` | 2835 |
| 6 | `06. 周杰伦-反方向的钟-Jay` | 反方向的钟 | 周杰伦 | Jay | `588d48213df9541f.jpg` | 1801 |
| 7 | `07. 周杰伦-可爱女人-Jay` | 可爱女人 | 周杰伦 | Jay | `588d48213df9541f.jpg` | 2333 |
| 8 | `08. 周杰伦-娘子-Jay` | 娘子 | 周杰伦 | Jay | `588d48213df9541f.jpg` | 2781 |
| 9 | `09. 周杰伦-完美主义-Jay` | 完美主义 | 周杰伦 | Jay | `588d48213df9541f.jpg` | 2169 |
| 10 | `10. 周杰伦-斗牛-Jay` | 斗牛 | 周杰伦 | Jay | `588d48213df9541f.jpg` | 2966 |
| 11 | `11. 周杰伦-星晴-Jay` | 星晴 | 周杰伦 | Jay | `588d48213df9541f.jpg` | 1533 |
| 12 | `12. 周杰伦-黑色幽默-Jay` | 黑色幽默 | 周杰伦 | Jay | `588d48213df9541f.jpg` | 1324 |
| 13 | `13. 周杰伦-龙卷风-Jay` | 龙卷风 | 周杰伦 | Jay | `588d48213df9541f.jpg` | 1819 |
| 14 | `14. 周杰伦-Mojito-Mojito` | Mojito | 周杰伦 | Mojito | `496a2744d96ecb2b.jpg` | 1622 |
| 15 | `15. 周杰伦-七里香-七里香` | 七里香 | 周杰伦 | 七里香 | `7172b388c6ed5739.jpg` | 1652 |
| 16 | `16. 周杰伦-乱舞春秋-七里香` | 乱舞春秋 | 周杰伦 | 七里香 | `7172b388c6ed5739.jpg` | 2954 |
| 17 | `17. 周杰伦-借口-七里香` | 借口 | 周杰伦 | 七里香 | `7172b388c6ed5739.jpg` | 1881 |
| 18 | `18. 周杰伦-园游会-七里香` | 园游会 | 周杰伦 | 七里香 | `7172b388c6ed5739.jpg` | 1880 |
| 19 | `19. 周杰伦-困兽之斗-七里香` | 困兽之斗 | 周杰伦 | 七里香 | `7172b388c6ed5739.jpg` | 1345 |
| 20 | `20. 周杰伦-外婆-七里香` | 外婆 | 周杰伦 | 七里香 | `7172b388c6ed5739.jpg` | 2413 |

说明：
- 封面文件名是内容寻址（FNV-1a 63 位 + 扩展名），同专辑的曲目共享同一张封面文件（如 `Jay` 的 9 首共用一个文件），这正是 Flutter 版 `CoverStore` 的语义。
- 一首的歌词只有 103 字节（`一路向北`，来源 LRC 本身只有词曲信息与「纯音乐，请欣赏」）；其余 19 首为完整 LRC。未对来源内容做筛选，保持「如实落库」。
- 补全后 `lyrics` 是来源的 LRC 文本（带 `[mm:ss.xx]` 时间轴），行级时间在渲染时再摊成逐字。

## 4. 立即刷新（不重启）

同一个 `shell.Model` 与同一个 `ui.Tester` 窗口贯穿补全前后：

- 补全前：列表查询命中降级标题（如 `01. 周杰伦-一路向北-J III MP3 Player`），截图 `m5-before-library.png`；
- 执行 `enrich.Service.EnrichTargets`（产品自动补全入口）；
- 补全后**同一进程**：`s.Invalidate()` 后下一帧，列表行标题变为 `一路向北`、艺术家 `周杰伦`、专辑 `J III MP3 Player`，封面列出现封面缩略图（`m5-after-library.png`）；舞台显示新标题、新封面，背景是该封面的取色渐变（`m5-after-stage.png` / `m5-after-stage-dark.png` / `m5-after-stage-words.png`）。
- 机制：`library.ApplyEnrichment` 每次写库都 `bump(id)` 递增全局与行级 revision；`model.refresh` 把 revision 作为列表 key 的一部分，`TrackList.Tick` 按新 key 重读第一页。无需重启、无需手动刷新。

### 4.1 真机 GUI 冒烟（补充证据）

`./scripts/bundle.sh` 组装出的 `.app` 在副本上真实启动（`TINGYU_DATA_DIR=/tmp/m5-smoke`）并跑完一次自动 pass：

```
library: 178 tracks / 26 albums / 3 artists / 0 playlists from /tmp/m5-smoke/library.sqlite (read-write, user_version 2)
metadata: four sources ready (qqmusic / netease / itunes / lrclib); AI fallback ready=false
metadata: automatic pass after startup
enrich: … "01. 周杰伦-晴天-叶惠美" → title="晴天" artist="周杰伦" album="叶惠美" lyrics=2044 cover="0c352eab65d53910.jpg" sources=[qqmusic lrclib]
metadata: pass done attempted=2 changed=2 offline=0 skipped=0 failed=0 covers=2 lyrics=2
```

之后直接查副本数据库，两行的 `title/artist/album/cover_art_path/lyrics` 都已写入。这条验证的是 `internal/app` 的装配与启动触发（`maybeAutoEnrich`），headless harness 验证的是同一条管线；两者都只写副本。

## 5. 封面缓存与孤儿回收

- 命名：`internal/scan/cover.go` 的 `CoverName`（FNV-1a 64 取 63 位，PNG 签名判 `.png`，其余 `.jpg`），与 Flutter 版 `cover_store.dart` 逐字节一致；这是仓库里唯一实现，M5 的抓取与本地扫描共用。
- 抓取：`images.Fetcher` 并发去重同一 URL、失败 URL 记忆 5 分钟、大小上限 24 MB、UA 固定；成功即落盘，磁盘上已有相同内容则不重写。
- 本次计数：20 首补全共 6 次真实下载（48 次 HTTP 里其余是元数据/歌词请求），19 次命中（同专辑复用 + 5 次热命中）；`Fetcher.Stats()` 的命中率 76%，`Store.Stats()` 记录写入 6。
- 孤儿回收：删除一个含两条曲目的测试来源后，`DeleteSource` 报告 2 个候选封面，`ReferencedCovers` + `Store.Prune` 只删除 **1** 个（独占封面），与生产曲目共享的那个保留。副本的 `covers/` 里另有 22 个历史孤儿（生产目录里本来就有），harness 先清掉它们再计数，避免把历史遗留算成本轮成果。

## 6. 取色

规格来源：`app/lib/features/player/stage_palette.dart`（方案与调研都认定它才是本项目的规格），落点 `client/internal/images/palette.go`：

- 缩略到 **24 px**；丢 `l<0.08 / l>0.92 / s<0.08` 的像素；**12 个色相桶**；主色 = 最大桶的均值，次色 = 与主色色相差 ≥24° 的最大桶，否则主色旋转 +18°；
- 饱和度钳制 0.28–0.46；亮度：深色 0.10–0.18、浅色 0.72–0.84；再按 5% 步进直到「压平后与正文对比度 ≥7:1」；最后按 35% canvas 压平（舞台画的就是这个显示色）；
- 有效彩色像素 <20% → 判灰封面，返回 `ok=false`，舞台回退 M4 的中性令牌渐变（`canvas→surfaceSunken`，深色 `canvas→surface`），并打一条日志。**中性渐变的两端刻意保持 M4 的值**，这样取色失败时观感与上一阶段完全一致。

实测（封面 `69d759041827d648.jpg`，`一路向北`）：

| 主题 | 主色（渐变起点） | 次色（渐变终点） | 与正文最小对比度 |
|---|---|---|---|
| 深色 | `#1D1615` | `#0F1417` | 16.2:1 |
| 浅色 | `#E9DEDA` | `#DAE6E9` | 13.7:1 |
| 中性回退（深） | `#0C0C0F` | `#141418` | — |
| 中性回退（浅） | `#F7F7F9` | `#F1F1F4` | — |

灰封面用例：`docs/screenshots/m5-gray-cover.png`（纯灰 96×96）→ `images.Extract` 返回 `ok=false`，舞台调用 `StageColors` 得到中性渐变；单测在 `internal/images/images_test.go`、`internal/ui/model/enrichment_test.go` 各固定一次。

关于调研报告给的「18 桶 / `s²·v` 权重」：**未采用**。报告 §3.8 自己写明「Flutter 版才是我们的规格来源，别被它覆盖」；本项目两色（主/次）在 Flutter 版是 12 桶 + 次峰色相差，直接照抄 18 桶会让同一封面在两个客户端得到不同颜色，违反双轨期的「同图同色」。参数差异在此记录，不是遗漏。

## 7. 未完成 / 未验证（如实标注）

1. **AI 兜底没有用真实密钥跑通**：接口（OpenAI 兼容 `/chat/completions`）、系统提示、回复清洗、静默跳过都有实现与 httptest 单测；实网只有四源。原因：仓库与日志里不得出现 key，而团队密钥里没有 AI key。需要时由用户提供（见 §8）。
2. **断网是模拟的**：harness 用一个「永不到达上游」的 `RoundTripper`（`network is unreachable`）代替拔网线；语义与真实断网一致（`net.Error`），但没有做真机的 `networksetup` 断网测试。
3. **动图 WebP 封面不支持**：`images.Decode` 只解静态 JPEG/PNG/GIF 首帧/WebP；动图 WebP 返回 `ErrNoImage`，该曲目保留占位封面并记日志。三个源实际下发的都是静态图，本次 20 首未遇到。
4. **歌词翻译、艺术家头像未接**：LRCLIB/Netease 的翻译行与艺术家头像不在 M5 范围，未实现。
5. **界面证据是 headless 渲染**：截图来自 `ui.Tester` 渲染的真实 `shell.Model` 与真实 View（1200×760），不是真机窗口截图；真机只做了启动 + 自动补全的冒烟（§4.1），没有在 GUI 里逐页点一遍（同一套 View 已在 M4 记录里真机验证过）。
6. **`一路向北` 的歌词只有词曲信息**：来源 LRC 本身如此，不是解析丢失。

## 8. 需要用户提供的凭据

| 用途 | 是否需要 | 说明 |
|---|---|---|
| QQ 音乐 / 网易云 / iTunes / LRCLIB | **不需要** | 全部公开接口，无账号 |
| AI 兜底（可选） | 需要时由用户提供 **OpenAI 兼容 API Key**（DeepSeek / Qwen / Kimi / OpenAI / 本地 Ollama 皆可） | 在 设置 → 元数据 → AI 兜底 里填；只存系统钥匙串账户 `tingyu_ai_settings`，不写 `settings.json`、不进日志（日志只打 `****后四位`）；不填则整段静默跳过 |

harness 支持用 `TINGYU_AI_KEY` / `TINGYU_AI_BASE_URL` / `TINGYU_AI_MODEL` 环境变量临时验证 AI 路径（不落盘、不打印）。

## 9. 质量门

```bash
cd client
gofmt -l ./internal ./cmd ./main.go ./tools   # 输出为空
CGO_ENABLED=0 go build ./...                  # 通过
CGO_ENABLED=0 go vet ./...                    # 通过
CGO_ENABLED=0 go test ./...                   # 全部 ok
CGO_ENABLED=0 go test -race ./...             # 全部 ok（修掉了一处测试自身的 map 竞争）
```

- 生产库 sha256：`310526fdbac4e7dd9615c4d124bb28049146f87f4bce00629ed8f10b4581fb73` → 同一值；`user_version` 2 → 2。
- 副本 `PRAGMA user_version` 运行后仍为 2；本次没有新增任何列（补全复用 `cover_art_path` / `cover_art_url` / `lyrics` / `duration` 四列）。
- 列表性能：加入封面列后 `TestLibraryScrollP95At10000Rows` 仍为 p50 1.23 ms / p95 2.00 ms / p99 2.56 ms（阈值 16.7 ms）。
- 没有把任何 key 写入仓库或日志：日志只有 `****` + 后四位；harness 的 AI 配置只从环境变量读。

## 10. 复现与文件清单

新增/主要修改：

```
client/internal/images/{color,decode,fetch,palette,store}.go     封面抓取/解码/取色/计数
client/internal/metadata/{provider,qq,netease,itunes,lrclib,opencc,ai,enricher}.go + data/
client/internal/enrich/service.go                               在途去重、会话配额、人工匹配
client/internal/library/enrich.go                               目标查询与最小写入（revision）
client/internal/titleparse/（由 internal/sources/smarttitle.go 移出，来源层与补全共用）
client/internal/ui/model/{enrichment,coverpalette,lrc}.go         面板/匹配弹层/取色缓存/逐字
client/internal/ui/pages/{settings_metadata,stage}.go            元数据设置分区、舞台取色
client/internal/ui/components/{match,lyrics,table}.go            匹配弹层、逐字渲染、列表封面列
client/internal/app/metadata.go                                  装配与 MetadataActions
client/internal/m5accept/、client/cmd/m5accept/、client/scripts/run-m5-accept.sh
client/README.md、docs/plan/2026-10-26-macos-mygo-m5-evidence.json、docs/screenshots/m5-*.png
```

未触碰：`app/`、`.github/`、`client/scripts/bundle.sh`、Info.plist、公证配置、播放内核（`internal/mpv`、`internal/player` 行为不变，只被 `titleparse` 的移动影响 import）。
