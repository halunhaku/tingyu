# P4 实际运行视觉审查

生成时间：2026-10-19T10:21:06.3034526+08:00

固定数据、Windows DPI 1.5、固定字体、固定客户区、关闭动画；逐像素比较 P4 清洁运行时基准。

| 用例 | 视口 | 差异像素 | 差异比例 | 结论 |
|---|---:|---:|---:|---|
| `library-desktop-dark` | 1898×1024 | — | — | 失败 |
| `library-mobile-scale2-light` | 585×1266 | — | — | 失败 |
| `sources-desktop-syncing-dark` | 1898×1024 | — | — | 失败 |
| `sources-mobile-relogin-dark` | 585×1266 | — | — | 失败 |
| `stage-desktop-light` | 1898×1024 | — | — | 失败 |
| `stage-mobile-dark` | 585×1266 | — | — | 失败 |

## 可执行问题

| 用例 / 位置 | 问题类型 | 严重性 | 明确修复要求 |
|---|---|---|---|
| library-desktop-dark，采集或环境阶段 | 视觉回归 / 运行时差异 | 高 | 按错误日志修复可复现条件；未经设计批准不得更新基准。错误：Runtime capture failed; see F:\project\tingyu\docs\ui-redesign\p5-evidence\rework-round-1\runtime-visual\library-desktop-dark\capture.log |
| library-mobile-scale2-light，采集或环境阶段 | 视觉回归 / 运行时差异 | 高 | 按错误日志修复可复现条件；未经设计批准不得更新基准。错误：Runtime capture failed; see F:\project\tingyu\docs\ui-redesign\p5-evidence\rework-round-1\runtime-visual\library-mobile-scale2-light\capture.log |
| sources-desktop-syncing-dark，采集或环境阶段 | 视觉回归 / 运行时差异 | 高 | 按错误日志修复可复现条件；未经设计批准不得更新基准。错误：Runtime capture failed; see F:\project\tingyu\docs\ui-redesign\p5-evidence\rework-round-1\runtime-visual\sources-desktop-syncing-dark\capture.log |
| sources-mobile-relogin-dark，采集或环境阶段 | 视觉回归 / 运行时差异 | 高 | 按错误日志修复可复现条件；未经设计批准不得更新基准。错误：Runtime capture failed; see F:\project\tingyu\docs\ui-redesign\p5-evidence\rework-round-1\runtime-visual\sources-mobile-relogin-dark\capture.log |
| stage-desktop-light，采集或环境阶段 | 视觉回归 / 运行时差异 | 高 | 按错误日志修复可复现条件；未经设计批准不得更新基准。错误：Runtime capture failed; see F:\project\tingyu\docs\ui-redesign\p5-evidence\rework-round-1\runtime-visual\stage-desktop-light\capture.log |
| stage-mobile-dark，采集或环境阶段 | 视觉回归 / 运行时差异 | 高 | 按错误日志修复可复现条件；未经设计批准不得更新基准。错误：Runtime capture failed; see F:\project\tingyu\docs\ui-redesign\p5-evidence\rework-round-1\runtime-visual\stage-mobile-dark\capture.log |

本报告只覆盖 Windows 固定运行时；跨平台设备、真实远程来源和人工读屏仍需独立验收。
