# 听屿 macOS 端 · 内核数据能力（歌单 / 收藏 / 来源删除 / 随机 / SQL 分页）实施与验收记录

日期：2026-10-26（Asia/Shanghai）
性质：**内核数据能力阶段**的实施与验收记录。改动集中在 `client/internal/library`（查询、收藏、歌单、来源删除）、`client/internal/player`（随机播放）、`client/internal/ui/{model,components,pages}`（视图接入 SQL 数据与五个写操作）、`client/internal/app`（写操作接线）、`client/internal/scan`（封面孤儿回收）、`client/internal/shell`（外壳与侧栏歌单）。**未改 `app/`（Flutter）、未合并 main、未打 tag、未写生产库**。
来源：M4 记录 §7 的「需内核支持清单」；数据语义见[迁移方案 §2.1（扫描合并、封面内容寻址、时间文本）、§2.5（分页与刷新契约）、§8.1（`user_version` 冻结 2，只允许 nullable 加列）](./2026-10-25-macos-mygo-migration-plan.md)。
上一阶段：[M4 记录](./2026-10-25-macos-mygo-m4-record.md)。

---

## 0. 结论

M4 留下的五项「需内核支持」全部接通，界面按钮不再提示缺内核，写入落在 `library.sqlite` 里并有独立连接读回的证据。

| # | 验收 | 结论 | 证据 |
|---|---|---|---|
| 1 | 原有空按钮：操作成功 → 重启后数据仍在 → 数据库可见对应行 | **通过** | §2（收藏、歌单、来源删除逐条；独立 SQLite 连接读回） |
| 2 | 歌单全链路 + `playlist_items` 级联删除 | **通过** | §2.2（新建→加 3 首→改名→排序→移出→删除歌单） |
| 3 | 收藏与取消双向生效；来源删除后曲目与封面无残留 | **通过** | §2.1、§2.3（计数对比，共享封面保留） |
| 4 | 随机播放与循环三态共存、可回到顺序 | **通过** | §2.4（单元测试 + 界面按钮） |
| 5 | 分页：`LIMIT/OFFSET` + 专辑/艺术家聚合；`EXPLAIN QUERY PLAN` 用到索引；10,000 行滚动 p95 | **部分通过**：索引与页查询达标，**滚动 p95 1.3–1.5 ms 高于 M4 基线 0.8 ms**（仍低于 16.7 ms 门槛 11 倍）。原因与口径见 §3.4，不写成通过 |
| 6 | `CGO_ENABLED=0 go build/vet/test/-race`、`gofmt -l` 干净 | **通过** | §4 |
| 7 | 生产库 sha256 前后一致 | **通过** | §5（`310526fd…`，mtime 未变） |

一句话：**五项能力的写路径与查询全部落地并有数据库证据；分页把「整表进内存」换成了 SQL，但滚动帧时间的 p95 没有回到 M4 的 0.8 ms 量级，多出的约 0.5–0.7 ms 落在「应用新一页」的那 12% 帧上**，如实记在 §3.4，没有用「看起来对」代替测量。

---

## 1. 环境与产物

| 项 | 值 |
|---|---|
| 机器 / 系统 | MacBook Air（Apple Silicon，arm64），macOS 27.2（26B118） |
| Go | go1.27.3 darwin/arm64，`CGO_ENABLED=0` |
| UI | `github.com/egoist/mygo v0.6.4` |
| 数据 | 一律 `cp library.sqlite` + `covers/` 到 `/tmp/tingyu-m5*`，`TINGYU_DATA_DIR` 指向副本；生产库全程未写 |
| 截图 | 24 张 `docs/screenshots/m4-*.png` 用副本重新渲染（歌单页/侧栏现在显示真实歌单） |

真实运行（库副本，178 首）：

```text
library: 178 tracks / 26 albums / 3 artists / 0 playlists from /tmp/tingyu-m5c/library.sqlite
         (read-write, user_version 2)
startup library read    457.6 ms since process,  28.6 ms since main
window: 1200x760, minimum 900x600
startup ready           669.3 ms since process, 240.3 ms since main
app: quit complete / window: closed
```

