# P3 · 声档曲库页实施记录

2026-10-18。用户先选择方向 C「声档」，随后确认 P2 v0.1。本轮在分支 `codex/ui-p3-library` 从播放页提交 `8706cf1` 继续，只迁移音乐曲库首页 `/library/songs`；收藏、专辑、艺术家、歌单、来源管理及其余页面继续使用原视觉与业务实现。

## 实施范围

- 曲库首页与对应应用外壳通过局部 Theme 使用 `VoiceArchiveColors`，没有全局替换主题。
- 桌面曲库使用声档标题、侧栏品牌摘要、内联搜索、播放全部、排序、来源筛选和多选。
- compact 页面承担歌曲/专辑/艺术家/歌单四段导航，应用外壳不再重复绘制第二份分段控件。
- 桌面表格按 P2 的内容宽度顺序逐级收起专辑、艺术家、来源列；单列布局不再显示行号，保留封面、双行信息与时长。
- 手机工具区固定为两层：计数与播放全部；排序、来源与多选。200% 字号下合并为“筛选与排序”和独立多选入口。
- 手机副标题默认只显示艺术家；选择具体来源后补充来源上下文，避免把专辑、来源全部挤进省略号。
- “播放全部”使用现有 `libraryTracksPageProvider` 补齐筛选后的所有分页，再调用原 `PlaybackController.playTracks`。查询变化会取消旧准备任务，失败会保留原因并提供再次操作入口。
- 空库、读取失败、未知来源、筛选、排序、内联搜索和多选继续使用现有 provider、路由及数据接口。
- 没有修改数据库、播放引擎、来源协议、凭据存储或 Riverpod 架构，没有新增依赖或升级依赖。

## 组件扩展

`TyTrackList`、`TyTrackRow` 和 `PlaybackTrackRow` 新增的是表现层参数：

- 独立来源列与来源语义；
- 艺术家独立列与列间距；
- 固定保留多选列，避免 hover 时整行跳动；
- 可配置封面尺寸、标题行数和行高；
- compact 元信息组合。

默认参数保持原有行为，因此未迁移页面无需同步换版。`TySidebar` 新增可选品牌头和搜索开关，只有曲库首页启用。`TyAppShell` 的声档主题与品牌头也限定在 `/library/songs`。

主要落点：

- [library_page.dart](../../app/lib/features/library/library_page.dart)
- [track.dart](../../app/lib/design/components/track.dart)
- [playback_track_row.dart](../../app/lib/features/shared/playback_track_row.dart)
- [app_shell.dart](../../app/lib/design/layout/app_shell.dart)
- [navigation.dart](../../app/lib/design/components/navigation.dart)
- [voice_archive_preview.dart](../../app/tool/voice_archive_preview.dart)

## 可复现预览

固定预览仍使用 [voice_archive_preview.dart](../../app/tool/voice_archive_preview.dart)：4 首虚构曲目、3 个来源标签、固定封面和 2026-10-18 日期，不访问网络。

支持的入口：

```text
TINGYU_DEBUG_ROUTE=/library/songs
TINGYU_PREVIEW_STATE=normal|empty|error
TINGYU_DEBUG_THEME=light|dark
TINGYU_PREVIEW_SCALE=2
TINGYU_PREVIEW_COVER=<absolute-cover-path>
```

Windows 截图使用 [windows-ui-screenshots.ps1](../../tools/windows-ui-screenshots.ps1) 单独启动进程，避免窗口争抢。真实生产冒烟重新以 `lib/main.dart` 构建，没有用预览内存播放代替。

## 视觉审查与返工

| 位置 | 类型 / 严重性 | 检查发现 | 修复与结果 |
|---|---|---|---|
| 桌面长曲名末尾与艺术家列 | 层级 / 高 | 省略号与下一列视觉相接 | 独立列增加 12dp 内间距；最终桌面浅色、深色截图复核通过 |
| 手机副标题 | 信息密度 / 高 | “艺术家 · 专辑 · 来源”在 390dp 下把来源挤到省略号之后，也违反 P2 的默认信息层级 | 默认只显示艺术家；来源筛选后显示“艺术家 · 来源”，并新增专项测试 |
| 手机 200% 字号工具区 | 响应式 / 中 | 原布局把工具拆成三行并留下单独图标 | 放大文字时合并为“筛选与排序”菜单与多选入口；最终截图无溢出且关键入口保留 |
| medium 表格 | 响应式 / 中 | 全列会在实际内容宽度内拥挤 | 按 P2 依次收起专辑、艺术家和来源列；864/863、708/707、560/559、460/459 边界测试覆盖 |
| 空库 / 读取失败 | 状态 / 中 | 失败标题和不可用多选需要明确 | 显示“无法读取曲库”；空库与失败时禁用播放全部和多选，保留恢复入口 |

本轮只触发一次局部视觉返工。返工后没有发现需要继续自动修改的具体问题，也没有通过降低测试标准来消除差异。

## 门禁摘要

| 门禁 | 结果 |
|---|---|
| `flutter analyze` | 通过，无问题 |
| 曲库及重点回归 | 34/34 通过 |
| 全量非 Golden | 352 通过，1 失败；失败为 Windows 缺少 `chmod` 的既有环境问题 |
| Golden 只校验 | 9 通过，3 个预期待批准差异；未更新基准 |
| Preview Release 构建 | 通过 |
| Production Release 构建 | 通过 |
| Windows 真实播放冒烟 | 通过；10 次循环未退出，`media_kit (libmpv)` 持续播放 |

完整命令、退出码、截图尺寸、像素差异和限制见 [P3 曲库证据](p3-library-evidence/results.md)。

## 审批与后续

当前状态是“实现与工程验收完成，等待用户视觉验收”，不是“曲库 Golden 已批准”。本轮没有执行 `--update-goldens`。

用户确认最终曲库截图后，下一步应：

1. 单独批准并更新 `library-songs-compact-light` 与 `library-songs-expanded-dark` Golden，再跑完整 Golden 校验。
2. 以真实来源管理页开始 P3 下一组迁移，继续复用 `sourcesProvider`、同步状态、路由和凭据接口。
3. 为夸克/WebDAV 使用受控凭据执行远程播放冒烟，并补 Android/iOS/macOS/Linux 实机验证。
4. 执行人工读屏与键盘焦点走查；现有 UIA 查询和 Widget Semantics 不能替代完整无障碍验收。
