# 听屿 (TINGYU)

连接本地文件夹、WebDAV 私人云与夸克网盘的 100% 纯原生 Apple 跨平台音乐播放器。专为 **macOS 15+ (Sequoia)** 与 **iOS 18+** 打造，采用 Swift 6、SwiftUI、SwiftData、AVFoundation、AppIntents 与 WidgetKit 深度构建。

---

## 特性亮点

- **100% Apple 原生架构**：基于 SwiftUI 与 `@Observable` 现代响应式状态模型，极致能效比与流畅 Spring 弹簧物理动效。
- **多音乐源统一接入**：
  - **本地文件夹**：采用 macOS / iOS 原生安全书签（Security-Scoped Bookmarks），持久化保留音乐目录读取授权，安全无干扰；
  - **WebDAV 私人云**：支持群晖、坚果云、Nextcloud 等标准 WebDAV 服务器，RFC 4918 目录解析，温和流控调度；
  - **夸克网盘 (Quark Drive) 原生直连**：内嵌官方 WebKit 安全登录网关，手机扫码秒级授权，两步式目录挑选，动态换取 CDN 签名 Range 直链边下边播。
- **多源智能音乐刮削管线**：
  - **智能文件名噪音清洗 (`SmartTitleParser`)**：智能识别华语音乐 `歌手 - 歌名` 格式，自动剥离音轨号、前导点、`[HQ]`、`(Live)` 等噪音；
  - **QQ 音乐官方正版源 (`QQMusicScraper`)**：周杰伦及华语流行歌曲 100% 正版专辑与 800x800 原生超清封面精准匹配；
  - **权威同步歌词 (`LRCLIBScraper`)**：毫秒级精准 LRC 时间轴滚动歌词；
  - **单曲右键重新匹配**：在曲目列表右键点击即可弹出可视化多候选匹配卡片，用户可自主挑选最契合的版本一键应用。
- **AI 大模型智能识别与洗库**：
  - 兼容标准 OpenAI 协议（`/chat/completions`）；
  - 预设一键切换 **DeepSeek**（调用成本极低）、**通义千问 (Qwen)**、**Kimi**、**OpenAI**、**本地 Ollama**；
  - 提供一键「AI 深度洗库」流水线，将各种乱码或特殊命名文件批量秒级还原为标准歌名、歌手与专辑。
- **Apple 系统级生态深度打通**：
  - **系统媒体中心**：`MPNowPlayingInfoCenter` 与 `MPRemoteCommandCenter`，打通锁屏媒体卡片、控制中心、触控栏与 AirPods 耳机手势；
  - **Siri 快捷指令与 App Intents**：原生注入“在听屿中播放”、“听屿切歌”等语音动作；
  - **桌面与锁屏小组件 (`WidgetKit`)**：提供小号、中号及锁屏胶囊小组件，支持直接点击交互切歌；
  - **iCloud (CloudKit) 多端云同步**：SwiftData 私有数据库跨端自动同步，离线自适应降级。

---

## 工程结构

