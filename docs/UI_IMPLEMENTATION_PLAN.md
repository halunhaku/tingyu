# 听屿 3.0 UI 可执行实施方案

> 执行角色：DeepSeek；工作根目录 `F:/project/tingyu`，Flutter 命令在 `app/` 内执行。
> 输入：修订后的 `docs/UI_UX_AUDIT.md`、`docs/UX_REDESIGN.md`、`DESIGN.md` 与现有 `app/` 源码；实现阶段以修订版的 §10 能力边界为准。
> 本规划 Agent 只读核查且只覆盖本交付文件，未执行分析、构建、测试或启动；下列命令及预期是后续执行门禁，不代表本次运行结果。
> `app/` 前缀在章节标题中若省略均指 `app/lib/` 或 `app/test/` 明写的完整文件相对路径；技术结论以标注的文件/行或文档章节为据。

## 0. 已核查事实、优先级与执行方式

- `docs/UI_UX_AUDIT.md:50-81` 是早期审计快照，46 个测试文件、244 用例为当时数据，不能把它当作本轮新增测试数。
- 本轮只读 `app/test/` 顶层目录时原有 48 个测试文件，另有首批新增的 `design_tokens_test.dart` 与 `design_system_render_test.dart`，见目录枚举；48 项逐个处置见 §10。
- **批次 1 已完成**；主 Agent 报告它的 `flutter analyze` 与 `flutter test` 已通过。本规划 Agent 未复跑，执行者从已提交成果接续。
- 已完成的 `app/lib/design/tokens/{color,typography,metrics,motion,tokens}.dart` 与 `app/lib/design/theme.dart` 的类型保持原样，见 `tokens.dart:12-83`、`theme.dart:14-43`。
- 已完成 `app/lib/design/layout/form_factor.dart:9-37,346-479`；`context.formFactor/.metrics/.traits` 与 `TyLayoutScope` 是实际上下文 API。
- `TyTheme.build({required Brightness brightness,TyDensity density})` 是实际主题签名；`context.ty.colors/.typography` 是实际取样式入口，见 `app/lib/design/theme.dart:14-43,330-346`。
- `app/test/support/pump.dart:13-93` 已有 `pumpTyApp`、`TyTestSizes`，`app/test/support/fake_audio_engine.dart:11-43` 已有可控 `FakeAudioEngine`。
- `app/lib/design/components/{cover,buttons,interactive}.dart` 已存在；B2 必须先按真实声明调用，勿另建相同类。
- `buttons.dart:12-42,151-177` 已将 `TyButton` 与 `TyIconAction` 按职责放在同一个 `buttons.dart`；修订后的 `DESIGN.md:24-40` 明确允许这种分组，不拆文件。
- `cover.dart:48-75,179-210` 同时放 `TyCover/TyAvatar`；其文件路径和现有公开构造函数优先于早期规划猜测。
- `interactive.dart:58-105` 已有 hover、press、focus、键盘激活、右键、长按原语；新组件使用它，不平行造第二套。
- `app/lib/main.dart:137-164` 正式应用仍以平台布尔选旧外壳，写死 `ThemeMode.system`；B2 接偏好、B3 换外壳。
- `app/lib/app/router.dart:26-88` 仍是单 `ShellRoute` 包裹 `/now-playing`；B3 换外壳，B4/5/6 逐批原子迁调用点，最终 `/stage` 用根 Navigator。
- `app/lib/data/models/library_summaries.dart:3-35` 的专辑身份是 `(artist,album)`、艺人身份是 `name`，没有设计文档旧版所写的 UUID id。
- `app/lib/app/playback_controller.dart:18-39,121-123,400-480` 同时管理来源队列、解析队列、并行索引、预取与队尾；B6 仅增一个末尾追加方法。
- 修订的 `docs/UX_REDESIGN.md:141-169,338-353` 将队列定为只读、跳转、末尾追加，也将仓储只读查询列为有限新增；本方案严格用此最新口径。
- `app/dart_test.yaml:1-5` 已将 golden 标为 skip，`.github/workflows/flutter.yml:45-55` 已使用 `flutter test --exclude-tags golden`；B7 检查保持，不重复改 CI。
- 顺序为 **B1 tokens / 脚手架 → B2 组件 / 偏好 → B3 外壳 → B4 曲库与搜索 → B5 来源 / 设置 / 引导 → B6 播放器 → B7 守卫 / 截图 / 文档**。
- 每批要求工程可编译、指定 smoke 可跑且改动边界清晰；批内路由与调用者同改，不能留某页面指向尚未定义的路径。
- 单 `ShellRoute` 在 B3 起取代双外壳；B3 仍用当时存在的真实页面/旧 URL，B4/5/6 逐批切换，最终没有旧 URL alias。
- 动作与持久数据的区别：代码批次可以回退；用户已经同步、删除来源或修改偏好时需通过备份恢复数据，不能宣称源码回退会恢复 SQLite。

## 1. 最新设计裁定与设计差异

### 1.1 只允许的业务接入

- `docs/UX_REDESIGN.md:338-353` 定义三类增量：三项 JSON 应用偏好、一个 `PlaybackController.enqueueTracks(List<Track>)`、搜索/最近添加的仓储**只读**新方法。
- 除此不改 `TrackRepository` 已有方法的签名/语义，不改 `SourceAdapter`/`TrackResolver`/`TingyuAudioHandler` 与 `lib/playback/**` 对外契约，不改 Drift schema。
- 引擎完整重置 `handler.setQueue` 会在 just_audio/media_kit 重建播放列表，见审查 `docs/DESIGN_REVIEW_1.md:10-23` 及当前 `playback_controller.dart:255-270`。
- 唯一允许的队列增量是末尾追加：优先复用 `handler.addToQueue`，见 `playback_controller.dart:432-458`；不通过新列表调用 `handler.setQueue` 来实现追加。
- 当前 `SourceScanResult` 只有 tracks/skipped/cancelled/truncated/truncationReason/isAuthoritative，见 `app/lib/sources/source_adapter.dart:4-32`；展示这些**实际有的**字段及合并计数。
- 仓储搜索可在 `app/lib/data/repositories/{track,playlist}_repository.dart` 新增只读分页/COUNT 方法；既有 `watchSearch` 保持原样（`track_repository.dart:50-81`）。
- `app/lib/data/repositories/source_repository.dart:9-28` 已提供来源列表，搜索来源采用现有 `sourcesProvider` 内存过滤，来源不新增 UI scope。

### 1.2 两份上游文本在同一主题上的口径差异

- 修订 `docs/UX_REDESIGN.md:146-153` 规定全局命中分组含“来源”，`docs/UX_REDESIGN.md:231-238` 又规定“来源不进搜索”范围；执行口径：`/search` 的全部结果包含来源小组，scope chips 仅歌曲/专辑/艺术家/歌单，来源命中跳 `/source/:id`。
- `docs/UX_REDESIGN.md:141-150` 说一次点击起播，而 `:160-168` 桌面表格又定义单击选择、双击播放；落实更具体规则：compact 列表单击起播，桌面表格单击选中、双击/hover 播放按钮起播。
- `docs/UX_REDESIGN.md:109-125` 用 `/album/:name?artist=` 和 `/artist/:name`；`app/lib/data/models/library_summaries.dart:3-35` 只有组合键/名称，故无人工构造 UUID。
- `docs/UX_REDESIGN.md:231-244` 的 `AsyncStateView` 是描述性别名，真实组件统一叫 `TyAsyncView`，见 `DESIGN.md:14-19,401-407`。
- 舞台主控按修订 `DESIGN.md:299-319` 的 **56**，不是早期重设计截图里的 64；触控命中至少 48。
- `DESIGN.md:263-279` 已把窗口定为**软下限 360×480**，不借 `window_manager` 申请原生最小值；Windows 412×915 compact 仍可调试。
- `DESIGN.md:397-406` 命中区 compact/medium/expanded 分别 ≥44/40/36，表格行内可视觉 32 而实际至少 36，密度切换不缩小命中区。
- `DESIGN.md:143-154` 已明确关闭动画时取色保持静态，仅停漂移；用户关闭 coverTint 或没有本地封面才改中性渐变。
- `DESIGN.md:10-26` 机械守卫限定 `lib/features/**` 和 `lib/design/components/**`；不能把 `lib/app/**`、`lib/design/tokens/**` 误作为全域常量扫描对象。
- 守卫要对 feature 层布局平台判断单独约束；权限、文件管理、音频分支按文件与表达式豁免，见 `DESIGN.md:17-27`，不能一律删除合法平台逻辑。
- `docs/UI_UX_AUDIT.md:52-72` 的“禁止碰数据/控制器”是审计旧基线；修订 `docs/UX_REDESIGN.md:338-353` 有优先级更高的窄范围新增，其他禁止事项仍成立。
- 旧审计声称“播放失败从不显示”，而当前 `app/lib/features/shared/playback_failure_listener.dart:14-41` 已显示全局提示；B6 重点是新增行内失败态，并保留原监听去重。
- 源头记录的其他不一致见 `docs/DESIGN_REVIEW_1.md:115-180`；本方案在验收条目保留 `[未验证]` 真机能力，不把文档中的早期实测视作新实现证据。

## 2. 文件级改动总览（按 tokens → 组件 → 外壳/路由 → 页面 → 播放器 → 守卫/文档）

### 2.1 B1 设计 tokens 与测试脚手架（已完成）

| 文件 | 唯一职责 | 状态 |
|---|---|---|
| `app/lib/design/tokens/color.dart` | 浅深色板和语义色 `TyColors`。 | 已完成 |
| `app/lib/design/tokens/typography.dart` | Type Scale 和字体 fallback。 | 已完成 |
| `app/lib/design/tokens/metrics.dart` | `TySpace/TyRadius/TyIconSize/TyElevation`。 | 已完成 |
| `app/lib/design/tokens/motion.dart` | `TyDuration/TyCurve`。 | 已完成 |
| `app/lib/design/tokens/tokens.dart` | `TyTokens`/`TyDensity` 聚合。 | 已完成 |
| `app/lib/design/theme.dart` | `TyTheme.build` 与 `context.ty`。 | 已完成 |
| `app/lib/design/layout/form_factor.dart` | `FormFactor`、`PlatformTraits`、`TyMetrics`、`TyLayoutScope`。 | 已完成，B3 补 provider 桥 |
| `app/test/support/pump.dart` | `pumpTyApp` 与预设尺寸。 | 已完成 |
| `app/test/support/fake_audio_engine.dart` | 测试用 `FakeAudioEngine`。 | 已完成 |
| `app/test/design_tokens_test.dart` | 比色与 token 断言。 | 已完成 |
| `app/test/design_system_render_test.dart` | 浅深/形态/密度渲染。 | 已完成 |

- 不覆盖这 11 个已完成文件来追随旧版文字里误写的 `ty.type` 或 `900×600` 常量；必要的窗口软下限补丁只在已有 `form_factor.dart` 的 `TyLayoutScope` 常量处修改。
- `form_factor.dart:390-407` 当前最小窗口值是 900×600，与修订 `DESIGN.md:263-279` 冲突；B3 改软下限 360×480 的 UI 判定值，并增窗口边界测试。
- `formFactorProvider` 是修订 `DESIGN.md §1` 所需的 provider 桥；widget 仍用已有 `context.formFactor`，不可新建另一套阈值常量。

### 2.2 B2 组件基础及偏好

| 文件（新增或续建） | 职责 |
|---|---|
| `app/lib/design/components/interactive.dart` | 续用已建 `TyInteractive/TyFocusRing` 的所有交互状态。 |
| `app/lib/design/components/buttons.dart` | 续用已建 `TyButton/TyIconAction`，追加 pill-play 变体。 |
| `app/lib/design/components/cover.dart` | 续用已建 `TyCover/TyAvatar`，保留本地/网络封面解析。 |
| `app/lib/design/components/feedback.dart` | `TySnack/TyTooltip/TyBadge` 的提示与徽标。 |
| `app/lib/design/components/search_field.dart` | `TySearchField`；输入空格与聚焦不触发播放。 |
| `app/lib/design/components/chip.dart` | `TyChip/TyFilterChip` 的选中态。 |
| `app/lib/design/components/segmented_control.dart` | `TySegmentedControl<T>`。 |
| `app/lib/design/components/dialog.dart` | `TyDialog` 的确认与表单校验。 |
| `app/lib/design/components/sheet.dart` | `TySheet` 的移动端弹层。 |
| `app/lib/design/components/async_view.dart` | `TyAsyncView<T>` 四态入口。 |
| `app/lib/design/components/skeleton.dart` | `TySkeleton` 的行/网格/详情形状。 |
| `app/lib/design/components/empty_state.dart` | `TyEmptyState`。 |
| `app/lib/design/components/error_view.dart` | `TyErrorView`。 |
| `app/lib/design/components/inset_group.dart` | `TyInsetGroup`。 |
| `app/lib/data/settings_store.dart` | 应用 JSON 偏好原子存储，与业务数据库隔离。 |
| `app/lib/app/preferences.dart` | `TyPreferences/PreferencesController/preferencesProvider`。 |
| `app/test/support/fixtures.dart` | 35 首/6 专辑/3 艺人/2 歌单/3 来源 fixtures。 |
| `app/test/settings_store_test.dart` | 重启恢复与损坏 JSON 的可恢复行为。 |
| `app/test/async_state_test.dart` | 四态、错误重试、空态行动。 |

