# 听屿 P6A 无真机自动验收

日期：2026-10-19

验收分支：`codex/ui-p6a-acceptance`

自动化运行基线提交：`97a3d4e38775decfc287c3d4c9f2449cb370194f`

环境：Windows `10.0.26300.0`、Flutter `3.47.2`、Dart `3.13.2`、
PowerShell `7.6.5`

## 1. 结论

P6A 已在当前没有 Android/iOS 真机、macOS 工具链和真实网盘账号的条件下，完成一轮
可重复的 Windows 自动验收。最终总门禁 `all` 用时 `369.881` 秒，12 个门禁全部退出
码 0；未更新 Golden、6 张已批准运行时基准或批准资产封印。

本轮证明的是当前 Windows 固定环境下的静态质量、交互契约、loopback 来源协议、
响应式截图结构、批准基准回归、本地 WAV 播放位置推进、舞台往返续播和自动语义树。
它不证明 Android、iOS、macOS、Linux、真实服务账号、真机触控、系统字号、人工读屏
或整体商业品质已经验收。因此 P6B 仍然必要。

最终汇总位于
[automated-acceptance-results.json](p6a-evidence/automated-acceptance-results.json)。

## 2. P6A 与 P6B 边界

| 范围 | P6A 本轮结果 | P6B 仍需完成 |
|---|---|---|
| 平台 | Windows 固定窗口、DPI 1.5 和固定字体 | Android、iOS、macOS、Linux 实际运行 |
| 页面 | 固定预览中的曲库、来源、播放舞台及关键状态 | 真机窗口、刘海/安全区、系统栏和横竖屏旋转 |
| 交互 | 键盘、语义动作、舞台进入与返回 | 真实触控、鼠标手感、系统返回手势和跨平台快捷键 |
| 来源 | 本地 loopback WebDAV/夸克 HTTP 协议替身 | 真实夸克与 WebDAV 账号、过期、风控和远程播放 |
| 播放 | 本地 WAV 经 `media_kit (libmpv)` 实际推进 | 真实曲库、网络直链、前后台、长时播放和故障恢复 |
| 无障碍 | UIA 查询、MSAA 自动树和原生 AX 错误检查 | Narrator、VoiceOver、TalkBack 人工读屏 |
| 视觉 | 6 张批准基准逐像素回归、17 场景诊断矩阵 | 真机字体缩放、动效手感和人工商业品质评审 |

P6A 不替代 P6B，也不把自动通过写成“商业品质已达成”。

## 3. 本轮自动化能力

- [p6a-automated-acceptance.ps1](../../tools/p6a-automated-acceptance.ps1)
  统一执行 static、interaction、integration、regression、golden、visual、runtime
  七层门禁，并生成机器可读汇总。
- [runtime-matrix.json](p6a-quality/runtime-matrix.json) 固定 17 个场景的路线、
  主题、视口、字号、页面状态、封面和环境哈希。
- [p6a-runtime-matrix.ps1](../../tools/p6a-runtime-matrix.ps1) 逐案启动固定预览，
  校验客户区尺寸、DPI、非空图像、夹具与字体哈希，并生成联系表。
- [windows-smoke-test.ps1](../../tools/windows-smoke-test.ps1) 使用生产 Windows
  构建和本地 WAV，检查播放推进、进入播放舞台、返回曲库、10 次往返续播和自动语义树。
- [windows-accessibility-probe.ps1](../../tools/windows-accessibility-probe.ps1)
  通过 Windows MSAA 读取舞台与曲库的节点、角色和名称。
- [p6a_interaction_contract_test.dart](../../app/test/p6a_interaction_contract_test.dart)
  覆盖 Tab 顺序、Enter/Space、自动重复、Esc 后焦点返还和禁用语义。
- [webdav_http_integration_test.dart](../../app/test/webdav_http_integration_test.dart)
  与 [quark_http_fixture_test.dart](../../app/test/quark_http_fixture_test.dart)
  使用真实 loopback socket 验证鉴权、分页、重试、Cookie、路径与取消。

夸克客户端只增加了可选的测试基址注入；生产固定的 `pc` 与 `cdn` 默认地址和行为保持
不变。测试替身不访问真实账号。

## 4. 自动门禁发现与修复

### P6A-F01：长按键盘会重复执行组件动作

位置：[interactive.dart](../../app/lib/design/components/interactive.dart)

问题类型：键盘交互，严重性 S2。