```text
.
├── project.yml                       # XcodeGen 声明式工程配置
├── Tingyu.xcodeproj                 # Xcode 项目工程
├── Sources/
│   ├── App/
│   │   └── TingyuApp.swift           # App 入口、SwiftData 容器、WindowGroup 与 MenuBarExtra
│   ├── Models/
│   │   ├── Track.swift               # SwiftData 曲目持久化实体
│   │   ├── MusicSource.swift         # 音乐来源实体 (本地文件夹 / WebDAV / 夸克网盘)
│   │   ├── Playlist.swift            # 播放列表实体
│   │   └── LyricLine.swift           # 时间轴 LRC 歌词解析引擎
│   ├── Services/
│   │   ├── Audio/
│   │   │   ├── AudioPlayerService.swift # AVPlayer 低能耗播放引擎、循环模式与队列
│   │   │   ├── NowPlayingManager.swift  # MPNowPlayingInfo & MPRemoteCommands 系统控制
│   │   │   └── SharedPlaybackState.swift # 跨进程 WidgetKit 共享播放状态
│   │   ├── Security/
│   │   │   └── KeychainService.swift    # Apple Keychain 原生凭据存储
│   │   ├── Library/
│   │   │   ├── LocalLibraryScanner.swift # 安全书签与 AVAsset 本地递归扫描
│   │   │   └── LegacyCacheMigrator.swift # 历史缓存自动迁移救援
│   │   ├── WebDAV/
│   │   │   ├── WebDAVClient.swift       # WebDAV async/await 网络客户端
│   │   │   └── WebDAVXMLParser.swift    # WebDAV PROPFIND XML 深度解析器
│   │   ├── Quark/
│   │   │   └── QuarkDriveClient.swift   # 夸克网盘 API 驱动与 CDN 直链解析
│   │   ├── Scraper/
│   │   │   ├── QQMusicScraper.swift     # QQ 音乐正版专辑与超清封面抓取
│   │   │   ├── LRCLIBScraper.swift      # LRCLIB 歌词检索服务
│   │   │   ├── NetEaseScraper.swift     # 网易云公开数据源
│   │   │   ├── iTunesCoverScraper.swift # iTunes Search 国际封面兜底
│   │   │   ├── SmartTitleParser.swift   # 智能文件名清洗与复合结构提取
│   │   │   ├── ChineseConverter.swift   # 原生繁简中文转换
│   │   │   └── MetadataEnricher.swift   # 多源降级并发调度器
│   │   ├── Cloud/
│   │   │   └── CloudSyncManager.swift   # CloudKit iCloud 多端同步管理器
│   │   └── Intents/
│   │       └── TingyuIntents.swift      # App Intents & Siri Shortcuts 快捷指令
│   ├── UI/
│   │   ├── Shared/
│   │   │   ├── CoverArtView.swift       # 封面图片展示与占位
│   │   │   ├── FluidBackgroundView.swift # 动态流体磨砂玻璃渐变背景
│   │   │   ├── AnimatedLyricsView.swift # Apple Music 级动态时间轴歌词
│   │   │   ├── PlaybackControls.swift   # 进度条与播放控制组件
│   │   │   ├── TrackRowView.swift       # 曲目行、上下文菜单与重新匹配入口
│   │   │   ├── SourceManagerView.swift  # 本地、WebDAV 与夸克来源管理器
│   │   │   ├── AddQuarkSheet.swift      # 夸克网盘扫码与目录选择面板
│   │   │   ├── AISettingsView.swift     # AI 大模型智能识别与洗库设置
│   │   │   └── ManualMatchSheet.swift   # 单曲右键重新匹配元数据弹窗
│   │   ├── macOS/
│   │   │   ├── MacOSContentView.swift   # macOS NavigationSplitView 主界面
│   │   │   ├── MacOSPlayerBar.swift     # 悬浮磨砂玻璃底栏
│   │   │   └── MacOSMenuBarExtra.swift  # 顶部菜单栏控制器
│   │   ├── iOS/
│   │   │   ├── IOSContentView.swift     # iOS TabView 导航界面
│   │   │   ├── IOSMiniPlayer.swift      # 悬浮 MiniPlayer 胶囊
│   │   │   └── IOSNowPlayingSheet.swift # 全屏沉浸播放器与歌词面板
│   │   └── Widgets/
│   │       └── TingyuWidget.swift       # 桌面与锁屏交互小组件 (WidgetKit)
│   └── Resources/
│       ├── Assets.xcassets/          # 1024x1024 通用高清应用图标
│       ├── Tingyu-macOS.entitlements # macOS 沙盒与安全书签授权
│       ├── Tingyu-iOS.entitlements   # iOS CloudKit 授权
│       ├── Info-macOS.plist          # macOS 应用配置
│       └── Info-iOS.plist            # iOS 应用配置 (后台音频播放等)
└── dist/
    ├── Tingyu-macOS.dmg             # 发布版 macOS DMG 安装镜像 (约 1.6 MB)
    └── Tingyu-macOS.zip             # 发布版 macOS 绿色压缩包 (约 1.2 MB)
```

---

## 开发与构建

### 运行环境要求
- macOS 15.0+
- Xcode 16.0+
- Command Line Tools (`xcode-select --install`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### 快速开始

1. **生成或更新 Xcode 工程**：
   ```bash
   xcodegen generate
   ```

2. **使用 Xcode 打开工程**：
   ```bash
   open Tingyu.xcodeproj
   ```
   在 Xcode 顶部选择 `Tingyu-macOS` 或 `Tingyu-iOS` Target 即可直接运行或调试。

3. **命令行构建 macOS Release 产物**：
   ```bash
   xcodebuild -project Tingyu.xcodeproj \
              -scheme Tingyu-macOS \
              -destination 'platform=macOS' \
              build
   ```
