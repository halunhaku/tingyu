# P4 自动化验收门禁

基线提交：`520d73637ee5b7653f781c7c86ac22eeca314864`

本门禁建立在已批准的 P3 曲库、来源管理和播放舞台视觉上。五层检查各自保存命令、
退出码与原始日志，任何一层通过都不能替代另一层。当前默认运行环境是 Windows
固定桌面；CI 只额外证明 Android、iOS、macOS、Linux 和 Windows 能构建。

## 一键入口

在仓库根目录运行：

```powershell
./tools/p4-quality.ps1 -Stage all
```

也可单独运行某一层：

```powershell
./tools/p4-quality.ps1 -Stage static
./tools/p4-quality.ps1 -Stage widget
./tools/p4-quality.ps1 -Stage golden
./tools/p4-quality.ps1 -Stage visual
./tools/p4-quality.ps1 -Stage runtime
```

`visual` 会先用仓库固定的 Windows 引擎构建
`app/tool/voice_archive_preview.dart`，再采集六种固定状态。`runtime` 会重新用
`app/lib/main.dart` 构建生产入口并运行真实本地音频与导航冒烟。两者必须顺序运行，
否则生产构建会覆盖预览构建产物。

所有步骤写入：

- `docs/ui-redesign/p4-evidence/quality-gates-results.json`
- `docs/ui-redesign/p4-evidence/gates/*.txt`
- `docs/ui-redesign/p4-evidence/runtime-visual/`
- `docs/ui-redesign/p4-evidence/production-smoke/`

如果某层失败，入口停止后续依赖层并仍写出已经执行门禁的退出码。退出码不能由空值
推断；每个 PowerShell 工具显式返回 `0` 或非零。

## 五层门禁

| 层 | 检查 | 通过条件 |
|---|---|---|
| 1 | P4 Dart 文件格式、`flutter analyze`、全部非 Golden 测试 | 三条命令退出码均为 0 |
| 2 | 曲库、来源、播放舞台、导航、搜索、状态与性能的重点 Widget / 交互测试 | 指定 12 个测试文件全部通过 |
| 3 | `test/golden/core_pages_golden_test.dart` | 12/12 Golden 只校验通过 |
| 4 | Windows 六种固定状态实际运行截图 | 每张与 P4 清洁运行时基准逐像素一致 |
| 5 | Windows 生产 Release、本地真实播放、位置推进和导航循环 | 进程不崩溃、`media_kit` 进入 playing、位置增加、循环完成 |

P4 没有引入自动更新 Golden 的开关。Golden 层只执行：

```powershell
flutter test --run-skipped -t golden test/golden/core_pages_golden_test.dart
```

仓库当前有 84 个历史文件不符合 Dart 3.13 formatter。P4 格式门禁只检查本轮触碰的
Dart 文件，避免用一个门禁提交改写大量无关业务文件。当前范围为
`lib/data/secure_store.dart`；后续 P4 改动应把对应文件加入同一检查。

`windows-smoke-test.ps1` 必须由脚本自己终止其启动的进程。冒烟至少记录：

- `positionDeltaMs > 0`
- 最终快照仍为 `processing=ready playing=true`
- 导航循环次数达到要求
- 进程没有自行退出

## 固定视觉环境

视觉用例清单见
[`p4-quality/runtime-visual-cases.json`](p4-quality/runtime-visual-cases.json)。
运行时基准的逐项来源和截图像素差见
[`p4-quality/runtime-baselines/provenance.json`](p4-quality/runtime-baselines/provenance.json)。

| 用例 | 物理客户区 | 状态 |
|---|---:|---|
| `library-desktop-dark` | 1898×1024 | 曲库桌面暗色 |
| `library-mobile-scale2-light` | 585×1266 | 手机 200% 字号 |
| `sources-desktop-syncing-dark` | 1898×1024 | 来源同步中 |
| `sources-mobile-relogin-dark` | 585×1266 | 手机重新登录 |
| `stage-desktop-light` | 1898×1024 | 播放舞台桌面浅色 |
| `stage-mobile-dark` | 585×1266 | 播放舞台手机暗色 |

