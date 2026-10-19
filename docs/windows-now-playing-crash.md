# Windows 播放页快速返回崩溃调查

当前状态：2026-10-06 已完成本机引擎修复、应用重编译、安装及回归。
临时 `WM_GETOBJECT` 拦截已删除，MSAA 读屏接口恢复。下面保留各阶段调查记录；
最终结果见文末「本地引擎完整修复」。

调查日期：2026-10-06。用户报告：开始播放 → 点击播放条的展开按钮 → 立即点击「返回」→ 声音停止 → 应用闪退。

## 已确认的崩溃原因

用本机 WinDbg 包中的 `amd64/cdb.exe`，加载 Flutter SDK 自带、匹配构建模式的 `flutter_windows.dll.pdb`，分析了三份 Windows Error Reporting dump：

| dump（位于 `%LOCALAPPDATA%/CrashDumps`） | 时间（北京时间） | 构建 | DLL 偏移 |
| --- | --- | --- | --- |
| tingyu.exe.30508.dmp | 14:04:23 | Debug | 0x3c18a |
| tingyu.exe.33264.dmp | 16:45:17 | Release | 0x3c16a |
| tingyu.exe.5660.dmp | 17:21:19 | Release | 0x3c16a |

三份栈均为：

```text
ui::AXNode::id
flutter::AccessibilityBridge::CreateRemoveReparentedNodesUpdate + 0xba
flutter::AccessibilityBridge::CommitUpdates + 0x40
flutter::FlutterWindowsEngine::Run::<lambda_14>
flutter::PlatformViewEmbedder::UpdateSemantics
flutter::Shell::OnEngineUpdateSemantics
flutter::Engine::UpdateSemantics
flutter::RuntimeController::UpdateSemantics
```

异常为 `0xc0000005`；故障指令 `mov eax,dword ptr [rax+48h]`，`rax=0`，读取地址 `0x48`。结合匹配源码，空指针来自 `child->parent()`，随后执行 `child->parent()->id()`。

本机 Flutter 3.47.2，framework `d3b14c876900e553bc736ca19295fc09e3853e8e`，engine `a804b261645ef8c13eb3d5c44a5c2fb0340c5539`。SDK 源码 `engine/src/flutter/shell/platform/common/accessibility_bridge.cc` 中该函数只检查 `!child`，父节点仍只用 assert 检查，未包含空父节点修复。

