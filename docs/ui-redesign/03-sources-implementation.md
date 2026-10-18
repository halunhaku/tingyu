# P3 · 声档来源管理页实施记录

2026-10-18。用户此前已确认方向 C「声档」与 P2 v0.1。本轮在
`codex/ui-p3-sources` 分支从曲库节点 `ac44d79` 继续，只迁移来源管理页
`/sources` 及其卡片组件。业务状态、协议接入、凭据存储、数据库、路由和播放引擎
继续复用现有实现。

来源页最终截图与对应 Golden 仍等待用户单独批准。本轮没有更新任何 Golden，
也没有把工程复核写成视觉定稿。

## 实施范围

- 页头显示来源总数、曲目总数与读取状态，桌面使用“添加来源”按钮，compact
  使用保留无障碍标签的添加图标。
- 新增来源总览，直接显示来源数、曲目数和当前连接/同步数量。
- 来源卡片重排为类型与序号、名称、连接状态、类型和同步信息、路径或账号、
  曲目数、主操作和更多菜单。
- 同步中保留确定进度、扫描计数和可见的“同步中”状态；夸克认证失败时，主操作
  由“重试”改为“重新登录”；本地目录和 WebDAV 失败仍走原有重试。
- 空态提供本地目录、WebDAV、夸克网盘三个明确入口，并说明扫描不会自动上传文件。
- 读取失败使用独立的错误标题、清理后的原因和重试入口，不向用户暴露内部
  `Bad state:`、`Exception:` 或 `StateError:` 前缀。
- compact 在 130% 以上字号把状态徽标移到名称下一行，并让主操作独占一行，
  避免 200% 字号把来源名挤成单字换行。
- `/sources` 使用局部 `VoiceArchiveColors`，应用外壳的声档主题也只扩展到该路由；
  其他页面继续使用原主题。

以下行为保持原实现：

- `sourcesProvider`、`sourceSyncProvider` 与对应的 Riverpod 依赖关系；
- 本地目录、WebDAV 与夸克的添加流程；
- 同步、补全元数据、重新登录、复制诊断信息、删除和来源详情路由；
- 安全存储、数据库、系统目录授权和远程协议客户端。

主要落点：

- [sources_page.dart](../../app/lib/features/sources/sources_page.dart)
- [source_card.dart](../../app/lib/design/components/source_card.dart)
- [source_status.dart](../../app/lib/features/sources/source_status.dart)
- [app_shell.dart](../../app/lib/design/layout/app_shell.dart)
- [voice_archive_preview.dart](../../app/tool/voice_archive_preview.dart)
- [source_archive_fixtures.dart](../../app/tool/source_archive_fixtures.dart)

## 固定预览

[voice_archive_preview.dart](../../app/tool/voice_archive_preview.dart) 现在支持
固定来源夹具。数据只包含三条虚构来源、228 首虚构曲目和固定同步日期，不读取数据库、
网络、系统凭据或真实目录。

```text
TINGYU_DEBUG_ROUTE=/sources
TINGYU_PREVIEW_STATE=normal|syncing|empty|relogin|error
TINGYU_DEBUG_THEME=light|dark
TINGYU_DEBUG_DENSITY=compact
TINGYU_PREVIEW_SCALE=2
```

固定预览复现时，应用必须使用仓库内补丁引擎：

```powershell
flutter "--local-engine-src-path=F:/project/tingyu/app/build/flutter-engine/checkout/engine/src" `
  "--local-engine=host_release" "--local-engine-host=host_release" `
  build windows --release -t tool/voice_archive_preview.dart
```

截图由 [windows-ui-screenshots.ps1](../../tools/windows-ui-screenshots.ps1) 为每个状态
启动独立进程，关闭动画并复用固定夹具。九张实际运行截图、尺寸、DPI、字体渲染条件与
SHA256 见 [来源页证据](p3-sources-evidence/results.md) 和
[capture-manifest.json](p3-sources-evidence/capture-manifest.json)。

## 视觉审查与返工

| 位置 | 类型 / 严重性 | 检查发现 | 修复结果 |
|---|---|---|---|
| 手机 390dp · 来源名称与状态徽标 | 响应式排版 / 高 | 200% 字号时徽标挤压名称，可能出现单字换行 | 大于 130% 字号时状态另起一行；200% 截图和位置断言通过 |
| 手机 · 夸克会话失效 | 恢复路径可见性 / 高 | 失败来源原本位于第三张卡，首屏看不到“重新登录” | 夹具把失败来源放到首位；首屏可直接看到恢复按钮 |
| 手机 · 读取失败 | 状态文案 / 中 | 错误详情暴露了内部 `Bad state:` 前缀 | 统一移除内部异常前缀，专项测试通过 |
| 固定截图 · 同步日期 | 可复现性 / 中 | 相对时间会随执行日期漂移 | 夹具固定为 2026-10-06、2026-10-05、2026-10-04 |

本轮只触发一次自动返工。返工后重新构建预览并重拍全部九张截图，未再发现需要继续
修改的具体视觉问题。这个结论只覆盖 Windows 固定夹具实际渲染，不替代用户批准、
Android/iOS 真机、远程来源或人工读屏验收。

## 门禁结果

| 门禁 | 结果 |
|---|---|
| `dart format --set-exit-if-changed` | 7 个文件、0 个待改动 |
| `flutter analyze` | 通过，无问题 |
| 来源页与来源同步重点回归 | 23/23 通过 |
| 全量非 Golden | 361 项中 360 通过、1 失败；唯一失败为 Windows 缺少 `chmod` 的既有环境问题 |
| Golden 只校验 | 10 通过、2 失败；来源页 14.31%，播放舞台 100%，均未更新 |
| 固定预览 Release | 通过 |
| 生产 Release | 通过 |
| Windows 本地播放与导航冒烟 | 通过；10 次循环未退出，`media_kit (libmpv)` 播放到约 19.51 秒 |

完整命令、退出码、截图和原始日志见
[P3 来源管理证据](p3-sources-evidence/results.md)。

## 审批状态与后续

来源管理页的代码和证据已经完成，但 `sources-expanded-light` Golden 当前有 14.31%
差异，基准没有更新。独立播放舞台 `stage-compact-dark` 仍有继承的 100% 差异，也不能
随来源页一起批准。两项都保留原基准。

可执行的下一阶段顺序：

1. 用户检查九张固定来源截图和当前交互，给出明确批准或逐项返工要求。
2. 获得批准后，只为已批准来源 Golden 建立独立更新提交；如需补 compact Golden，
   先新增固定状态和固定字体测试，再单独请求基准批准。
3. 播放舞台继续等待单独视觉批准，不与来源页 Golden 合并。
4. 在受控凭据环境验证真实 WebDAV、夸克扫描与播放，并补 Android/iOS/macOS/Linux
   实机冒烟。
5. 来源页批准后才进入下一组页面迁移，保持一次一个页面或一组关联组件、独立提交和
   可回退节点。

当前限制：

- 本轮只验证 Windows；
- 固定预览不能证明真实夸克或 WebDAV 会话、同步和远程播放；
- 尚未完成人工 Narrator/VoiceOver/TalkBack 和完整键盘焦点走查；
- Widget 测试、静态分析和截图不能替代真实设备与用户视觉批准。