- B2 大改 `app/lib/main.dart:137-165` 的主题接线，但**不在 B2 伪造新的设置页入口**；真实外观设置行在 B5 接入。
- B2 删除旧 `app/lib/app/theme.dart:1-69`，删除前迁所有 import；旧平台密度 `defaultTargetPlatform` 不保留。
- B2 改写 `app/test/theme_density_test.dart` 和受主题 import 影响的 UI 测试，保持触控大小与不同密度差异断言。
- `app/lib/design/components/feedback.dart` 与 `DESIGN.md §1` 的“按职责分文件”一致；三个反馈类型同一职责，不拆成过度琐碎文件。

### 2.3 B3 外壳、布局与可增量路由

| 文件 | 职责 |
|---|---|
| `app/lib/design/layout/app_shell.dart` | 唯一 `TyAppShell`；宽度选侧栏、rail、底导航，透传真实路由 child。 |
| `app/lib/design/layout/panels.dart` | 独立面板宿主；B6 接完整播放器检查器。 |
| `app/lib/design/components/sidebar.dart` | `TySidebar`；继续给真实来源、歌单入口。 |
| `app/lib/design/components/nav_rail.dart` | `TyNavRail`；medium 真实导航。 |
| `app/lib/design/components/bottom_nav.dart` | `TyBottomNav`；B3 暂映射当时已存在的四个真实根目的地。 |
| `app/lib/design/components/page_header.dart` | `TyPageHeader`；新外壳第一页可实际使用。 |
| `app/lib/design/components/section_header.dart` | `TySectionHeader`；新外壳第一页可实际使用。 |
| `app/lib/design/components/panel.dart` | `TyPanel`；B6 切实歌词/队列内容。 |
| `app/lib/design/layout/form_factor.dart` | B3 增 `formFactorProvider` 桥及软下限。 |
| `app/lib/app/router.dart` | 将旧 ShellRoute builder 改 TyAppShell，仍服务现有真实页面。 |
| `app/lib/main.dart` | 移除 `mobile:` 与 `TINGYU_DEBUG_MOBILE_SHELL` 强制结构。 |
| `app/test/form_factor_test.dart` | 断点、软下限、平台交互、改宽保持服务状态。 |

- B3 删除 `app/lib/features/shell/{app_shell,mobile_shell}.dart`，因为所有旧路由已由 TyAppShell 承载；B4/B5/B6 分批迁路由时只维护这个外壳。
- B3 TyBottomNav 接老根：`/library`、`/favorites`、`/playlists`、`/sources`；B4 所需 `/search` 与 `/my` 真页落地时**同批**改为最终四目的地。
- B3 `TyAppShell` 的 `ShellRoute` 仍只有**一个**，`matchedLocation` 判定详情时 compact 隐藏底 Tab；B4 更换详情 URL，不新增第二 Shell。
- B3 分批期间的旧 URL 是尚未迁走的当前路径，不与新 URL 并行注册同页别名；最终 B6 移除所有旧路径。
- B3 软下限宽 <360 或高 <480 时只显示明确的 `TyErrorView`，360×480 与 412×915 均显示可用 compact 外壳。

### 2.4 B4 内容页、搜索与只读查询

| 文件 | 准确职责 |
|---|---|
| `app/lib/data/models/search_page_result.dart` | `SearchPageResult<T>({items,total})`，total 来源于真实 COUNT。 |
| `app/lib/data/repositories/track_repository.dart` | **只新增**歌曲/专辑/艺人搜索与最近添加分页及 count，不动旧方法。 |
| `app/lib/data/repositories/playlist_repository.dart` | **只新增**按歌单名搜索的分页及 count，不动编辑方法。 |
| `app/lib/app/providers.dart` | 搜索 250ms、防抖范围和会话级排序/筛选 provider；保留现有 public provider。 |
| `app/lib/features/library/library_view_state.dart` | `LibrarySort/LibraryFilter` 与 query 参数映射。 |
| `app/lib/features/library/search_page.dart` | `/search`、分组检索、scope 页面与命令面板共用数据。 |
| `app/lib/features/settings/my_page.dart` | `/my`：来源、设置、AI、关于的真实链接。 |
| `app/lib/design/components/track_row.dart` | `TyTrackRow`；复用旧行起播/收藏/菜单逻辑。 |
| `app/lib/design/components/track_table.dart` | `TyTrackTable`；表头、固定高、多选、排序。 |
| `app/lib/design/components/track_list.dart` | `TyTrackList`；compact 固定行高。 |
| `app/lib/design/components/album_card.dart` | `TyAlbumCard`。 |
| `app/lib/design/components/artist_row.dart` | `TyArtistRow`。 |
| `app/lib/design/components/playlist_card.dart` | `TyPlaylistCard`。 |
| `app/lib/design/components/detail_hero.dart` | `TyDetailHero`。 |
| `app/lib/design/components/sort_menu.dart` | `TySortMenu`。 |
| `app/lib/design/components/context_menu.dart` | `TyContextMenu`；桌面右键、触摸长按同动作。 |
| `app/lib/design/components/command_palette.dart` | `TyCommandPalette`；真实 query/search 分组与键盘选中。 |

- B4 迁 `app/lib/features/{library,albums,artists,playlists}/**` 现有页面，共享播放/收藏注入逻辑用原 provider。
- B4 修改 `app/lib/app/router.dart` 的曲库、专辑/艺人/歌单、搜索/我的路径；`/sources` 和 `/settings` 暂仍旧页，B5 迁。
- B4 修改 `app/lib/main.dart:249-283` macOS 10 个快捷键项里的导航路径，本批入口到已存在真实 B4 页面，正在播放一项 B6 改 `/stage`。
- B4 删除 `app/lib/features/shared/{cover_art,track_row,empty_state}.dart`，所有 import 同批迁 TyCover/TyTrackRow/TyEmptyState。
- B4 保持 `features/shared/add_to_playlist.dart` 对歌单仓储的真实写入与 `features/shared/current_track.dart` 的身份细粒度订阅。
- B4 迁旧 `_AlbumTrackRow/_ArtistTrackRow/_TrackRowWithPlayback` 为各宿主传入不同 `onPlay`，避免统一控件误改队列快照。

### 2.5 B5 来源、设置、真实引导

| 文件 | 准确职责 |
|---|---|
| `app/lib/design/components/source_card.dart` | `TySourceCard`；合并旧来源卡/列表项。 |
| `app/lib/design/components/settings_row.dart` | `TySettingsRow`；四类设置行。 |
| `app/lib/design/components/progress_bar.dart` | `TyProgressBar`；确定/不确定同步进度。 |
| `app/lib/features/sources/onboarding_page.dart` | 首次入库实际授权/添加来源/扫描/结果。 |
| `app/lib/features/sources/source_sync.dart` | 同一来源取消 token、防双击与真实回执。 |
| `app/lib/features/sources/{sources_page,source_page}.dart` | WebDAV/夸克/本地/SAF 入口、重试与来源恢复。 |
| `app/lib/features/settings/{settings_page,ai_settings_page}.dart` | 外观设置、AI 原操作与可重试错误。 |
| `app/lib/features/library/manual_match_dialog.dart` | 保留原元数据查询但改用 TyDialog。 |
| `app/lib/app/router.dart` | `/onboarding` 放根 Navigator、`/ai` 新页和 settings 子路径。 |
| `app/test/{source_state,onboarding}_test.dart` | 非权威同步、合法首用判定与真实写库调用。 |

- B5 修改 `app/lib/app/router.dart` 与设置页、MyPage 各调用者同批移除 `/settings/ai`，接 `/ai`。
- B5 保留现有夸克扫码、登录 WebView、WebDAV 测连、Android SAF 和本地目录选择流程。
- B5 `sourcesProvider` 与 `allTracksProvider` **两者都成功返回 data** 且都空才引导；有来源零曲目给来源恢复态。
- B5 来源级同步异常展示原因 + 重试；`skipped/cancelled/truncated` 仅有计数/状态，不虚构文件名。
- B5 危险清洗/删除来源等保留原确认；本方案没有“从库中移除单曲目”的新动作。

### 2.6 B6 播放器与末尾追加

| 文件 | 准确职责 |
|---|---|
| `app/lib/app/playback_controller.dart` | 只增 `Future<void> enqueueTracks(List<Track> tracks)`，无新编辑 API。 |
| `app/lib/design/components/transport_bar.dart` | `TyTransportBar` 状态、行内错误。 |
| `app/lib/design/components/mini_player.dart` | `TyMiniPlayer`、常驻收藏、Hero 入口。 |
| `app/lib/design/components/player_stage.dart` | `TyPlayerStage`、主控 56、展开/关闭。 |
| `app/lib/design/components/seek_bar.dart` | `TySeekBar` 的 seek、buffered 与键盘。 |
| `app/lib/design/components/volume_control.dart` | `TyVolumeControl` 的静音/音量，无输出设备操作。 |
| `app/lib/design/components/lyrics_view.dart` | `TyLyricsView`、LRC 点击跳转/手滚。 |
| `app/lib/design/components/queue_view.dart` | `TyQueueView`，只显示、点跳转和追加结果。 |
| `app/lib/design/motion/transitions.dart` | 命名过渡及 reduce motion。 |
| `app/lib/features/player/stage_background.dart` | 本地封面 24×24 取色/缓存/静态退化。 |
| `app/lib/features/player/{queue_page,lyrics_page}.dart` | compact 根页复用同一 TyQueueView/TyLyricsView。 |
| `app/lib/app/router.dart` | 根 `/stage`,`/queue`,`/lyrics`，删除 `/now-playing`。 |
| `app/lib/main.dart` | macOS 10 项中舞台入口与调试 route 完成最终迁移。 |
| `app/test/{playback_queue_append,player_transport,lyrics_view}_test.dart` | 追加四边界、三形态播放器与歌词行为。 |

- B6 删除 `app/lib/features/player/{now_playing_page,player_bar,mini_player,playback_controls,seek_bar,queue_panel,lyrics_panel,fluid_background}.dart`，旧 import/路由/测试同批全迁。
- B6 保留 `app/lib/features/player/lrc_parser.dart`，`TyLyricsView` 用其原来的逐行时间轴。
- B6 `stage_background.dart` 只取本地 `coverFileProvider` 返回的落盘路径，远端封面未落盘直接中性渐变。
- B6 继续保留 `PlaybackFailureListener` 在 `MaterialApp.builder`，行内错误不是全局监听替代品。
- B6 检查剩余旧 URL 调用，清除 `/library`、`/recent`、`/now-playing` 等全部别名；仅一次原子 cutover，不保留 redirect。

### 2.7 B7 守卫、截图与文档交付

| 文件 | 准确职责 |
|---|---|
| `app/test/design_guard_test.dart` | `DESIGN.md §0.5` 的全部规则与精确豁免。 |
| `app/test/fixtures/guard/valid.dart.txt` | 守卫正样例（结构合法、token、业务平台分支）。 |
| `app/test/fixtures/guard/invalid.dart.txt` | 每条规则至少一项反样例。 |
| `app/test/ui_snapshot_test.dart` | 320–1920 宽布局、两主题、PNG 矩阵。 |
| `app/test/library_golden_test.dart` | Windows 本机曲库图，tag=golden。 |
| `app/test/stage_golden_test.dart` | Windows 本机舞台图，tag=golden。 |
| `tools/windows-smoke-test.ps1` | 跟新路由与语义定位的真实运行检查。 |
| `app/dart_test.yaml` | **已存在 skip golden**，核对不改。 |
| `.github/workflows/flutter.yml` | **已显式 exclude-tags golden**，核对不改。 |
| `docs/UI_IMPLEMENTATION_PLAN.md` | 本方案，执行完成后按实际验证记录批次结果。 |

- B7 执行者需在其实际任务范围内更新面向用户的既有帮助/发布说明，以实际行为为准，不新建另一份设计系统规范。
- B7 删除过渡性的未使用页面私有组件、旧复制样式、过时代码注释，保留所有现有测试断言的行为覆盖。
- `test/fixtures/guard` 文件是测试样例，不应作为生产源码，被守卫扫描范围之外。

## 3. 批次执行门禁（每批完成后可编译、smoke、整体回退）

### B1：首批测试脚手架 + 设计系统骨架（已完成）

