<!-- project-status:start -->
## 项目状态与入口

- **维护状态**：候选主线 · 保留项目，按实际使用需求投入。
- **项目入口**：现役代码位于 `app/`，当前为 2.0.0 预览阶段；运行与安装说明见下方文档。
- **项目导航**：[全部项目与维护安排](https://github.com/halunhaku)。

<!-- project-status:end -->

# 听屿 (TINGYU)

> **连接本地文件夹、WebDAV 私人云与夸克网盘的 macOS 音乐播放器。**
> 现只维护 **macOS 单端**：Windows / Linux / Android / iOS 的 Flutter 代码与构建流水线已删除；界面沿袭 Apple Music 的红粉强调色、磨砂材质与流体播放舞台。

> [!NOTE]
> 现役实现是 **`app/`（Flutter，仅 macOS）**；上一版 SwiftUI 实现整体归到 **`legacy-swift/`**（`Sources/`、`Tingyu.xcodeproj/`、`project.yml`），**冻结不再演进**，只作移植参考。
> `docs/` 下的迁移方案、审计与报告是历史档案，保留原文，不再随平台收缩改写。

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter" alt="Flutter" />
  <img src="https://img.shields.io/badge/Dart-3.13-0175C2?logo=dart" alt="Dart" />
  <img src="https://img.shields.io/badge/Platform-macOS-blue" alt="Platform" />
  <img src="https://img.shields.io/badge/Storage-drift%20(SQLite)-green" alt="drift" />
  <img src="https://img.shields.io/badge/Accent-%23FA243C-red" alt="Apple Music Red" />
</p>

---

## 界面预览

### 曲库主界面
侧栏（曲库 / 最近添加 / 艺术家 / 专辑 / 收藏 + 来源 + 播放列表）、带封面的曲目列表与底部悬浮播放条：

<p align="center">
  <img src="docs/screenshots/flutter-library.png" width="900" alt="听屿 曲库主界面" />
</p>

### 全屏「正在播放」与待播清单
随封面取色的流体渐变舞台、超细进度条与传送器，右侧是实时待播队列：

<p align="center">
  <img src="docs/screenshots/flutter-now-playing.png" width="900" alt="全屏正在播放与待播清单" />
</p>

### 来源管理
夸克网盘 / WebDAV / 本地目录三类来源的同步状态、重新登录与添加入口：

<p align="center">
  <img src="docs/screenshots/flutter-sources.png" width="900" alt="来源管理" />
</p>

### 窄窗布局
窗口收窄到 compact 宽度时，来源改成一来源一卡片：标题、状态、操作分行摆放，删除收进右上角菜单（整张卡片可点进详情）：

<p align="center">
  <img src="docs/screenshots/mobile-sources-after.png" width="360" alt="窄窗来源管理" />
</p>

> `main-window.png` 与 `now-playing-fullscreen.png` 是上一版 SwiftUI 实现的截图，保留在同目录作对照。

---

## 特性亮点

### 1. 播放内核：libmpv 单引擎
- 用 `media_kit`（libmpv）：统一解码、gapless、缓冲可控、任意 URL + 自定义请求头。引擎由 `playback/engine_factory.dart` 注入，界面只认 `PlaybackEngine` 接口。
- **系统媒体会话**由 `audio_service` 一套 `AudioHandler` 接通 macOS Now Playing 与媒体键。
- 待播队列（列表内点击即插播）、时间轴歌词（自动滚动 + 当前行高亮 + 一键抓取）、迷你播放条与全屏「正在播放」舞台。
- 加载失败不再静默：失败写进播放快照并在界面提示（`PlaybackFailure`）。
- 循环/随机是真的下发给引擎的（`LoopMode.one` / `PlaylistMode.single`），不是只在界面上换图标；
  播完停止后再按播放键会从头重放，不会卡在"点了没反应"。
- 界面不会跟着进度条一起重画：进度 tick 只重建进度条本身（详见 §31.3）。

### 2. 三种音乐来源，原生直连
- **本地文件夹**：macOS 直接读文件系统路径，系统目录选择器授权后扫描入库。
- **WebDAV**：群晖 / 坚果云 / Nextcloud 等标准 WebDAV，PROPFIND 解析目录，带鉴权头取流。
- **夸克网盘**：应用内官方网页登录 / 扫码登录 / Cookie 导入，目录挑选后动态换取 CDN 直链播放。

### 3. 多源元数据刮削
- 文件名清洗（`SmartTitleParser`）识别 `歌手 - 歌名`，剥离音轨号、前导点、`[HQ]`、`(Live)` 等噪音；
- QQ 音乐 / 网易云 / iTunes / LRCLIB 多源降级抓取封面与歌词；繁简转换用内置 OpenCC 字表；封面与歌手写真落盘缓存；
- 单曲可「重新匹配」，在多候选中人工挑一个覆盖。

### 4. 数据与凭据
- 曲库落在 drift(SQLite)：`tracks` / `music_sources` / `playlists`；扫描按 `filePathOrUrl` 合并（整轮一个 batch），分别统计新增 / 更新 / 移除；只有完整扫描会移除未见曲目，取消、截断、跳过条目、目录层级超限、响应无法解析都会让本次扫描**不具权威性**，从而保留旧曲目及其收藏、歌单引用；
- 封面按内容哈希落盘（同一张专辑封面只存一份），完整同步后自动回收不再被引用的旧图；
- 时长从解码器回填：夸克/WebDAV 的目录接口不报时长，播过一次之后界面就是真实时长；
- 本地目录重复同步近似空转：大小与修改时间都没变的文件跳过标签解析与封面写盘；
- 夸克 Cookie、WebDAV 密码等凭据进 macOS Keychain（开发构建无签名时回退为仅本人可读的本地文件）；
- 旧版曲库可用 `tools/legacy-export/` 一次性导出后导入。

### 5. 与上一版 SwiftUI 实现的差异
- **已对齐**：曲库 / 最近添加 / 收藏、专辑与艺术家浏览、播放列表、播放条与全屏舞台、歌词、队列、来源管理与同步、人工匹配、设置页、AI 智能识别与洗库（`AIService` / `AIMetadataParser` / `AISettingsPage`）。
- **尚未迁移**：macOS 原生三件套（WidgetKit 小组件、App Intents / Siri、AirPlay 路由选择器）——见 `docs/crossplatform-migration.md` §18 的 M6。

---

## 工程结构

```text
.
├─ app/                                        # 现役 Flutter 工作区
│  ├─ lib/
│  │  ├─ main.dart                             # 入口：装配、AudioHandler、调试入口
│  │  ├─ app/                                  # router · theme · providers · playback_controller · track_resolver · source_adapters
│  │  ├─ data/                                 # db/(schema + database + drift 生成) · models/ · repositories/
│  │  │                                        #   cover_store · secure_store · legacy_import · enrichment_service
│  │  ├─ sources/                              # local/(扫描器) · webdav/ · quark/ · scraper/
│  │  ├─ playback/                             # playback_engine · engine_factory · media_kit_engine
│  │  │                                        #   playback_item · playback_snapshot · tingyu_audio_handler
│  │  └─ features/                             # library · albums · artists · playlists · player · sources · settings · shell · shared
│  ├─ macos/                                   # 唯一保留的平台工程（Runner + Podfile）
│  ├─ assets/                                  # 应用图标 · OpenCC 字表
│  └─ test/                                    # flutter_test 测试（解析器 / 数据层 / 播放队列 / 来源）
├─ docs/                                       # 历史档案（审计 / 迁移方案 / UI 走查证据），保留原文
│  └─ screenshots/
├─ tools/legacy-export/                        # 旧版 SwiftUI 曲库的一次性导出工具
├─ legacy-swift/                               # 上一版 SwiftUI 实现：Sources/ · Tingyu.xcodeproj/ · project.yml，冻结保留
└─ .github/workflows/flutter.yml               # analyze + test（含 drift 生成代码校验）+ macOS 构建
```

---

## 开发与构建

### 环境
- **Flutter 3.47+**（开发机：3.47.2 / Dart 3.13.2）
- **macOS**：Xcode（CocoaPods 由 Flutter 自动驱动）

### 常用命令
```bash
cd app

flutter pub get

# 跑起来
flutter run -d macos

flutter analyze
flutter test

# 打包
flutter build macos --release        # → build/macos/Build/Products/Release

# 改了 data/db/schema.dart 之后必须重新生成（CI 会校验生成代码是否同步）
dart run build_runner build
```

视觉基线（不替代人工走查）：`cd app && flutter test --run-skipped -t golden`
校验核心页面基准图；改版后确认版式是有意变的，用 `--update-goldens` 重新生成并 review 差异。

### 调试入口（`main.dart` 读取的环境变量）
| 变量 | 作用 |
|---|---|
| `TINGYU_DEBUG_ROUTE=/sources` | 启动即打开某个页面（截图 / 排查用） |
| `TINGYU_DEBUG_THEME=dark\|light` | 启动即覆盖主题偏好（走查深浅色用；只影响本次进程，不写回设置） |
| `TINGYU_DEBUG_DENSITY=compact\|comfortable` | 启动即覆盖界面密度（走查紧凑密度用） |
| `TINGYU_DEBUG_SCAN_DIR=<目录>` | 在真实进程里跑一次「扫描 → 合并入库」并打印结果 |
| `TINGYU_DEBUG_LEGACY_JSON=<文件>` | 导入旧版导出的曲库 JSON |
| `TINGYU_DEBUG_SOURCES=<a,b,...>` | 启动即载入队列并播放，便于脚本化验证播放链路 |

### CI
`.github/workflows/flutter.yml`：推到 `main` 或改动 `app/**` 的 PR 在 Ubuntu 上跑
`dart run build_runner build` 校验 drift 生成代码无漂移、`flutter analyze` 与 `flutter test`；
随后在 macOS runner 上构建 `flutter build macos --release` 并上传产物；推 `v*` tag 时额外发 Release。

> 注意 `on.push` 必须同时写 `branches` 与 `tags`：只写 `tags` 会让分支推送**完全不触发**
> 这个 workflow（GitHub 的行为，已在 §31.8 记录踩坑经过）。

> 本机跑 `flutter analyze` 时，若仓库路径含非 ASCII 字符，analysis server 的 LSP 通道会解析崩溃；
> 用 `dart analyze` 得到同样的结论。

---

## 平台与验证状态

| 平台 | 状态 |
|---|---|
| **macOS 12+** | ✅ 唯一支持平台：播放与系统媒体会话、曲库 / 专辑 / 艺术家 / 播放列表、全屏舞台与歌词、来源管理均已实机核验（本文截图即本机实拍）；`flutter build macos --debug` 产物可启动 |

里程碑进度：**M0–M5 已完成**；M6（macOS 原生增强：WidgetKit / App Intents / AirPlay）未开始。
2026-09-26 做过一轮全面优化（数据丢失修复、播放正确性与重建风暴、封面去重 91%、索引迁移、来源重试），
结论与"明确未做"的清单见 [`docs/crossplatform-migration.md`](docs/crossplatform-migration.md) §31（历史档案，其中跨平台口径已不适用于当前 macOS 单端）。

---

## 开源协议与声明

- 本项目基于 [MIT License](LICENSE) 开源。
- **免责声明**：本项目定位为**个人私有云盘与本地音频播放工具**。应用自身不内置、不提供、不分发任何受版权保护的音乐音频资源，所有播放内容均来源于用户合法拥有的个人存储或第三方网盘授权。