首次在副本上打开（要建 5 条排序索引）实测 `startup ready 1246.3 ms`；索引建好后再冷启动 **669.3 ms**（M1 门槛 1.5 s）。迁移后 `PRAGMA user_version` 仍是 2，`tracks` 仍 178：

```text
PRAGMA user_version → 2
SELECT COUNT(*) FROM tracks → 178
SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_tracks_sort%'
  → idx_tracks_sort_title / _artist / _album / _duration / _added
```

（`go run` 下 libmpv 无法 dlopen 未签名 framework，播放内核不可用属该跑法的已知限制，见 README「构建」；本阶段不改播放链，随机播放由控制器单测与界面按钮覆盖。）

---

## 2. 逐项验收

所有数据库证据都来自**与写连接分开的第二条 SQLite 连接**（`internal/shell` 的端到端用例里用 `sqlite.Open` 重新打开同一文件；接受跑用 `sqlite3`）。界面级的证据是 `ui.Tester` 真点击按钮、真写库、再读回。

### 2.1 收藏写入与取消

| 步骤 | 证据 |
|---|---|
| 点击行内 ♥（`internal/shell` 端到端用例） | `SELECT COUNT(*) FROM tracks WHERE is_favorite = 1 AND title = ?` → 1；行内按钮立刻变成「取消收藏此曲」 |
| 收藏页（同一 flag 的查询） | 页面显示「已显示 1 / 共 1 首」 |
| 再点一次（取消） | `SELECT COUNT(*) FROM tracks WHERE is_favorite = 1` → 0；收藏页回到空态 |
| 重开连接（模拟重启） | `library.OpenWritable` 后 `Track(id).IsFavorite` 仍为 `true` |
| 库副本实测（178 首） | `favourite: I Do -> true` / `unfavourite: I Do -> false` / `favourite again: I Do -> true`；程序结束重开连接 `after reopen: favourite of I Do -> true`；`sqlite3`：`SELECT is_favorite, COUNT(*) FROM tracks GROUP BY is_favorite;` → `0|177`、`1|1` |

实现：`library.SetFavorite(ctx, id, favorite)` / `SetFavorites(ctx, ids, favorite)`（一个事务），写入后 `bump(ids...)` 同时推高全局与行级 revision。

### 2.2 歌单全链路

界面路径：歌单页「新建歌单」→ 内联名称框（Enter 提交）→ 曲库行菜单「添加到播放列表 → 歌单名」、专辑页「加入歌单」→ 歌单详情页行菜单「下移 / 移出歌单」、头部「重命名 / 删除歌单」。

库副本实测（178 首，输出逐行）：

```text
playlist created: pl-1792976827647621 "M5 验收"
added 3 tracks: [0:I Do 1:Intro 2:Mine Mine]
renamed: "验收歌单"
moved 2 -> 0: [0:Mine Mine 1:I Do 2:Intro]
removed row 1: [0:Mine Mine 1:Intro]
before delete: source tracks=2 other source=178 items=[0:Mine Mine 1:Intro 2:验收曲目一]
...
playlist deleted: {Name:验收歌单 Items:2}
end counts={Tracks:178 Albums:26 Artists:3 Playlists:0 Sources:1}
```

`sqlite3` 读回（测试中途保持状态）：

```text
sqlite> SELECT id, name, created_at FROM playlists;
pl-1792976827647621  验收歌单  2026-10-26T01:07:07.647621Z
sqlite> SELECT playlist_id, position, track_id FROM playlist_items ORDER BY position;
pl-1792976827647621  0  src-1789263929408853::quark://73f8cd62ae…
pl-1792976827647621  1  src-1789263929408853::quark://ab7c63577d…
```

级联删除：删除歌单后 `playlist_items` 为该歌单的行数为 0（`DeletePlaylist` 返回 `Items: 2`），`tracks` 仍是 178 —— 条目随外键走，曲目不动。

语义（照搬 Flutter 客户端，见 `app/lib/data/repositories/playlist_repository.dart`）：