- 前置：无；当前仓库已拥有 §2.1 所列 tokens/theme/form factor/support。
- 真正调用 `TyTheme.build(brightness:Brightness.light,density:TyDensity.comfortable)`；没有 `TyTheme.light()` 平行构造。
- 真正调用 `pumpTyApp(tester,home: widget,size: TyTestSizes.phone,overrides:...)`；不创建第二个 test root。
- 骨架现有界限 `TyLayoutScope.minWindowSize` 后续 B3 改 360×480，不因 B1 完成而拒绝上游新裁定。
- 主 Agent 已报告 `flutter analyze`、`flutter test` 通过；这不是本规划 Agent 自己复验结论。
- 完成判据：B2 从现有 Ty 类和测试脚手架直接 import，不删除已完成的首批 2 个测试。
- 若执行者单独复核 B1：`flutter analyze` 与 `flutter test test/design_tokens_test.dart test/design_system_render_test.dart`，预期退出 0。
- Smoke：以 `TyTestSizes.phone/tablet/desktop` 渲染浅深双主题，不发生布局异常。
- 回退界限：B1 是本次实施基线，后续只回退自己的批次，不先推倒已验证 tokens。

### B2：现有组件原语 + 基础四态 + 偏好接入

- 前置：B1。
- 涉及文件：§2.2 全表；只动 `app/lib/main.dart` 主题构造与相关旧主题 import。
- `SettingsStore.read()` 与 `save()` 只处理 `{themeMode,density,coverTint}`；不碰 `library.sqlite` 与 `SecureStore`。
- `TingyuApp` 从 `preferencesProvider` 读 resolved 值，pending 仅用默认 system/comfortable/true；不能重新 `AudioService.init`。
- 损坏 JSON 保留文件供诊断并返回可恢复错误；重置操作显式覆盖后恢复默认，不能无声丢用户值。
- 原 `main.dart:155-164` 的 `MaterialApp.router.builder` 失败监听保留，运行时主题切换不重建 handler。
- 组件基础被两个真实使用点检验：旧设置页容器改 TyInsetGroup、全局失败反馈显示 TySnack；异步页加载用 TyAsyncView。
- 验证：`flutter analyze --no-pub`。
- 验证：`flutter test test/design_tokens_test.dart test/design_system_render_test.dart test/theme_density_test.dart test/settings_store_test.dart test/async_state_test.dart test/playback_failure_listener_test.dart`。
- 期望：均退出 0；新 container 读回三项值、触摸命中面积达标、旧失败文字/去重断言在。
- Smoke：`pumpTyApp` 注入 412×915、768×800、1440×900；切偏好时明暗/密度变化但 `FakeAudioEngine` 不二次 init。
- 回退：恢复 B2 主题接线及删除旧主题的操作为一个原子变更；用户 JSON 需另行备份并恢复。

### B3：唯一外壳、宽度布局、既有目的地可用

- 前置：B2。
- 涉及文件：§2.3 全表；两个旧 shell 文件在其所有 import 已迁完后删。
- 一次 `LayoutBuilder` 读取 child 约束，决定 factor/metrics/traits，并挂已有 TyLayoutScope；provider 只桥接同一次 factor。
- `formFactorProvider` 是 `Provider<FormFactor>`，嵌套 override 不重新建立 databaseProvider/playbackProvider 的状态；测试断言与 `context.formFactor` 相等。
- 旧 `/library`,`/favorites`,`/playlists`,`/sources` 均保留现有真实页面服务 B3 底 Tab，切换 `go` 后不增加返回栈。
- 在 compact 的现有详情路径隐藏 Tab，以 `state.matchedLocation` 判断，不靠 `Platform.isAndroid`。
- 最小窗口软限制 360×480，仅在更小时显示 TyErrorView，不能给 Windows Runner 注册原生最小值。
- 验证：`flutter analyze --no-pub`。
- 验证：`flutter test test/form_factor_test.dart test/navigation_gesture_test.dart test/design_system_render_test.dart`。
- 期望：640/1024 两断点准确、四个 Tab canPop false、详情 push 后 canPop true、360×480 可用。
- Smoke：Windows 视图 resize 412→900→1440，分别看到 bottom nav/rail/sidebar，播放状态和当前路径仍在。
- 回退：TyAppShell、路由 builder 与两个旧 shell 删除同时回退，不留下不存在的 builder import。

### B4：曲库页、四类真实分页搜索、跨页路由

- 前置：B3。
- 涉及文件：§2.4 全表、`features/{library,albums,artists,playlists}/**` 与其耦合测试。
- 先在 TrackRepository/PlaylistRepository 增只读 query+COUNT+分页测试，旧 `watchSearch` 不动。
- 再在 `app/providers.dart` 以 250ms 统一 debounce，SearchPage 与 CommandPalette 共用结果。
- `/search` 的全部组先查各组前 5 条及精确 COUNT；“查看全部”按 scope 发 40 条一页（页码 offset 0,40,80…）。
- 可读 `sourcesProvider` 中来源名过滤作为全部结果第五组；没有“来源” scope chip。
- 内容页替换共享 Ty 组件，每个旧起播 wrapper 将**当前可见排序集合**传给 `playTracks(list,startIndex)`。
- 同批路由切 `/library/{songs,albums,artists,playlists}`,`/favorites`,`/search`,`/my`,`/album/:name?artist=`,`/artist/:name`,`/playlist/:id`。
- B4 `TyBottomNav` 改四目标：歌曲 / 搜索 / 收藏 / 我的；同批 `MyPage` 已真实可点来源/设置/AI/关于。
- B4 修改 macOS 菜单中库/专辑/艺人/收藏等旧路径，当前 `/now-playing` 保持到 B6；不存在目的地不提早指向。
- 验证：`flutter analyze --no-pub`。
- 验证：`flutter test test/search_debounce_test.dart test/search_page_test.dart test/library_mobile_search_test.dart test/track_interaction_test.dart test/router_path_parameters_test.dart test/navigation_gesture_test.dart test/playlist_state_test.dart test/track_repository_test.dart test/playlist_repository_test.dart`。
- 期望：中文/同名匹配正确；201 条可点到；COUNT 真实；表格点击与双击不同；无旧 `/albums` 或 `/artists` 二次 builder。
- Smoke：412 宽搜索 Tab 自动聚焦并可输入空格；1440 宽表格双击起播；`/album/中文?artist=甲` 与 `/artist/甲` 深链进退正常。
- 回退：仓储只读新增、页面、组件、路由、macOS 菜单、改写测试同批退；库表及 legacy 导入不动。

### B5：来源、设置、合法首次引导

- 前置：B4。
- 涉及文件：§2.5 全表、`source_sync_test.dart` 与 `ai_settings_page_test.dart`。
- SourceSyncController 在每个 sourceId 上只允许一次扫描，cancel token 传入原 `SourceAdapter.scan(isCancelled:)`；取消后保留非权威保护。
- 回执准确显示 merge added/updated/removed 与 scan skipped/cancelled/truncated/reason；若总数未知 TyProgressBar 不显示虚假百分比。
- 有来源零曲目时显示“来源恢复/重新同步”而不是首用；只有 sources/track 的两个 AsyncValue 都 data 且为空才进引导。
- `/settings` 外观段调用 PreferencesController 三 setter，`/ai` 从旧 `/settings/ai` 原子迁移，AI 原文案和业务动作不断。
- `/onboarding` 根 Navigator 仅在真实首用条件自动 push 或 redirect；已在引导页继续成功添加来源后离开引导并显示真实同步结果。
- WebDAV 必填字段逐个 errorText；夸克、本地/SAF 和 legacy 导入路径保持。
- 验证：`flutter analyze --no-pub`。
- 验证：`flutter test test/source_sync_test.dart test/source_state_test.dart test/onboarding_test.dart test/ai_settings_page_test.dart test/ai_settings_repository_test.dart test/legacy_import_test.dart test/database_migration_test.dart`。
- 期望：取消/跳过/截断永不删旧曲，重复同步同源无第二次 scan；有来源零歌不进 onboarding。
- Smoke：空库且无来源→本地授权→扫描中取消→重试→显示新增计数；有来源零歌→恢复态重试入口。
- 回退：只回退 UI 编排层代码；已运行的来源删除和同步涉及真实数据时用事前 SQLite 备份恢复。

### B6：播放器三形态与末尾追加

- 前置：B5。
- 涉及文件：§2.6 全表、全旧播放器入口与路由/测试；旧引擎对外契约保持。
- 首先 `PlaybackController.enqueueTracks(List<Track>)`：空列表返回；等待当前 `_prefetchFuture`；确认同一 `_queueGeneration`；追加来源与原始队列；通过既有预取+`addToQueue` 追加已解析三数组。
- 绝不重新 `handler.setQueue` 或从播放 URI 假设 track id；追加不重置播放 position/playing。
- 实现末尾追加时 `_sourceQueue` 可先有**未解析尾项**；`_queue/_trackIds/_resolvedSourceIndices` 只在每首成功解析并 `handler.addToQueue` 后同步追加，不加入无意义占位。
- `_nextSourceIndex` 在解析游标处继续；若追加前 `_passFinished=true`，追加后新尾项可经预取被看见，next 不能无故重放旧完整队列。
- `_originalSourceQueue` 也按输入位置追加，shuffle 切回顺序时重复 id 不被去重；当前来源组与引擎顺序一致。
- 如果追加期间切歌/重建，检测 generation 变化并让旧异步请求无效，不能将新曲插进前一个会话；以测试锁定预期。
- 路由将 `/stage`,`/queue`,`/lyrics` 放 rootNavigatorKey；从 shell 用 `push` 覆盖，深链无历史时退 `/library/songs`。
- `TyTransportBar/TyMiniPlayer` 点击 stage，compact Hero 从 mini 封面展开；播放器三形态常驻收藏。
- `TyPlayerStage` 主控 56，音量与进度/缓冲真实展示；后端名只读在设置诊断行。
- 背景仅用本地封面小尺寸解码；无缓存、快速切歌时上一个结果不得污染当前。
- 验证：`flutter analyze --no-pub`。
- 验证：`flutter test test/playback_queue_append_test.dart test/playback_queue_wrap_test.dart test/playback_controller_modes_test.dart test/ui_rebuild_seek_test.dart test/player_transport_test.dart test/lyrics_view_test.dart test/transport_row_layout_test.dart test/now_playing_layout_test.dart test/tingyu_audio_handler_test.dart test/track_resolver_initial_uri_test.dart`。
- 期望：播放中追加不中断、shuffle/repeat 的 next 到新尾项、重复 id 保留重数、切歌竞态不串位；tick 零行重建、seek 松手一次。
- Smoke：Windows 样本播放→追加 2 首→下一首→看 SMTC 当前标题与 UI 一致→stage 展开/关闭回原详情，播放不停。
- 回退：Controller 增量、播放器组件、删除的旧页面及根路径一同退；不能只退 controller 却留下“加入队列”按钮。

### B7：全域守卫、截图矩阵与真实应用交付

- 前置：B6 所有新组件被真实页面使用。
- 涉及文件：§2.7 全表，测试 guard fixture、Windows smoke 更新；CI 两个配置只核对已有值。
- 守卫启用规则 §11；features 中确需二维码白色或权限平台判断用逐表达式 `// guard-ok: 理由`。
- 检查所有 Ty* 被实际使用，各异步页四态、Tab/Enter/Esc 与 Semantics/焦点可达。
- Windows 图按真实逻辑尺寸与 DPI 记录，同构建浅深各取 1440×900、1280×720；412×915 用无头图片补物理屏不足。
- 验证：`flutter analyze`，期望 `No issues found!`。
- 验证：`flutter test --exclude-tags golden`，期望普通测试全绿；Windows golden 明确运行 `flutter test --run-skipped -t golden`。
- 验证：`flutter test test/design_guard_test.dart test/ui_snapshot_test.dart test/ui_rebuild_seek_test.dart`，期望规则样例、尺寸和重建指标全绿。
- Windows 真机命令和人工矩阵见 §12；Linux CI 保持 `flutter test --exclude-tags golden`，并不重写它。
- 回退：守卫/截图/工具成批退；不可为了让命令绿而删除旧断言或把 UI 失败判为 empty。

## 4. 偏好存储、依赖构造与 FormFactor 接入

### 4.1 `settings_store.dart` 的具体类和失败边界

1. 文件：`app/lib/data/settings_store.dart`，定义 `class SettingsStore` 与 `Future<TyPreferences> read()`、`Future<void> save(TyPreferences value)`。
2. 默认目录来自 `getApplicationSupportDirectory()`，文件名固定 `settings.json`；测试用注入的 `Future<Directory> Function()` 临时目录。
3. JSON 三字段名称逐字是 `themeMode`、`density`、`coverTint`；不写任何 AI 密钥/来源凭据。
4. `themeMode` 字符串只接受 `system`,`light`,`dark`；`density` 只接受 `comfortable`,`compact`；`coverTint` 是 bool。
5. 文件不存在默认 system/comfortable/true；单字段缺失用对应默认值，未知枚举值返回错误并在设置呈可恢复态。
6. JSON 解析失败不得先写空文件覆盖原件；提供用户可操作重置，重置之后才保存默认。
7. 保存同目录临时文件、flush，再 rename；任何写入异常反馈到 UI，不宣称“已保存”。
8. 新的偏好 JSON 没有 Drift schema 迁移，见 `DESIGN.md:42-52`。

