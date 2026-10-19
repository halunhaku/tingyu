# 听屿 P5 审查与返工记录

日期：2026-10-19

审查分支：`codex/ui-p5-review`
P5 起点提交：`b30e159`
已批准视觉方向：C「声档」
已批准 P4 基准提交：`520d73637ee5b7653f781c7c86ac22eeca314864`

## 1. 结论

本轮对曲库、来源管理、全屏播放及其共用交互组件执行 P5 审查。第一轮只针对四个有
具体位置和验收条件的问题返工；返工后定向测试、全量非 Golden 测试、Golden、静态分析、
固定运行时截图和 Windows 预览构建均通过。六个固定运行时场景与已批准 P4 基准逐像素
完全一致，没有更新 Golden 或 P4 运行时基准。

本轮自动返工为 1 轮，未触发第二轮。结论只证明 Windows 固定夹具和本轮代码的回归
门禁通过，不证明 Android、iOS、macOS、Linux、真实夸克/WebDAV、真实播放链路、
人工读屏或完整商业品质已经通过。

## 2. 问题与修复

严重性使用 S1 阻断、S2 高、S3 中/低。P5 只在存在具体问题时返工。

| ID | 位置 | 问题类型 | 严重性 | 返工前问题 | 明确修复要求 |
|---|---|---|---|---|---|
| P5-01 | [interactive.dart](../../app/lib/design/components/interactive.dart) 及主按钮、图标按钮、行操作 | 键盘可见焦点 | S2 | Tab 能移动焦点，但通用 `TyInteractive` 没有可见焦点指示；传输键已有独立焦点外观 | 建立统一、不改变布局的焦点环；已有复合焦点外观不重复绘制 |
| P5-02 | [app_shell.dart](../../app/lib/design/layout/app_shell.dart) 的 compact 迷你条与底部导航 | 底部安全区 | S2 | 24dp 底部 inset 下导航仍到达屏幕底边 `844`；预期为 `820` | 底部组合只消费一次安全区；来源详情改用迷你条时同样满足 |
| P5-03 | [track.dart](../../app/lib/design/components/track.dart) 曲目行 | 读屏语义重复 | S2 | 曲名、艺术家、专辑、时长和正在播放音柱可形成多个重复节点；整行可访问名称缺少时长 | 保留一个完整、可操作的曲目节点；收藏、选择、更多等子操作保持独立 |
| P5-04 | 播放舞台 844×390、200% 字号 | 验收缺口 | S3 | 既有测试只证明主控仍在首屏，没有稳定证明大字号标题可滚动到 | 增加标题可达和主控仍可见的回归断言；无具体视觉问题时不为通过测试改页面 |

返工前失败证据见
[before-tests.txt](p5-evidence/rework-round-1/before-tests.txt)：

- P5-01 的主按钮和图标按钮测试均找不到 `ty-focus-indicator`。
- P5-02 的实际底边为 `844`，与期望的 `820` 相差 24dp。

修复结果：

- [interactive.dart](../../app/lib/design/components/interactive.dart) 用不占布局的 2px
  内缘焦点线绘制统一焦点环；只有可操作控件可以请求焦点，并允许复合组件声明自己的
  圆角或关闭通用环。
- [transport.dart](../../app/lib/design/components/transport.dart) 保留传输键原有焦点外观，
  关闭通用焦点环，避免双环。
- [app_shell.dart](../../app/lib/design/layout/app_shell.dart) 在底部迷你条和导航外层使用
  `SafeArea(top: false)`；没有把安全区写死为平台像素值。
- [track.dart](../../app/lib/design/components/track.dart) 将视觉子节点从语义树排除，
  外层显式提供含时长的完整名称和点击动作；视觉子操作仍分别提供名称和动作。
- [voice_archive_stage_layout_test.dart](../../app/test/voice_archive_stage_layout_test.dart)
  验证 844×390、200% 字号下标题可滚动到视口内，且传输主控不离开 390 高视口。

新增 [p5_review_regression_test.dart](../../app/test/p5_review_regression_test.dart)，覆盖：

- 主按钮与图标按钮的键盘焦点环；
- 聚焦前后组件尺寸不变；
- compact 底部导航和来源详情迷你条各消费一次 24dp 安全区；
- 曲目名称与“正在播放”各出现一次；
- 曲目整行仍有 `tap` 动作；
- 收藏与更多操作是带独立 `tap` 动作的节点。

四项返工后均关闭。没有把测试通过直接替代视觉或人工读屏验收。

## 3. 自动化证据