- 位置只有压紧成 `0..n-1` 才有意义。曲目被删时 `playlist_items` 由外键级联摘除但位置不重排，于是有空洞；**每个写操作前先压紧**，否则追加会撞 `(playlist_id, position)` 主键、按行号删会删错曲目、重排会留下旧高位行。
- 加曲按传入顺序追加，**允许同一首出现两次**（Flutter 同语义）。
- 排序用「整表重写」：一个事务里 `DELETE` 全量再按新顺序 `INSERT`，避免交换时的瞬时主键冲突。
- 删除歌单靠 `ON DELETE CASCADE`，`PRAGMA foreign_keys` 在每个可写连接上打开。

### 2.3 删除来源：曲目、歌单条目与封面

语义（方案 §2.1 #2、#4）：一个来源只拥有 `source_id` 等于它的曲目；删除时曲目与歌单条目一起走，待删除曲目引用过的封面**只在没有任何剩余曲目引用时才回收**（内容寻址封面跨曲目、跨来源共享）。

库副本实测（先加一个合成来源：2 首，一首用独有封面、一首复用既有来源的封面；再把它的一首加入歌单）：

```text
before delete: source tracks=2 other source=178 items=[0:Mine Mine 1:Intro 2:验收曲目一]
source deleted: {Source:验收来源 Tracks:2 PlaylistItems:1 Covers:[ffffffffffffffff.jpg 005f82e11f47bc17.jpg]}
after delete: source tracks=0 other source=178 items=[0:Mine Mine 1:Intro] orphan covers removed=2 shared kept=true
```

- 别的来源曲目数 178 → 178（未被误删）。
- 歌单里属于被删来源的那一条随级联消失（3 → 2）。
- `music_sources` 少一行（见 §5 的计数）。
- 封面：共享的那张 `keep=true` 保留；该来源独有的 `ffffffffffffffff.jpg` 被删。`removed=2` 里的第二个是副本里**此前就存在**的孤儿封面 —— `CollectOrphanCovers` 是全量回收（只认 `SaveCover` 产出的 16 位十六进制 + `.jpg/.png` 名字，目录里其它文件与子目录不动），不是只删本次涉及的。这一点写在这里以免误读。

### 2.4 随机播放

控制器状态 `SetShuffle`，与循环三态正交（`Update` 同时带 `Repeat` 与 `Shuffle`）：

- **起播**：选中曲目固定第一首，其余随机；按**下标**排除选中曲而不是按 id（歌单可能收录同一首两次，按 id 会把两份都剔掉）。
- **播放中切换**：只重排尚未交给引擎的那一段（`queue[resolvedNext:]`），前缀 —— 当前曲与已解析项 —— 一个位置都不动，因此不打断播放、引擎下标不错位。
- **回到顺序**：关闭随机时按**原始列表顺序**还原尾部，并按**重数**消耗（不是按 id 集合），同一首出现两次的曲目一份都不会丢。
- 循环三态不变：单曲循环仍下发给内核、列表循环仍重播已装载队列（重播的是当前这份随机顺序）。

测试：`internal/player/shuffle_test.go` 四个用例（首位固定 + 全排列不丢不重、关闭后前缀不动且尾部回到原序、重复曲目保留、与三种循环共存）；界面：传输条与舞台的「随机播放：开/关」按钮，`internal/shell` 用例点击后状态与按钮文字一致。

### 2.5 界面接线（只有数据接入，无视觉改动）

- 曲库/收藏/搜索/专辑详情/艺术家详情的行菜单：「收藏 / 取消收藏」「添加到播放列表 →（歌单列表）」；歌单详情页另有「移出歌单 / 上移 / 下移」。
- 歌单页与歌单详情页：新建（内联名称框）、重命名、删除歌单（`ui.AlertDialog` 二次确认）、播放全部、随机播放。
- 来源页：删除来源（二次确认，文案说明曲目会一起移除、磁盘文件不动）。
- 设置/播放：随机播放开关显示真实状态。
- 侧栏「播放列表」段：真实歌单与曲目数，点击进入。
- 仍显示「需内核支持」的只剩 M5 的元数据匹配与歌词抓取（文案已改为「属于后续里程碑（M5）」）。

