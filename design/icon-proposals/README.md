# 听屿图标设计提案

状态：用户已选择 A「声屿」，并于 2026-10-27 授权统一替换。A 已接入现役 client/；B、C 仅作为提案保留。

## 定位与视觉依据

- 现役应用：`client/`，macOS 本地 / WebDAV / 夸克网盘音乐播放器；品牌关键词：私人曲库、沉浸聆听、原生桌面。
- `README.md` 与 `client/resources/icon.png`：红粉渐变底、深色音符。
- 以当前 `client/internal/ui/tokens/tokens.go` 为配色依据：浅底 #F4F4F1、深底 #0E0E10；浅色强调 #B01B2E、深色强调 #F26D7E。历史 Flutter 琥珀规范不作为当前配色。
- `client/internal/ui/components/icons.go`：24 单位网格、1.8 描边、圆端点与圆连接。

## 三个方向

| 方向 | 表达 | 适用判断 |
|---|---|---|
| A 声屿 | 双音符与水面波纹，红粉渐变 | 推荐；品牌延续最好，呼应「屿」 |
| B 涟漪 | 唱片中心与两段同心声波，青绿渐变 | 更安静、偏沉浸音乐体验；涉及品牌配色调整 |
| C 声档 | 档案容器与播放三角，靛蓝渐变 | 更强调私人曲库与整理；涉及品牌配色调整 |

方向差异集中于应用标志、曲库及专辑图标；播放、搜索、来源、收藏等通用动作保留一致语义，避免增加学习成本。

## 文件与使用

每套 37 个 SVG：32 个功能轮廓图标、1 个品牌轮廓、收藏填充态、1024px 应用图标、深浅品牌轮廓各 1 个。

- `a-sound-island/`、`b-resonance/`、`c-sound-archive/`：独立 SVG，可复制到资源目录或传给 SVG 解析器。
- `preview.svg.png`：三方向 PNG 预览。
- `preview.svg`：可放大矢量对比图。
- `preview.html`：本地浏览预览及完整文件目录。
- `generate.py`：可复现 SVG 生成脚本，仅使用 Python 标准库。
- `manifest.json`：规格记录。

功能图标统一 `viewBox="0 0 24 24"`、`stroke-width="1.8"`、`stroke-linecap="round"`、`stroke-linejoin="round"`，主要内容位于 3–21 单位范围，矩形圆角为 2–3 单位。输出尺寸 16 / 24 / 32 对应描边约 1.2 / 1.8 / 2.4px。

轮廓使用 `currentColor`。网页内联 SVG 时可继承 CSS `color`；用 `<img>` 引用时不会继承宿主元素颜色，需使用明确配色版本或在宿主渲染器中设定颜色。浅色功能图标建议 #17171A，深色建议 #F3F3F5。品牌使用各目录的 `brand-light.svg` / `brand-dark.svg`。

应用图标为矢量母版；尚未转换为 macOS .icns，也未写入 bundle。功能图标仍需在接入阶段验证 MyGo SVG 解析与当前颜色传递，不能把本地预览视为运行时验收。

## 清晰度检查

112 个 SVG 全部通过 XML 解析。PNG 预览已实际渲染并目视检查：三个品牌在深浅背景的 16 / 24 / 32px，以及播放、收藏、搜索、文件夹、同步、设置六类典型功能图标的三个尺寸。

24 / 32px 轮廓舒展；16px 能保留主轮廓，但 A 的音符内孔、B 的唱片内圈、C 的播放三角细节更紧凑，推荐品牌侧栏采用 24px 以上。预览页须以 100% 缩放查看原尺寸。其余功能图标已给出文件与 24px 分类示例，尚未逐一进行全部尺寸的实机验收。

选定方向后再做目标渲染器验证、必要的 16px 专用光学校正和应用资源接入。


## A 方案接入记录（2026-10-27）

- 运行时资源：`client/internal/ui/components/icons/`，34 个 SVG，使用 go:embed 编译进应用。
- 应用内 AppMark 使用品牌音符与水波；普通音乐占位继续使用 music 图标。
- 侧栏与来源卡片按 local / webdav / quark 显示对应图标。
- Dock 母版：`client/resources/icon.svg`；构建输入：`client/resources/icon.png`。
- 菜单栏模板：`client/internal/app/tray.png`，32px 透明黑色模板，由 macOS 自动着色。
- PNG 可通过 `client/scripts/generate-icon.swift` 重建；绘制几何与已批准 SVG 对应。
- 实际 MyGo 渲染预览：`runtime-preview.png`，包含全部 34 个图标的深浅背景与 16 / 24 / 32px。
- 可复现预览：在 client/ 执行 `go run ./tools/iconpreview`。
- 验证：components + shell 共 779 项通过；app 4 项通过。并行打包时一次舞台冷帧性能测试超预算，独立复测通过；app 模拟服务测试在允许临时本地端口后通过。
- 已完成本地 ad-hoc 签名打包及脚本内签名验证：`client/build/darwin-arm64/听屿.app`。
- 未替换 /Applications 中的已安装应用，未重启正在运行的实例。
