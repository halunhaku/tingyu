# 听屿 macOS 端 MyGo 迁移 · M4 界面实施与验收记录

日期：2026-10-25（Asia/Shanghai）
性质：**M4 实施与验收记录**。本阶段只改 `client/` 与新增的 `docs/screenshots/m4-*.png`、`docs/plan/2026-10-25-macos-mygo-m4-scroll-samples.txt`、本文件；**未改 `app/`、未改内核包（`internal/{library,scan,mpv,player,mainq,mediasession}`）、未合并 main、未打 tag、未写生产库**。
判据来源：[迁移方案 §6 的 M4 行、§3.1、§2.5、§8.1](./2026-10-25-macos-mygo-migration-plan.md)（阈值未改）。
上一阶段：[M1 记录](./2026-10-25-macos-mygo-m1-record.md)。代码与运行说明：[`client/README.md`](../../client/README.md)。

---

## 0. 结论

M4 的令牌、组件与 12 个页面全部落地；但有**两处不能写成通过**：

| # | 验收 | 结论 | 证据 |
|---|---|---|---|
| 1 | 逐页可完成原有操作（每页列出可操作项与实测结果） | **部分通过**：曲库/收藏（只读）/专辑/艺术家/搜索+命令面板/舞台/队列/歌词/设置/来源/引导可用；**歌单页被内核阻塞**，收藏开关与「加入歌单」只能如实提示 | §2 逐页表 |
| 2 | 曲库 10,000 行滚动 p95 帧时间 ≤16.7 ms | **通过** | 750 帧采样 p95 **0.800 ms**（§3；原始采样见 [samples](./2026-10-25-macos-mygo-m4-scroll-samples.txt)） |
| 3 | 舞台展开/收起可用；歌词随播放高亮 | **通过** | 路由展开/收起 + `Match` 封面近似；`TestStageExpandsAndCollapses`、`TestLyricsHighlightAndSeek`；截图深/浅 |
| 4 | 界面截图（至少曲库、舞台、来源/设置、深色与浅色各一） | **通过** | 24 张 `docs/screenshots/m4-*.png`（12 页 × 深/浅；§5） |
| 5 | `CGO_ENABLED=0 go build ./...`、`go vet`、`go test`、`-race`、`gofmt -l` 干净 | **通过** | §6 |

一句话：**界面与装配完成，数据写路径与歌单仍在内核边界之外**；没有把不可用的页面写成已通过。

---

## 1. 环境与产物

| 项 | 值 |
|---|---|
| 机器 / 系统 | MacBook Air（Apple Silicon，arm64），macOS 27.2（26B118） |
| Go | go1.27.3 darwin/arm64，`CGO_ENABLED=0` |
| UI | `github.com/egoist/mygo v0.6.4`（`ui` 即时模式） |
| 新增包 | `internal/ui/{tokens,model,components,pages}`；`internal/shell` 重写为外壳；`internal/app` 只加窗口/菜单/动作装配 |
| 出包 | `cd client && ./scripts/bundle.sh` → `build/darwin-arm64/听屿.app`（12.9 MB） |
| 数据 | 一律 `cp library.sqlite` + `covers/` 到 `/tmp/tingyu-m4*`，`TINGYU_DATA_DIR` 指向副本；生产库全程未写 |

生产库复核：`mtime 2026-10-25 14:30:24`、`sha256 310526fd…`、`PRAGMA user_version = 2`，与 M1 记录一致。

---

## 2. 验收 1：逐页操作

图例：**✓** 已实测可用；**⚠** 界面完整但写库操作缺内核，点击会显示「需内核支持」；**✗** 未完成（明确阻塞）。

