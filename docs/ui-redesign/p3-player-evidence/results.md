# 验证结果 · 2026-10-18

| 门禁 | 实际结果 | 原始证据 |
|---|---|---|
| Flutter 静态分析 | 通过，无问题 | [日志](analyze-final.txt) |
| 全量单元 / Widget | 344通过，1跳过，1失败；失败是既有Windows缺少chmod | [日志](full-tests-verified.txt) |
| 布局 / 性能定点复核 | 通过，保留封面及页面零重建检查，新增桌面元信息完整可见断言 | [日志](final-layout-tests.txt) |
| Golden（批准前） | 11通过，舞台1项差异；当时没有更新基准 | [日志](golden-final.txt)、[批准前差异](golden-diffs/stage-compact-dark_isolatedDiff.png) |
| Golden（批准后） | 12/12通过；只更新已批准舞台基准 | [校验日志](../p3-sources-evidence/golden-approved-test.txt)、[批准记录](../p3-sources-evidence/golden-approval.txt) |
| 固定数据与生产Windows构建 | 两种入口均构建成功，使用仓库固定的本地引擎 | [夹具构建](preview-build-final.txt)、[生产构建](production-build-final.txt) |
| 真实音频播放 | media_kit/libmpv进入ready/playing，120秒本地音频位置持续递增，进程未退出 | [结果](production-smoke-final/result.json)、[快照](production-smoke-final/stdout.log) |
| 舞台开合冒烟 | 旧脚本使用坐标，截图证明未实际打开舞台；不计作开合验证通过 | [截图](production-smoke-final/02-expanded.png) |
| 生产舞台路由 | 真实主入口通过调试路由渲染舞台，缺封面占位可见；短音频已结束，不作为持续播放证明 | [截图](production-stage/stage.png)、[记录](production-stage.txt) |
| 原生无障碍 | 未通过验证：MSAA探针PowerShell7编译失败；UIA命名节点只有1，不宣称读屏可用 | [错误](production-smoke.txt) |
| 设计令牌 | 198组对比度检查通过，批准令牌散列保持一致 | [验证报告](../p2-evidence/token-validation.json) |

## 最终运行截图

截图来自真实Flutter进程的固定数据入口；不是位图套壳，也不是真实音频链路证明。

- [桌面浅色](desktop-light-final/stage.png) / [桌面深色](desktop-dark-final/stage.png)：首轮裁切已修复，标题、歌手、专辑完整呈现，当前与接下来明确分组。
- [手机深色队列](mobile-dark-final/stage.png) / [手机浅色歌词空态](mobile-light-final/stage-tab-lyrics.png)：封面、进度、控制、预览均可见，预览没有溢出。
- [失败状态](failure/stage.png)：错误原因和重试明确，不呈现正常暂停图标。
- [未知时长](unknown/stage.png)：显示 `--:--`，不可拖动。
- [横窗2倍字](long-landscape-final/stage.png)：封面/元信息区域需滚动，控制和歌词、队列入口可见。截图验证了降级，不代表长标题无需滚动。
- [无播放空态](empty-final/stage.png)。

失败和未知时长在返工前采集；返工只改变非compact封面预算，这两项compact画面不受影响。最终横窗及空态已补拍。

用户于 2026-10-18 明确批准舞台视觉。`stage-compact-dark` 只按具名用例更新，
SHA256 为
`0cf05d3588fcee2a77a0f9bd456ae23f542e1431dbef6898cac2e747142487c1`；
不带 `--update-goldens` 的完整 Golden 校验为 12/12。批准前差异图保留为历史证据。

未执行跨平台设备、远程来源或人工读屏验收。当前状态为“本页实现已交付且视觉与固定
Golden 已批准，跨平台、远程来源和人工无障碍门禁待补齐”，不是全部P3/P4完成。