### 4.2 `preferencesProvider` 与启动顺序

1. 文件：`app/lib/app/preferences.dart`；定义 immutable `TyPreferences`（3 字段）和 `PreferencesController extends AsyncNotifier<TyPreferences>`。
2. `settingsStoreProvider=Provider<SettingsStore>`；`preferencesProvider=AsyncNotifierProvider<PreferencesController,TyPreferences>`。
3. `PreferencesController.build` 读取 `ref.read(settingsStoreProvider).read()`，setter `setThemeMode/setDensity/setCoverTint` 先持久化成功再更新 state。
4. 原 `main.dart:54-64` 保持 `WidgetsFlutterBinding.ensureInitialized()` 与 onError zone 原顺序。
5. 原 `main.dart:67-74` 的桌面 `MediaKit.ensureInitialized` 保留。
6. 原 `main.dart:77-96` 的权限/edge-to-edge/AudioSession 保留原条件和顺序。
7. 原 `main.dart:98-109` 建立 engine 和唯一一次 `AudioService.init<TingyuAudioHandler>`。
8. 原 `main.dart:111-129` 保持 data harness、AppLifecycleListener 及 handler.dispose 的唯一出口。
9. 再 `ProviderScope` 覆盖 `audioHandlerProvider`，由 `TingyuApp` 的 Consumer 读取偏好状态。
10. `MaterialApp.router(theme:TyTheme.build(brightness:Brightness.light,density:value.density),darkTheme:TyTheme.build(brightness:Brightness.dark,density:value.density),themeMode:value.themeMode,...)`。
11. 偏好 pending 的临时默认值只用于首次 frame；失败显示可重置入口，不触发 handler 二次 init。
12. `MaterialApp.builder` 中 `PlaybackFailureListener` 原全局提示继续存在；行内失败在 B6 才补。
13. `TingyuApp` 对明暗与密度选择只重建 MaterialApp 的主题，不重建 `ProviderScope` 的 audioHandlerProvider。
14. macOS 菜单、调试 route 与 app router 生命周期保持单次创建；偏好变化不刷新导航栈。
15. B5 SettingsPage 外观分组接三个 setter，保存中禁重复点，出错保留旧可见选择。

### 4.3 宽度、交互能力与 provider 桥

- B3 在 `app/lib/design/layout/form_factor.dart` 添加 `formFactorProvider=Provider<FormFactor>` 只读桥。
- `TyAppShell` `LayoutBuilder` 对实际可用 child 宽度算 `FormFactor.ofWidth(width)`（现枚举阈值见 `form_factor.dart:9-37`）。
- 用该 factor 和 prefs.density 调一次 `TyMetrics.resolve`，按当前 `Theme.of(context).platform` 算 PlatformTraits。
- 同一个 factor 传 `TyLayoutScope` 及嵌套 ProviderScope 的 `formFactorProvider.overrideWithValue(factor)`；页面 widget 仍 `context.formFactor`。
- provider 只做业务派生跨组件读宽度，不存独立窗口宽度，断点 639.99/640/1023.99/1024 双 API 始终相同。
- 平台只控制 hover、快捷键 Ctrl/⌘、长按、滚动条、安全区/授权，绝不凭 Android/iOS 推断 compact。
- Windows 可缩至 412×915 以看 compact，Android 横屏 1280 可走 expanded；尺寸取当前布局约束。
- `TyLayoutScope.minWindowSize` 从旧 900×600 改 `Size(360,480)`（旧值证据 `form_factor.dart:390-407`，新值 `DESIGN.md:263-279`）。
- 宽 <360 或高 <480 时用 TyErrorView 告知当前尺寸；不限制 Windows 窗口本身，也不强制手机竖屏高度 >480 才可运行系统栏布局。
- 行命中目标按 `TyMetrics.hitTarget` compact 44 / medium 40 / expanded 36，输入含触摸能力时至少 44，不随 compact density 调小。
- 宽度变化测试必须断言当前曲目/queue 和浏览路由仍在；排序、筛选、搜索词由 provider 保留，滚动由 PageStorageKey 保留。
- 切根页时局部选区/焦点/输入光标重置，符合修订 `docs/UX_REDESIGN.md:102-113`；测试不强求它们保活。

## 5. 最终路由表、旧路径与 10 个菜单项

- 唯一 `ShellRoute` 使用 `TyAppShell(child:child)`；最终 `createRouter({String initialLocation='/library/songs'})` 不带 `mobile`。
- 定义根 `_rootNavigatorKey=GlobalKey<NavigatorState>()` 与 Shell `_shellNavigatorKey=GlobalKey<NavigatorState>()`，在 GoRouter/ShellRoute 各自接 `navigatorKey`。
- `/stage`,`/queue`,`/lyrics`,`/onboarding` 是 root GoRoute，`parentNavigatorKey:_rootNavigatorKey`；`context.push` 覆盖外壳，`pop` 返回原列表。
- shell builder 接 `GoRouterState.matchedLocation` 到 TyAppShell，compact 在详情匹配 `/album/`,`/artist/`,`/playlist/`,`/source/` 时隐藏底 Tab。
- 深链 `/stage` 无历史时 Back 和 Esc 都 `context.go('/library/songs')`，避免 `pop` 空栈。
- 切 Tab、菜单直接到根路径统一 `context.go`；详情、舞台和根弹层统一 `context.push`。
- 旧入口切换按 B4 内容页、B5 设置/引导、B6 舞台执行；同一目标不能保留新旧别名。

| 旧路径/入口 | 最终路径 | 确切页面与参数消费 |
|---|---|---|
| `/` | `/library/songs` | 修改 initialLocation，旧 `/` 不注册 alias。 |
| `/library` | `/library/songs` | `LibraryPage()`，查询排序/筛选。 |
| `/recent` | `/library/songs?sort=added` | `LibraryPage` 全量按 dateAdded 排序，不用旧 100 条截断。 |
| `/favorites` | `/favorites` | `LibraryPage(favoritesOnly:true)` + 专辑分段。 |
| `/albums` | `/library/albums` | `AlbumsPage`。 |
| `/artists` | `/library/artists` | `ArtistsPage`。 |
| `/playlists` | `/library/playlists` | `PlaylistsPage`。 |
| `/albums/:artist/:album` | `/album/:name?artist=` | `AlbumDetailPage(albumKey:AlbumKey(artist:state.uri.queryParameters['artist']!,album:state.pathParameters['name']!))`。 |
| `/artists/:name` | `/artist/:name` | `ArtistDetailPage(artist:state.pathParameters['name']!)`。 |
| `/playlist/:id` | `/playlist/:id` | `PlaylistPage(playlistId:...)`，真实 id 原样。 |
| `/sources` | `/sources` | `SourcesPage`。 |
| `/source/:id` | `/source/:id` | `SourcePage(sourceId:...)`。 |
| `/settings` | `/settings` | `SettingsPage`，外观等六分组。 |
| `/settings/ai` | `/ai` | `AISettingsPage`，设置入口改路由。 |
| `/now-playing` | `/stage` | `TyPlayerStage`，根 Navigator，`?tab=lyrics|queue`。 |
| 无 | `/search?q=&scope=` | `SearchPage`，四 scope（来源只进全部结果小组）。 |
| 无 | `/my` | `MyPage`，compact 第四根 Tab。 |
| 无 | `/onboarding` | 首次引导，根 Navigator。 |
| 无 | `/queue` 与 `/lyrics` | compact 独立根页重用播放器组件。 |
| 无 | `/settings/:section` | 同一 SettingsPage 可选 `appearance/playback/library/sources/ai/about`；未知 section 错误态。 |

- 生成专辑链接统一：`'/album/${Uri.encodeComponent(album.album)}?artist=${Uri.encodeQueryComponent(album.artist)}'`；query 中艺术家含 `&/+/%` 不得裸拼。
- `go_router 18` 已解 path/query 参数，见 `app/lib/app/router.dart:48-59` 的已有提醒；builder 不可再次 `decodeComponent`。
- `/album/:name` 缺 `artist` 或空 `name` 时 TyErrorView 给退回专辑列表的真实 action，不能查询整个专辑表误命中。
- 艺人中文名 `Uri.encodeComponent`，不存在艺人显示错误态，不添加 `artistId` 数据库列。
- `app/lib/features/albums/albums_page.dart:132-134` 专辑卡片使用新链接。
- `app/lib/features/artists/artist_detail_page.dart:271-273` 专辑关联链接同方法；回退到 `/library/artists`。
- `app/lib/features/artists/artists_page.dart:143-145` 艺人卡片改 `/artist/${Uri.encodeComponent(name)}`。
- `app/lib/features/albums/album_detail_page.dart:43-79` 深链 Back → `/library/albums`，已有栈则 pop。
- `app/lib/features/playlists/playlist_page.dart:139-142` 深链 Back → `/library/playlists`。
- `app/lib/features/library/library_page.dart:130-140` 两个详情/分段按钮改 `/library/artists` 与 `/library/albums`。
- `app/lib/features/settings/settings_page.dart:90-95` AI 入口改 `/ai`。
- B6 旧 `player_bar.dart:119-121`、`mini_player.dart:50-52` 换 Ty 组件的 `context.push('/stage')`。
- B6 更新 `main.dart:137-151` 的 `TINGYU_DEBUG_ROUTE` 默认与允许值；`TINGYU_DEBUG_MOBILE_SHELL` 删除（平台布尔布局已过时）。
- B6 更新 macOS 10 个带 shortcut 菜单项的全部注册；B4 先迁四个导航、B5 迁设置、B6 迁正在播放，播放/上一/下一等保持原 handler 命令。
- 用只读搜索 `grep` 或 `rg` 检查 `main.dart`、`app/router.dart`、所有 `features/**` 的 `context.push/go` 不再含旧路径；不可留下旧注释误导 QA。
- `navigation_gesture_test.dart`：新四根 Tab 的 `canPop=false`；专辑/艺人/设置/AI 详情可以 pop；compact 详情底 Tab 隐藏。
- `router_path_parameters_test.dart`：中英文、`&/+/%` 的专辑/艺人双向编码，参数恰解一次。

## 6. 设计系统 §6 的 Ty* 映射与关键 API

> 这节给调用形状与数据来源；已存在 Ty 类按现有**真实签名**使用。组件共文件按修订 `DESIGN.md:24-40` 的职责分组处理，不人为拆原语。

### 6.1 结构与容器

- `TyAppShell` → `app/lib/design/layout/app_shell.dart`：`TyAppShell({required Widget child,required String matchedLocation})`，ShellRoute 唯一外壳。
- `TySidebar` → `app/lib/design/components/sidebar.dart`：`TySidebar({required String path,required ValueChanged<String> onNavigate,bool collapsed=false})`；旧 `features/shell/app_shell.dart:68-147` 的歌单/来源组逻辑迁移。
- `TyNavRail` → `app/lib/design/components/nav_rail.dart`：`TyNavRail({required String path,required ValueChanged<String> onNavigate})`，宽 88。
- `TyBottomNav` → `app/lib/design/components/bottom_nav.dart`：`TyBottomNav({required String path,required ValueChanged<String> onNavigate})`，高 64+SafeArea。
- `TyPageHeader` → `app/lib/design/components/page_header.dart`：`TyPageHeader({required String title,String? subtitle,Widget? actions,bool sliver=false})`。
- `TySectionHeader` → `app/lib/design/components/section_header.dart`：`TySectionHeader({required String title,int? count,Widget? action})`。
- `TyDetailHero` → `app/lib/design/components/detail_hero.dart`：`TyDetailHero({required Widget cover,required String title,required List<String> metadata,required List<Widget> actions})`。
- `TyPanel` → `app/lib/design/components/panel.dart`：`TyPanel({required String title,required Widget child,VoidCallback? onClose})`，检查器标题只渲一次。
- `TyInsetGroup` → `app/lib/design/components/inset_group.dart`：`TyInsetGroup({required String title,required List<Widget> children})`；旧 AI/设置 `_Section` 合并。
- `TyLayoutScope` → 已有 `app/lib/design/layout/form_factor.dart`：`TyLayoutScope(width:,formFactor:,metrics:,traits:,child:)`；遵守其实际定义。
- `FormFactor` → 同文件已有 `ofWidth(double)`，阈值 640/1024；provider 桥按 §4.3。
- `PlatformTraits` → 同文件现有 `forPlatform(TargetPlatform)` 等实际入口，专管输入/权限语汇。

### 6.2 列表、网格、队列