| 页面 | 可操作项与实测 |
|---|---|
| **曲库** | ✓ 虚拟化列表（10,000 行）；✓ 单击行从该行起播（队列从点击项起算）；✓「播放全部」跨全部分页取齐；✓ 5 字段排序（曲名/艺术家/专辑/时长/最近添加）+ 升降序（列头与「排序：」菜单）；✓ 来源过滤（多来源时出现）；✓ 每页 40 + 滚动近底 +「加载更多」，一次一页；✓「添加目录…」原生目录选择；✓ 扫描进度/结果；✓ 行右键/⋯：播放、在访达中显示；⚠ 收藏、加入歌单、匹配元数据；✓ 页内搜索（⌘F / 侧栏）跳搜索页 |
| **收藏** | ✓ 歌曲/专辑两段；✓ 歌曲表格（排序、来源过滤、播放）；✓ 专辑封面网格 + 播放整张 + 点进详情；⚠ 行内 ♥（收藏写入）。真实库当前 0 收藏，空态如实说明 |
| **专辑** | ✓ 自适应封面网格（150 宽、方形封面）；✓ 卡片点进详情；✓ 卡片播放按钮播放整张；✓ 详情：播放、曲目列表点击起播、在艺人中查看；⚠ 加入歌单 |
| **艺术家** | ✓ 艺术家列表（头像、曲目/专辑/总时长）；✓ 行播放与点进详情；✓ 详情：播放全部、专辑横排、全部曲目、>20 首时「全部展开/收起」；✓ 行点击从该行起播 |
| **歌单** | ✗ **数据层未接入**：内核 `library` 只有曲目/来源查询。页面如实说明，不画假歌单；「新建歌单（需内核）」只提示。**本页不验收**（见 §7） |
| **搜索** | ✓ 250 ms 防抖（输入与查询不一致时显示「正在搜索…」）；✓ 全部/歌曲/专辑/艺术家/歌单 分段；✓ 全部视图四组、每组 5 条 + 真实总数 +「查看全部」；✓ 单范围 40/页 +「加载更多」；✓ Enter 播放最佳命中；✓ 最近搜索（内存 ≤10，可清除）；✓ 歌曲行播放、专辑/艺术家跳转；⚠ 歌单搜索（内核无查询） |
| **命令面板** | ✓ ⌘K；✓ 独立查询与 250 ms 防抖；✓ 空查询「最近播放」+「快捷入口」，有词「歌曲/专辑/艺术家」各 5 条；✓ ↑↓ 移动、Enter 激活、Esc 关闭（`TestPaletteOpensFiltersAndPlays`）；✓ 快捷入口：播放/暂停、上/下一首、舞台、曲库、收藏、来源、设置、队列、歌词、新建歌单（后者提示内核）。⚠ 歌曲项只播该曲（Flutter 播命中列表），见 §8 |
| **舞台** | ✓ 传输条封面/曲名、⌘⇧P 打开；✓ Esc/返回箭头收起；✓ 封面与传输条封面共享 `Match` 身份（Hero 近似）；✓ 大封面、曲名、点艺术家进详情；✓ 进度拖动/点跳、上/下一首、播放/暂停、循环三态、音量；✓ 歌词/队列侧栏（窗口 ≥1000）；✓ 失败态「播放失败：…」+「重试此曲」；⚠ 收藏 |
| **队列** | ✓ 当前播放 + 接下来 N 首；✓ 行点击跳到该首（经 `PlayTracks` 重建队列）；✓ 只读（不插入/删除/重排，与 Flutter 控制器一致）；✓ 空态 |
| **歌词** | ✓ LRC 解析（`[mm:ss]`、1/2/3 位小数、一行多时间戳、ID 标签忽略、纯文本回退）；✓ 当前行高亮（强调色）；✓ 自动滚动到当前行；✓ 手动滚动后 3 s 内不自动回拉；✓ 点行 seek 到该行时间；✓ 未播放/无歌词空态；⚠「抓取歌词」（M5 + 写库） |
| **设置** | ✓ 主题模式：跟随系统/浅色/深色；✓ 界面密度：舒适/紧凑（行高 44/40、页边距 32/24、侧栏 224/208）；✓ 封面动态取色开关（持久化；视觉应用属 M5，页面写明）；✓「恢复默认外观」；✓ 播放信息（libmpv/媒体会话/关窗行为/循环）；✓ 音乐库计数（曲目/专辑/艺术家/歌单/来源）；✓「同步全部来源」（只扫本地，远端跳过）；✓ 来源摘要；✓ 数据目录/曲库/封面路径 + 复制；✓ 关于；✓ 可写副本落盘 `settings.json`，只读模式只在本进程生效并提示 |
| **来源** | ✓ 来源列表（名称/类型/曲目数/上次同步）；✓「添加来源 → 本地目录…」原生选择；✓ 本地来源「同步」重扫；✓「查看曲目」回到曲库并按来源过滤；⚠ 删除来源（内核写）；✓ WebDAV/夸克显示为 M3 未接入，不提供会失败的假表单 |
| **引导** | ✓ 有库 ∧ 无来源 ∧ 无曲目时进入（与 Flutter 触发条件一致）；✓ 三步说明 + 三张来源卡 +「添加音乐来源 / 先去设置看看 / 跳过」；✓ 本地「选择目录…」直接起扫描；✓ 本进程内只出现一次 |