| 门禁 | 最终结果 | 证据 |
|---|---|---|
| Dart 格式 | 6 个触碰文件，0 个需改动 | [format-final.txt](p5-evidence/rework-round-1/format-final.txt) |
| `flutter analyze` | 退出码 0，No issues found | [analyze-final.txt](p5-evidence/rework-round-1/analyze-final.txt) |
| 全量非 Golden 测试 | 366/366 通过，退出码 0 | [non-golden-tests-final.txt](p5-evidence/rework-round-1/non-golden-tests-final.txt) |
| P5 定向回归 | 8/8 通过，退出码 0 | [targeted-regression-final.txt](p5-evidence/rework-round-1/targeted-regression-final.txt) |
| Golden | 12/12 通过，退出码 0，未使用自动更新 | [golden-tests.txt](p5-evidence/rework-round-1/golden-tests.txt) |
| Windows 固定预览构建 | 退出码 0 | [preview-build.txt](p5-evidence/rework-round-1/preview-build.txt) |
| Windows 六场景运行时比较 | 6/6 逐像素完全一致，退出码 0 | [runtime-visual-results.json](p5-evidence/rework-round-1/runtime-visual/runtime-visual-results.json) |

固定运行时条件由门禁自行验证：Flutter `3.47.2`、Dart `3.13.2`、Windows DPI 1.5、
固定字体与封面 SHA256、禁用动画。桌面客户区为 `1898×1024`；手机客户区为
`585×1266`。

| 用例 | 主题与状态 | 差异像素 | 结论 |
|---|---|---:|---|
| `library-desktop-dark` | 曲库桌面暗色 | 0 | 通过 |
| `library-mobile-scale2-light` | 曲库手机 200% 字号 | 0 | 通过 |
| `sources-desktop-syncing-dark` | 来源同步中 | 0 | 通过 |
| `sources-mobile-relogin-dark` | 来源需重新登录 | 0 | 通过 |
| `stage-desktop-light` | 播放舞台桌面浅色 | 0 | 通过 |
| `stage-mobile-dark` | 播放舞台手机暗色 | 0 | 通过 |

首次运行曾因会话没有稳定提供 DPI 1.5 或完整手机客户区而停在采集条件检查，未进行
像素比较。失败现场已原样保存在
[runtime-visual-attempt-1-environment-blocked](p5-evidence/rework-round-1/runtime-visual-attempt-1-environment-blocked/)；
重试前先用单场景确认 `585×1266 / DPI 1.5`，随后六场景门禁通过。该环境阻塞不属于
视觉返工轮次。

## 4. 实际截图审查

| 场景 | 客户区 | 图片 | SHA-256 | 审查结论 |
|---|---:|---|---|---|
| 播放舞台，手机，Light，200% 字号 | 585×1266 | [stage.png](p5-evidence/rework-round-1/runtime-accessibility/stage-mobile-scale2-light/stage.png) | `c7f3c0502f373a727ad48dfb4c08ff73dc470fb3d233a56ca11dba3b7421ab91` | 标题、进度和主控可见，无裁切或溢出；底部入口保留 |
| 播放舞台，横屏，Dark，200% 字号 | 1266×585 | [stage.png](p5-evidence/rework-round-1/runtime-accessibility/stage-landscape-scale2-dark/stage.png) | `9b7a2a598053d28cd277d01b16c0534f246b0b4a0c5685c2de341c88ca3fbd81` | 首屏优先封面、进度和主控；曲名可滚动到；没有主控被固定区域覆盖 |

两张图均由 Windows 固定预览入口实际运行采集，DPI 为 1.5，使用固定封面并禁用动画。
对应采集元数据在同目录的 `capture-metadata.json`。自动审查报告
[visual-review.md](p5-evidence/rework-round-1/runtime-visual/visual-review.md) 对六张
批准基准截图的结论是“没有发现与已批准基准的可执行视觉差异”。

本次没有修改 P4 的 6 张运行时基准、12 张 Golden 或批准资产封印。运行时实际图为
PNG 字节完全一致，而不只是低于容差；门禁没有遮罩、忽略区域或自动接受差异的开关。

## 5. 尚未覆盖的范围

以下项目仍需独立验收，不能用本轮结果替代：

- Android、iOS、macOS、Linux 的实际字体、窗口、触控和响应式渲染；
- 真实夸克网盘与 WebDAV 凭据、登录过期、同步取消、部分成功和远程播放；
- 真实播放引擎的长时播放、失败恢复、前后台切换和系统媒体控制；
- Narrator、VoiceOver、TalkBack 的人工读屏，以及完整焦点顺序和所有快捷键；
- 实际触控设备上的滚动、拖动、手势区、安全区和 200% 系统字号；
- 自动化截图无法判断的审美质量、动效手感和商业品质。

横屏 200% 字号截图中，曲名位于可滚动内容而不是首屏固定区域；这是当前 P2 声档规范
允许的降级方式。仍需在真实触控设备上确认用户能发现并完成滚动，不以测试中
`ensureVisible` 的通过替代人工体验验收。

## 6. 后续执行

P5 的 Windows 自动门禁和第一轮问题返工已经完成。后续新增问题必须带图名或组件位置、
问题类型、严重性和明确修复要求；仍按每次一个页面或一组关联组件返工。任何新视觉差异
先复现和定位，不能通过更新 Golden、放宽像素比较或删除断言消除。

跨平台或人工验收若发现具体问题，应按“问题记录 → 一轮最小修复 → 定向回归 → 全量门禁
→ 固定截图复核”的顺序处理。最多连续自动返工两轮；第二轮仍不通过时停止并报告阻塞。