- `TyTrackTable` → `app/lib/design/components/track_table.dart`：`TyTrackTable({required List<Track> tracks,required ValueChanged<int> onPlay,required ValueChanged<Set<int>> onSelect,required LibrarySort sort})`。
- TyTrackTable `ListView.builder(itemExtent:context.metrics.tableRowHeight)`，独立列头 `TySectionHeader`；列宽按 §6.2，当前排序箭头可见。
- `TyTrackList` → `app/lib/design/components/track_list.dart`：`TyTrackList({required List<Track> tracks,required ValueChanged<int> onPlay,Future<void> Function()? onRefresh})`。
- TyTrackList compact 固定 itemExtent=56 且密度忽略 compact；混合分组头单独 sliver，不让变高项进入固定高同一个 builder。
- `TyTrackRow` → `app/lib/design/components/track_row.dart`：`TyTrackRow({required Track track,required VoidCallback onPlay,required bool selected,int? index,VoidCallback? onSelect})`。
- 旧 `features/shared/track_row.dart:17-43,149-200` 的收藏 `setFavorite`、加入歌单、重新匹配逻辑迁真实 action；移除所有“从库中移除”的非持久假动作。
- 旧 `_TrackRowWithPlayback/_AlbumTrackRow/_ArtistTrackRow` 分别见 `library_page.dart:255-285`、`album_detail_page.dart:195-226`、`artist_detail_page.dart:282-313`；各宿主产生可见队列快照再调用共享行。
- TyTrackRow 桌面单击选中/双击播、hover 播键直接播；compact 单击播、长按与桌面右键同菜单顺序。
- `TyAlbumCard` → `app/lib/design/components/album_card.dart`：`TyAlbumCard({required AlbumSummary album,required VoidCallback onOpen,VoidCallback? onPlay})`。
- `TyArtistRow` → `app/lib/design/components/artist_row.dart`：`TyArtistRow({required ArtistSummary artist,required int albumCount,required VoidCallback onOpen})`。
- `TyPlaylistCard` → `app/lib/design/components/playlist_card.dart`：`TyPlaylistCard({required Playlist playlist,required int trackCount,required List<Track> covers,required VoidCallback onOpen})`。
- `TyQueueView` → `app/lib/design/components/queue_view.dart`：`TyQueueView({required List<Track> sourceQueue,required int currentIndex,required ValueChanged<int> onPlayAt})`。
- TyQueueView 分“正在播放/接下来”，每行 48、收藏态真实订阅；用户点某位置 `PlaybackController.playAt(index)`，支持重复 id。
- TyQueueView 内容 `sourceQueue` 来源 `PlaybackController.sourceQueue`，不只取预取 `_queue`；旧 `queue_panel.dart:97-132` 一次全库 map 的实现可迁移。
- TyQueueView 提供“添加到队列”外部入口或从行上下文菜单调用 `enqueueTracks`；无其它队列写操作。

### 6.3 播放器

- `TyTransportBar` → `app/lib/design/components/transport_bar.dart`：`TyTransportBar({required VoidCallback onStage,required VoidCallback onLyrics,required VoidCallback onQueue})`。
- TyTransportBar 复用旧 `player_bar.dart:26-29,133-205` 的 identity/playing/position 独立订阅，队列空整条收起。
- `TyMiniPlayer` → `app/lib/design/components/mini_player.dart`：`TyMiniPlayer({required VoidCallback onStage})`，40 封面 + 常驻收藏 + 播放/下一。
- TyMiniPlayer 沿旧 `mini_player.dart:26-31,103-119` 只订阅必要快照字段，进度 tick 不连带封面重建。
- `TyPlayerStage` → `app/lib/design/components/player_stage.dart`：`TyPlayerStage({String? initialTab})`，舞台内容两栏与全屏无外壳。
- TyPlayerStage 主控 56 来自 TyMetrics，薄背景、无流体多圆渐变；关闭回进入前的真实路径。
- `TySeekBar` → `app/lib/design/components/seek_bar.dart`：`TySeekBar({required Duration position,required Duration duration,required Duration buffered,required ValueChanged<Duration> onSeek})`。
- TySeekBar 保留旧 `features/player/seek_bar.dart:46-98` 本地拖动预览 + 最终 seek 一次；键盘 5s/30s 步进。
- `TyVolumeControl` → `app/lib/design/components/volume_control.dart`：`TyVolumeControl({required double volume,required ValueChanged<double> onChange})`，静音 0 与上一次非零值。
- 音频后端名只读展示在 `app/lib/features/settings/settings_page.dart` 的诊断行，来源是既有 `PlaybackEngine.name`；VolumeControl 不含 output 枚举或切换。
- `TyLyricsView` → `app/lib/design/components/lyrics_view.dart`：`TyLyricsView({required LrcDocument document,required Duration position,required ValueChanged<Duration> onSeek})`。
- TyLyricsView 使用旧 `features/player/lrc_parser.dart`、当前行高亮、逐行点击 seek、手滚 3s 不回拉；纯文本不作无时间戳 seek。
- `TyCover/TyAvatar` → 现有 `app/lib/design/components/cover.dart:48-75,179-210`，按现有 path/url/seed/size 参数调用。
- 本地 `TyCover` 的 `coverFileProvider`+按 size×DPR decodeWidth，网络图缓存尺寸，见 `cover.dart:39-117`；取色另有 §8 本地小图路径。

### 6.4 输入、按钮、反馈

- `TySearchField` → `app/lib/design/components/search_field.dart`：`TySearchField({required TextEditingController controller,required ValueChanged<String> onChanged,VoidCallback? onClear,FocusNode? focusNode})`。
- `TyCommandPalette` → `app/lib/design/components/command_palette.dart`：`TyCommandPalette({required String query,required List<SearchHit> results,required ValueChanged<SearchHit> onSubmit})`；对 5 类结果按键盘导航。
- `TyButton` → **现有** `app/lib/design/components/buttons.dart:27-42`，沿用 `label/onPressed/icon/variant/dense/expand/tooltip` 构造函数。
- B2 在已有 `TyButtonVariant` 增 `pillPlay` 并实现强调胶囊，继续 `TyInteractive` 的 hover/press/focus，绝不新增 button.dart 同类。
- `TyIconAction` → **现有** `app/lib/design/components/buttons.dart:151-177`，`icon` 与 `semanticLabel` 必传，`tooltip` 可选但 UI 图标动作必须提供。
- `TyChip/TyFilterChip` → `app/lib/design/components/chip.dart`：`TyChip({required String label,bool selected=false,VoidCallback? onTap})`，FilterChip 给 `ValueChanged<bool> onSelected`。
- `TySegmentedControl<T>` → `app/lib/design/components/segmented_control.dart`：`TySegmentedControl({required List<T> values,required T selected,required String Function(T) label,required ValueChanged<T> onSelected})`。
- `TySortMenu` → `app/lib/design/components/sort_menu.dart`：`TySortMenu({required LibrarySort selected,required ValueChanged<LibrarySort> onSelected})`；`?sort` 和勾选一致。
- `TyContextMenu` → `app/lib/design/components/context_menu.dart`：`TyContextMenu.show(context,{required List<TyMenuAction> actions,Offset? position})`。
- TyContextMenu 共享动作文本与回调；桌面右键浮层，触摸长按底 sheet，歌单额外“移出歌单”调用 PlaylistRepository，当前曲目菜单可末尾入队。
- `TyDialog` → `app/lib/design/components/dialog.dart`：`TyDialog.confirm(context,{required String title,required String detail,bool destructive=false})`，来源删除/清洗前弹确认。
- `TySheet` → `app/lib/design/components/sheet.dart`：`TySheet.show(context,{required Widget child})`，最大高度 90%，下拉关闭。
- `TySnack` → `app/lib/design/components/feedback.dart`：`TySnack.show(context,{required String message,String? actionLabel,VoidCallback? onAction})`，仅短反馈。
- `TyTooltip` → 同 `feedback.dart`：`TyTooltip({required String message,required Widget child})`，400ms 延迟。
- `TyBadge` → 同 `feedback.dart`：`TyBadge({required String text})`，只显示真实已算计数。
- `TyProgressBar` → `app/lib/design/components/progress_bar.dart`：`TyProgressBar({required int done,int? total,String? semanticsLabel})`，total 未知为 indeterminate。
- `TySourceCard` → `app/lib/design/components/source_card.dart`：`TySourceCard({required MusicSource source,required SourceSyncState sync,required VoidCallback onPrimary,required VoidCallback onOpen})`。
- `TySettingsRow` → `app/lib/design/components/settings_row.dart`：`TySettingsRow({required String label,String? detail,required Widget control,required TySettingsRowKind kind})`。

### 6.5 四态与辅助组件

- `TyAsyncView<T>` → `app/lib/design/components/async_view.dart`：`TyAsyncView({required AsyncValue<T> value,required bool Function(T) isEmpty,required Widget Function(T) data,required VoidCallback onRetry,required TySkeletonKind skeleton})`。
- `TySkeleton` → `app/lib/design/components/skeleton.dart`：`TySkeleton({required TySkeletonKind kind,int? count})`，行默认 12、网格 3 排、详情封面/字块。
- `TyEmptyState` → `app/lib/design/components/empty_state.dart`：`TyEmptyState({required IconData icon,required String title,required String description,Widget? action})`。
- `TyErrorView` → `app/lib/design/components/error_view.dart`：`TyErrorView({required String title,required String detail,required VoidCallback onRetry,bool inline=false})`。
- `TyInteractive` → 现有 `app/lib/design/components/interactive.dart:58-105`，所有自绘点击组件委托它处理 hover/press/focus/次要点击/长按。
- `TyFocusRing` → 现有 `interactive.dart:211-241`，2px 环预留外侧空间避免焦点跳布局。
- `TyAvatar` 是 TyCover 相关头像变体，只消费上游 `artistAvatarProvider(name)` 的图片字节，不自己构造异步网络请求。
- B7 守卫枚举所有这些 Ty* 声明在产品路径中的引用，未被真实页面使用的组件不能算满足 §6。

## 7. 内容页、四类查询与实际搜索语义

### 7.1 搜索新增只读接口（B4）