返工前的自动重复测试期望一次 Enter 和一次 Space 共执行 2 次，实际执行 6 次；
`KeyRepeatEvent` 被当成新的动作触发。对播放、删除、提交等操作，这意味着按住按键会
重复执行业务动作。修复后只有首次 `KeyDownEvent` 触发，`KeyUpEvent` 与
`KeyRepeatEvent` 不再产生动作。

同一测试还发现没有 `onTap` 的控件仍可能被语义树标记为可用。修复后默认启用状态依据
实际动作能力计算，禁用按钮会向辅助技术报告禁用态。失败原文保存在
[interaction-before.txt](p6a-evidence/rework-round-1/interaction-before.txt)，修复后
定向测试 8/8 通过：
[targeted-after-4.txt](p6a-evidence/rework-round-1/targeted-after-4.txt)。

### P6A-F02：导航截图曾出现“假通过”

位置：[windows-smoke-test.ps1](../../tools/windows-smoke-test.ps1)

问题类型：验收证据完整性，严重性 S1。

初版冒烟脚本虽然以退出码 0 结束，但 `02-expanded.png` 实际仍是曲库页：点击坐标落在
播放条右侧控件，没有进入播放舞台。仅检查“进程未退出且位置推进”会错误证明舞台往返
续播已经通过。

修复后改为点击传输条左侧封面/标题区域，并允许 320ms 舞台过渡完成；首次进入后读取
MSAA 树，必须找到“关闭舞台”和当前曲名节点，之后点击左上返回。若未真正进入舞台，
门禁直接失败。最终结果中的 `expandedStageConfirmed` 为 `true`。

### 测试替身中的非产品问题

HTTP 集成首次实现曾出现 Dart `HttpHeaders` API 误用、WebDAV 取消时序假设错误和
夸克夹具请求头遍历问题。这些失败都发生在新增测试代码中，修复后没有改动 WebDAV
业务实现。相关中间失败日志原样保留在
[rework-round-1](p6a-evidence/rework-round-1/)，没有通过放宽断言绕过。

## 5. 最终门禁结果

| 门禁 | 最终结果 | 证据 |
|---|---|---|
| 格式 | 5 个触碰 Dart 文件，0 个需改动 | [format.txt](p6a-evidence/gates/format.txt) |
| 静态分析 | `No issues found!` | [analyze.txt](p6a-evidence/gates/analyze.txt) |
| 交互契约 | 60/60 通过 | [interaction-contracts.txt](p6a-evidence/gates/interaction-contracts.txt) |
| loopback 集成 | 53/53 通过 | [local-integrations.txt](p6a-evidence/gates/local-integrations.txt) |
| 全部非 Golden 测试 | 374/374 通过 | [non-golden-tests.txt](p6a-evidence/gates/non-golden-tests.txt) |
| Golden | 12/12 通过，未自动更新基准 | [golden.txt](p6a-evidence/gates/golden.txt) |
| 固定预览构建 | Windows Release 构建成功 | [visual-preview-build.txt](p6a-evidence/gates/visual-preview-build.txt) |
| 6 张批准基准 | 6/6 像素与 PNG 字节完全一致 | [runtime-visual-results.json](p6a-evidence/approved-runtime/runtime-visual-results.json) |
| 17 场景矩阵 | 17/17 结构检查通过 | [matrix-results.json](p6a-evidence/runtime-matrix/matrix-results.json) |
| 生产 Windows 构建 | `tingyu.exe` 构建成功 | [production-build.txt](p6a-evidence/gates/production-build.txt) |
| 本地播放与语义树 | 通过，详见第 7 节 | [result.json](p6a-evidence/production-smoke/result.json) |
| 批准资产封印 | Golden 与 P4 运行时基准哈希全部匹配 | [visual-asset-seal.txt](p6a-evidence/gates/visual-asset-seal.txt) |

交互契约和非 Golden 全量测试、定向 8 个测试之间存在包含关系，以上数字不能相加。

6 张批准运行时基准的差异像素均为 0，`maxChannelDelta` 为 0，并同时满足 PNG 字节
完全一致。固定条件为 Flutter `3.47.2`、Dart `3.13.2`、Windows DPI 1.5、固定字体
和禁用动画；没有遮罩、忽略区域或自动接受差异。

## 6. 响应式运行时矩阵

[runtime-matrix.json](p6a-quality/runtime-matrix.json) 的 17 个场景分布如下：