快捷键实测：⌘K、⌘F、⌘,、⌘1–4、⌘⇧P、⌘L、⌘U、Space、⌘←/→、⌘⇧←/→（±10 s）、⌘↑/↓（±0.05 音量）均已接线；应用菜单「听屿/播放/前往」已安装（§4.4 真实运行日志有 `menu: installed`）。输入框内的 Space/方向键优先给输入框。

---

## 3. 验收 2：10,000 行滚动

**方法**（可复现）：

1. `ui.Tester` 以 1200×760 构建同一 `shell.Model.View`，注入 10,000 条合成曲目（标题/艺术家/专辑齐全，封面缺失；封面在真实库中按需解码并 LRU，滚动热路径不重复读盘）。
2. 调 `TrackList.LoadAll()` 让列表真的持有 10,000 行（正常 UI 仍是 40/页）。
3. 触摸板滚动 400 步 × 1200 DIP（约 48 万 DIP，覆盖全表；末帧首可见行 ≥ 9,900），每步计时。
4. 同时以 `MYGO_FRAME_STATS=all` 记录 MyGo 每帧的 build/layout/paint/present；`scroll_p95` 取滚动阶段（frame > 30）的**逐帧** total。
5. 命令：`cd client && ./scripts/measure-scroll.sh`；原始 750 帧逐行采样：[samples](./2026-10-25-macos-mygo-m4-scroll-samples.txt)。

**结果**（本次运行）：

| 口径 | p50 | p95 | p99 | max |
|---|---|---|---|---|
| 逐帧 total（750 帧，`MYGO_FRAME_STATS`） | 0.200 ms | **0.800 ms** | 1.000 ms | 1.300 ms |
| 逐帧 build | 0.100 | 0.100 | 0.100 | 0.100 |
| 逐帧 layout | 0.100 | 0.500 | 0.700 | 0.900 |
| 逐帧 paint | 0.000 | 0.100 | 0.100 | 0.100 |
| 逐帧 present（内存） | 0.100 | 0.200 | 0.200 | 0.200 |
| 400 次滚动调用墙钟（可能含多帧） | 1.001 ms | 1.126 ms | 1.384 ms | 1.498 ms |

阈值 16.7 ms：**p95 0.800 ms，余量约 20×**。

**口径限制（不掩盖）**：这是 `ui.Tester` 的 build+layout+paint+内存 present，**不含 GPU 光栅化**；真实窗口的 `MYGO_FRAME_STATS` 在本次自动化会话中被系统判定为遮挡（显示器休眠/窗口被终端覆盖），只记录了第 1 帧，因此不作为通过依据。`TINGYU_BENCH_ROWS=10000` 的真实窗口滚动台架已留在 `internal/app`（窗口可见时会输出逐帧日志），本次未取得可用数据。正常使用中 GPU 只画可见行；若要在目标机复测，唤醒显示器、让窗口可见后运行：

```bash
MYGO_FRAME_STATS=all TINGYU_DATA_DIR=/tmp/tingyu-copy TINGYU_BENCH_ROWS=10000 \
  build/darwin-arm64/听屿.app/Contents/MacOS/听屿
```

---

## 4. 验收 3：舞台与歌词

- **展开**：传输条封面/曲名点击、⌘⇧P、菜单「播放 → 打开播放舞台」；页面替换整个窗口（侧栏与传输条不绘制），因此封面可以从传输条位置匹配到舞台。
- **收起**：左上返回、Esc、菜单前往其他页。
- **Hero 近似**：传输条封面与舞台封面使用同一 `components.CoverMatch{ID: track.ID}` + `ui.ElementTransition{Match: …, Duration: 320 ms}`；没有 Flutter 的 Hero，观感按方案 §3.1 接受近似。
- **歌词高亮**：`ParseLRC` → `Lyrics.Current(position)` → 当前行 `TitleL`/强调色，其余 `BodyL`/次级色；列表滚到当前行；手动滚离当前行后 3 s 内不再自动回拉；点行 seek。
- 自动化：`TestStageExpandsAndCollapses`（打开后文本含「关闭舞台/西西里/第一句」→ 关闭后回曲库）、`TestLyricsHighlightAndSeek`（点「第三句」→ seek 9 s）、model 层 `TestParseLRC`/`TestParseLRCPlainText`。
- 截图：[舞台浅色](../screenshots/m4-stage-light.png)、[舞台深色](../screenshots/m4-stage-dark.png)、[歌词浅色](../screenshots/m4-lyrics-light.png)、[歌词深色](../screenshots/m4-lyrics-dark.png)。