- 文件 `app/lib/data/models/search_page_result.dart`：`SearchPageResult<T>({required List<T> items,required int total})`，构造为不可变列表。
- `TrackRepository.searchTracksPage(String query,{required int offset,int limit=40}) → Future<SearchPageResult<Track>>`，title/artist/album LIKE，稳定排序 `title,artist,album,id`。
- `TrackRepository.searchAlbumsPage(String query,{required int offset,int limit=40}) → Future<SearchPageResult<AlbumSummary>>`，按 `(artist,album)` 聚合，再按 `album,artist` 排序分页。
- `TrackRepository.searchArtistsPage(String query,{required int offset,int limit=40}) → Future<SearchPageResult<ArtistSummary>>`，按 `artist` 聚合，再按 name 排序。
- `PlaylistRepository.searchPlaylistsPage(String query,{required int offset,int limit=40}) → Future<SearchPageResult<Playlist>>`，name LIKE，稳定排序 `name,id`。
- `TrackRepository.recentlyAddedPage({required int offset,int limit=40}) → Future<SearchPageResult<Track>>`，按 `dateAdded DESC,id` 排序，替代旧 provider 100 首上限，保留旧 `watchRecentlyAdded`。
- 四类搜索中的 `total` 必须由数据库真实 COUNT；专辑用组合键 GROUP BY 的子查询 COUNT，不能只算 album 名重复合并。
- 搜索查询把 `%`,`_`,`\` 作为字面量转义，使用 SQL LIKE ESCAPE，应用输入 trim/lower 与现 `watchSearch` 的原始子串规则一致。
- 数据层只读查询不写任何 row，不更改旧 `watchSearch/search` 方法，也不改变 repository 现有写操作的用户数据语义。
- B4 测试直接在内存 DB 写 251+ 首、同名专辑跨艺人、中文歌单及空字符串，断言分页无漏/无重、total 等于真实命中数量。
- `sourcesProvider` 只过滤来源名称，全部结果中至多 5 条；来源未加载时来源组单独 loading/error，不让曲目结果假装为整页错误。
- 命令面板与 `/search` 结果都遵循歌曲→专辑→艺术家→歌单→来源，四 scope chips 不含来源。
- “查看全部 N 条”仅当该组真实 COUNT 已返回 N 才显示 N；查询尚未得到计数时只写“查看更多”，不编造数字。
- 250ms 防抖唯一入口仍是 `SearchQueryController.set`，见 `app/lib/app/providers.dart:105-115` 现 220ms；清空立即同步即时/防抖值。
- 最近搜索内存最多 10 条，切根页保留本次会话、重启为空；偏好 JSON 仍只有三项。
- 命中子串从原文对应位置着浅强调底，大小写不敏感但不改用户原文字形；中文可找中文。

### 7.2 曲库列表与起播快照（B4）

- `allTracksProvider` 已是全库流（`providers.dart:73-78`），LibraryViewState 只整理快照，不在 build 中每行重新调用仓储。
- 排序固定：标题/艺术家/专辑/添加时间/时长；同值按 id 保证稳定，手动选项写 `?sort=`。
- 筛选 chips：全部/最近添加/收藏；会话级 provider 保持它们跨 route 的值，B4 端到端断言。
- `?sort=added` 的 `/recent` 迁移采用新增按添加时间完整分页，原 `recentlyAddedProvider` 100 条仍给其他旧消费用。
- desktop TyTrackTable 单击选择、双击起播；多选 Ctrl/⌘、Shift；悬停播放图标一次起播。
- compact TyTrackList 单击起播，右侧收藏与更多，侧滑入队是末尾追加、不能执行队列插入。
- 每行 `onPlay(i)` 在点击时封闭“当时可见集合 + 排序”快照后 `playTracks(visible,startIndex:i)`，不能用 id 反查全库另建队列。
- 桌面浮动批量栏：播放、末尾加入队列、加入歌单、收藏；多选保留用户的顺序，不对 id 去重。
- 右键/长按菜单同序：播放、添加到队列(末尾)、添加到歌单、收藏、在专辑中查看、在艺人中查看、重新匹配元数据。
- 歌单页专属“移出歌单”仍调用 `PlaylistRepository.removeAt(playlistId, index)` 对歌单成员关系生效，非删除曲库 Track。
- 列表行 `itemExtent` 和 SliverHeader 各自单独布局，滚动 200+ 首不得因每个子项不同高度做多次测量。
- 四态数据加载：loading→TySkeleton、error→TyErrorView+retry、empty→TyEmptyState+引导/同步、data→真实列表。

### 7.3 专辑、艺人、歌单（B4）

- `albumsProvider` 与 `artistsProvider` 现有分组，见 `app/lib/app/providers.dart:84-93`，继续沿用，不给聚合模型添加数据库 id。
- `AlbumSummary.artist/album` 是查询键，`AlbumDetailPage` 根据 path 专辑名与 query artist 构造原 `AlbumKey`。
- `artistAvatarProvider` 已缓存头像，见 `app/lib/features/artists/artists_page.dart:18-35`；TyAvatar 取它的 bytes 或首字。
- 详情保持现有 `albumTracksProvider`/`artistTracksProvider` 对排序与曲序的业务定义，不统一成错误的全库排序。
- 艺术家页显示专辑分组及全部曲目默认 10 项、“全部展开”；不把 10 首当全部曲目起播。
- 歌单列表首格“新建歌单”，实际调用 `PlaylistRepository.create`，重命名、重排、删除原能力继续。
- `playlistTracksProvider` 依 `playlist_items.position` 保序，见 `playlist_repository.dart:69-95`；起播队列须保留重复曲目条目。
- `playlist_state_test.dart` 的 loading≠不存在/error 重试继续；查不到 id 只在 data 返回后认定不存在。
- 收藏专辑当前无专辑 favorite 字段，收藏分段只按专辑内**已有收藏曲目**聚合，文案说明该口径。
- `CoverArt` 的本地路径、网络 URL、确定性占位迁 TyCover；用户手动封面更新后从 coverFileProvider 正常刷新。

### 7.4 首用、来源与设置（B5）

- `sourcesProvider` 和 `allTracksProvider` 同时 data([]) 才算首次引导，不能单独凭曲目数 0 判定。
- 来源已有但歌 0 进入来源恢复页：展示来源状态、重新授权/同步动作，避免误导用户重加来源。
- `source_sync.dart:42-76` 当前同来源重复调用有门闩，新增 cancel token 按 sourceId 维持此门闩。
- `source_adapter.dart:43-47` 已有 `scan(isCancelled:)`，B5 向下传 token；cancelled 不使 `removeMissing` 成 true。
- `scan.isAuthoritative` 仅在 !cancelled、!truncated、skipped==0 为 true，见 `source_adapter.dart:22-31`；B5 结果文案忠实体现。
- `MergeResult.added/updated/removed` 与 scan 的 skipped/cancelled/truncated/reason 分开呈现；不知道 total 时不显示百分比。
- sourceId 任务旧 generation 在取消+重试后不可覆盖新状态；同源并发仍受门闩，不为快速重试强行并行。
- 夸克登录、WebDAV 测试连接、本地权限/SAF 由旧 `sources_page.dart:144-349` 原入口迁移，不由 form factor 推断 OS 授权。
- WebDAV URL/用户名/密码每项有独立 errorText，测试连接失败解释 HTTP/凭据原因，而不造文件级失败记录。
- `SettingsPage` 三项外观设置同 JSON，AI 设置保持 `aiSettingsProvider` 原 secure store 与测试连接/清洗取消能力。
- `settings_page.dart:61-80` 的高成本同步/清洗入口加确认，来源删除沿现有 `sources_page.dart:463-520` 凭据释放顺序。

## 8. 播放器追加、URI、取色的实现不变量（B6）

### 8.1 `PlaybackController.enqueueTracks` 的唯一实现口径

1. 路径：`app/lib/app/playback_controller.dart`；签名**只有** `Future<void> enqueueTracks(List<Track> tracks)`。
2. 输入空列表立即完成，不改变队列/播放/重复模式，避免无意义版本更新。
3. 捕获操作开始时 `_queueGeneration`，如果当前引擎队列正在装载，则等待装载完成再进行，不能把追加发给旧引擎会话。
4. 先等待现有 `_prefetchFuture` 完成；因为 `_resolveNext` 已提前推进 `_nextSourceIndex`，不能只凭 `>=length` 判断预取已结束，见 `playback_controller.dart:408-429`。
5. await 后再次对照 generation 与 `_queueArmed`；切歌或 playTracks 造成的旧会话结果不能写回当前队列。
6. 将输入列表逐位追加到 `_sourceQueue`，并按其传入顺序追加 `_originalSourceQueue`，每个 occurrence 都保留，不按 `track.id` 建 Set。
7. `_sourceQueue` 含未解析歌曲；`_queue/_trackIds/_resolvedSourceIndices` 只对应成功解析并已发送 `handler.addToQueue` 的项，三者长度相等且索引映射回 sourceQueue；`playback_controller.dart:430-458` 原实现可复用。
8. 对未解析尾项用现有 `_ensureAhead(minimumAhead:1)`，按需将第一条追加成功的媒体逐项 append；不能“为凑四份数组等长”将 unresolved Track 塞入 `_queue`。
9. 如果添加之前 `_passFinished=true`，追加后 `_nextSourceIndex` 原数值自然指向新首项，`_passFinished` getter 返回 false；下一首必须能解析新尾项。
10. 如果正处于 repeat-all 的 `_replayResolvedQueue`，先让现有 generation/arm 闸落稳再添加，不能打断当前流再 setQueue 二次。
11. 如果 shuffle 开启，已经解析/播放的前缀次序不动；新列表追加到尚未解析尾部，切回顺序时 `_originalSourceQueue` 恢复原来+新尾项的**重数**。
12. 如果 repeat-one，新增尾项仍进入来源快照；在用户切回 repeat-all/手动 next 时下一个真实条目可达，不自动更改 repeat 状态。
13. 每个 `handler.addToQueue` 成功后才原子更新 `_queue/_trackIds/_resolvedSourceIndices`；失败时该条目不出现在 UI“已解析队列”，来源队列仍有其原输入并展示可解释失败。
14. UI 读 `sourceQueue` 展示全部； `queueDisplayIndex` 对应 `_resolvedSourceIndices[currentSnapshot.index]`，点重名曲的第二处 `playAt(position)` 准确。
15. `AudioService` 与 SMTC 由 handler 的 `addToQueue` 通告，不手工直接改系统媒体状态。
16. 播放中追加不调用 `handler.setQueue`、不调用 `playTracks`、不走 UI 临时 queue copy 和隐式 pause/seek。
17. `playback_queue_append_test.dart` 用 FakeAudioEngine 挂住预取 Future，断言 pending 落地前还未混入新会话，结束后四个队列/映射一致。
18. 同测试覆盖正在播放且正在 seek 时追加，断言 position/playing 当前 id 不变、`setQueueCalls` 不增加、`addToQueueCalls` 随实际解析增长。
19. 同测试覆盖随机与 repeat-all、repeat-one 后“下一首”到追加项，旧队列 wrap 回归继续。
20. 同测试覆盖重复 track id 两处与播放中切歌/重进舞台交错，不允许以 id 判 index 或把旧异步结果发给新会话。

### 8.2 TrackResolver/handler 生命周期

- `app/lib/app/track_resolver.dart:53-84` 按本地 Windows 盘符、https 与 Quark 的不同 URI 初始化；不改解析器，继续跑 `track_resolver_initial_uri_test.dart`。
- `app/lib/main.dart:98-129` 唯一 `AudioService.init` 与生命周期 dispose；切主题、route 和 stage 不重新初始化 handler。
- `app/lib/playback/tingyu_audio_handler.dart:69-114` 的 `setQueue/addToQueue` 发布系统媒体；追加通过现有 handler API，不直接写 `AudioService.queue`。
- `PlaybackSnapshot` 的 position/buffered/rate 原有按值相等逻辑保持，见 `docs/UI_UX_AUDIT.md:58-72`；播放器 UI 仅选择必要字段订阅。
- 当前已存在倍速数据与 handler 行为，但产品这批没有倍速交互菜单；快照 rate 可用于诊断，不能变成新 setter。
- 现有播放器失败的全局 SnackBar 留存；B6 `TyTransportBar` 增可持续的内联 TyErrorView 与恢复按钮。
- 三形态收藏使用已有 `TrackRepository.setFavorite(track.id,value)`，非曲库音频 id 未解析时禁用并说明原因。
- stage 宿主里的歌词/队列重用 `TyLyricsView/TyQueueView`，desktop 检查器与 compact 独立页不复制状态算法。
- `TySeekBar` 完成拖动后仅一次 `seek()`，不要让每帧 `onChanged` 发送 handler.seek。
- `ui_rebuild_seek_test.dart:148-382` 现有 tick 时列表/封面/队列行 0 重建指标按新 Ty 类型改断言，绝不降低次数阈值。

### 8.3 舞台取色的真实解码路径

- 输入只来自本地 `coverFileProvider(path)` 成功解析出的**文件绝对路径**，见 `app/lib/app/providers.dart:45-52` 与 `DESIGN.md:143-154`。
- `Image.file(cacheWidth:)` 只控制屏幕图像解码缓存，不提供 RGBA 像素，见 `app/lib/design/components/cover.dart:39-117`。
- `stage_background.dart` 按 Flutter 解码 API：`ImmutableBuffer.fromFilePath(path)` → `ImageDescriptor.encoded(buffer)` → `descriptor.instantiateCodec(targetWidth:24)` → `getNextFrame()` → `image.toByteData(format:ImageByteFormat.rawRgba)`。
- 每个 buffer/descriptor/codec/image 生命周期按 Flutter 对应 dispose 释放；只把 24×24 RGBA 像素送 `compute` 做 12 桶 HSL 统计。
- cache key=绝对路径+stat.mtime+目标尺寸(24)，LRU 64；同图片重复进入舞台只读缓存，不重解原图。
- 亮度/饱和度阈值、12 桶与 7:1 对比度收敛算法用 `DESIGN.md §2.5` 的明确值，不另造 UI 颜色常量。
- URL 封面尚未落本地文件时立即中性渐变，不专为舞台取色发 HTTP；取色失败也是中性色。
- 每次切曲保存 trackId，异步完成时若当前 trackId 已变，丢弃旧结果；单纯切换 theme 可以复用 RGBA 主次色再按 theme 钳制。
- `coverTint=false` 明确中性渐变；`disableAnimations=true` 保留已取出的静态两色，仅停止漂移与 crossfade，见 `DESIGN.md:151-154`。
- 仅一个 160° 主次色线性渐变加 canvas 压平，不保留旧 `fluid_background.dart:104-167` 多层全屏渐变与 `willChange:true`。
- 测试构造本地彩色图/灰图、远端未落盘、文件 mtime 改变、快速 A→B 切歌、reduce motion，断言静态颜色不误覆。

## 9. 新增测试及 B1 测试脚手架迁接

- `app/test/support/fixtures.dart` 使用原 `app/test/support/test_support.dart:1-87` 的临时 SQLite/静音媒体，不复制另一套 DB helper。
- `app/test/design_tokens_test.dart` 已在 B1 确认颜色/间距数据，用现有字段 `context.ty.typography`，不按误写的 `ty.type` 重构。
- `app/test/design_system_render_test.dart` 已覆盖浅/深、compact/medium/expanded、density（`:18-68`），B3 补 360×480 与触摸宽窗。
- `app/test/settings_store_test.dart` 用临时目录覆盖 read/write/重启/坏 JSON 重置/原子写中断，不碰用户安装目录。
- `app/test/async_state_test.dart` 验证 TyAsyncView loading/error/empty/data 与重试一次，错误信息不可吞成空态。
- `app/test/form_factor_test.dart` 边界 359/360、479/480、639/640、1023/1024 和 Windows 412 宽命中区。
- `app/test/search_page_test.dart` 实库 251+ 首分页 COUNT、中文及转义、四范围、来源小组、每组 5 首与“查看全部”。
- `app/test/track_interaction_test.dart` 桌面 click/select、double-click/play、hover/play、Ctrl/Shift、compact longPress 与批量末尾追加。
- `app/test/source_state_test.dart` skipped/cancelled/truncated 三种非权威保持旧歌、来源异常重试、没有逐文件假明细。
- `app/test/onboarding_test.dart` sources/tracks 两 provider 同时 data([]) 才进入；有来源 0 曲走来源恢复；授权取消无假数据。
- `app/test/playback_queue_append_test.dart` 假引擎挂预取与播放交错，计数确认没有 setQueue 重建及四处映射正确。
- `app/test/player_transport_test.dart` mini/transport/stage 收藏、buffered 进度、空队列折叠、错误态、后台歌曲身份。
- `app/test/lyrics_view_test.dart` LRC 点击 seek、纯文本不可 seek、手滚 3s 前后不同自动滚动。
- `app/test/stage_background_test.dart` 本地/远端/灰图/快速切歌/减少动态对颜色结果的影响。
- `app/test/ui_snapshot_test.dart` 多尺寸两主题与状态注入并输出 `app/build/ui-snapshots` PNG，断言无 overflow。
- `app/test/{library,stage}_golden_test.dart` 使用 `@Tags(['golden'])`；`app/dart_test.yaml:1-5` 默认 skip，本地 `--run-skipped -t golden`。
- 守卫 fixture 中一个正例必须放 feature 权限 `Platform.isAndroid` 且有逐表达式 `// guard-ok: ...`；反例 feature 按平台返回不同 Layout。
- 新增测试只针对真实新增边界，既有 48 项不能因数量增加而删弱原断言。