| 页面 | 场景数 | 覆盖 |
|---|---:|---|
| 曲库 | 6 | 360×640、390×844、639×640、1024×683、1265×683；Light/Dark；normal/empty/error；200% 字号 |
| 来源管理 | 5 | 手机与桌面；normal/syncing/relogin/error；200% 字号 |
| 播放舞台 | 6 | 手机、横屏、桌面；normal/empty/failure；队列与歌词；200% 字号 |

逐案采集元数据、原图与日志位于
[runtime-matrix](p6a-evidence/runtime-matrix/)，总览为
[contact-sheet.png](p6a-evidence/runtime-matrix/contact-sheet.png)。17 个场景全部
通过 PNG 尺寸、DPI、状态元数据和空白图检查。

联系表人工目视复核未发现新的 S1/S2 布局缺陷，但该矩阵没有批准像素基准，结论仅限
结构、溢出和明显层次问题。桌面失败态的“播放失败 / 重试此曲”提示、手机 200% 字号
的正文换行、横屏舞台主控仍可见，均在原图复核范围内。

## 7. 生产 Windows 冒烟

生产构建使用固定 Windows 引擎，并通过 `TINGYU_DEBUG_SOURCES` 播放本地 120 秒 WAV。
这不是曲库真实来源播放；它验证生产二进制、`media_kit (libmpv)` 和页面导航的组合。

- 引擎保持 `processing=ready playing=true`，播放位置从 `8,330ms` 推进到
  `22,890ms`，增量 `14,560ms`。
- 10 次“进入播放舞台 → 返回曲库”后进程仍存活，`expandedStageConfirmed=true`。
- 最终 MSAA 树有 74 个节点、52 个命名节点；舞台态 MSAA 树有 27 个节点、21 个
  命名节点。
- 原生 AX 更新错误为 0。
- UIA 查询只枚举到 1 个命名后代，因此本轮自动无障碍证据主要来自 MSAA；这不足以
  证明 Narrator、VoiceOver 或 TalkBack 的实际朗读体验。

实际运行截图顺序为
[01-playing.png](p6a-evidence/production-smoke/01-playing.png)、
[02-expanded.png](p6a-evidence/production-smoke/02-expanded.png)、
[03-after-navigation.png](p6a-evidence/production-smoke/03-after-navigation.png)，
总览为
[production-smoke/contact-sheet.png](p6a-evidence/production-smoke/contact-sheet.png)。
三张图分别显示曲库播放、播放舞台和返回曲库后的继续播放。

## 8. 尚未覆盖

- 未在 Android、iOS、macOS、Linux 实际运行；当前环境没有 Android AVD/真机或
  macOS 工具链。
- 未使用真实夸克网盘或 WebDAV 账号。loopback 测试只证明 HTTP 传输、协议解析、重试、
  Cookie、取消和目录扫描契约。
- 未进行 TalkBack、VoiceOver、Narrator 人工读屏，也未检查真实系统焦点顺序与全部
  快捷键组合。
- 未验证真实系统字体缩放、真机触控、软键盘、安全区、横竖屏旋转、跨平台窗口和字体。
- 生产冒烟使用调试源启动单首本地 WAV，不是从真实曲库行、新鲜夸克直链或 WebDAV
  发起播放；也未验证扬声器实际出声、长期播放、前后台切换或系统媒体控制。
- 自动像素一致只证明没有偏离已批准 Windows 基准，不证明审美质量或整体商业品质。

## 9. P6B 建议顺序

1. 先用可用模拟器补齐 Android 手机与平板视口，再补 iOS Simulator；每个平台保留
   固定字体、固定视口和稳定数据的截图产物。
2. 在真机执行触控、返回手势、底部安全区、系统字号、横竖屏和真机媒体会话冒烟。
3. 使用受控测试账号执行真实 WebDAV 与夸克登录、同步、取消、过期和远程播放。
4. 由人工使用 Narrator、VoiceOver、TalkBack 检查朗读名称、角色、状态、操作和焦点
   顺序；自动 MSAA/UIA 结果只能作为前置门禁。
5. 所有发现问题按“位置、类型、严重性、明确修复要求”记录。每轮只修一个页面或一组
   关联组件；连续两轮仍失败时停止并报告阻塞。

## 10. 复现

在仓库根目录运行：

```powershell
./tools/p6a-automated-acceptance.ps1 -Stage all
```

也可分别运行 `static`、`interaction`、`integration`、`regression`、`golden`、
`visual`、`runtime`。结果写入 `docs/ui-redesign/p6a-evidence/`；Golden 基准只能经过
明确设计批准后更新。