---

## 5. 验收 4：截图

**方法**：`client/tools/screenshots` 读取只读库副本（178 首、全部含歌词与封面），用**同一个 `shell.Model.View`** 经 `ui.Render` 以 1200×760、2× 渲染；不是另画一套静态页。`settings.json` 写在临时目录，库副本只读（不写生产库，也不改副本）。

12 页 × 深/浅 = 24 张：

| 页面 | 浅色 | 深色 |
|---|---|---|
| 曲库 | [m4-library-light](../screenshots/m4-library-light.png) | [m4-library-dark](../screenshots/m4-library-dark.png) |
| 专辑 | [m4-albums-light](../screenshots/m4-albums-light.png) | [m4-albums-dark](../screenshots/m4-albums-dark.png) |
| 艺术家 | [m4-artists-light](../screenshots/m4-artists-light.png) | [m4-artists-dark](../screenshots/m4-artists-dark.png) |
| 收藏 | [m4-favorites-light](../screenshots/m4-favorites-light.png) | [m4-favorites-dark](../screenshots/m4-favorites-dark.png) |
| 歌单 | [m4-playlists-light](../screenshots/m4-playlists-light.png) | [m4-playlists-dark](../screenshots/m4-playlists-dark.png) |
| 搜索 | [m4-search-light](../screenshots/m4-search-light.png) | [m4-search-dark](../screenshots/m4-search-dark.png) |
| 舞台 | [m4-stage-light](../screenshots/m4-stage-light.png) | [m4-stage-dark](../screenshots/m4-stage-dark.png) |
| 队列 | [m4-queue-light](../screenshots/m4-queue-light.png) | [m4-queue-dark](../screenshots/m4-queue-dark.png) |
| 歌词 | [m4-lyrics-light](../screenshots/m4-lyrics-light.png) | [m4-lyrics-dark](../screenshots/m4-lyrics-dark.png) |
| 设置 | [m4-settings-light](../screenshots/m4-settings-light.png) | [m4-settings-dark](../screenshots/m4-settings-dark.png) |
| 来源 | [m4-sources-light](../screenshots/m4-sources-light.png) | [m4-sources-dark](../screenshots/m4-sources-dark.png) |
| 引导 | [m4-onboarding-light](../screenshots/m4-onboarding-light.png) | [m4-onboarding-dark](../screenshots/m4-onboarding-dark.png) |

---

## 6. 验收 5：质量门

```text
gofmt -l .                                   → 空
CGO_ENABLED=0 go build ./...                 → 通过
CGO_ENABLED=0 go vet ./...                   → 通过
go test ./...                                → 全部包通过
go test -race ./...                          → 全部包通过
./scripts/bundle.sh                          → 听屿.app 12.9 MB，签名/框架校验通过
```

`-race` 下 `TestLibraryScrollP95At10000Rows` 自动跳过（race 插桩会主导帧时间），其余功能测试全部运行；跳过的原因写在测试里，不是静默跳过整个测试包。

覆盖（新增）：分页一次一页/到底不再建页、刷新保页与行 revision、搜索防抖与分组、LRC 解析/当前行、设置宽容解析/原子写、命令面板键盘、舞台展开收起、歌词点行 seek、收藏/歌单的「需内核支持」提示、逐页导航、10,000 行帧时间。

---

## 7. 需内核支持清单（本 todo 未改内核）

按优先级排列；括号内是当前界面上的表现。