---

## 3. SQL 分页与聚合

### 3.1 查询形状

`internal/library/query.go`：

- `TrackQuery{SourceID, PlaylistID, Favorite, Artist, Album, Search, Sort, Desc, Limit, Offset}` → `TracksPage` / `CountTracks`。过滤维度各自命中索引（`source_id`、`is_favorite`、`(artist)`、`(artist, album)`、歌单的 `(playlist_id, position)` 主键与 `playlist_items(track_id)`）。
- `AlbumQuery` → `AlbumsPage` / `CountAlbums`：`GROUP BY t.artist, t.album`，一次分组拿曲目数、总时长、年份、封面。
- `ArtistQuery` → `ArtistsPage` / `CountArtists`：`GROUP BY t.artist`，带专辑数与曲目数。
- `Counts`（曲目/专辑/艺术家/歌单/来源）与 `RecentlyPlayed` 各一条查询。
- 空字符串专辑/艺术家按占位名显示（`未知专辑`），但**分组用原始列**：把 `TRIM(...)`/`CASE` 放进 `GROUP BY` 会让 SQLite 无法用 `idx_tracks_artist_album` 分组，退化出临时 B 树。

### 3.2 EXPLAIN QUERY PLAN（`internal/library` 测试断言，真实 SQLite 执行）

```text
source page      SEARCH t USING INDEX idx_tracks_source (source_id=?) | USE TEMP B-TREE FOR ORDER BY
favourites page  SEARCH t USING INDEX idx_tracks_favorite (is_favorite=?) | USE TEMP B-TREE FOR ORDER BY
album page       SEARCH t USING INDEX idx_tracks_artist_album (artist=? AND album=?) | USE TEMP B-TREE FOR ORDER BY
artist page      SEARCH t USING INDEX idx_tracks_artist (artist=?) | USE TEMP B-TREE FOR ORDER BY
playlist page    SEARCH pi USING INDEX sqlite_autoindex_playlist_items_1 (playlist_id=?)
                 SEARCH t USING INDEX sqlite_autoindex_tracks_1 (id=?)
album aggregate  SCAN t USING INDEX idx_tracks_artist_album | USE TEMP B-TREE FOR ORDER BY
artist aggregate SCAN t USING INDEX idx_tracks_artist | USE TEMP B-TREE FOR count(DISTINCT) | USE TEMP B-TREE FOR ORDER BY
```

库副本（178 首）上的同一断言：

```text
library page (title sort)  SCAN t USING COVERING INDEX idx_tracks_sort_title
source-filtered page       SEARCH t USING INDEX idx_tracks_source (source_id=?) | USE TEMP B-TREE FOR ORDER BY
favourites page            SEARCH t USING INDEX idx_tracks_favorite (is_favorite=?) | USE TEMP B-TREE FOR ORDER BY
```

**没有全表扫描的页查询，也没有一次把整表读进内存。** 两处如实说明：

1. 过滤 + 排序的页仍要 `USE TEMP B-TREE FOR ORDER BY`（过滤索引与排序索引不是同一条）。排序索引让**未过滤**的曲库页（默认按曲名）走覆盖索引、零排序。
2. 搜索是 `LIKE '%词%'`，子串无法走 B 树索引，必然扫一遍；`LIMIT` 与 250 ms 防抖是它的边界。要用索引得换 FTS5（改 schema），不在本阶段。

### 3.3 排序索引（只加索引，不改列、不动 `user_version`）

页查询需要 ORDER BY 也被索引服务，否则每次都排整表（实测最深一页 ~10 ms，已接近一帧）。`schema.go` 新增 5 条**排序索引**，每条正好等于一种排序的 ORDER BY（含 collation 与方向）：

```sql
idx_tracks_sort_title    (title COLLATE NOCASE, artist COLLATE NOCASE, id)
idx_tracks_sort_artist   (artist COLLATE NOCASE, album COLLATE NOCASE, disc_number, track_number, title COLLATE NOCASE, id)
idx_tracks_sort_album    (album COLLATE NOCASE, artist COLLATE NOCASE, disc_number, track_number, title COLLATE NOCASE, id)
idx_tracks_sort_duration (duration, id)
idx_tracks_sort_added    (date_added, id)
```