Flutter 上游同栈问题：[issue #175041](https://github.com/flutter/flutter/issues/175041)。对应修复：[PR #190903](https://github.com/flutter/flutter/pull/190903)，调查时仍为 Open。补丁检查 `!child || !child->parent()`，避免空父节点解引用。

## 应用调用链与结论边界

- `player_bar.dart` 的展开按钮执行 `context.push('/now-playing')`，是播放页导航。
- `now_playing_page.dart` 的「返回」执行 `context.pop()`，无法 pop 时执行 `context.go('/library')`；没有暂停或释放播放器的调用。
- `playbackProvider` 非 autoDispose，控制器销毁回调仅取消快照订阅。
- 这三份 dump 的故障栈位于 Flutter 原生无障碍语义树更新。不能用相同 DLL 偏移认定是音频插件缩略图线程造成堆破坏。
- 用户观察到的「先暂停」尚未确认是 pause 指令、音频中断还是进程崩溃前停止出声。需要带时间戳的播放状态和指令日志才能区分。
- 本次分析使用已有 dump，尚未重新自动化复现用户的精确操作，也没有声称已修复或完成实机回归。

## 后续修复与验收

优先在包含对应引擎修复的 SDK 上验证，或构建带空父节点检查的本地 Windows engine。仅修改 SDK 源码后执行普通 `flutter build windows` 不会重编译引擎，必须确认最终 DLL 包含修复。

应用层取消路由动画、固定语义边界可作为待验证缓解方案，不能据此宣称根因已修复。优先保留无障碍支持；如临时关闭读屏接口，必须明确记录功能损失与撤除条件。

验收时开启原生无障碍语义树（例如 Narrator），分别使用本地音频和远端来源，覆盖刚起播及稳定播放后、进入后立即返回及等待动画结束后返回，并连续多次切换。检查进程存活、播放位置持续推进、是否出现 pause/stop 指令和新增 WER 记录。Dart widget 测试无法覆盖原生 AXTree 崩溃。

## 重跑 dump 分析

本机命令示例（SDK 路径及 WinDbg 包版本需按环境调整）：

```powershell
& 'C:/Program Files/WindowsApps/Microsoft.WinDbg_1.2606.22001.0_x64__8wekyb3d8bbwe/amd64/cdb.exe' `
  -y F:/flutter/bin/cache/artifacts/engine/windows-x64-release `
  -z "$env:LOCALAPPDATA/CrashDumps/tingyu.exe.5660.dmp" `
  -c '.ecxr; k; q'
```

Debug dump 使用 `windows-x64` 符号目录。没有加载匹配 PDB 时显示的 `InternalFlutterWindows_WindowManager_UpdatePopupPosition` 是邻近导出符号，不代表真实故障函数。

## 2026-10-06 本机重新编译与部署

执行 `flutter build windows --release` 成功，将完整 Release 目录复制到
`%LOCALAPPDATA%/Programs/Tingyu`。没有替换 Flutter 引擎或加入引擎修复。

使用 `tools/windows-smoke-test.ps1` 在已部署的可执行文件上运行：生成本地
120 秒 WAV，通过现有 `TINGYU_DEBUG_SOURCES` 入口起播；启动 8 秒后查询
UI Automation，再用真实鼠标连续执行 10 次展开和快速返回（点击展开后等待
180ms，首次额外保存截图）。窗口测试期间置顶，结束后取消置顶。

最终有效一轮产物位于 `app/build/windows-smoke/20261006-final/`：

- `02-expanded.png` 确认已进入带「返回」按钮的播放页。
- `03-after-navigation.png` 确认已回到曲库。
- `result.json`：PID 4360，10 轮后进程未退出。
- `stdout.log`：测试后仍 `playing=true`，本地 WAV 的 position 持续推进。
- `stderr.log`：仍有 `Failed to update ui::AXTree`，例如
  `13 will not be in the tree and is not the new root`。

结论：该轮本地 WAV 的稳定播放后快速切换未出现暂停或闪退，但原生语义树
错误仍存在。尚未覆盖刚开始播放的竞态及远端歌曲，不构成原问题已修复的证明。
之前的坐标/窗口遮挡校准轮次不作为完整导航回归证据。

## 17:44 用户在新部署版本上再次复现

用户操作：点击曲库歌曲播放 → 进入正在播放 → 返回 → 闪退。
WER 事件时间 17:44:33，dump `tingyu.exe.14300.dmp` 保存于 17:44:36；
应用路径 `%LOCALAPPDATA%/Programs/Tingyu/tingyu.exe`，确认是新部署版本。
进程运行约 17 秒后崩溃。

加载 Release PDB 后，再次确认故障为
`AccessibilityBridge::CreateRemoveReparentedNodesUpdate+0xba` 内联的
`ui::AXNode::id`，`rax=0`，读取 `0x48`，异常 `0xc0000005`，
DLL 偏移 `0x3c16a`。与之前三份 dump 是同一个空父节点故障。

重新编译应用仍打包相同、未修复的预编译 Flutter engine DLL，因此没有
消除根因。本地 WAV 的稳定播放回归不覆盖此次曲库起播的精确时序。
后续应采用包含修复的引擎并针对曲库起播场景回归；本次没有修改引擎。

## 17:54–17:58 临时稳定版与真实曲库回归

启动时保持 semantics 和路由外固定 Semantics 边界两种应用层尝试均未通过，
出现原生树错误及新 dump，相关尝试已撤回。

最终采用 Windows runner 的临时兼容处理：在 runner 和 Flutter 子窗口上，
拦截 `WM_GETOBJECT` 中 `OBJID_CLIENT`、`UiaRootObjectId` 的查询，返回 0，
阻止未修复的原生 AccessibilityBridge 被激活。其他消息继续原有处理；
子窗口 subclass 在销毁时解除。Release 构建及 `main.dart` 静态检查通过，
完整运行目录已更新到 `%LOCALAPPDATA%/Programs/Tingyu`。

**功能限制**：该 Windows 稳定版暂时不向 Narrator 等读屏工具提供应用内容。
这是避开错误路径的兼容方案，Flutter 引擎本身尚未修复。macOS、Linux、
Android、iOS 不使用该 runner，不受这项改动影响。

测试人员可在启动前设置 `TINGYU_WINDOWS_ACCESSIBILITY=1` 恢复原有接口，
用于验证将来带补丁的引擎；当前引擎下该开关会恢复已知崩溃路径。
采用并验证引擎修复后，应删除此兼容处理及其开关。

回归使用真实曲库点击，不设置调试 WAV 为播放来源。新增
`TINGYU_DEBUG_PLAYBACK_LOG=1` 只记录正常曲库流程的播放快照，不主动起播。
脚本等待歌曲首次达到 `ready playing=true` 后，以真实鼠标点击进入播放页，
约 180ms 后返回（首轮额外截图），包含 UI Automation 查询。

| 曲库歌曲 | 新进程 PID | 快速进入/返回 | 结果 | 产物目录（app/build/windows-smoke 下） |
| --- | --- | --- | --- | --- |
| 英雄 / doa | 32676 | 30 轮 | 存活、持续播放、无 AXTree 错误 | library-native-guard |
| 一路向北 / 周杰伦 | 3092 | 20 轮 | 存活、持续播放、无 AXTree 错误 | library-native-guard-row2 |

两轮 `02-expanded.png` 确认播放页展示真实曲目封面和标题，
`03-after-navigation.png` 确认返回曲库；stdout 中播放位置持续推进。
测试期间没有新增 WER dump。该结果验证了当前机器上的临时兼容处理，
不代表 Flutter 上游缺陷已修复，也未完成所有 Windows 设备及来源的回归。

## 19:38 本地引擎完整修复

独立源码固定为 Flutter framework `d3b14c876900e553bc736ca19295fc09e3853e8e`，
与本机 3.47.2 SDK 一致；构建目录位于 `app/build/flutter-engine/checkout`。
没有修改全局 `F:/flutter` 的引擎缓存。安装前完整备份位于
`app/build/windows-stable-backup`。

首先应用上游 PR #190903 的空父节点保护并编译引擎。真实曲库 30 次导航没有崩溃，
但出现 202 条 AXTree 错误，不能认定完整修复。首次更新的诊断日志显示：
真实根 `0` 的树之外还包含已脱离的节点 `21`；原有排序将 `21` 放在最前，
并把它当作初始根，随后所有根 `0` 更新被 AXTree 拒绝。
证据：`app/build/windows-smoke/engine-candidate-trace/stderr.log`。

最终引擎补丁在提交前从当前根（首次 Flutter 更新使用 `0`）遍历本帧的有效树，
结合待提交节点关系及未更新节点的现有关系，过滤已脱离的更新；同时保留空父节点保护。
新增两个回归测试，覆盖首次更新夹带脱离节点及同帧移除后仍有脏更新的场景。
组合补丁、独立测试夹具修正及 SHA256 固定在 `tools/engine-patches/`。
测试夹具修正只调整模拟 API 和 Release AOT 路径，不影响应用 DLL。

引擎检查：18 项 `AccessibilityBridgeTest.*` 和 29 项 Windows `*Accessibility*`
全部通过。XML 记录在 `engine/src/out/host_release/tingyu-*-accessibility.xml`。
空父节点恶意更新测试预期打印一条 AXTree 拒绝日志，该测试通过不等于应用运行有树错误。

使用 Flutter 的 `--local-engine-src-path`、`--local-engine=host_release`、
`--local-engine-host=host_release` 重编译应用成功。runner 的临时 `WM_GETOBJECT`
拦截和环境开关已删除，应用默认提供读屏接口。构建脚本包含 Windows 头文件、
wrapper、快照和图标裁剪工具，避免只生成 DLL 后应用无法打包。

这个引擎默认使用 MSAA，UIA 默认关闭，所以 UI Automation 只能读取窗口标题不能
单独判定读屏失效。最终检查直接枚举 Flutter 子窗口的 `IAccessible`：42 个节点，
其中 33 个有名称，包含曲库、歌曲、歌手及操作按钮。

| 完整应用目录 | 曲库歌曲 | 快速返回 | 结果目录（app/build/windows-smoke 下） |
| --- | --- | --- | --- |
| 独立最终候选 | 英雄 / doa | 30 次 | final-candidate-narrator |
| 本机安装 Programs/Tingyu | 一路向北 / 周杰伦 | 30 次 | installed-engine-fix-narrator |

两轮均无闪退、无 AXTree 错误，播放进度持续推进，MSAA 枚举通过；截图确认展开播放页
及返回曲库。`narrator-session.json` 记录讲述人 PID 在测试前后均存在。
讲述人使用 UIAccess，普通进程无法读取其路径；测试清理已改为 Windows 官方启动/退出
快捷键，并已关闭本轮启动的读屏会话。以上验证没有审计实际朗读音频或所有键盘读屏流程。
修复期间没有新增应用 WER dump。

已安装的应用 SHA256：
`1a66b5717ed1c2f1239abf43427baf098d8d1f827ab36e6d995fb2b86e9de0f0`。
已安装的引擎 DLL SHA256：
`13c66fe122ffb6345ffd3d5161fc7a581321eb3b1bf9cbbbcbf47da52cd757e1`。
两者均与最终候选一致。桌面快捷方式继续指向本机安装目录。

Windows CI 已改为固定版本源码初始化、同步、配置、引擎编译、无障碍测试及本地引擎
应用构建；本机初始化脚本和工作流 YAML 检查通过，远端 Actions 尚未运行。
后续 Windows 打包必须采用此流程，普通官方引擎构建会重新引入原始缺陷。
完整操作见 [引擎构建说明](../tools/engine-patches/README.md)。