1. **收藏写入**：`UPDATE tracks SET is_favorite = ? WHERE id = ?`（单条与批量）。（行内 ♥、舞台 ♥、收藏页均只提示。）
2. **歌单读**：`playlists` 列表 + `playlist_items` 按 position 取曲目；**歌单写**：创建、重命名、删除、加曲、移出、重排。（歌单页因此不显示数据。）
3. **SQL 分页与聚合**：`TracksPage(filter, sort, limit, offset)`、`CountTracks`、`AlbumsPage`、`ArtistsPage`。当前为一次 `Tracks()` 全量读入 + 内存分页/分组；10,000 行性能达标，但违反方案 §2.5「禁止把整表塞进内存做筛选」的目标口径，需内核查询。
4. **随机播放**：控制器无 shuffle（Flutter 有 `PlayOrder.shuffle`）。（舞台/传输条没有随机键，未伪造。）
5. **队列跳播的原地语义**：`PlayAt(index)`（当前用 `PlayTracks` 重建队列，能跳到该首，但队列身份与 Flutter 的 `playAt` 不完全一致）。
6. **来源删除**：删除 `music_sources` 行 + 曲目 + 歌单引用 + 凭据。（按钮只提示。）
7. **歌词抓取/写入**、**元数据匹配写回**：M5 + 内核写路径。（歌词页「抓取歌词」未提供假按钮。）
8. **封面图片管线与取色**（M5）：当前封面在 UI 线程按需解码 + 96 张 LRU；舞台使用中性令牌渐变，不冒充封面取色。
9. **设置归属**：当前 `settings.json` 由 UI 侧 `model` 读写；若内核统一接管，迁移这一处即可。

---

## 8. 与 Flutter 版的差异与未完成项

- **歌单页不完整**：这是本里程碑最大缺口，根因是内核无歌单查询/写入，不是界面未画。
- **收藏开关不可用**：只读展示真实收藏状态；写入按钮只提示内核缺失。
- **搜索命令面板的歌曲项**只播放该曲（Flutter 用命中列表起播）；搜索结果行点击仍按结果列表起播。
- **无 compact（<640）外壳**：窗口最小 900×600，方案 §2.4 #39 已决定砍掉；窄窗只走 expanded/medium 收窄，无底部 Tab/迷你条。
- **舞台无下拉手势**：桌面最小宽度下 compact 手势不可达；用 Esc/返回/⌘⇧P。
- **取色开关不改变舞台颜色**：取色算法属 M5；开关只落盘并显示说明。
- **真实窗口帧统计未取得**：会话中窗口被系统视为遮挡；以 `ui.Tester` 的 build+layout+paint 为验收口径，已在 §3 明示。
- **读屏无障碍未验证**：键盘路径、焦点环与 `Label` 已铺（行、按钮、搜索框、列表），但未做 VoiceOver 专项；方案 §2.4 #47 原定 M6 后补。
- **封面解码在主线程**：可见行按需解码，未做后台管线；M5 的图片管线会替换。
- **启动时一次性读全表**：178 首无感；10,000 行首屏未单独测（滚动达标）。

---

## 9. 真实运行记录

| 场景 | 结果 |
|---|---|
| 178 首库副本（quark URL），`TINGYU_AUTO_QUIT_MS=6000` | 窗口 1200×760、菜单安装、出包后首启 `startup ready 830.5 ms`（复用同一进程的热启动 208 ms）、`Cmd+Q` 路径清理 Now Playing/引擎、退出；源曲目为 M3 远端 URL，播放失败属预期，UI 不崩 |
| 本地扫描 + 播放（/tmp/tingyu-m4-local，2 个 3 s WAV，目录名含中文与空格） | `scan: 文件 2，入库 2（新增 2 / 更新 0 / 移除 0）`，2 ms；`play: sound after 205.6 ms`；重启后 `play_count` 可见；退出干净 |
| 生产库 | 未变：`mtime 2026-10-25 14:30:24`、`sha256 310526fd…`、`user_version 2` |

---

## 10. 约束合规

- 只做 M4：未接远端来源（M3）、未做元数据补全（M5）、未改 `/internal/{library,scan,mpv,player,mainq,mediasession}`。
- 未改 `app/`；未合并 main；未打 tag。
- 开发/验收全程 `TINGYU_DATA_DIR` 指向库副本；未写生产库。
- 未把不可用页面写成通过：歌单页、收藏写入、歌单写入、来源删除、抓取歌词、随机播放均明确标注。

---

## 11. 复现

```bash
cd client
CGO_ENABLED=0 go build ./... && CGO_ENABLED=0 go vet ./...
go test ./... && go test -race ./...
gofmt -l .

# 截图（需要一份库副本）
mkdir -p /tmp/tingyu-m4 && cp "$HOME/Library/Application Support/com.halunhaku.tingyu/library.sqlite" /tmp/tingyu-m4/
cp -R "$HOME/Library/Application Support/com.halunhaku.tingyu/covers" /tmp/tingyu-m4/
CGO_ENABLED=0 go run ./tools/screenshots -data /tmp/tingyu-m4 -out ../docs/screenshots

# 10,000 行帧时间 + 原始采样
./scripts/measure-scroll.sh

# 出包
./scripts/bundle.sh
```