截图工具会调整外窗，直到 Flutter 子窗口客户区达到清单中的精确物理像素，并关闭
Windows 11 顶层窗口的 DWM 圆角，避免圆角透出的桌面内容污染客户区截图。DPI 必须为
1.5；Flutter、Dart、字体和封面 SHA256 也必须与清单一致。固定入口使用相同数据，
关闭动画，并以宽度决定 compact / expanded 布局。`density` 不是本入口的独立输入，
不得在证据中写成已生效的变量。

像素比较结果写入每个用例目录的 `comparison.json`，包括：

- 原始尺寸与是否同尺寸
- 差异像素数和差异比例
- 最大通道差与平均绝对差
- 差异包围框
- 批准图、实际图和差异图 SHA256
- 逐像素是否完全一致，以及 PNG 字节是否完全一致

视觉通过采用逐像素相等；任何非零差异都失败。差异图只用于定位，不能作为新基准。
自动审查会在 `runtime-visual/visual-review.md` 给出用例、包围框、问题类型、严重性
和修复要求。最多自动返工两轮；两轮后仍失败就停止并报告阻塞。

### 运行时基准来源

P4 的六张运行时基准位于 `p4-quality/runtime-baselines/`，设计批准仍指向
`520d73637ee5b7653f781c7c86ac22eeca314864` 的 P3 视觉。首次固定环境比较发现，
Windows 11 会把顶层窗口边缘圆角化，客户区截图的底部圆角会透出当时桌面的内容；
最初两张桌面图分别出现过 21 和 31 个环境像素差异，放大后确认它们来自圆角边缘，
与 Flutter 页面内容和鼠标位置无关。

P4 截图工具因此对固定预览顶层窗口设置 `DWMWCP_DONOTROUND`，并用同一固定入口重新
采集六张基准。最终六张新图相对各自 P3 原图都只有底部两个圆角内的 62 个 DWM 环境
像素不同；客户区内不再混入桌面背景，页面尺寸和 Flutter 布局未改变。P3 原图保持
不变，清单同时记录 P3 来源路径与 SHA256；P4 基准、Golden 和案例清单均不得自动改写。
门禁仍要求零像素差，没有遮罩、容差或忽略区域。

## 批准资产封印

`approved-visual-assets.sha256` 同时封印 12 张 Golden 和 6 张 P4 运行时基准图。
CI 从仓库根目录执行：

```bash
sha256sum --check docs/ui-redesign/p4-quality/approved-visual-assets.sha256
```

新增或修改被封印图片必须同时具备：

1. 用户对当轮实际截图的明确视觉批准；
2. 批准范围记录，不得把“全部批准”外推到未展示的状态；
3. 图片与 `approved-visual-assets.sha256` 同一次审查提交；
4. 对应 Golden 只按具名用例校验，不用全量自动更新掩盖回归。

## CI 与跨平台边界

GitHub Actions 执行依赖解析、Drift 生成代码无差异检查、P4 格式检查、静态分析、
全部非 Golden 测试、批准资产封印，以及 Android、iOS、macOS、Linux、Windows 五类
构建。Golden 和实际运行视觉比较仍只在固定 Windows 环境执行，因为其他字体栈会产生
不同的像素结果。

CI 五平台构建通过不证明：

- Android、iOS、macOS、Linux 的运行时交互或视觉正确；
- 真实夸克网盘或 WebDAV 的登录、扫描和远程播放通过；
- Narrator、VoiceOver、TalkBack 或完整键盘焦点顺序通过；
- Windows 固定视觉在整个产品范围内达到商业品质。

这些项目必须在对应设备、受控凭据或人工无障碍审查中单独记录，不能沿用本次 Windows
自动化证据。

## Windows 凭据回退

`SecureStore` 的 macOS 未签名开发回退会创建 0600 文件。`chmod` 仅存在于 POSIX，
因此该操作现在只在非 Windows 执行；Windows 文件继续继承当前用户应用配置目录的
ACL。两者不是相同的安全模型，此修复只消除 Windows 对不存在命令的错误依赖。