## 10. 原有 48 个测试逐个处置对照

| `app/test/` 下原文件 | 分类/处置 | 执行者须保留或改写的断言 |
|---|---|---|
| `ai_client_test.dart` | 服务/保留 | 鉴权、错误响应与重试边界。 |
| `ai_library_refactor_service_test.dart` | 服务/保留 | 分批清洗、中断与不越权覆盖。 |
| `ai_metadata_parser_test.dart` | 来源/保留 | JSON 解析与噪声剥离原行为。 |
| `ai_settings_page_test.dart` | UI/改写 B5 | 原中文文案、开关前后字段、测试连接/清洗路径与 `/ai` 导航。 |
| `ai_settings_repository_test.dart` | 数据/保留 | 安全存储与兼容旧 key。 |
| `chinese_converter_test.dart` | 来源/保留 | 繁简映射原边界。 |
| `database_migration_test.dart` | 数据/保留 | 旧 schema 迁移，不因 UI 加偏好改库。 |
| `enrichment_service_test.dart` | 服务/保留 | 上游失败仍保留已补字段。 |
| `http_retry_test.dart` | 来源/保留 | 指数退避/错误界限。 |
| `legacy_import_test.dart` | 数据/保留 | 幂等、曲目与歌单顺序不失。 |
| `library_mobile_search_test.dart` | UI/改写 B4 | 412 宽搜索焦点/清空，250ms 后查询，键入空格不播暂停。 |
| `local_bookmark_source_adapter_test.dart` | 来源/保留 | 本地书签恢复与失效提示。 |
| `local_library_scanner_test.dart` | 来源/保留 | 扩展名、取消、截断扫描。 |
| `local_rescan_gate_test.dart` | 数据/保留 | 重扫无关字段不覆盖用户更改。 |
| `metadata_enricher_test.dart` | 来源/保留 | 多来源封面/歌词回退。 |
| `metadata_search_query_test.dart` | 混合/改写 B4/B5 | 业务拼接不动；手工匹配弹层打开时不自动出网。 |
| `navigation_gesture_test.dart` | UI/改写 B3/B4/B5/B6 | 四根 go 不压栈、详情 push 可 pop、根舞台 Esc 与深链 fallback。 |
| `netease_avatar_test.dart` | 来源/保留 | 头像 URL fallback。 |
| `now_playing_layout_test.dart` | UI/改写 B6 | 412×915 舞台完整可视、844×390 可滚动、不溢出及 56 主控命中。 |
| `playback_controller_modes_test.dart` | 播放/保留 | 随机/重复/同 id 重数旧行为。 |
| `playback_controller_resolve_failure_test.dart` | 播放/保留 | 解析失败不被 tick 擦除。 |
| `playback_duration_persist_test.dart` | 数据/保留 | 时长可信时只写回一次。 |
| `playback_error_formatter_test.dart` | 播放/保留 | 中文错误分类。 |
| `playback_failure_listener_test.dart` | UI/改写 B2/B6 | MaterialApp.builder 挂载、`「标题」原因`、失败身份去重、新曲失败重弹。 |
| `playback_just_audio_engine_test.dart` | 引擎/保留 | just_audio 映射原行为。 |
| `playback_media_kit_processing_test.dart` | 引擎/保留 | processing State 映射。 |
| `playback_queue_wrap_test.dart` | 播放/保留 | 旋转、预取尾、循环后 next 原边界。 |
| `playback_snapshot_equality_test.dart` | 播放/保留 | 快照按值相等与位置 tick 独立。 |
| `playlist_position_test.dart` | 数据/保留 | 歌单顺序位置规范。 |
| `playlist_repository_test.dart` | 数据/保留 | 歌单添加、移出与重复曲目。 |
| `playlist_state_test.dart` | UI/改写 B4 | loading≠不存在、error 可重试、缺 id 时错误；不删状态分支。 |
| `quark_qr_login_test.dart` | 来源/保留 | 扫码和取消。 |
| `quark_test.dart` | 来源/保留 | 分页、鉴权、目录扫描。 |
| `quark_web_navigation_test.dart` | 来源/保留 | WebView 登录/导航约束。 |
| `router_path_parameters_test.dart` | 路由/改写 B4 | path 参数已解码、query 艺术家 `&/+/%` 往返、缺参错误态。 |
| `saf_source_adapter_test.dart` | 来源/保留 | SAF 权限与路径。 |
| `search_debounce_test.dart` | provider/改写 B4 | 220ms→250ms、末次输入、即时清空、自动补全和截断信息原覆盖。 |
| `smart_title_parser_test.dart` | 来源/保留 | 文件名词法原逻辑。 |
| `source_adapter_cache_test.dart` | 来源/保留 | 配置指纹更新与并发构建。 |
| `source_by_id_provider_test.dart` | provider/保留 | 来源详情状态实时订阅。 |
| `source_sync_test.dart` | 来源/保留且 B5 加断言 | 非权威不删旧曲、取消/重复同步。 |
| `theme_density_test.dart` | UI/改写 B2/B3 | 跟随偏好而非目标平台、触控≥44、medium≥40/expanded≥36。 |
| `tingyu_audio_handler_test.dart` | 播放/保留 | AudioService state、mediaItem、dispose 与现有节流。 |
| `track_repository_test.dart` | 数据/保留且 B4 加断言 | 原 search/merge 不动；新增只读 count/page 的真实数据库测试。 |
| `track_resolver_initial_uri_test.dart` | 播放/保留 | Windows 盘符、Quark/https 初始 URI。 |
| `transport_row_layout_test.dart` | UI/改写 B6 | 五键中心距差 <1dp、主键偏移±0.5dp、左右对称±0.5dp、主控≥48 命中、320 不溢出。 |
| `ui_rebuild_seek_test.dart` | UI/改写 B4/B6 | tick 行/封面/队列 0 重建；6 拖动帧 seek 0、松手 1；44×2→88 图片解码。 |
| `webdav_test.dart` | 来源/保留 | 连接、凭据、扫描错误。 |

- `DESIGN.md:409-419` 显式九个 UI 耦合文件必须都在上表改写，且无原测试文件删除。
- `playback_failure_listener_test.dart:58-111`、`playlist_state_test.dart:70-160`、`metadata_search_query_test.dart:45-68` 另有 widget 耦合，虽不在九个名单中，也按原覆盖迁。
- `router_path_parameters_test.dart:1-30` 原参数只解码一次断言保留，新增复合 album query 的特有情况。
- `search_debounce_test.dart:45-215` 原截断提示与补全会话不因新搜索仓储分页而删除。
- `ui_rebuild_seek_test.dart:148-382` 还包括行/封面解码与队列单次订阅；用新 Ty 类型替换监听对象而不是删断言。
- `playback_queue_wrap_test.dart` 和 `playback_controller_modes_test.dart` 是 enqueue 新测试之外的独立老回归，B6 两者都跑。

## 11. 机械守卫、Semantics 与单一验证网

### 11.1 守卫实现范围与每条规则

- 测试：`app/test/design_guard_test.dart`；扫描路径**仅** `app/lib/features/**` 与 `app/lib/design/components/**`，见 `DESIGN.md:10-26`。
- 规则 `Colors.`：允许 `Colors.transparent`；二维码白底等真实需要逐行 `// guard-ok: 扫码识别背景必须纯白`。
- 规则 `Color(0x` 与 `Color.fromARGB`：组件与 feature 均禁，唯一色值定义在 `lib/design/tokens/` 且该路径不在扫描域。
- 规则 `CircularProgressIndicator(`：feature/组件禁作页面加载；瞬时来源进度走 TyProgressBar。
- 规则 `EdgeInsets.all(`/`EdgeInsets.only(`/`EdgeInsets.symmetric(`/`EdgeInsets.fromLTRB(` 后跟数字字面量：结构值 0/1/2 与 double.infinity 例外。
- 规则 `SizedBox(height:`/`SizedBox(width:` 后跟数字字面量：结构值 0/1/2 例外，设计间距改 `context.metrics`。
- 规则 `BorderRadius.circular(` 后跟数字字面量：应 `ty.radii` 或 `metrics`，不在组件内散值。
- 规则 `TextStyle(` 与 `fontSize:`：表现层读 `context.ty.typography`，不能重新造字体属性。
- 规则 `Platform.is*` 仅禁止用于布局分叉；当前媒体权限/SAF/文件管理等代码按“路径+表达式”白名单且当行有具体理由。
- `// guard-ok: 理由` 只豁免其**同一行表达式**，不能豁免整个文件或注释掉警告但保留坏 UX。
- `test/fixtures/guard/valid.dart.txt` 与 `invalid.dart.txt` 每一正反例各命中/不命中一次，避免正则误伤 legit 业务。
- `app/lib/main.dart` 的平台启动逻辑与 `app/lib/app/source_adapters.dart` 的权限分支不在扫描域，不为通过 guard 而随意移除。
- `features/sources/quark_qr_login_page.dart` 真实扫码图纯白实物色按单行理由豁免，QR 继续可扫。
- 守卫测试报告列每一处豁免行及原因；代码 review 要确认它是权限/素材需求而非偷藏任意色。

### 11.2 无障碍与性能验证

- `TyIconAction` `semanticLabel` 必须非空，`tooltip` 也必须 UI 实例可见；`Semantics(button:true)` 包实际动作。
- TyTrackRow 合并“标题·艺人·时长·播放中”语义，收藏按钮语义与整行分离以便读屏独立激活。
- TySeekBar `Semantics(value:'1:23 / 4:05',onIncrease/onDecrease)` 与键盘左右 5s、Shift 左右 30s。
- 同步进度 `Semantics(liveRegion:true,value:'已扫描 N 首')`；没有 total 时不能读“已完成 0%”。
- `FocusTraversalGroup` 顺序导航→内容→传输条→检查器，模态层 Esc 关闭后焦点归原位置。
- reduce motion 不停静态取色，只令 `TyDuration` 的过渡时长视图上归零，并停止舞台漂移/音乐音柱。
- 首屏渲染 35 首 fixture 有长标题/缺封面；1440→412 resize 下 `takeException()==null`。
- 滚动 200+ 首列表 itemExtent 固定；拖 seek 6 帧时行与封面不随 tick 重建。
- Windows 可用 `tools/windows-accessibility-probe.ps1` 抽查 TyButton/Tab/Stage 语义树，标可实际获取的控件名。

## 12. 修订 `docs/UX_REDESIGN.md` §12 七条可执行验收

### 12.1 第 1 条：Windows 真运行，浅深两主题 × 三档尺寸

- Windows PowerShell 仓库根：`./tools/build-windows-engine.ps1 -Stage App`，期望退出 0，构建使用 repo 内补丁引擎；具体需要本地引擎见 `docs/UI_UX_AUDIT.md:24-43`。
- 进入 `app/` 后：`flutter "--local-engine-src-path=F:/project/tingyu/app/build/flutter-engine/checkout/engine/src" "--local-engine=host_release" "--local-engine-host=host_release" run -d windows --release`，期望真实窗口出现曲库、可打开设置及播放舞台。
- 等价验收核心是 `flutter run -d windows` 能在配好本地引擎的环境运行；本机该调用必须带上上述 local-engine 标志。
- 用 Windows 调整客户区到**逻辑** 1440×900 与 1280×720，浅色/深色各保存曲库与舞台截图；同一构建与有据可查的真实内容。
- 用 `flutter test test/ui_snapshot_test.dart --plain-name '412×915 移动形态截图'` 生成 412×915 浅深两图，期望四 Tab、mini 条与 SafeArea 均可见。
- 150% 系统 DPI 下物理 1440×900 仅逻辑 960×600，见 `docs/UI_UX_AUDIT.md:35-48`，登记实际 client size 与 DPI，不能拿物理像素冒充逻辑布局。
- Windows 运行：`./tools/windows-smoke-test.ps1 -AppDirectory app/build/windows/x64/runner/Release -OutputDirectory app/build/ui-smoke -Cycles 2`，预期 `result.json` 中进程未退出、原生语义错误数为 0。
- 目标截图输出 `app/build/ui-snapshots/{theme}_{width}x{height}_{page}.png`；截图文件和窗口参数同时保留便于人工比较。