理由与边界：§8.1 冻结的是**列语义与版本号**，索引是纯性能、对 drift 客户端不可见（它自己的 6 条照旧，多出来的不会报错）。代价是每条扫描写入多维护 5 棵索引；10,000 行的建索引一次性 ~50 ms。若用户不接受「共享库多出 5 条索引」，删掉它们即可回到内存排序——但分页性能会回到「每页排整表」。

### 3.4 10,000 行：页查询与滚动帧时间

页查询（`internal/library` 的 10,000 行 fixture，`go test ./internal/library -run TestTenThousandRowPaging`，单条语句墙钟）：

| 查询 | 页 | 计数 |
|---|---|---|
| 曲库页（曲名，OFFSET 6000） | 302 µs | 8 µs |
| 收藏页（OFFSET 900） | 1.012 ms | 26 µs |
| 最后一页（最近添加，OFFSET 9960） | 352 µs | 18 µs |
| 来源页（OFFSET 5000） | 7.313 ms | 135 µs |
| 专辑聚合（60 张，OFFSET 100） | 3.076 ms | — |
| 艺术家聚合（40 位） | 2.984 ms | — |

来源页最慢（7.3 ms）：过滤用 `idx_tracks_source`，排序仍要临时 B 树；`LIMIT 40` 之后只排到需要的行。**这些查询都发生在帧外的后台 goroutine 上**（每帧只轮询一次结果），所以它们不等于帧时间。

界面做法（`internal/ui/model`）：

- 两种后端方法：`LoadTracks/LoadAlbums/LoadArtists` 返回一个容量 1 的 channel，查询在自己的 goroutine 上跑（`library.Queries`，10 s 超时）；模型每帧非阻塞轮询。同步方法只留给「播放全部」、专辑曲目、搜索预览与计数。
- 翻页增量：已加载的行与当前查询同源（同 base，含 revision）时，下一页只请求 `OFFSET = 已加载`、`LIMIT = 目标窗口 − 已加载` 的**增量行**并追加；换过滤/换排序/revision 变了则整窗重读（否则旧行的收藏位、播放次数、标题会是旧的 —— 这个 bug 正是端到端用例抓出来的）。
- 闸门：滚动近底时请求「读到的行 + 2 页」而不是固定一页（快速滚动不会一直撞在已加载末尾）；「加载更多」仍是一次一页；`loading/done` 保证一帧最多一次请求，请求被放弃时只丢 channel（容量 1，goroutine 不会阻塞）。

**滚动帧时间**（`./scripts/measure-scroll.sh`，10,000 行、1,000 步 × 1200 DIPs 走完全表，MyGo 帧统计与 M4 同口径）：

| 口径 | p50 | p95 | p99 | max |
|---|---|---|---|---|
| 本次：逐帧 total | 0.400 ms | **1.500 ms** | 1.700 ms | 3.600 ms |
| 本次：build | 0.100 | 0.200 | 0.200 | 2.400 |
| 本次：layout | 0.100 | 1.000 | 1.100 | 1.800 |
| 本次：paint | 0.100 | 0.100 | 0.100 | 1.000 |
| 本次：present | 0.100 | 0.300 | 0.400 | 0.400 |
| **M4 基线**（全表已在内存） | 0.200 | **0.800** | 1.000 | 1.300 |
| 本次：滚动调用墙钟（含后台查询被调度到的时间） | 0.371 ms | 2.085 ms | 2.227 ms | 3.895 ms |

