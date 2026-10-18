# P3 · 声档全屏播放页实施记录

2026-10-18。用户以“确认”批准 P2 后实施，分支 `codex/ui-p3-player`。本轮仅迁移全屏播放及其歌词、队列、进度与状态呈现；曲库、来源管理尚未迁移。批准记录见 [decision-c.json](decision-c.json)。

## 实施与可回退范围

- `VoiceArchiveColors` 与批准 JSON 对应，通过局部 Theme 应用于播放页；其余页面继续使用原主题。
- 桌面左右分栏，手机在窗口足够高时显示 168dp 歌词/队列预览；短窗和大字号提供面板入口，封面与元信息可以滚动，播放控制保留在可访问区域。
- 当前播放与接下来分组，点击仍使用原队列索引。歌词解析、封面取色偏好、Riverpod、路由和播放控制器复用现有实现。
- 失败呈现原因与重试入口，重试调用现有 `playAt`；未知时长禁用拖动并显示 `--:--`，读屏语义同步处理。
- 未修改数据库、来源协议、音频引擎或依赖版本。普通组件与测试夹具由轻量模型实现，主代理负责接线、测试和视觉审查。

## 证据与复现

所有原始日志和截图保存在 [p3-player-evidence](p3-player-evidence/)。`app/tool/voice_archive_preview.dart` 是真实 Flutter 页面使用的固定数据入口：4 首虚构曲目、固定进度 84 秒、固定封面、关闭动画；播放命令仅改变内存，**不作为真实播放证明**。

视觉入口环境变量：`TINGYU_PREVIEW_STATE=normal|failure|unknown|long|empty`、`TINGYU_PREVIEW_SCALE=2`、`TINGYU_PREVIEW_COVER` 指向绝对封面路径。使用现有 `windows-ui-screenshots.ps1`，单独进程依次采集，避免窗口争抢。复现构建需遵循仓库本地 Windows 引擎配置并指定 `-t tool/voice_archive_preview.dart`；生产冒烟必须重新以 `lib/main.dart` 构建。

Windows DPI 1.5，桌面截图客户区 1898×1024（约1265×683逻辑像素），手机 585×1266（390×844）；不是 Android/iOS 真机证据。字体沿用仓库与本机固定环境，精确 SDK/字体散列见环境清单。生成的海面封面仅用于固定夹具，来源是内置 ImageGen，原始提示与散列另存清单，不是品牌资产。

## 视觉审查与返工

| 位置 | 类型 / 严重性 | 证据与修复要求 | 处理 |
|---|---|---|---|
| 手机歌词预览空态 | 布局 / 高 | 原大空态在168dp槽内溢出；改为可滚动的紧凑空态 | 页面测试通过 |
| 桌面1265×683左列歌手/专辑 | 裁切 / 高 | [首轮截图](p3-player-evidence/desktop-light/stage.png)中元信息被挤出首屏；按可用高度收缩封面 | 第1轮视觉返工，新增完整可见性测试，重建截图复核 |
| 极短横窗与2倍字 | 响应式 / 中 | 元信息需滚动，控制和面板入口必须可见 | 测试覆盖；不宣称所有元信息首屏可见 |
| Golden舞台 | 基准差异 / 已批准 | [批准前差异图](p3-player-evidence/golden-diffs/stage-compact-dark_isolatedDiff.png) | 用户于 2026-10-18 具名批准；仅更新 `stage-compact-dark`，完整 Golden 12/12 通过 |

没有第二轮自动视觉返工。用户已于后续来源管理节点明确批准舞台视觉；批准记录和当前
SHA256 见
[来源页 Golden 批准记录](p3-sources-evidence/golden-approval.txt)。这个批准只覆盖固定
Windows Golden 与当前夹具，不覆盖尚未执行的跨平台、远程来源和人工无障碍验收。

## 门禁与限制

最终结果见 [验证结果](p3-player-evidence/results.md)。静态分析、Widget、Golden、真实运行截图和真实引擎冒烟分别记录，不互相替代。

Windows 原生 MSAA 探针在 PowerShell 7 下编译失败（`List<>` 引用缺失），没有原生无障碍通过结论。既有来源适配器测试因 Windows 缺少 `chmod` 失败，保留原始错误；未通过放宽断言或修改业务来掩盖。尚未执行 Android/iOS/macOS/Linux 真机冒烟、夸克/WebDAV 远程播放或完整人工读屏。

## 下一步

1. 保持 `stage-compact-dark` 为只在校验模式下不漂移的已批准基准；任何后续像素变化需
   先给出具体问题证据，再重新请求批准。
2. 补齐原生无障碍探针与可用平台的真实播放冒烟；远程来源使用受控凭据测试，不把本地
   音频冒烟当成远程来源验证。
3. 进入 P4，将静态分析、Widget、Golden、实际运行截图视觉对比和跨平台冒烟作为独立
   门禁记录。