### 12.2 第 2 条：§6 每组件实际引用、每异步页面四态

- 命令：`flutter test test/design_guard_test.dart test/async_state_test.dart test/form_factor_test.dart`，期望均退出 0。
- §6 组件按 §2/§6 每个路径可被至少一个功能页真实调用，未使用的空类不可通过 guard。
- `LibraryPage/SearchPage/AlbumsPage/ArtistsPage/PlaylistsPage/SourcesPage/SettingsPage/AISettingsPage` 注入 loading/error/empty/data，均见 skeleton、详情+重试、行动空态、真实内容。
- `PlaylistPage` 特别保留 loading 不显示“播放列表不存在”的旧断言。
- 播放失败现有全局 SnackBar 去重继续，B6 另有行内 TyErrorView，可同时验证两种目的。

### 12.3 第 3 条：`flutter analyze` 无 issue，所有测试全绿

- 在 `app/` 执行 `flutter analyze`，期望打印 `No issues found!` 且退出 0。
- 在 `app/` 执行 `flutter test --exclude-tags golden`，期望退出 0、普通测试全绿；`dart_test.yaml` 已默认 skip golden。
- Windows golden 显式 `flutter test --run-skipped -t golden`，期望两个 golden 文件与受控参考图一致。
- 如果验收表明要跑完整 `flutter test`，先运行 `flutter test`，期望退出 0（默认跳过 golden 仍包含所有普通测试）。
- 专项运行 `flutter test test/ui_rebuild_seek_test.dart`，期望 tick 0 行/0 封面/0 队列行、6 帧拖动 0 seek、松手 1 seek。
- 专项运行 `flutter test test/playback_queue_append_test.dart test/playback_queue_wrap_test.dart test/playback_controller_modes_test.dart`，期望新追加与旧队尾/模式均全绿。
- 每次改写旧测试都在 PR 清单记录原断言与新的同等强度断言，不以总通过项变多覆盖个别删除。

### 12.4 第 4 条：播放、队列、歌词、收藏、来源、元数据、AI

- 真机以本地一首、WebDAV 一首、夸克一首分别起播，确认音频流、显示标题、上一/下一、后台播放与系统媒体一致。
- 曲库按艺术家或时长排序及收藏过滤后在中间一首起播，确认完整队列遵循“当时可见集合 + 排序”。
- 菜单“添加到队列”选择单首/多首末尾追加，播放继续、seek 时间不倒退，下一首能到追加项。
- 在 shuffle/repeat 下重复执行追加且保留同一 id 两次，队列面板可分别点两行跳对应位置。
- LRC 有时间轴歌词点击跳转，纯文本无误 seek，手动滚动 3s 内不拉回；重新匹配后重新显示。
- 曲库行/mini/transport/stage/queue 收藏切换后刷新 Favorites；无 track id 的禁用态理由清楚。
- 歌单新建/重命名/按位置重排/移出歌单/删除，保持原持久化与确认。
- 来源取消、截断、跳过与认证错误分别演示，非权威旧歌曲不丢、来源级重试可点。
- AI 密钥/预设、测试连接、清洗与取消、手工匹配元数据，各原能力按既有测试输入跑通。
- 命令：`flutter test test/legacy_import_test.dart test/database_migration_test.dart test/track_resolver_initial_uri_test.dart test/source_sync_test.dart`，期望原数据/URI/同步断言全绿。

### 12.5 第 5 条：各平台习惯与设备事实边界

- Windows 1440 expanded：侧栏、hover 行动作、右键菜单、Ctrl+K、Ctrl+L/U、Esc、Ctrl+A 多选、滚动条、SMTC 当前媒体有截图或交互记录。
- Windows 768/900 medium：rail 88、bar 72、队列/歌词用抽屉/独立宿主；Tab 焦点环可见。
- 412×915 compact：四 Tab、mini 常驻收藏、44 命中、长按同菜单、stage 下拉收起、返回后在原列表；widget 测试可覆盖布局与交互。
- Windows 宽触屏如果可用按 PlatformTraits 实测≥44 命中；无触屏设备时硬件验收标 `[未验证]`。
- macOS 没有本地 Xcode/真机，CI macos-14 编译证明可编译，原生菜单快捷键冲突与锁屏媒体状态标 `[未验证]`。
- Android/iOS 无设备，Windows 宽度模拟不证明 SAF/bookmark/通知权限与真实系统媒体；真机原生项目明确标 `[未验证]`。
- Linux CI 构建只证明编译，桌面常显滚动条/MediaKit 实机交互无设备时标 `[未验证]`。

### 12.6 第 6 条：四态、长标题/缺封面/大量数据/网络失败

- 命令：`flutter test test/async_state_test.dart test/source_state_test.dart test/onboarding_test.dart test/ui_snapshot_test.dart`，期望全绿。
- 测试配置使用 35 首/6 专辑/3 艺人/2 歌单/3 来源基础 fixture 再增 251 首/超长歌单实例，保证分页及虚拟列表被真实触发。
- 无头尺寸 320/390/412/640/768/1024/1440/1920 逐一 `takeException()==null`；<360 使用可理解窗口提示，不要求硬挤内容。
- 浅深主题展示空库、大库、长中英混标题、缺封面、同步中、播放失败、登录失败。
- 来源有但零曲目必须展示恢复操作；无来源/无歌且数据完成才展示 onboarding；loading/error 不误导为无来源。
- 任何同步回执未知 total 时只说“已扫描 N 首”，不显示百分比或未算出的文件失败数量。

### 12.7 第 7 条：组合 token/组件能产生新页

- 命令：`flutter test test/design_guard_test.dart test/design_tokens_test.dart test/design_system_render_test.dart`，期望规则、主题、窗口数值全绿。
- `MyPage` 的关于分区组合 `TyPageHeader+TyInsetGroup+TySettingsRow+TyButton`，不重新声明页面颜色/字号/任意 margin 常量。
- `TyIconAction` 图标语义、`TySeekBar` 值语义、列表 focus/hover、减少动态均在测试中观察到。
- 关键文本与强调色对比度按 `DESIGN.md §2.2–2.3` 既有 tokens 测试，不以截图代替数值验收。
- 新页面只需组合已存在 Ty 组件、tokens 与一个 GoRoute，在视觉上与曲库/来源/设置一致。

## 13. 具体风险、不可逆点、规避与回归

- **队列快照语义**：`playTracks(tracks,startIndex)` 会从点击位置旋转来源队列，见 `playback_controller.dart:193-225`；按当时可见排序传副本，`playback_queue_wrap_test.dart` 锁定。
- **预取竞争**：预取先推进游标再 await resolve（`playback_controller.dart:408-429,465-480`）；`enqueueTracks` 先等待 `_prefetchFuture`，交错测试锁定不会插到旧会话。
- **索引与四集合**：来源列表与三份已解析并行数组映射是不同长度的两个层次（`playback_controller.dart:18-39,440-458`）；只成功解析后同步追加后三份，逐下标对照 FakeHandler queue。
- **队尾循环**：`_passFinished` 由 `_nextSourceIndex>=sourceQueue.length` 导出，见 `playback_controller.dart:121-123`；追加前后 next 按新增尾部流动而不直接重放，测试 repeat-all 与 repeat-one。
- **随机与重复**：`toggleShuffle` 已按重数还原，见 `playback_controller.dart:316-355`；追加也更新原序列表，重复 id 测试保证两份仍在。
- **切歌版本**：`_queueGeneration` 与 `_queueArmed` 保证重建期不污染旧引擎，见 `playback_controller.dart:31-40,375-400`；B6 两个 pending resolve 交错测试。
- **TrackResolver 初始 URI**：`track_resolver.dart:53-84` 区分 Windows 盘符/Quark/https，B6 不修改它，原 `track_resolver_initial_uri_test.dart` 必跑。
- **audio_service/SMTC 生命周期**：`main.dart:98-129` 唯一 handler 初始化/销毁；Ty 主题切换不触发重复 init，`tingyu_audio_handler_test`+Windows 真机观察。
- **系统媒体追加**：`TingyuAudioHandler.addToQueue` 已负责发布队列（`tingyu_audio_handler.dart:69-114`）；UI 不自己改 AudioService 状态，SMTC 与 UI 对照。
- **扫描取消**：`SourceAdapter.scan(isCancelled:)` 原接口已在 `source_adapter.dart:43-47`；B5 只加 UI 编排层 cancel token，`source_sync_test` 非权威不删曲。
- **同步并发**：`source_sync.dart:42-49` 同源重入门闩，补 generation 使旧 callback 不覆盖新同步；不同来源测试各自状态独立。
- **同步反馈**：`SourceScanResult` 无失败文件列表（`source_adapter.dart:4-32`），回执限定已有 fields/合并数；状态测试保证无虚假明细。
- **legacy 导入**：`app/lib/data/legacy_import.dart:34-39,113-189` 保留原 ids/顺序；偏好文件与数据库无交叉，`legacy_import_test` 原断言保留。
- **数据库迁移**：`app/lib/data/db/database.dart:17-57,88-117` 当前兼容旧 sources；本次不改 schemaVersion；数据库迁移测试及旧库复制实例作为回归。
- **真实删除不可逆**：`source_repository.dart:57-61` 来源删除关联删除曲目和歌单引用；真机手动同步/删除前备份 `library.sqlite` 与封面/安全存储。
- **JSON 偏好写入**：B2 save 会新增 settings.json，回退源码不恢复旧 JSON；原子写与坏文件保留测试，真实回退备份 JSON。
- **本地取色内存**：封面屏幕 cacheWidth 不等于取色 RGBA（`cover.dart:39-117`，`DESIGN.md:143-154`）；24×24 解码、资源 dispose、LRU64、灰图/快速切歌测试。
- **流体背景 GPU**：旧 `fluid_background.dart:104-167` 多渐变大面积过绘制；单渐变和减少动态测试，不扩大封面取色到远端 HTTP。
- **seek 行重建**：`ui_rebuild_seek_test.dart:148-382` 原进度 tick/行/封面断言严格保持，借 provider.select 与 RepaintBoundary 实现。
- **四态与老测试遗漏**：`playlist_state_test.dart:70-160`、`playback_failure_listener_test.dart:58-111` 原覆盖即使文档没列也迁，禁止以新的基础组件测试代替。
- **旧深链失效**：修订 `docs/UX_REDESIGN.md:111-128` 不保留旧 alias；用户保存的旧 URL 在切换后不达，属于产品明确接受的不可逆外部入口变更，发布说明提示。
- **专辑路径稳定性**：组合键以当前 artist/name 表示，改元数据后历史深链不再命中；代码不制造持久 id，只在错误页给列表回退。
- **Windows 本地引擎**：`docs/UI_UX_AUDIT.md:24-43` stock engine 会崩；widget test 绿不等于 release run 成功，B7 真机 smoke 必做。
- **macOS/Android/iOS 真机**：当前工作机缺设备见 `docs/UI_UX_AUDIT.md:35-51`；编译/无头快照与原生权限/媒体行为分别标记 `[未验证]`。

## 14. 明确不做与交付边界

- 按 `docs/UX_REDESIGN.md §10` 不做推荐、社交、评论、在线曲库、歌词投稿等联网内容扩张。
- 不引入外部动画库、UI 库、字体文件、窗口管理依赖；窗口只有软件提示下限 360×480。
- 不做播放队列“下一首播放/移除/重排/清空”，因为公开引擎只有完整重建与末尾追加；队列 UI 只读、点击跳转与末尾追加。
- 不做单曲“从曲库移除”；歌单成员“移出歌单”保持现有业务动作。
- 不做逐文件同步失败明细，不扩展 `SourceAdapter` 返回协议或伪造文件名。
- 不提供输出设备选择、倍速菜单；后端名称只读放设置诊断行。
- 不从未落地的远端 URL 为动态取色额外下载，不因用户减少动态而删除已经解析的静态封面色。
- 不改播放内核/音频 handler/TrackResolver 的公开契约，不修改 Drift schema、legacy 导入结构或旧仓储方法；仅 §1 三类窄范围新增。
- 不做主题任意编辑器、多窗口、迷你窗；偏好只有系统/浅/深、舒适/紧凑、取色开关。
- 不保留旧路径 alias、双外壳、旧组件副本，也不通过删测试或放宽性能阈值让新 UI 表面通过。
- 交付后执行者按 B1→B7 全量完成，每批 gate 满足后进入下一批；因无实际 macOS/Android 设备的真机结果如实标 `[未验证]`，不冒充完成。