- 门限 16.7 ms：**p95 1.5 ms，余量 ~11×**，判定通过。重复运行落在 p50 0.3–0.4 ms、p95 1.3–1.5 ms（下表为其中一次；另一次为 total p50 0.300 / p95 1.300 / p99 1.400 / max 2.900，layout p95 0.800）。
- **与 M4 基线的比较：p95 1.5 ms vs 0.8 ms，没有回到 0.8 ms 量级。** 差距集中在 1,000 帧中**应用新一页的那 123 帧**（layout 0.8–1.0 ms），稳态帧（p50）是 0.4 ms vs 基线 0.2 ms。把步长降到 400 DIP（更接近真实触摸板）复测，total p95 1.3 ms、layout p95 0.8 ms，差距不消失。原因：每次有新行进来，`ui.List` 要为变化的行数重新同步/重排并测量新进入视口的行，而 M4 的 10,000 行是一次性装进列表的，滚动帧里没有任何行数变化。若要把 p95 压回 0.8 ms，需要 MyGo 侧支持「只在尾部追加、不重排行数」的增量更新（或把页大小调大以减少行数变化次数——实测 4 页预取反而是 1.4 ms，不划算）。
- 结论如实写：**吞吐与稳定性达标，帧时间相对 M4 退化约 0.5–0.7 ms**；没有用「仍在 16.7 ms 内」代替这一条。

### 3.5 空字符串元数据的一次性归一

`GROUP BY` 用原始列（索引友好），于是历史上存成 `''` 的专辑/艺术家会和存占位符的行分成两组、显示成两个同名分组。`ensureSchema`（只在**可写**打开时跑）加了一条幂等归一：

```sql
UPDATE tracks SET artist = '未知艺术家' WHERE TRIM(artist) = ''
UPDATE tracks SET album  = '未知专辑'  WHERE TRIM(album)  = ''
```

只改「完全空」的元数据，改成界面本来就会显示的名字；不改列、不动 `user_version`、重复跑无变化。匹配时（`TrackQuery{Artist/Album: 占位符}`）也同时接受 `col = 占位符` 与 `TRIM(col) = ''`，所以归一之前建的查询也不会漏行。

### 3.6 刷新契约（M4 §2.5 保留）

- 列表 key 含**库 revision**（任何写都会推高：扫描、收藏、歌单、播放次数）+ epoch（应用侧显式 `Invalidate`）→ 任何写都会重读已加载的窗口，且保持已翻页数。
- 行键 `RowKey{ID, Rev, Pos}`：元数据写只重建该行；`Pos` 只在歌单页生效（同一首可以出现两次，光靠 ID 会撞键 —— 端到端用例复现过这个 panic 并已修）。
- 计数与歌单摘要按 1 秒节流重读：`recordPlay` 每次起播都会推高 revision，但曲目数/专辑数不会因此变；显式 `Invalidate`（应用自己写完）不受节流。

---

## 4. 质量门

```text
cd client
gofmt -l .                                   → 空
CGO_ENABLED=0 go build ./...                 → 通过
CGO_ENABLED=0 go vet ./...                   → 通过
CGO_ENABLED=0 go test ./...                  → 全部包通过
CGO_ENABLED=0 go test -race ./...            → 全部包通过
```

新增测试：

| 包 | 用例 |
|---|---|
| `internal/library` | 分页/过滤/排序/搜索、歌单顺序与分页、专辑与艺术家聚合、计数与最近播放、`EXPLAIN QUERY PLAN` 索引断言、10,000 行页查询耗时、歌单全链路（含空洞压紧与重复曲目）、收藏写入与重开持久化、删除来源（不误删、级联、封面集合）、引用封面列表 |
| `internal/player` | 随机：首位固定/全排列、关闭后还原为原序（前缀不动）、重复曲目保留、与三种循环共存 |
| `internal/ui/model` | 一触发一页与闸门、刷新保页与行键 revision、页在途时保留旧行、搜索防抖与分组、聚合列表、收藏/歌单/随机经 Actions 落到应用、歌单页顺序 |
| `internal/shell` | 端到端：点击按钮 → 真写库 → **独立连接**读回（收藏/取消、歌单建-加-改名-排序-移出-删除、来源删除与孤儿封面、随机按钮）；10,000 行滚动 p95 |

`-race` 下 `TestLibraryScrollP95At10000Rows` 跳过（race 插桩主导帧时间，原因写在测试里）。

---

## 5. 生产库与证据

生产库：`~/Library/Application Support/com.halunhaku.tingyu/library.sqlite`

```text
before: 310526fdbac4e7dd9615c4d124bb28049146f87f4bce00629ed8f10b4581fb73  2026-10-25 14:30:24
after:  310526fdbac4e7dd9615c4d124bb28049146f87f4bce00629ed8f10b4581fb73  2026-10-25 14:30:24
PRAGMA user_version = 2；tracks = 178（前后一致）
```

所有写操作、扫描、截图、10,000 行台架都在 `/tmp/tingyu-m5*` 的副本上。副本上的最终状态（`sqlite3`）：

```text
PRAGMA user_version → 2
SELECT COUNT(*) FROM tracks → 178
SELECT COUNT(*) FROM music_sources → 1        （删掉合成来源后）
SELECT COUNT(*) FROM playlists → 0            （删掉验收歌单后）
SELECT playlist_items 为该歌单的行数 → 0      （级联）
```

---

## 6. 偏差与未完成

- **滚动 p95 未回到 0.8 ms 量级**（§3.4）：需要 MyGo 的下表增量能力或另设页大小策略，属内核外依赖，未在本阶段动。
- **排序索引**是共享库 schema 的加法（§3.3），已在上面写明理由与代价；如果要严格「与 Flutter 库完全同索引集」，删这 5 条即可，代价是分页退化回整表排序。
- **搜索仍扫全表**（子串无法用 B 树索引）：用 `LIMIT` 与防抖兜住；FTS5 属后续。
- **删除来源的凭据**：本地来源没有凭据；WebDAV/夸克的 secret 由远端来源工作（另一个 todo）引入的安全存储负责，届时删除来源需要同时删 secret —— 本阶段的 `DeleteSource` 只处理数据库与封面，注释里已写。
- **封面全量回收**会顺带删掉副本里此前就存在的孤儿（§2.3），这是 `CollectOrphanCovers` 的语义，不是 bug；生产库只有在真正删除来源时才会触发。
- **播放计数会推高 revision**：列表 key 含 revision，所以起播一首会让已加载窗口在后台重读一次。窗口只加载了 40 行时是 ~0.3 ms；如果用户已经滚到 10,000 行，每次起播就是一次整窗查询（后台 ~10–30 ms，不影响帧时间）。可优化点：把播放计数放进独立的、不进列表 key 的 revision（代价是行内的播放次数不再即时刷新）。本阶段保留「任何写都刷新」的简单契约。
- **`TINGYU_BENCH_ROWS` 合成行台架已移除**：它靠「把合成行塞进视图模型」，与现在的 SQL 分页相冲；10,000 行改用 fixture + `scripts/measure-scroll.sh` 覆盖。
- **M4 §7 第 5 项（队列跳播的原地语义）仍未做**：队列页点击仍走 `PlayTracks` 重建队列（能跳到该首，但队列身份与 Flutter 的 `playAt` 不完全一致）。本阶段没有扩这项的理由：它不是「需内核支持」的空按钮，跳播本身已可用。
- 未做：远端来源（另一 todo）、元数据补全/歌词抓取写回（M5）、封面取色（M5）、签名公证（M6）。

---

## 7. 复现

```bash
cd client
gofmt -l . && CGO_ENABLED=0 go build ./... && CGO_ENABLED=0 go vet ./...
CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go test -race ./...

# 分页与索引证据
CGO_ENABLED=0 go test ./internal/library -run 'TestQueryPlansUseIndexes|TestTenThousandRowPaging' -v

# 10,000 行滚动帧时间（原始采样写到第二个参数）
./scripts/measure-scroll.sh /tmp/tingyu-scroll.txt

# 库副本上的界面与截图
mkdir -p /tmp/tingyu-copy && cp "$HOME/Library/Application Support/com.halunhaku.tingyu/library.sqlite" /tmp/tingyu-copy/
cp -R "$HOME/Library/Application Support/com.halunhaku.tingyu/covers" /tmp/tingyu-copy/
TINGYU_DATA_DIR=/tmp/tingyu-copy TINGYU_AUTO_QUIT_MS=7000 go run .
CGO_ENABLED=0 go run ./tools/screenshots -data /tmp/tingyu-copy -out ../docs/screenshots
```
