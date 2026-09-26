# 听屿 跨平台迁移方案 v1（Flutter）

> 目录变更：旧版 SwiftUI 实现（原根目录的 `Sources/`、`Tingyu.xcodeproj/`、`project.yml`）已于 2026-09-14
> 整体移入 `legacy-swift/`；下文出现的 `Sources/...` 等旧路径，一律按 `legacy-swift/Sources/...` 理解
> （正文保留当时的写法，不改历史记录）。
>
> 状态：**已批准**（2026-09-11）。M0–M5 已完成（结论见 §13–§15、§17、§19–§24）；进度与剩余里程碑见 §18；本机音频异常（2026-09-14 复核已恢复）见 §16。
> 日期：2026-09-11
> 依据：仓库实测（`Sources/` 61 个 Swift 文件 / 8837 行）、`project.yml`、以及公开生态现状核查。

---

## 0. 已确认决策（本轮）

| 编号 | 决策 | 结论 |
|---|---|---|
| D1 | 跨平台目标 | macOS + Windows + Linux + Android + **iOS** |
| D2 | 统一栈 | Flutter（Dart），一套 UI + 一套业务逻辑 |
| D3 | macOS 观感降级 | 接受 |
| D4 | 现有 Swift 版 macOS 应用 | **冻结维护**（只修 bug），Flutter 版成熟后取代 |
| D5 | 播放引擎 | **双引擎**：桌面 `media_kit`(libmpv) + 移动 `just_audio`，统一 `PlaybackEngine` 抽象 |
| D6 | macOS 原生能力 | **全部保留**：WidgetKit 小组件、App Intents、AirPlay（各留一个 Swift 扩展 / 通道） |
| D7 | macOS 分发 | 保持现状：Developer ID 签名 + 公证 + 自更新，**不上 Mac App Store**（不受 App Sandbox 强约束） |
| D8 | 仓库布局 | monorepo：Flutter 工作区 `app/`，方案文档 `docs/crossplatform-migration.md` |
| D9 | 首个里程碑范围 | M0 骨架 + M1 技术验证闸门（三平台播放与系统媒体面板） |

---

## 1. 目标与非目标

**目标**
- 一套 Dart 代码覆盖 macOS / Windows / Linux / Android / iOS（现有 SwiftUI iOS 版由 Flutter 版取代）。
- 保留产品的差异化解码能力：多源曲库（本地 / WebDAV / Quark）、抓取式元数据与歌词、AI 元数据解析、歌词动画与流体背景。
- 保留 macOS 的三个 Apple 原生能力（小组件、快捷指令、AirPlay）。
- 三平台分发链路可自动化：DMG+公证 / MSIX 签名 / Flatpak+AppImage / APK+AAB。

**非目标**
- 不追求 macOS 像素级还原 SwiftUI 版本。
- 不引入 DRM 解密（Apple Music / QQ音乐加密格式依旧不支持，与当前能力上限一致）。
- 不保留 Swift 版与 Flutter 版的双向数据同步（仅提供一次性导出/导入迁移）。

---

## 2. 现有资产盘点与处置判定（实测）

| 层 | 文件 / 行数 | 处置 | 说明 |
|---|---|---|---|
| `App/TingyuApp.swift` | 1 / 79 | 重写 | 应用装配、场景声明 → `main.dart` + `app/di.dart` |
| `Models/` | 4 / 231 | 重写（结构复用） | `Track/MusicSource/Playlist/LyricLine` → Dart model + drift table |
| `Services/Audio/` | 4 / 1028 | 重写（逻辑复用） | `AudioPlayerService` 570、`StreamingResourceLoader` 215、`LocalAudioResourceLoader` 125、`NowPlayingManager` 118 |
| `Services/Scraper/` | 8 / 约 800 | 重写（逻辑复用） | QQ音乐 110 / 网易云 113 / LRCLIB / iTunes / `MetadataEnricher` 113 / `SmartTitleParser` 96 / `ChineseConverter` / `ArtistAvatarStore` 91 |
| `Services/Quark/` | 2 / 约 500 | 重写 | `QuarkDriveClient` 410、`QuarkCookieStore` |
| `Services/WebDAV/` | 2 / 333 | 重写 | `WebDAVClient` 239、`WebDAVXMLParser` 94 |
| `Services/Library/` | 4 / 约 460 | 重写 | 扫描 213、分组、同步 81、`LegacyCacheMigrator` 89 |
| `Services/Cloud/` | 1 / 139 | 重写 | `CloudSyncManager` |
| `Services/Security/` | 1 / 89 | 替换 | `KeychainService` → `flutter_secure_storage` |
| `Services/AI/` | 2 / 236 | 重写 | `AIService` 160、`AIMetadataParser` 76 |
| `Services/Intents/` | 1 / 85 | **保留 Swift** | App Intents 扩展 |
| `UI/` | 28 / 4916 | 重写 | 分平台视图结构保留（iOS / macOS 两套布局） |
| `UI/Widgets/` | 3 / 约 300 | **保留 Swift** | WidgetKit 扩展，挂到 Flutter 的 macOS 工程 |
| `Resources/` | plist / entitlements / assets | 迁移 | Flutter 侧重建 + 图标资源复用 |

**结论**：约 3611 行 Service 逻辑需要用 Dart 重写（逻辑可照搬，语言与 API 换），4916 行 UI 全部重写，约 385 行 Swift（Widget 261 + Intents 85 + AirPlay 80 中的原生部分）原样保留。

---

## 3. 技术选型

| 关注点 | 选型 | 理由 / 备注 |
|---|---|---|
| UI 框架 | Flutter（stable） | 桌面三平台生产可用；Android 一等公民；无 WebView 依赖 |
| 状态管理 | Riverpod（`flutter_riverpod`） | 编译期安全、可测试、无 BuildContext 依赖，适合"播放状态 + 曲库状态"两个独立全局源 |
| 路由 | `go_router` | 声明式、深链（`tingyu://`）与 App Intents 触发路由都走它 |
| 本地库 | `drift` + `sqlite3` 3.x（Dart hooks 自带 SQLite，已废弃 `sqlite3_flutter_libs`） | 类型安全 schema、可写迁移；替代 SwiftData |
| 网络 | `dio` | 抓取需要自定义头/超时/重定向控制；上游 Content-Type 五花八门，统一按文本取回后自行 `jsonDecode` |
| 音频标签 | `audio_metadata_reader` | 纯 Dart 读取 mp3/flac/m4a/ogg/opus/wav/aiff 的标签与时长（扫描器用） |
| 繁简转换 | 内置 OpenCC 字表（Apache-2.0） | Flutter 无 ICU 变换 API；逐字转换，接口预留词组级消歧 |
| HTML 解析 | `html`（package:html）+ 正则兜底 | 替代 Swift 侧的抓取解析（M4 起按需引入） |
| XML | `xml` | WebDAV 的 PROPFIND 解析（替代 `WebDAVXMLParser`） |
| 桌面播放 | `media_kit` + `media_kit_libs_*` | libmpv 统一解码、gapless、缓冲可控、支持任意 URL + headers |
| 移动播放 | `just_audio` | ExoPlayer / AVPlayer，功耗与系统集成优于 libmpv |
| 系统媒体会话 | `audio_service`（Android/iOS/macOS）+ `audio_service_win`（SMTC）+ `audio_service_mpris`（Linux MPRIS） | 一套 `AudioHandler` 打通五个平台的 Now Playing / 媒体键 / 锁屏 |
| 安全存储 | `flutter_secure_storage` | Keychain / DPAPI / libsecret，对应 `KeychainService` |
| 桌面外壳 | `window_manager`、`tray_manager`、`launch_at_startup` | 窗口/托盘/开机自启；Linux 托盘依赖 `libayatana-appindicator3` |
| 菜单栏 | macOS：`PlatformMenuBar`；Windows/Linux：应用内 `MenuBar` | `PlatformMenuBar` 官方仅支持 macOS |
| 单实例 | `windows_single_instance` / `local_notifier` | 桌面必备（点击文件/URL 唤起） |
| 本地 HTTP 代理 | `shelf` + `shelf_router` | 把带鉴权头的远程流包装成本地 URL 喂给播放引擎（替代 `StreamingResourceLoader` 语义） |
| 国际化 | `flutter_localizations` + `intl` | 中文优先 |
| 测试 | `flutter_test` + `drift` 内存库 | 只覆盖解析器 / 迁移 / 队列逻辑 |

**打包**
- macOS：`flutter build macos --release` → `codesign --deep`（含嵌套插件与扩展）→ `dmg` → `xcrun notarytool submit` + `stapler`。
- Windows：`flutter build windows --release` → `msix` 包（或 Inno Setup 安装器）→ EV 证书 / Azure Trusted Signing 签名（否则 SmartScreen 拦截）。
- Linux：`flutter build linux --release` → Flatpak（推荐，携带 libmpv/libsecret 依赖）+ AppImage（备选）+ `.deb`。
- Android：`flutter build appbundle` + `apksigner`（Play 上架用 AAB）。

---

## 4. 仓库与目录结构

```
tingyu/
├─ Sources/ · Tingyu.xcodeproj/ · project.yml      # 现有 Swift 版：冻结维护
├─ app/                                            # 新增 Flutter 工作区
│  ├─ pubspec.yaml
│  ├─ analysis_options.yaml
│  ├─ lib/
│  │  ├─ main.dart
│  │  ├─ app/            di.dart · router.dart · theme.dart · l10n.dart
│  │  ├─ core/           result.dart · failures.dart · logger.dart · http_client.dart · atomic_file.dart
│  │  ├─ data/
│  │  │  ├─ models/      scanned_track.dart · library_summaries.dart
│  │  │  ├─ db/          schema.dart · database.dart · database.g.dart（drift 生成）
│  │  │  ├─ cover_store.dart · legacy_import.dart
│  │  │  └─ repositories/ track_repository.dart · playlist_repository.dart · source_repository.dart
│  │  ├─ sources/        local/local_library_scanner.dart · webdav/ · quark/ · scraper/{qqmusic,netease,lrclib,itunes}/
│  │  ├─ playback/
│  │  │  ├─ playback_engine.dart · playback_item.dart · playback_snapshot.dart
│  │  │  ├─ media_kit_engine.dart · just_audio_engine.dart · engine_factory.dart
│  │  │  ├─ tingyu_audio_handler.dart      # audio_service 桥
│  │  │  ├─ queue_controller.dart · lyrics_clock.dart · stream_proxy.dart
│  │  ├─ platform/
│  │  │  ├─ now_playing/ · secure_store/ · autostart/ · airplay/ · single_instance/ · paths/
│  │  │  └─ widget_bridge/                 # 与 Swift 扩展共享 App Group 数据
│  │  ├─ features/      library/ · player/ · playlists/ · sources/ · settings/ · lyrics/ · search/
│  │  └─ channels/      airplay_channel.dart · widget_bridge_channel.dart
│  ├─ macos/   Runner.xcodeproj（含 TingyuWidget / TingyuIntents 扩展 target）
│  ├─ windows/ · linux/ · android/ · ios/
│  ├─ assets/  icons · fonts · default_cover
│  └─ packaging/ dmg/ · msix/ · flatpak/ · appimage/ · scripts/
└─ docs/
```

**分层规则（强制）**
- `features/` 只依赖 `data/`、`playback/`、`platform/` 的接口，禁止 import 具体引擎（`media_kit` / `just_audio`）或具体云端实现。
- `sources/` 不得直接操作 UI 或播放器，只返回 `StreamHandle` / `RemoteEntry`。
- `platform/` 每个能力先定义抽象，再在 `platform/<capability>/<impl>` 提供各平台实现，用 `engine_factory.dart` 风格按 `Platform.is*` 注入。

---

## 5. 核心模块设计

### 5.1 播放子系统

```dart
// playback/playback_engine.dart
abstract interface class PlaybackEngine {
  Stream<PlaybackSnapshot> get snapshots;          // position / duration / buffered / playing / processing
  Future<void> setQueue(List<PlaybackItem> items, {int startIndex = 0});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}
```

- 桌面实现 `MediaKitEngine`：`media_kit.Player.open(Media(url, httpHeaders: ...))`；队列/gapless 用 mpv 的 playlist 能力。
- 移动实现 `JustAudioEngine`：`ConcatenatingAudioSource` 承载队列；`AudioSession` 配置播放类别与音频焦点。
- `engine_factory.dart` 按平台返回实现；**UI 与状态层只依赖抽象**。

```dart
// playback/tingyu_audio_handler.dart
final class TingyuAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  TingyuAudioHandler(this._engine) {
    _engine.snapshots.listen(_pushState);          // → playbackState
    queueController.currentItem.listen(_pushMediaItem); // → mediaItem
  }
  // play/pause/seek/skipToNext/skipToPrevious 全部转发到 PlaybackEngine
}
```

`audio_service` 在 Android/iOS/macOS 直接映射 `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` / MediaSession；Windows 由 `audio_service_win` 映射 SMTC；Linux 由 `audio_service_mpris` 暴露 MPRIS2。**`NowPlayingManager.swift`(118 行) 的职责在 Dart 侧只剩"推 mediaItem + playbackState"。**

**流式来源**：`media_kit` 直接消费 `Media(url, httpHeaders: ...)`，桌面侧**没有** `shelf` 代理；移动侧 `just_audio` 的 `headers` 由**它自己内建的 localhost HTTP 代理**实现（`HttpServer.bind(loopbackIPv4, 0)`，播放器只看到 `http://127.0.0.1:<port>/proxy/...`）。因此 Android 必须放行回环地址的明文流量（见 §23），否则带鉴权头的来源一律加载失败。

### 5.2 来源子系统（M3 已落地）

```dart
abstract interface class SourceAdapter {
  String get sourceId;
  Future<SourceScanResult> scan({void Function(int, String)? onProgress, bool Function()? isCancelled});
  Future<PlaybackItem> open(String filePathOrUrl);   // → URL + 鉴权头（httpHeaders）
}
```

实现：`sources/local/local_library_scanner.dart`（本地目录）、`sources/webdav/`（PROPFIND + Basic 认证）、
`sources/quark/`（Drive 接口 + Cookie 会话 + 直链缓存）。远端适配器只产出 `ScannedTrack`，
入库仍由 `TrackRepository.mergeScan` 负责；`open()` 返回的 `PlaybackItem.httpHeaders`
会被播放引擎（`Media(httpHeaders:)`）原样带给服务器。

元数据抓取不实现 `SourceAdapter`，而是按能力拆成三个窄接口
（`sources/scraper/metadata_provider.dart`）：

| 接口 | 实现 | 用途 |
|---|---|---|
| `MetadataSearcher` | QQ 音乐、网易云 | 搜歌名/歌手/专辑/封面地址 |
| `LyricsProvider` | LRCLIB（主）、网易云（兜底） | 取歌词；LRCLIB 返回的多为繁体，统一转简体 |
| `CoverLookup` | iTunes | 按专辑名/歌手查封面地址 |
| `ArtistLookup` | 网易云 | 艺术家头像地址（`ArtistAvatarStore` 用） |

`MetadataEnricher` 负责编排（管道顺序与旧版 `MetadataEnricher.swift` 一致）：
脏文件名解析 → QQ 音乐主元数据 → LRCLIB 歌词 → 网易云歌词兜底 → 网易云/iTunes 封面兜底。
它只产出 `EnrichmentResult`（纯数据），落盘与写库由 `data/enrichment_service.dart` 完成。

繁→简转换：Flutter 没有 ICU 的 `Traditional-Simplified` 变换，改用内置的 OpenCC 字表
（`assets/opencc/TSCharacters.txt`，Apache-2.0）做逐字转换（不做词组级消歧，接口预留）。

### 5.3 数据层（drift，M2 已落地）

表（`app/lib/data/db/schema.dart`）：`tracks` · `music_sources` · `playlists` · `playlist_items`。
与 §5.3 初版规划相比的收敛：`albums` / `artists` 不建表（用 `GROUP BY` 聚合，见 `TrackRepository.albums/artists`）；
`lyrics_cache` / `match_overrides` / `play_history` 推迟到 M3（歌词与匹配覆盖目前落在 `tracks` 的 `lyrics` 列与后续的抓取层）。

关键约定：

- **主键与匹配**：`tracks.id` 主键；`(source_id, file_path_or_url)` 唯一 —— 扫描合并的匹配键（对齐 `LibrarySync.swift`）。
  本地扫描产生的 id 是 `sourceId::path`（幂等），旧库导入则保留原 UUID。
- **封面不入库**：`cover_art_path` 存 `CoverStore` 管理的文件名（FNV-1a 64 位命名），二进制写应用支持目录；
  避免上千首内嵌封面把 SQLite 撑大、拖慢查询与备份。
- **时间戳按文本存 UTC**（`storeDateTimeAsText`）—— 默认的 Unix 秒会丢毫秒，旧库 `dateAdded` 带毫秒，往返会对不上。
- **外键级联**：`playlist_items` 对 `playlists` 与 `tracks` 都是 `ON DELETE CASCADE`，
  删除曲目/来源不必手工清列表（`beforeOpen` 打开 `PRAGMA foreign_keys`）。
- **扫描合并**：`TrackRepository.mergeScan` 只回写"文件事实"（大小、格式、etag、mtime、时长、封面缺省填充），
  占位元数据（未知艺术家/未知专辑/夸克曲库/WebDAV 曲库/空标题）才允许被真实值替换；
  收藏、播放计数、歌词、已有封面属于用户资产，永不被扫描覆盖。
- **本地扫描**：`LocalLibraryScanner` 支持扩展名与旧版一致；遍历在主 isolate，标签解析分批进
  `Isolate.run`（默认 64 个/批），标签读取用纯 Dart 的 `audio_metadata_reader`（内置 `ffprobe` 不现实）。
  排序说明：旧版用 `localizedStandardCompare`，Dart 侧暂用码点序（中文即 Unicode 序，非拼音），M4 UI 阶段再引入排序键。

### 5.4 macOS 三个 Swift 扩展点（D6）

| 能力 | 形态 | 数据通道 |
|---|---|---|
| WidgetKit 小组件 | 在 `app/macos/Runner.xcodeproj` 内新增 app-extension target，搬运 `TingyuWidget.swift` + `SharedPlaybackState.swift` | App Group（`group.com.halunhaku.tingyu`）共享 JSON/UserDefaults；Dart 侧在播放状态变化时写入 |
| App Intents | 搬运 `TingyuIntents.swift` 到独立 intents target | 扩展无法直接调 MethodChannel：用 App Group 文件 + Darwin notification 唤醒宿主，宿主 Flutter 侧监听并执行 |
| AirPlay | 保留 `AirPlayPickerView.swift`(80)，封装为 `airplay` MethodChannel（仅 macOS） | Dart 侧 20 行胶水，弹出 `AVRoutePickerView` |

**待实测确认**：非沙盒宿主 macOS 应用能否直接使用 App Group 容器（WidgetKit 扩展本身必须沙盒）。若不通过，退路一是固定路径共享文件 + 扩展的 `com.apple.security.temporary-exception.files.absolute-path.read-only` 例外；退路二是给主应用开沙盒（会牵动 Quark/WebDAV 与本地文件访问权限，需权衡）。此项列为里程碑 M1 的验证项。

### 5.5 UI 层结构

- 保留现有"分平台布局"设计：`features/player/` 内 `player_view_macos.dart` / `player_view_mobile.dart`，由断点 + `Platform.is*` 选择；不强行一套响应式布局。
- 自绘组件重写：`FluidBackgroundView`(86) → `CustomPainter`/`FragmentProgram`；`AnimatedLyricsView`(100) + `LyricLine` → `AnimationController` + 时间轴（`lyrics_clock.dart`）；`CoverArtView` → `Image` + 缓存（`cached_network_image` 或自建）。
- macOS 主题：整体 Material 3，局部使用 `Cupertino*` 控件贴近系统观感；`PlatformMenuBar` 承载原生菜单栏。

---

## 6. 数据迁移（旧版 → Flutter 版，M2 已落地）

导出工具：`tools/legacy-export/ExportLegacyLibrary.swift`（一次性工具，不进产品）。

```bash
# 编译（xcode-select 指向 CommandLineTools 时必须显式给 DEVELOPER_DIR）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swiftc -parse-as-library -O -o /tmp/tingyu-legacy-export \
    tools/legacy-export/ExportLegacyLibrary.swift \
    Sources/Models/Track.swift Sources/Models/MusicSource.swift Sources/Models/Playlist.swift

# 导出（缺省输出 ~/Desktop/tingyu-legacy-export.json）
/tmp/tingyu-legacy-export /tmp/tingyu-legacy-export.json
```

- 工具把 `~/Library/Application Support/default.store`（含 `-wal`/`-shm` 与 `.default_SUPPORT`）
  **复制到临时目录后打开副本**，绝不写原库；原库 md5 前后一致已核验。
- 导出 JSON 契约：`{version: 1, exportedAt, sources[], tracks[], playlists[]}`；
  日期为 ISO8601（UTC，毫秒），空值写 `null`；`coverArtBase64` 携带封面二进制；**不含任何密码/Cookie**。

导入端：`app/lib/data/legacy_import.dart`
（`LegacyLibraryImporter.importFile`）——保留旧主键（曲目/播放列表 id），
播放列表引用在迁移后依然成立；失效引用直接丢弃；重复导入幂等。
封面 base64 落到 `CoverStore`；时间戳统一转 UTC 存储。

---

## 7. 迁移阶段（每阶段都有可运行产物与验收判据）

| 阶段 | 内容 | 验收判据 | 对照 Swift 资产 |
|---|---|---|---|
| **M0 骨架** | `app/` 工作区、`di/router/theme`、三平台 CI（macOS/Windows/Ubuntu runner，Linux 需 `libmpv-dev`/`libsecret-1-dev`/`libayatana-appindicator3-dev`）、签名脚本骨架 | 三平台空壳应用能在 CI 构建并启动 | — |
| **M1 技术验证（风险最高）** | `PlaybackEngine` 抽象 + `media_kit` 桌面实现 + `audio_service`(+win/mpris) 接通系统媒体面板；跑通本地文件播放、队列、封面元数据；同时验证 §5.4 的 App Group 方案 | macOS/Win/Linux 三平台：能播放本地音频，系统媒体面板显示曲目并可控制 | `AudioPlayerService` 570、`NowPlayingManager` 118 |
| **M2 数据层** | drift schema/dao/repository；本地库扫描；导入旧版导出 JSON | 扫描 1000+ 文件不卡 UI；导入后曲库与旧版一致 | `Models/` 231、`LocalLibraryScanner` 213、`LibrarySync` 81、`LegacyCacheMigrator` 89 |
| **M3 来源层** | WebDAV → Quark（含 Cookie 会话与代理流）→ 抓取器（QQ/网易/LRCLIB/iTunes）→ `MetadataEnricher` / `SmartTitleParser` / `ChineseConverter` | 每个来源可用真实账号/真实专辑跑通"列出 → 播放 → 元数据补全" | `WebDAVClient` 239+94、`QuarkDriveClient` 410、抓取器约 800 |
| **M4 核心 UI** | 曲库 / 专辑 / 艺术家 / 播放页 / 队列 / 歌词 / 设置；`features/` 全部落地 | macOS 上达到与 Swift 版同等的功能覆盖（外观可不同） | `UI/` 4916 |
| **M5 移动端** | `just_audio` + `audio_service`(MediaSession + 前台服务)、通知权限、`mediaPlayback` 前台服务类型、MediaStore/SAF 读本地音乐、国内 ROM 保活；iOS 侧 AudioSession 类别与后台音频能力 | Android 后台连续播放 1 小时不被杀，锁屏与蓝牙按键可控；iOS 锁屏控制面板正常 | — |
| **M6 macOS 原生增强** | 小组件、App Intents、AirPlay 三件套搬运与联调 | 小组件随播放状态刷新；App Intents 可控制播放；AirPlay 可切设备 | `TingyuWidget` 261、`TingyuIntents` 85、`AirPlayPickerView` 80 |
| **M7 分发** | DMG+公证、MSIX+EV 签名、Flatpak+AppImage+deb、Android 签名上架；自更新通道 | 三平台干净机器安装可用、无签名警告 | — |

**工作量量级（估算，非实测）**：M1–M4 是主体，Dart 代码量约 10000–13000 行（Services 3611 → 约 4500 行 Dart；UI 4916 → 约 6500 行 Flutter）。M0/M1 是风险闸门：**若 M1 三平台系统媒体会话验证失败，方案需要回炉**。

---

## 8. CI / 构建流水线

```yaml
# .github/workflows/flutter.yml（要点）
jobs:
  build:
    strategy:
      matrix: { os: [macos-14, windows-2022, ubuntu-22.04] }
    steps:
      - subosito/flutter-action
      - ubuntu: apt-get install libmpv-dev libsecret-1-dev libayatana-appindicator3-dev ninja-build libgtk-3-dev
      - flutter pub get && flutter analyze && flutter test
      - flutter build {macos|windows|linux} --release
      - 平台签名（macOS: codesign+notarytool / Windows: signtool+Azure Trusted Signing）
```

---

## 9. 风险登记表

| # | 风险 | 影响 | 缓解 | 触发点 |
|---|---|---|---|---|
| R1 | libmpv / FFmpeg 许可证（GPL 传染） | 闭源收费分发受限 | 使用 LGPL 构建的 libmpv；发布前做许可证审计 | M7 前 |
| R2 | 双引擎状态不一致（进度/缓冲/封面） | 播放 UI 与系统面板显示不同步 | 抽象层收敛为单一 source of truth；引擎侧只暴露 `PlaybackSnapshot` | M1 |
| R3 | App Group 在非沙盒宿主不可用 | 小组件/Intents 拿不到数据 | 退路见 §5.4；M1 内完成验证 | M1 |
| R4 | Linux 运行时依赖（libmpv/libsecret/appindicator） | 目标机装不上或崩溃 | Flatpak/AppImage 内自带依赖；无 keyring 时降级为文件存储 + 提示 | M1/M7 |
| R5 | Android 后台被杀（国内 ROM） | 后台播放中断 | 前台服务 + 通知权限引导 + 厂商白名单引导页 | M5 |
| R6 | Flutter macOS 多 target（扩展）需手改 Xcode 工程 | 每次 `flutter create` 覆盖风险 | 扩展 target 一次建好后不再重建工程；构建脚本对 Runner.xcodeproj 做幂等补丁 | M6 |
| R7 | 抓取源结构变化 / 合规 | 功能失效或投诉下架 | 抓取器接口隔离、可独立更新；不上架来源相关的商店页描述 | 持续 |
| R8 | 双版本维护期拉长 | 旧版 bug 与新版进度互相挤占 | D4 冻结策略：旧版只修阻塞性 bug | 持续 |

---

## 10. 里程碑闸门（建议）

- **M0 完成即评审**：目录结构、CI 三平台绿灯。
- **M1 完成即评审**：播放 + 系统媒体会话三平台验证结论。**这是"继续 / 调整 / 放弃"的决策点。**
- **M4 完成即评审**：macOS 功能对齐完成，可决定旧 Swift 版正式下线时间。

---

## 11. 决策记录与剩余开放问题

**已决策（2026-09-11）**
1. iOS 纳入 Flutter 版，与桌面/Android 共用一套 Dart 代码（D1）。
2. 方案文档入库 `docs/crossplatform-migration.md`（D8）。
3. Flutter 工作区放 `app/`（D8）。
4. 首个里程碑 = M0 骨架 + M1 技术验证闸门（D9）。

**剩余开放问题**
1. Android 是否读取设备本地音乐（MediaStore / SAF 权限），还是仅"自有曲库 + 网络来源"？影响 M5 权限模型、上架隐私描述与扫描器设计。
2. 是否上 Google Play 等应用商店（影响签名/隐私政策工作量，非技术阻塞）。

---

## 12. 环境前提（本机实测，2026-09-11）

| 项 | 状态 |
|---|---|
| Xcode | 已安装 `/Applications/Xcode.app`；但 `xcode-select -p` 仍指向 `/Library/Developer/CommandLineTools`，构建脚本需 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 或执行 `sudo xcode-select -s` |
| CocoaPods | 已安装 1.17.0（`brew install cocoapods`），macOS/iOS 插件构建必需 |
| Flutter SDK | 已安装 3.47.2 / Dart 3.13.2，位于 `~/development/flutter`（tag 浅克隆），`/opt/homebrew/bin/flutter` 为符号链接；`flutter doctor` 对本机 SDK 报 `[user-branch]` 通道警告（tag 检出所致，不影响构建） |
| Android SDK | 已安装 `~/Library/Android/sdk`，但缺 `cmdline-tools` 且未接受 license，**Android 本地构建暂不可用**（M5 前补齐） |
| Homebrew / ffmpeg | 已安装 |
| 磁盘可用 | 约 4 GiB（Flutter SDK 约 1.8 GiB + 构建产物；安装 SDK 时磁盘曾耗尽，已清理临时 zip 与 Homebrew 缓存） |

**本地验证边界**：Flutter 不支持从 macOS 交叉构建 Windows/Linux 桌面目标，因此本机只能验证 macOS（及 Android/iOS 需对应 SDK/模拟器）；**Windows/Linux 的构建与运行验证必须由 CI 承担**。

---

## 13. M1 技术验证结论（2026-09-11）

分支 `ci/flutter-bootstrap`（**已合入 `main` 并删除**：PR [#1](https://github.com/halunhaku/tingyu/pull/1)
于 2026-09-14 合并为 `4c05d3e`，此后所有提交直接落在 `main`）· 提交 `416a994`

| 平台 | 构建 | 运行时（播放 + 系统媒体会话） |
|---|---|---|
| macOS | ✅ 本地 Debug 构建 + CI Release 构建 | ✅ **已验证**（见下方证据） |
| Windows | ✅ CI Release 构建 | ⚠️ 未验证：SMTC 需 Windows 实机 |
| Linux | ✅ CI Release 构建 | ⚠️ 未验证：MPRIS2 需 Linux 桌面实机（DBus） |
| Android / iOS | 未纳入 M1 范围（依赖移动端构建环境） | — |

**CI**：`analyze + test` 通过（4 个 handler 契约测试），三平台 release 构建全部绿灯。

**macOS 运行时证据**

1. 播放链路（3 个 5 秒测试音轨，经 `TINGYU_DEBUG_SOURCES` 注入）：

   ```
   engine=media_kit (libmpv) processing=ready playing=true position=2671ms duration=5000ms index=0
   … index 0 → 1 → 2 → completed，全程 0 error
   ```

2. 系统媒体会话（`nowplaying-cli` 独立复核，非应用自述）：

   ```
   $ nowplaying-cli get title duration playbackRate
   tone-440.wav / 5 / 1          # bundle id: com.halunhaku.tingyu

   $ nowplaying-cli pause   → 引擎 playing=false
   $ nowplaying-cli play    → 引擎 playing=true
   $ nowplaying-cli next    → 系统标题 tone-880.wav，引擎 index=2
   ```

   即"引擎 → 系统面板"与"系统指令 → 引擎"双向打通。

**闸门结论**：**继续**。播放引擎抽象与系统媒体会话桥在 macOS 上成立，无阻塞性发现。遗留项（不阻塞后续里程碑）：

- R2（双引擎状态一致性）仅在 macOS 侧观察到正确行为，移动端需在 M5 复核。
- 系统面板实测中出现过 `duration=0`，已定位为"时长在引擎加载完成前不可知"并在 `_syncMediaItem` 中修复（时长可知后补发媒体元数据并去重），测试覆盖。
- Windows/Linux 的运行时验证需要对应实机，建议在 M3 之前安排一次人工确认。

---

## 14. M2 数据层结论（2026-09-11）

交付物（`app/`）：

| 模块 | 文件 | 对应 Swift 资产 |
|---|---|---|
| 表结构与连接 | `lib/data/db/schema.dart` · `database.dart`（SQLite 文件 + 后台 isolate + UTC 文本时间戳） | SwiftData 模型 |
| 曲目读写与合并 | `lib/data/repositories/track_repository.dart` | `LibrarySync.swift` 81 行 |
| 播放列表 | `lib/data/repositories/playlist_repository.dart` | `Playlist.trackIds` |
| 来源 | `lib/data/repositories/source_repository.dart` | `MusicSource` |
| 封面缓存 | `lib/data/cover_store.dart` | `@Attribute(.externalStorage) coverArtData` |
| 本地扫描 | `lib/sources/local/local_library_scanner.dart` | `LocalLibraryScanner.swift` 213 行 |
| 旧库迁移 | `tools/legacy-export/ExportLegacyLibrary.swift` + `lib/data/legacy_import.dart` | `LegacyCacheMigrator.swift` 89 行 |

**验证结果**

1. 自动化测试 26 项全绿（`flutter analyze` 无告警）：合并语义（新增/更新/删除/用户资产保留/占位值升级）、
   播放列表顺序与级联、聚合查询、扫描器过滤与标签映射（含 UTF-16 中文 ID3）、导入契约与幂等。
2. **真实目录扫描**（ffmpeg 生成 3 个带中文标签的文件 + 隐藏目录 + 非音频文件）：

   ```
   SCAN tracks=3 unreadable=0 cancelled=false elapsed=18ms
   SCAN|七里香|周杰伦|七里香|2.00s|flac|41481|trackNo=1|cover=null
   SCAN|以父之名|周杰伦|叶惠美|3.06s|mp3|49995|trackNo=1|cover=21a21e95221c944c.png
   SCAN|晴天|周杰伦|叶惠美|3.06s|mp3|49021|trackNo=2|cover=null
   ```

   隐藏目录与非音频文件被正确跳过；内嵌封面落盘并回传文件名。

3. **真实旧库导入**（旧库为夸克来源 176 首）：`LegacyImportReport(sources: 1, tracks: 176, playlists: 0, skippedTracks: 0)`。
   并用 `sqlite3` 对新旧两个库做独立比对：

   | 比对项 | 结果 |
   |---|---|
   | `ZTRACK` vs `tracks` 行数 | 176 = 176 |
   | `(title, artist, album)` 集合 | 完全一致（无单边差异） |
   | `filePathOrUrl` 集合 | 完全一致 |
   | 来源行数 / 名称 / kind / trackCount | 1 = 1，`夸克网盘 (音乐)` / `quark` / 176 |
   | 时间戳 | 以 UTC 文本存储并保留毫秒（`2026-09-08T02:56:48.323Z`） |

**结论**：M2 达成验收判据（扫描可用、旧库无损导入）。已知偏差与遗留：

- 排序用码点序而非旧版的 `localizedStandardCompare`（中文排序表现不同，M4 处理）。
- 「1000+ 文件不卡 UI」目前靠架构保证（遍历在主 isolate、解析分批进子 isolate、SQLite 在后台 isolate），
  未做真实 1000+ 文件的压测；建议在 M3 开始前用真实音乐目录跑一次。
- 扫描的全量进度 UI、来源配置界面属于 M4；M2 只保证数据与扫描能力。

---

## 15. M3 来源层结论（2026-09-11）

交付物（`app/`）：

| 模块 | 文件 | 对应 Swift 资产 |
|---|---|---|
| 来源抽象 | `lib/sources/source_adapter.dart` | — |
| WebDAV | `lib/sources/webdav/{webdav_client,webdav_xml_parser,webdav_source_adapter}.dart` | `WebDAVClient.swift` 239 + `WebDAVXMLParser.swift` 94 |
| Quark | `lib/sources/quark/{quark_cookie_store,quark_drive_client,quark_source_adapter}.dart` | `QuarkDriveClient.swift` 410 + `QuarkCookieStore.swift` |
| 凭据 | `lib/data/secure_store.dart` | `KeychainService` / 明文 cookie 回退（已移除） |
| 抓取 | `lib/sources/scraper/{qq_music,netease,lrclib,itunes_cover}_provider.dart` | 四个 Scraper（约 500 行） |
| 解析 | `lib/sources/scraper/{smart_title_parser,chinese_converter}.dart` + `assets/opencc/TSCharacters.txt` | `SmartTitleParser.swift` 96 + `ChineseConverter.swift`（ICU） |
| 编排 | `lib/sources/scraper/metadata_enricher.dart` + `lib/data/enrichment_service.dart` | `MetadataEnricher.swift` 113 |
| 头像 | `lib/sources/scraper/artist_avatar_store.dart` | `ArtistAvatarStore.swift` 91 |

**验证结果**

1. **81 项测试全绿**（`flutter analyze` 无告警），其中 M3 新增 55 项：WebDAV 26（命名空间 XML、
   href 三态解析、跳过规则、401/403/429/503 文案、depth 0 与非 0 的差异、限流间隔）、
   Quark 11（目录解析、直链三种 JSON 形状、缓存与 `__puus` 回写、错误映射、BFS 深度/截断/取消）、
   富化编排 7（不出网快路径、主来源命中、标题不匹配不改写、兜底顺序、封面缺失、可疑标题跳过）、
   文件名解析 8、繁简转换 3。
2. **真实 WebDAV 服务器**（本机临时脚本，PROPFIND/GET/Basic 认证）：
   - 扫描 `/周杰伦/` → 2 首（隐藏目录与 png 被正确跳过，etag/大小/百分号编码 URL 正确）；
   - `/forbidden/` → `WebDavForbidden`（"WebDAV 拒绝访问该目录 (403 Forbidden)"）；
   - `/busy/` → `WebDavRateLimited`（"坚果云提示请求过于频繁（临时封禁中）…"）；
   - **服务器根路径 `/` 扫描 → 2 首**（旧版此处会静默返回空，见下方偏差）；
   - 适配器 `open()` 产出的 `PlaybackItem` 带 `Authorization`，用同样的头直接 GET 得到
     `200` 且字节数与 `fileSize` 完全一致。
3. **真实公开接口**（本机联网）：

   ```
   QQ      |晴天|周杰伦|叶惠美|https://y.gtimg.cn/.../T002R800x800M000000MkMni19ClKG.jpg
   LRCLIB  |len=841|[00:27.38] 窗外的麻雀 在电线杆上多嘴 …      ← 已由繁体转成简体
   NETEASE |晴天(深情版)|Lucky小爱|…|lyrics len=969|avatar=…?param=500y500
   ITUNES  |…/600x600bb.jpg
   ```
4. **端到端**（WebDAV 扫描 → 入库 → 真实抓取 → 封面落盘）：

   ```
   E2E merge=+2
   E2E enrich 七里香 → changed=true cover=true lyrics=true
   E2E row|七里香|周杰伦|七里香|lyrics=841|cover=…/covers/46ba4b3e784092aa.jpg (197471 bytes)
   E2E row|晴天|周杰伦|叶惠美|lyrics=1089|cover=…/covers/11d82db9849c2dea.jpg (183730 bytes)
   ```

**与旧版的有意偏差**

| # | 偏差 | 原因 |
|---|---|---|
| 1 | 修正 `normalizePath('/')`：旧版得到 `//`，导致从服务器根目录扫描时所有条目都过不了前缀检查、**静默返回空** | 旧版只对 `/dav/` 这类带路径的根目录正常 |
| 2 | 所有 JSON 接口统一按文本取回再 `jsonDecode` | QQ 返回 `application/x-javascript`、网易云 `text/plain`、iTunes `text/javascript`，dio 的类型推断会直接失败（实测：修复前这四个来源全部返回 null） |
| 3 | Quark Cookie 不再写一份明文文件兜底 | 明文凭据落盘是纯安全降级 |
| 4 | 新增 `isCancelled`（旧版无取消） | `SourceAdapter.scan` 契约要求 |
| 5 | 繁→简用 OpenCC 字表逐字转换（旧版用系统 ICU 变换） | Flutter 无 ICU API；词组级消歧待需要时接入 |

**遗留与未验证项**

- **Quark 未做实机验证**：旧库凭据已失效（导出里 `syncStatus = 夸克凭据已失效`），
  无法在线验证 `listFolder` / 直链；该模块由 11 项基于假 HTTP 适配器的测试覆盖，
  等你在应用里重新登录后再补一次端到端。
- **本机音频输出当前故障**：`afplay` 报 `AudioQueueStart failed (-66681)`，
  media_kit 也拿不到音频时钟（position 恒为 0）。因此"HTTP + 鉴权头的远端音频出声"这一条
  只能验到"mpv 成功鉴权取流并解析出容器时长"（未鉴权时该服务器返回 401，取不到时长）。
  M1 阶段同一台机器上音频正常（当时已验证到播放位置推进 + 系统媒体面板），
  所以这是环境问题而非代码回归；恢复方式见 §16。
- 歌词/元数据匹配沿用旧版的"互相包含"判据，网易云可能命中翻唱版本（实测 `晴天` 命中
  `晴天(深情版)`），与旧版行为一致，未做收紧。
- 艺术家/专辑排序仍是码点序（M4 处理）。

---

## 16. 本机环境异常（2026-09-14 复核：已恢复）

**音频输出不可用**（2026-09-11 记录）：`afplay` 报 `AudioQueueStart failed (-66681)`，`coreaudiod` 在运行，
默认输出设备是"MacBook Air扬声器"（另有 `OrayVirtualAudioDevice` 虚拟声卡）。
影响：所有需要"真的出声"的验证（WebDAV 远端播放、M5 移动端前的桌面播放回归）——当时 media_kit
也拿不到音频时钟，`position` 恒为 0，远端音频只能验到"成功鉴权取流并解析出容器时长"。

**现状（2026-09-14 复核）**

| 检查 | 结果 |
|---|---|
| `afplay` 播一段 0.2s 静音 wav | ✅ 退出码 0，不再出现 -66681 |
| 默认输出设备 | 仍是「MacBook Air扬声器」；`OrayVirtualAudioDevice` 也仍在设备列表里 |
| 应用内实播 | ✅ 跑真实 macOS 构建：夸克来源的《龙卷风》在播、进度 `0:17 / 4:10` 持续推进 —— 音频时钟正常 |

期间**没有重启过机器**（`kern.boottime` = 2026-09-06 10:11，今天 uptime 已 7 天 23 小时），
所以不是靠重启恢复的；具体是谁修好的、是不是 coreaudiod 自己缓过来，没有证据，不猜。
§15 里"远端音频出声只能验到解析出时长"那条随之闭环。

---

## 17. M4 桌面 UI 结论（2026-09-12）

交付物（`app/lib/`）：

| 模块 | 文件 | 对应 Swift 资产 |
|---|---|---|
| 外壳与导航 | `app/router.dart` · `app/theme.dart` · `features/shell/app_shell.dart` | `MacOSContentView.swift` 484 |
| 状态与动作 | `app/providers.dart` · `app/playback_controller.dart` · `app/track_resolver.dart` · `app/source_adapters.dart` | `AudioPlayerService` 的界面侧职责 |
| 共享组件 | `features/shared/{cover_art,track_row,empty_state,format,add_to_playlist}.dart` | `TrackRowView` 158 · `CoverArtView` |
| 曲库 | `features/library/library_page.dart` · `library/manual_match_dialog.dart` | `LibraryTrackListView` · `MacOSTrackTable` 200 · `ManualMatchSheet` 258 |
| 专辑/艺术家 | `features/albums/*` · `features/artists/*` | `AlbumGridView` 85 · `AlbumDetailView` 208 · `ArtistListView` · `ArtistDetailView` 241 · `ArtistAvatarView` 72 |
| 播放 | `features/player/{player_bar,now_playing_page,playback_controls,queue_panel,fluid_background,lyrics_panel,lrc_parser}.dart` | `MacOSNowPlayingToolbar` 441 · `PlaybackControls` 103 · `UpNextQueueView` 158 · `FluidBackgroundView` 86 · `AnimatedLyricsView` 100 |
| 播放列表 | `features/playlists/playlist_page.dart` | `PlaylistActions` + 侧栏 CRUD |
| 来源与设置 | `features/sources/*` · `features/settings/settings_page.dart` | `SourceManagerView` 524 · `AddQuarkSheet` 481 |

**验证结果**

1. `flutter analyze` 无告警；**81 项测试全绿**（UI 未新增测试：桌面布局属人工核验对象，见下）。
2. macOS Debug 构建通过，并**逐页截图核验**（`screencapture` + 视觉复核）：

   | 页面 | 核验到的内容 |
   |---|---|
   | 曲库 `/library` | 侧栏（曲库/最近添加/艺术家/专辑/收藏 + 来源计数 176/3 + 播放列表 + 设置）、179 首列表（已富化的 周杰伦 · 七里香/叶惠美）、底部悬浮播放条 |
   | 专辑 `/albums` | 标题「专辑」+ 4 张专辑网格（七里香 / 叶惠美 / 夸克曲库 …） |
   | 艺术家 `/artists` | 「2 位」+ 周杰伦 16 首 / 未知艺术家 163 首（首字头像） |
   | 正在播放 `/now-playing` | 全屏舞台（封面 + 标题 + 传送器）+ 歌词区 + 右侧「接下来播放」（2 首） |
   | 设置 `/settings` | 曲库统计（179/4/2/0/2）、来源与批量操作入口、播放引擎 `media_kit (libmpv)` + `audio_service` |
   | 全部页面 | **无** Flutter 溢出条纹、**无**红色异常框 |

3. 截图核验发现并修掉的两个真实缺陷：
   - **播放条溢出 99px**：Flutter 模板默认窗口只有 800×600，侧栏占 248px 后内容区不足。
     已把窗口默认尺寸改为 1180×760、最小 900×600（`MainFlutterWindow.swift`），
     并让播放条按宽度分级收敛（窄窗口先去掉音量，再去掉进度条）。
   - **外部设置的队列不显示元数据**：队列若非经 `PlaybackController` 设置（调试入口、
     未来的系统恢复/深链），界面拿不到曲目 id。已给 `PlaybackEngine` 增加
     `currentItem` / `items`，播放条、正在播放页、队列面板都改为"库内行优先、引擎条目兜底"。

**与旧版的功能对照（M4 范围内）**

- 已对齐：侧栏与分组、曲库/最近添加/收藏、专辑与艺术家浏览、播放列表 CRUD 与拖拽排序、
  播放条、全屏正在播放舞台、歌词（高亮 + 自动滚动 + 一键抓取）、队列、来源管理
  （本地目录 / WebDAV 表单 / 夸克 Cookie + 文件夹选择）、同步与元数据补全、人工匹配、设置页。
- 未纳入（按本轮决定）：AI 元数据解析与 AI 设置面板（单独排一个里程碑）；移动端布局（M5）。
- 已知差异：菜单栏搜索快捷键仍为 ⌘1–⌘4 跳转 + 侧栏搜索框（旧版是 ⌘K 聚焦搜索框）；
  夸克登录沿用"粘贴 Cookie"（旧版的 WKWebView 抓取属 UI 增强，未移植）。

---

## 18. 里程碑进度

| 里程碑 | 状态 |
|---|---|
| M0 骨架 + CI | ✅ |
| M1 播放与系统媒体会话闸门 | ✅（macOS 运行时已验证；Win/Linux 待实机） |
| M2 数据层 | ✅ |
| M3 来源层 | ✅（本地 / WebDAV / 夸克三条链路都已跑通；夸克在 Android 真机上验到能拉起官方登录页（§22），桌面上完成了 178 首扫描入库与直链播放；真实账号的登录与 Cookie 抓取由你完成） |
| M4 桌面 UI | ✅（AI 与移动端不在本轮范围） |
| M5 移动端（Android / iOS） | ✅ Android：构建 + 模拟器与真机播放、SAF 本地音乐（§21）、应用内夸克登录（§22）、失败提示（§23）；iOS：构建 + 模拟器运行（§20）、本地目录安全作用域书签（§24）。两端的真机端到端遗留见对应小节 |
| M6 macOS 原生增强（WidgetKit / App Intents / AirPlay） | 未开始 |
| M7 分发（DMG / MSIX / Flatpak / 商店） | 未开始 |

---

## 19. M5 移动端结论（2026-09-12）

交付物（`app/`）：

| 模块 | 文件 | 对应 Swift 资产 |
|---|---|---|
| 移动外壳 | `lib/features/shell/mobile_shell.dart` · `lib/features/player/mini_player.dart` | `IOSContentView.swift` 202 · `IOSMiniPlayer.swift` 73 |
| 歌单页 | `lib/features/playlists/playlists_page.dart` | `IOSPlaylistsView.swift` 136 |
| 移动布局适配 | `now_playing_page.dart`（窄屏纵向 + 队列底部弹层）· `router.dart`（按平台选外壳） | `IOSNowPlayingSheet.swift` 119 |
| Android 平台配置 | `android/app/src/main/AndroidManifest.xml`（权限 / 前台服务 / 媒体键接收器 / `AudioServiceActivity`） | 旧版无 Android 目标 |
| iOS 平台配置 | `ios/Runner/Info.plist`（`UIBackgroundModes: audio`） | 同旧版能力 |
| 通知权限 | `main.dart` 在 Android 上请求 `POST_NOTIFICATIONS`（`permission_handler`） | — |

**本机构建 Android 的前置（实测踩过的坑，写下来避免重复）**

1. SDK 缺 `cmdline-tools`：装到 `~/Library/Android/sdk/cmdline-tools/latest` 并 `sdkmanager --licenses` 接受授权。
2. **Gradle 必须用 JDK 21**：本机只有 Temurin 26，AGP 的 `JdkImageTransform` 在 JDK 26 上会 `jlink` 失败；
   已下载免安装版 Temurin 21 到 `~/development/jdk-21`，并 `flutter config --jdk-dir=~/development/jdk-21/Contents/Home`。
3. `permission_handler` 12.x 需要 compileSdk 34（已装 `platforms;android-34`）；13.x 要求 `android-37`，
   而当前 SDK 里该平台叫 `android-37.0`，故本工程钉在 `^11.4.0`。
4. 构建前需 `ANDROID_HOME=~/Library/Android/sdk`；首次构建会下载 Gradle 9.3.1 与依赖。

**验证结果（Android 模拟器 Pixel 10 Pro / Android 17，真机不适用）**

1. **构建**：`flutter build apk --debug` 通过；`apkanalyzer` 核验产物清单包含
   `INTERNET` / `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `WAKE_LOCK` / `POST_NOTIFICATIONS`，
   以及 `com.ryanheise.audioservice.AudioService`（`foregroundServiceType=mediaPlayback`）、`MediaButtonReceiver`、
   `AudioServiceActivity`。
2. **后台播放链路（端到端）**：在模拟器上播放设备内音频时，系统 `MediaSessionService` 报告
   `PlaybackState {state=PLAYING(3), position=1039→3033, buffered position=3030, speed=1.0, activeItem=1}`，
   即 ExoPlayer 解码推进、`audio_service` 的媒体会话已被系统接管。
3. **界面（逐屏截图核验）**：
   - 曲库页：标题「曲库」+ 底部 Tab（曲库/收藏/歌单/音乐源）+ 曲目列表；
   - 歌单页：空态文案 + 「新建」入口；
   - 迷你播放条：显示当前曲目「晴天 / 周杰伦」与播放/下一首按钮；
   - 正在播放页：大封面 + 曲目信息 + 传送器 + 歌词（含「抓取歌词」）+ 右上队列入口；
   - **无溢出条纹、无红色异常框**。
4. 权限请求：首次启动时弹出系统「允许听屿发送通知？」，确认 `POST_NOTIFICATIONS` 请求路径生效。

**截图核验发现并修掉的问题**

- **手机端正在播放页横向溢出 142px**：原布局沿用桌面形态（左侧舞台 + 固定 320px 队列栏），
  在 426pt 宽的手机上放不下。已改为：窄屏（<720pt）纵向铺满 + 队列改为底部弹层入口（对齐旧版 iOS 的 sheet 形态）。

**未完成与风险**

- **iOS：构建与模拟器运行已验证**（见下方"iOS 补验"），但**播放链路未在 iOS 上端到端验证**
  （见该节的说明）。
- **Android 本地音乐访问仍是缺口**：实测直接读取 `/sdcard/Music/*.mp3` 会 `EACCES`（Android 13+ 需要
  `READ_MEDIA_AUDIO` 或 SAF 目录授权）。本次验证是绕开该限制、把音频放进应用私有目录完成的。
  旧版没有 Android 目标，因此这是新增需求：建议下一步做「SAF 目录选择 + 持久化 URI 权限」，
  与 iOS 的安全作用域书签一一对应。
- 移动端未做真机验证（模拟器无音频输出：启动参数 `-no-audio`）；后台保活、厂商省电策略需真机复核。

---

## 20. M5 补充：iOS 构建与模拟器验证（2026-09-12）

**前置修复（两处，均为一次性环境问题）**

1. 安装 Xcode 的 iOS 平台组件：`xcodebuild -downloadPlatform iOS`（iOS 26.5 模拟器运行时，8.52 GB）。
   在此之前 `flutter build ios` 直接失败，报 `iOS 26.5 is not installed`。
2. **`xcode-select` 必须指向 Xcode**：本机原先指向 `/Library/Developer/CommandLineTools`，
   导致 Flutter 的 native-assets 钩子（`objective_c` 包）在 Xcode 脚本阶段执行
   `xcrun --show-sdk-path --sdk iphoneos` 时拿到空输出，构建报
   `Bad state: No element` / `Target build_hooks failed`。
   修复：`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`（已由你执行）。
   顺带好处：此后 flutter 命令不再需要手动带 `DEVELOPER_DIR`。

**验证结果**

| 项目 | 结果 |
|---|---|
| 设备构建 | ✅ `flutter build ios --debug --no-codesign` → `build/ios/iphoneos/Runner.app` |
| 模拟器构建 | ✅ `flutter build ios --debug --simulator` → `build/ios/iphonesimulator/Runner.app` |
| 模拟器安装与启动 | ✅ iPhone 17 / iOS 26.5：`simctl install` + `launch` 成功 |
| 移动 UI | ✅ 截图核验：导航标题「曲库」、底部 Tab（曲库/收藏/歌单/音乐源）、库内 178 首列表、空态与「添加来源」按钮；无异常 |
| 播放链路 | ⚠️ 未在 iOS 上端到端验证：`simctl` 不支持点击自动化，且 `SIMCTL_CHILD_*` 环境变量未能传入 Flutter 应用（实测用 `TINGYU_DEBUG_ROUTE` 验证过：启动仍停在 /library），因此无法用调试入口直接起播 |

**iOS 侧新增的代码改动**：`Info.plist` 的 `UIBackgroundModes: audio`；
移动端启动时显式配置 `AudioSessionConfiguration.music()`（音频焦点、被电话打断、
后台播放与锁屏控制的前提；旧版在 `AudioPlayerService` 里做的是同一件事）。
播放链路的其余部分与 Android 共用同一套 Dart 代码（Android 侧已实测 PLAYING 推进）。

---

## 21. Android 本地音乐（SAF 目录授权）（2026-09-12）

**问题**：Android 10+ 的分区存储下，直接读 `/sdcard/Music/*.mp3` 会 `EACCES`
（实测复现：ExoPlayer 报 `open failed: EACCES`）。旧版没有 Android 目标，所以这是新增需求。
两条正路：`READ_MEDIA_AUDIO` + MediaStore（只覆盖"媒体库里的音频"）或 SAF 目录授权
（任意目录、用户显式授权，语义与 iOS 的安全作用域书签一致）。本工程选后者。

**交付物**

| 模块 | 文件 | 说明 |
|---|---|---|
| 原生桥 | `app/packages/tingyu_saf/`（本地 Flutter 插件：Kotlin + Dart） | `pickDirectory` 拉起系统目录选择器并**持久化**读权限；`listChildren` 用 `DocumentsContract` 枚举目录；`hasPermission` / `releasePermission` |
| 来源适配器 | `lib/sources/local/saf_source_adapter.dart` | 递归枚举授权目录 → `ScannedTrack`（`filePathOrUrl` 是 `content://` URI，ExoPlayer 可直接播放）；扩展名过滤、批量上限、取消、单目录失败不中断 |
| 接线 | `lib/app/source_adapters.dart` · `features/sources/{sources_page,source_page}.dart` | Android 本地来源走 SAF（tree URI 存在 `music_sources.local_bookmark`）；桌面仍是文件系统路径；删除来源时释放授权 |
| 授权失效 | `SafPermissionLostException` | 用户在系统设置里撤销授权时给出明确提示 |

**验证（Android 模拟器，真机不适用）**

1. `flutter build apk --debug` 通过（含新插件的 Kotlin 编译）；安装到 Pixel 10 Pro / Android 17。
2. 走完整用户路径（用 adb 点击 + 截图逐步核对）：
   「音乐源」→「添加来源」→「本地目录」→ 系统目录选择器（`ACTION_OPEN_DOCUMENT_TREE`）→
   选中 `Movies` →「USE THIS FOLDER」→ 系统「Allow access to Movies」→ 允许。
3. 应用随即建源并同步：界面显示 **「系统授权的音乐目录（SAF）」**、
   **`2 首 · 已同步（新增 2 / 更新 0 / 移除 0）`**，列表出现 `qilixiang` / `qingtian` 两行
   （文件名解析出的标题，元数据留给抓取管道补全）。
4. **播放 content:// 曲目**：点击列表行后，系统 `MediaSessionService` 报告
   `PlaybackState {state=PLAYING(3), position=2067→3033, buffered=3030, speed=1.0}`，无错误 ——
   即 SAF 枚举出来的 `content://` URI 已被 ExoPlayer 正常读取并解码。

**遗留**：iOS 侧的对应能力（文件夹书签）尚未实现；移动端真机（非模拟器）未验证。

---

## 22. 夸克登录改为应用内网页登录（2026-09-12）

**动机**：粘贴 Cookie 对用户太笨重。夸克没有面向第三方的公开授权接口
（与阿里云盘的 OpenAPI 不同），业界做法只有两种：内嵌官方网页登录后读取 Cookie，
或逆向扫码接口。这里选前者——**不依赖任何逆向接口**，官方改页面也不影响，
且旧版 Swift 也是这么做的（`QuarkWebLoginView` + WKWebView）。

**实现**（纯 Dart，无新增原生代码）

| 环节 | 做法 |
|---|---|
| 打开登录 | `webview_flutter` 打开 `https://pan.quark.cn/list`，并**强制桌面 UA**（`QuarkDriveClient.userAgent`）——移动 UA 会被导到"立即下载"推广页，拿不到网页版界面；这个 UA 与后续 API 请求完全一致 |
| 抓取凭证 | `WebViewCookieManager().getCookies(domain:)` 读取系统 Cookie 存储（含 HttpOnly），拼成 Cookie 串；Android 走 `CookieManager`，iOS/macOS 走 `WKHTTPCookieStore` |
| 校验与落库 | 用现成的 `QuarkDriveClient.verifyCookie` 校验 → 成功即自动返回上一页并把 Cookie 写进系统安全存储（`SecureStore`）；失败则在页面顶部提示"请先完成登录" |
| 自动完成 | 每 3 秒轮询一次；也可手动点右上角「完成」立即校验 |
| 重新登录 | 来源列表里对已存在的夸克来源提供「重新登录」，更新凭据而不动已入库曲目 |
| 平台差异 | Windows / Linux 官方 WebView 插件不支持，那里仍保留"粘贴 Cookie"入口（`QuarkLoginPage.isSupported` 分流） |

**验证**：Android 真机（Xiaomi 14 Ultra / Android 16）安装 release 包后走
「音乐源 → 添加来源 → 夸克网盘」，应用内 WebView 成功加载夸克网页版界面
（页面内可见「登录」「全部文件」「我的分享」等），顶部提示条显示
"请在下方页面完成登录，成功后会自动返回"。**真实账号的登录与自动抓取需你本人完成**
（我无法也不应该代你登录），完成后应用会自动返回并让你选曲库文件夹。

**风险**：官方网页若大改（登录入口迁移、增加验证码/风控），需要跟着调整；
但相比逆向接口，这种改动的频率与破坏性都低得多。

---

## 23. Android 真机播放无声（2026-09-13）

**现象**（Xiaomi 14 Pro / Android 16 真机，release 包）：点任意曲目后**底部播放条照常出现**，
但没有声音、进度也不走；界面没有任何报错提示。

**定位**：release 包的 Dart `print` 不进 logcat，改跑 `flutter run --debug` 后拿到栈：

```
E/ExoPlayerImplInternal: Caused by: java.io.IOException:
    Cleartext HTTP traffic to 127.0.0.1 not permitted
E/AudioPlayer: TYPE_SOURCE: Cleartext HTTP traffic not permitted.
E/flutter: Unhandled Exception: (0) Source error
  #8  AudioPlayer.setAudioSources (just_audio.dart:897)
  #9  JustAudioEngine.setQueue (just_audio_engine.dart:54)
  #11 PlaybackController._restartEngineFrom (playback_controller.dart:156)
```

**根因**：`just_audio` 对**带 `headers` 的音频源**（夸克直链、WebDAV 鉴权头）不直连，
而是起一个 localhost HTTP 代理转发，ExoPlayer 实际去取 `http://127.0.0.1:<port>/proxy/...`。
Android 自 targetSdk 28 起默认禁止明文 HTTP，**回环地址也在禁止范围内**（除非显式放行），
于是 `HttpDataSource$CleartextNotPermittedException` → `Source error`。
`setAudioSources` 抛出的异常没人接（`PlaybackController` 未捕获），所以 UI 只留下一个"看起来在播"的空播放条。

**修复**（只放行回环，不打开 `usesCleartextTraffic`，公网仍强制 HTTPS）：

| 文件 | 改动 |
|---|---|
| `app/android/app/src/main/res/xml/network_security_config.xml` | 新增：`<domain-config cleartextTrafficPermitted="true">` 列出 `127.0.0.1` 与 `localhost` |
| `app/android/app/src/main/AndroidManifest.xml` | `<application>` 增加 `android:networkSecurityConfig="@xml/network_security_config"` |

**验证**：`flutter run --debug` 热装后点歌出声、进度推进；再 `flutter build apk --release`
覆盖安装（debug/release 同用 debug keystore，签名一致，**不需要卸载、曲库数据未丢**），
release 包同样正常播放。合并后的清单经 `build/app/intermediates/merged_manifests/release/` 核验含 `networkSecurityConfig`。

**失败暴露到界面（同日补做）**

加载异常不再逃逸到调用方，而是变成快照里的状态：

| 环节 | 做法 |
|---|---|
| 契约 | `PlaybackEngine` 的 `setQueue` / `addToQueue` **不抛异常**；失败写进 `PlaybackSnapshot.failure`（`PlaybackFailure{message, title}`） |
| `just_audio` | 捕获 `setAudioSources` / `addAudioSource` 的异常；`playbackEventStream` 的 `onError` 兜底（`PlayerInterruptedException` 是换队列打断的正常噪声，不上报）；进入 `ready` 后自动清空失败 |
| `media_kit` | 订阅 `stream.error`（libmpv 的失败不走抛出）；媒体装载出确定时长后自动清空失败 |
| 提示 | `features/shared/playback_failure_listener.dart` 挂在 `MaterialApp.builder`（该位置在 `ScaffoldMessenger` 之下、路由之上），桌面/移动两套外壳共用；按"失败对象是否换了实例"去重——进度事件反复推送同一份快照只提示一次，换一首歌再失败会重新提示 |
| 测试 | `test/playback_failure_listener_test.dart`（提示内容、同实例不重复提示、新失败重新提示） |

**遗留（原）**：真机端到端核验尚未做（验证过程中手机被拔掉）；`PlaybackFailure.message` 目前直接透传
引擎原文（如 `Source error`），没有做「明文被拦 / 文件不存在 / 网络不可达」的中文化归类。

**真机复核（2026-09-14，Xiaomi 24031PN0DC / Android 16 / release 包，源码 `main@8d3e166`）**

| 检查 | 做法 | 结果 |
|---|---|---|
| 远端播放 | 夸克来源点《轻盈法则》 | ✅ `PlaybackState PLAYING`，进度 0:20 持续推进，封面 / 专辑 / 歌手齐全 |
| 本地播放 | SAF 来源点《不能说的秘密》 | ✅ `PLAYING`，position 推进 |
| 失败提示（引擎侧） | 往 `/sdcard/Music` 放一个只有 ID3、没有任何 MPEG 帧的 `broken.mp3`，同步后点它 | ✅ 界面弹出「broken」`PlatformException(Error: java.lang.IllegalArgumentException, ...)`；logcat 里是 ExoPlayer 的 `None of the available extractors … could read the stream` |
| 失败提示（解析侧） | 飞行模式下点夸克曲目（取直链必失败） | 复核当场 ❌「点了没反应」→ 同日修复（`38c8019`）：弹出「伊斯坦堡」无法播放：夸克网络连接异常: unknown |
| 未捕获异常 | 离线时的 `HandshakeException` | ✅ 已定位（`just_audio` 的本地代理漏错误，我们接不到）并加防护（`eda139f`）：真机上由 `main()` 的 zone 守卫打印 `[unhandled] HandshakeException …`，同刻 VPN 日志显示目标是刚入队的直链 `dl-pc-sz.drive.quark.cn:443` |
| 夸克重新登录 | 来源列表点「重新登录」 | ✅ WebView 打开官方登录页 → 自动校验已有会话 → 凭据写回，来源状态变「登录已更新（夸克用户）」，曲目未受影响 |
| 同步移除 | 删掉 `broken.mp3` 再同步 | ✅ `移除 1`，曲目回到 2 首，数据无损 |

**复核发现的新问题**

1. **取直链失败是静默的**（**同日已修**，提交 `38c8019`）：飞行模式下点夸克曲目，logcat 里只有
   `[playback] 跳过无法解析的曲目「…」: 夸克网络连接异常`，整队列都解析不出来时控制器直接返回、
   界面"点了没反应"。现在用户点的那一首解析失败时，控制器把原因写进同一个 `PlaybackSnapshot.failure`，
   走既有提示通道；真机实测弹出 **「伊斯坦堡」无法播放：夸克网络连接异常: unknown**（点一次弹一次，
   后续被跳过的曲目只进日志）。回归测试 `test/playback_controller_resolve_failure_test.dart` 四条，
   去掉上报调用即失败。
2. **离线时的未捕获异常**（**同日已定位并加防护**，提交 `eda139f`）：
   `Unhandled Exception: HandshakeException: Connection terminated during handshake`，不带栈。
   读依赖源码后确认这类错误**我们接不到**：带 headers 的音频源在 Android 上走 `just_audio`
   的本地 HTTP 代理，代理服务器的 `_server.listen` 调用 handler 时既不 `await` 也不挂 `onError`
   （`just_audio-0.10.6/lib/just_audio.dart`），上游 TLS 失败就直接漏到 zone —— 离线点歌正是这条路径。
   处理：① 富化服务 `enrichTrack` 改为**不抛异常**（尽力而为：失败记一行日志、计作"没有变化"），
   我们自己那些 `unawaited(...)` 的调用点因此不再漏；② `main()` 主体放进 `runZonedGuarded`，
   未捕获的异步错误带上栈打印，下次能直接指出是哪条请求。新增
   `test/enrichment_service_test.dart`（去掉 catch 即失败）。
   **真机复核（2026-09-14，release 包）**：联网起播一首夸克曲目 → 开飞行模式 → 按播放器「下一首」，
   日志里出现 `[unhandled] HandshakeException: Connection terminated during handshake`（我们的守卫打的，
   不再是引擎那条无栈横幅）；同一刻 VPN 的 DNS/TCP 日志在连 `dl-pc-sz.drive.quark.cn:443`，
   即刚入队的那条直链 —— 与"来源是 just_audio 的本地代理"的读码结论对上了。
   **仍有局限**：错误是 `Future.error(error, stackTrace)` 带**空栈** rethrow 出来的
   （`HandshakeException.osError` 在这里同样为 null），所以日志里看不到调用方；要指名到代码行，
   只能在调试期挂 `HttpOverrides` 记 URL。真正需要修的是依赖本身（`_ProxyHttpServer.start` 没给 handler 挂错误处理），
   我们这边只能兜住 + 记日志。
3. **来源详情页的统计会过期**（**同日已修**，提交 `89fedb9`）：根因是详情页读的 `sourceByIdProvider`
   是一次性的 `FutureProvider` —— 同步在别处写回统计后它不会重读。现在 `SourceRepository.watchById`
   + `sourceByIdProvider` 改成 `StreamProvider`，与它下面的曲目列表一样跟着数据库走。
   真机实测：在来源列表点「同步」（移除 1 首）后，详情页**立刻**显示
   「2 首 · 已同步（新增 0 / 更新 0 / 移除 1）」，不必再杀进程重进。
   回归测试 `test/source_by_id_provider_test.dart`（换成 `FutureProvider` 即失败，实测过）。
4. **原遗留已解决**（见 §27）：失败文案已通过 `PlaybackErrorFormatter` 归纳为简明中文（明文拦截 / 404 / 网络不可达 / 非法参数 / 格式损坏等），并剥离 `PlatformException` 外壳。

---

## 24. iOS 本地音乐（文档选择器 + 安全作用域书签）（2026-09-14）

**问题**：§21 给 Android 补上了 SAF 目录授权，iOS 侧还是缺口 —— 沙盒拿不到用户任意目录的长期访问权，
而桌面那条 `file_selector` 路径只在当前这次进程里有效（重启后目录就不可读），更没法持久化。

**方案**：与 Android 的 SAF 一一对应：用户在系统文档选择器里显式授权一个目录，应用把这份授权存成
**安全作用域书签**（base64，落 `music_sources.local_bookmark`），插件在进程内保持安全作用域，
拿到真实路径后交给 `dart:io` 与 AVPlayer。

**交付物**

| 模块 | 文件 | 说明 |
|---|---|---|
| 原生桥 | `app/packages/tingyu_saf/ios/`（podspec + `TingyuSafPlugin.swift`） | `pickFolderBookmark` 拉起 `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`，返回书签（base64）与目录路径；`resolveBookmark` 解析书签、**开启安全作用域并在进程内保持**，返回绝对路径；`releaseBookmark` 关闭作用域 |
| 来源适配器 | `lib/sources/local/local_bookmark_source_adapter.dart` | 扫描复用 `LocalLibraryScanner`（标签、封面、isolate 分批与 Android / 桌面完全一致），把绝对路径改写成**相对授权目录**的路径；`open()` 用当前解析出的根目录拼回绝对路径 |
| 授权失效 | `lib/sources/local/folder_permission.dart` | `FolderPermissionLostException`：两个平台共用同一句提示；原先的 `SafPermissionLostException` 随之删除 |
| 列语义 | `lib/data/db/schema.dart` | `local_bookmark` 的注释从"旧版迁移留痕"改成"系统授权目录的持久化凭据：Android = tree URI，iOS = 安全书签" |
| 接线 | `lib/app/source_adapters.dart` · `features/sources/{sources_page,source_page}.dart` | iOS 本地来源按书签构造适配器；添加来源走文档选择器；删除来源调 `releaseBookmark`；来源页显示「系统授权的音乐目录（安全书签）」；添加入口副标题按平台改成"本机 / 电脑" |

**为什么库里存相对路径**：iOS 授权到的目录可能位于别的应用或文件提供者的容器里，绝对路径含容器
UUID，会随应用更新变化。若存绝对路径，每次更新后的扫描都会把整个曲库判成"全部移除 + 全部新增"
（合并键就是 `filePathOrUrl`），收藏与播放列表随之丢失。相对路径跨重装稳定，播放时用当前根目录拼回。

**验证**

| 项目 | 结果 |
|---|---|
| `flutter analyze` | ✅ 无问题 |
| `flutter test` | ✅ 108 项全绿，含新增 `test/local_bookmark_source_adapter_test.dart`：相对路径映射、授权目录换位置后匹配键不变、`open()` 拼回绝对路径、书签失效抛授权提示、只调用 iOS 侧方法 |
| iOS 模拟器构建 | ✅ `flutter build ios --debug --simulator`，`tingyu_saf.framework` 已链接进 `Runner.app` |
| 桌面回归 | ✅ `flutter build macos --debug` 通过（插件加 iOS 平台后桌面构建不受影响） |
| 选择器弹出 | ✅ iPhone 17 / iOS 26.5：应用内「音乐源 → 添加来源 → 本地目录」成功拉起系统文档选择器（截图核验，未走 Android 分支、无异常） |

**端到端核验的现状**：模拟器里「选目录 → 入库 → 播放」这一轮没能跑完。

- 模拟器的「文件」里默认**没有任何可授权的目录**：「我的 iPhone」只会列出发了 `UIFileSharingEnabled`
  的应用，而本机模拟器只有系统 App、iCloud 未登录；本机 `com.apple.FileProvider.LocalStorage` 的
  存储根也是空的（实测）。
- 绕开办法（已验证可行，留给下次）：临时装一个空壳 App（`Info.plist` 打开 `UIFileSharingEnabled`
  与 `LSSupportsOpeningDocumentsInPlace`），把测试音频塞进它的 `Documents/`，它就会以
  「我的 iPhone → <App 名>」出现在选择器里。本次已用它把
  「音乐源 → 添加来源 → 本地目录 → 系统文档选择器（能看到该目录）」走通。
- 剩下最后两下（进入该目录 → 右上角「打开」）只能在模拟器上点，而本机 macOS 的辅助功能授权会间歇性
  失效（`osascript` 报 -25211「不允许辅助访问」），无法稳定自动点击；按你的选择先到此为止。

**遗留**：真机上的「选目录 → 入库 → 播放」端到端核验待做。建议路径：`flutter run` 到 iPhone →
「音乐源 → 添加来源 → 本地目录」选一个真实音乐目录 → 核验来源页显示「系统授权的音乐目录（安全书签）」、
库里 `filePathOrUrl` 是**相对授权目录**的路径、点歌出声；随后更新一次应用（或删掉重装），
确认曲目没有被判成「全部新增 / 全部移除」（收藏与歌单还在）。

---

## 25. 手机端「来源管理」改卡片布局（2026-09-14）

**问题**（真机截图实测）：窄屏上 `SourceTile` 把「同步 / 重新登录 / 打开 / 删除」四个控件塞进
`ListTile.trailing`，留给状态文案的宽度只剩几十点 —— 一条「191 首 · 登录已更新（夸克用户）」被折成三四行，
删除按钮还紧贴屏幕边缘（误触风险）。见 `docs/screenshots/mobile-sources-before.png`。

**改法**（`lib/features/sources/sources_page.dart`）：`Platform.isAndroid || Platform.isIOS` 时改用
`_SourceCard`；其余平台保持原来的 `ListTile`（桌面那套一行未动）。

| 区块 | 内容 |
|---|---|
| 标题行 | 来源图标 + 名称（`titleMedium` / w600，超长省略）+ 右上角 ⋮ 菜单（打开 / 删除来源） |
| 状态行 | `N 首 · 同步状态`、`上次同步 MM-DD HH:MM`（时间从带秒的完整时间戳压缩到一行放得下） |
| 进度 | 同步中显示 2px 进度条 + 当前文件名（单行省略） |
| 操作行 | 单独一行：`同步`（tonal，主操作）+ `重新登录`（仅夸克） |
| 整卡 | 可点，进来源详情 —— 比原来只有一个小箭头可点好按 |

删除从"行尾一个垃圾桶图标"收进 ⋮ 菜单（仍有二次确认）：手机上的破坏性操作不该紧贴屏幕边缘。
两端共用同一套动作实现（`_reloginQuarkSource` / `_confirmDeleteSource`，从 `SourceTile` 里提出来）。
改后见 `docs/screenshots/mobile-sources-after.png`。

**验证**：`flutter analyze` 干净、`flutter test` 114 项全绿（本次是纯布局调整，按约定以真机截图核验为准）；
真机（Xiaomi 24031PN0DC / release 包）逐项核过：状态文案不再折行、⋮ 菜单是「打开 / 删除来源」、
点卡片本体进详情页、同步与重新登录按钮位置正常；桌面构建与启动正常（桌面分支未改动）。

---

## 26. 非完整来源扫描不再误删曲库（2026-09-25）

**问题**：来源同步把每次扫描都当作完整快照。目录暂时不可访问、子目录读取失败、用户取消扫描或达到
文件数上限时，扫描结果只包含部分甚至零首曲目；合并层仍删除所有“本次未见”的旧曲目，并级联删除收藏状态
和播放列表引用。

**修复**：

- `SourceScanResult` 与各来源扫描结果显式携带 `cancelled`、`truncated`、`skipped` 完整性信息，
  `isAuthoritative` 仅在扫描未取消、未截断且没有跳过条目时为真。
- 本地文件系统把根目录不存在和子目录读取失败计入跳过项；SAF、WebDAV、夸克扫描在达到文件数上限时
  标记为截断。所有来源适配器统一传播这些状态。
- `TrackRepository.mergeScan(removeMissing:)` 只在权威完整快照下删除未见曲目；非完整扫描仍正常新增和更新
  已扫描曲目，但保留未见曲目、收藏和播放列表引用。
- 来源同步后的曲目数改为按数据库实际结果重算；状态文案明确显示“部分同步，未扫描曲目已保留”。

**验证**：

- 新增端到端同步回归：本地来源目录暂时不存在时，旧曲目、收藏、播放列表引用和来源曲目数全部保留。
- 新增合并层及 Local / SAF / WebDAV / 夸克扫描边界测试，覆盖跳过、取消、截断与完整扫描。
- `flutter test`：119 项全绿；`flutter analyze`：在纯 ASCII 临时工作区无问题。
- Linux debug 应用真实进程烟测：先扫描 1 首 WAV 入库，再删除整个来源目录并用同一数据库重启；
  第二次输出 `merge=+0/~0/-0`，曲库仍为 `tracks=1`。

---

## 27. M5 播放失败文案中文化与异常归类（2026-09-25）

**问题**：§23 中虽然打通了播放失败在 UI (SnackBar) 弹出提示的通道，但 `PlaybackFailure.message`
直接透传底层的 `PlatformException`（如 `PlatformException(Error: java.lang.IllegalArgumentException, ...)`）、
ExoPlayer 泛型错误（`Source error`）或 libmpv 英文消息，未对明文拦截、文件不存在、网络不可达等常见失败做中文归类。

**方案**（`lib/playback/playback_error_formatter.dart`）：

- 统一由 `PlaybackErrorFormatter.format(Object? error)` 进行分析与归类：
  1. **保留成熟领域业务异常**：`FolderPermissionLostException`、`QuarkException`、`WebDavException` 优先使用自带的明确中文提示；
  2. **强类型异常映射**：`FileSystemException`（errno 2 / 13）分别映射为「音频文件不存在或已被移动」与「没有访问权限」；`SocketException` / `HandshakeException` / `HttpException` 映射为「网络连接失败，请检查网络设置」；
  3. **底层引擎原文归类**：剥离 `PlatformException` 与 `Exception:` 技术外壳；若自身已含中文则直接展示；英文原文按关键词归类为明文 HTTP 拦截、404/文件丢失、401/403 权限异常、429/503 频控、网络故障、参数非法、格式损坏与通用资源错误。
- 在三处播放失败源头统一接入：
  - `JustAudioEngine._fail`（移动端 ExoPlayer / AVPlayer）；
  - `MediaKitEngine._fail`（桌面端 libmpv）；
  - `PlaybackController._reportResolveFailure`（解析直链与校验阶段）。

**验证**：

- 新增单元测试 `test/playback_error_formatter_test.dart`（9 组，覆盖明文拦截、404、网络不可达、权限、流控、参数非法、格式损坏、Source error 与中文保留）。
- 扩充 `test/playback_controller_resolve_failure_test.dart`（离线网络异常与目录授权失效在控制器的中文快照验证）。
- `flutter test`：130 项全绿；纯 ASCII 镜像下 `flutter analyze` 零告警。
- Linux debug 桌面二进制重新构建并通过冒烟运行。

---

## 28. AI 智能识别与曲库清洗迁移（2026-09-25）

**背景**：旧版 Swift 实现了 `AIService` 与 `AIMetadataParser`，支持接入 OpenAI 兼容的大语言模型（内置 DeepSeek、Qwen、Kimi、OpenAI、Ollama 预设）对乱码/复杂文件名进行批量清洗识别。该能力在 Flutter 跨平台迁移中落地。

**方案**：

1. **协议层 (`lib/sources/ai/ai_config.dart` · `ai_client.dart`)**：
   - 沿用工程现有的 `Dio`，实现标准 OpenAI `/chat/completions` 请求；
   - 支持动态鉴权（有 key 注入 `Bearer` 头，本地 Ollama 免密时不注入）；
   - 异常映射：401 认证失败、429 限流、5xx 服务端异常、网络断连超时及畸形结构解析失败；
   - 内置 `testConnection()` 发送快速探测。

2. **元数据解析器 (`lib/sources/ai/ai_metadata_parser.dart`)**：
   - 注入资深音乐专家 System Prompt，约束大模型输出严格 JSON 数组；
   - 自动截取 JSON 边界，剥离 ```` ```json ```` 外壳与模型回复闲聊，容错缺失字段并复用 `ParsedSongInfo`。

3. **配置存储与洗库服务 (`lib/sources/ai/ai_settings_repository.dart` · `ai_library_refactor_service.dart`)**：
   - 基于系统安全存储（`SecureStore`）加密存储完整配置与 API 密钥，且自动无缝读取旧版 Swift 遗留的 `tingyu_ai_api_key`；
   - 洗库服务按批次（默认 25 首）拉取曲目，调用 AI 识别；仅在标题/歌手/专辑发生有效变化时写回数据库，并可选联动 `LibraryEnrichmentService` 自动重新下载新封面与歌词；
   - 支持外部中途取消、单批次失败容错及 300ms 批次间限流防封禁。

4. **UI 与路由集成 (`lib/features/settings/ai_settings_page.dart` · `router.dart` · `settings_page.dart`)**：
   - 注册 `/settings/ai` 路由；在主设置页新增「智能」区块与磁贴；
   - 支持服务商预设切换（自动带出端点与模型）、密钥显隐、连通性实时测试、整库清洗进度条与中途取消。

**验证**：

- 单元测试：
  - `test/ai_client_test.dart`（8 项通过）；
  - `test/ai_metadata_parser_test.dart`（5 项通过）；
  - `test/ai_settings_repository_test.dart`（4 项通过）；
  - `test/ai_library_refactor_service_test.dart`（3 项通过）；
  - `test/ai_settings_page_test.dart`（2 项通过）。
- `flutter test`：全套 152 项测试全绿；ASCII 路径静态分析 `flutter analyze` 零告警。
- Linux debug 桌面端冒烟验证：直跳 `/settings/ai` 成功加载并正常渲染。

---

## 29. 播放模式（随机 / 顺序）与循环控制补全（2026-09-25）

**背景**：原 Flutter 播放层缺少随机播放（Shuffle）与循环模式控制（播完停止 / 列表循环 / 单曲循环），队列被硬编码为单一顺序无限循环，且传送器界面上缺少控制按钮。

**方案**：

1. **数据模型与快照 (`lib/playback/playback_snapshot.dart`)**：
   - 引入 `PlayOrder { sequential, shuffle }`；
   - 引入 `PlaybackRepeatMode { off, all, one }`（避免与 Flutter 3.27+ material 的 `RepeatMode` 产生重名导入冲突）；
   - 快照携带 `playOrder` 与 `repeatMode` 响应式同步到 UI。

2. **控制器逻辑与队列重排 (`lib/app/playback_controller.dart`)**：
   - `toggleShuffle()`：在顺序与随机间切换；进入随机时保留当前播放曲目为首项并打乱其余曲目，退出随机时基于 `_originalSourceQueue` 恢复原始曲库顺序；
   - `cycleRepeatMode()`：在「列表循环 → 单曲循环 → 顺序播完停止 → 列表循环」间三态轮转；
   - `playTracks(..., shuffle: true)`：支持直接以随机打乱顺序起播；
   - 单曲循环结束时自动重播当前曲；播完停止模式在到达末尾后不再无限循环。

3. **界面层完整接入 (`lib/features/player/playback_controls.dart` 等)**：
   - `PlaybackControls`：在核心播放区两侧增设 Shuffle（随机）与 Repeat（循环模式）图标按钮，单曲循环显示带 `1` 的图标并高亮主题色；
   - 专辑页 (`AlbumDetailPage`)、艺术家页 (`ArtistDetailPage`)、歌单页 (`PlaylistPage`) 头部统一增设「随机播放」快捷操作按钮。

**验证**：

- 单元测试：新增 `test/playback_controller_modes_test.dart`（3 项通过，覆盖循环切换、随机与还原原序、直接随机起播）。
- `flutter test`：全套 156 项测试全部绿灯通过；ASCII 镜像路径静态分析零告警。
- 本地 Release 产物已编译并覆盖安装到系统，启动测试平稳。

---

## 30. 移动端返回手势与二级页面导航补全（2026-09-25）

**问题**：Android 全面屏手势下返回行为不符合原生预期。

1. **缺少边缘滑动返回**：`pageTransitionsTheme` 未配置，Android 默认使用的转场没有交互式「右划返回」；
2. **二级页面无法逐级返回**：专辑详情、艺术家详情、来源详情、设置、正在播放等页面全部用 `context.go(...)` 打开，`go` 是**替换**当前路由而不是入栈，导航栈深度恒为 1 —— `canPop()` 永远为 false，系统返回直接退出应用，且页面上没有返回按钮；
3. **正在播放页仍显示底部导航**：全屏舞台下 Tab 栏与迷你播放条没有隐藏。

**方案**：

| 层面 | 改动 |
|---|---|
| 转场动画 | `lib/app/theme.dart`：`pageTransitionsTheme` 指定 Android = `PredictiveBackPageTransitionsBuilder`（Android 14+ 预测式返回），iOS/macOS = `CupertinoPageTransitionsBuilder`（边缘右划返回），桌面保持 `ZoomPageTransitionsBuilder` |
| 路由语义 | 顶层 Tab 之间继续用 `context.go`（不压栈 → 系统返回退出应用）；所有二级/三级入口改为 `context.push`（入栈 → 系统返回与边缘滑动都能逐级 pop）：专辑列表/详情、艺术家列表/详情、歌单详情、来源列表/详情、设置、AI 设置、正在播放（迷你条与桌面播放条） |
| 返回按钮 | `AlbumDetailPage` / `ArtistDetailPage` 补上 `Scaffold`+`AppBar`+`BackButton`（此前完全没有返回入口，只能靠系统返回）；`PlaylistPage` / `SourcePage` / `SettingsPage` 在 `context.canPop()` 为真时显示 `BackButton` |
| 空态兜底 | 详情页空态按钮改为 `context.canPop() ? context.pop() : context.go(列表页)`，深链直达时也能退回列表 |
| 全屏舞台 | `MobileShell`：`/now-playing` 下 `bottomNavigationBar` 置空，隐藏 Tab 栏与迷你播放条 |

**验证**：

- 新增 `test/navigation_gesture_test.dart`（3 项通过）：
  1. 四个根 Tab 之间 `go()` 切换后 `canPop()` 恒为 false（系统返回直接回桌面）；
  2. 曲库 →（push）设置 →（push）AI 识别，`canPop()` 逐级为 true，`BackButton` 两次逐级 pop 回曲库；
  3. 曲库 → 专辑列表 → 专辑详情，详情页自带返回按钮，逐级 pop 回曲库。
- `flutter test`：全套 160 项全绿；ASCII 镜像 `flutter analyze` 零告警。
- Release 重新构建并覆盖安装到本机，启动冒烟无异常。

---

## 31. 全面优化（正确性 / 性能 / 健壮性 / 工程）（2026-09-26）

一次覆盖全应用的优化，来源是三路只读审计（播放层、数据层、来源层、UI 层、工程脚手架）
加上真实库（196 首 / 3 个来源 / 47 张专辑）的实机复现。下面按严重程度列出改动、证据与验证方式。
所有结论都在本机 Linux Release 包 + Xvfb 里跑过真实进程验证（截图见下），不是只看代码。

### 31.1 曲库被误删（严重，数据丢失）

**问题**：`SourceScanResult.isAuthoritative` 决定合并时是否删除"本次没扫到的旧曲目"。
夸克与 Android SAF 的扫描器在**碰到层级上限时静默丢弃整棵子树**，却仍返回 `truncated: false`：

- `quark_drive_client.dart`：`if (depth > maxDepth) continue;`、子目录入队条件 `depth + 1 <= maxDepth`；
- `saf_source_adapter.dart`：`if (directory.depth > maxDepth) continue;`。

于是 maxDepth 之外的歌在库里被判为"已删除"，连同播放列表引用一起被外键级联清掉。
WebDAV 的同款逻辑是对的（会置 `truncated = true`），说明这是两处遗漏而不是设计。

夸克还有第二条同类路径：`_listFolderPage` 在**响应结构不符**（缺 `data.list`、非 JSON）
时返回空列表，调用方据此认为"这是个空目录"→ 权威快照 → 整个目录的曲目被删。

**修法**：

| 位置 | 改动 |
|---|---|
| `quark_drive_client.dart` | 层级越界、翻页翻满、`total` 比取回的多、响应结构异常，四种情况统一 `complete: false` 并带上原因；`total`（请求里本来就带 `_fetch_total=1`）用于兜底校验 |
| `saf_source_adapter.dart` | 层级越界时置 `truncated` + 原因 |
| `webdav_client.dart` | 补齐 `truncationReason`（行为不变，只是文案更准） |
| `source_adapter.dart` | 新增 `truncationReason`；`isAuthoritative` 语义不变 |
| `source_sync.dart` | 同步状态文案改用来源给的具体原因（层级上限 / 数量上限 / 结构异常），不再一律写"达到数量上限" |
| `test/quark_test.dart` | 原先**把旧行为钉死**的用例（`maxDepth=1 → truncated isFalse / isAuthoritative isTrue`）改为断言新行为，并新增"结构异常不算权威快照""total 对不上按不完整处理"两条回归用例 |
| `test/saf_source_adapter_test.dart` | 新增层级越界用例 |

### 31.2 播放正确性（单曲循环 / 播完停止 / 预取竞态 / 失败提示）

四类只有真机才能暴露的缺陷，全部补测试（并确认过它们在修前会失败）：

1. **单曲循环从来没生效**：循环模式只存在于控制器里，从未下发给引擎；而 `just_audio` 只在
   **整个播放列表**播完时才报 `completed`（默认 `LoopMode.off`），队列里通常有 2–3 首预取，
   所以除了最后一首以外都不会走进"重播当前曲"分支。现在 `PlaybackEngine` 增加
   `setRepeatMode`：`just_audio` → `LoopMode.one`，`media_kit` → `PlaylistMode.single`。
2. **播完停止后播放键与下一首都是死的（移动端）**：`just_audio` 在 `completed` 状态下
   `play()` 直接成功返回但不重新出声，`seekToNext()` 也没有下一首。现在停止分支同时
   `pause()` + `seek(0)`，`togglePlayPause()` 也会先处理 completed 状态。
3. **预取与队列重建竞态**：重建队列期间旧会话的进度事件仍会触发 `_ensureAhead`，把新解析的
   条目 append 到**旧引擎队列**，或把 `_nextSourceIndex` 提前推走 —— 结果是这一轮少放一首歌，
   或三份平行数组与引擎队列错位（高亮、`next()` 判断、播放历史全指错）。现在用 `_queueArmed`
   在 `setQueue` 返回前挡住预取，`playAt`/`next` 会先等在建的预取落地。
4. **取直链失败的提示会被下一个进度 tick 抹掉**：控制器写入的 failure 被引擎快照的
   `copyWith` 覆盖（引擎那份恒为 null）。现在控制器自己留一份 `_pendingFailure` 并参与合并，
   只在"新会话开始/换到另一首真的在播"时清空。
5. **歌单里有重复曲目时，关闭随机会让队列多出一行**：还原顺序原先按 id 集合过滤原始队列，
   同一首歌的两份都会被塞回尾部。现在按重数逐个消耗，队列长度与内容都不变。

### 31.3 播放与列表性能（每个进度 tick 的全应用重建）

引擎每 60ms（media_kit）/ 200ms（just_audio）推一份新快照，而 `PlaybackSnapshot` 没有值相等语义，
Riverpod 因此认定"状态变了"→ **每个 watcher 都重建**：曲库/专辑/艺术家每一行、队列面板每一行、
迷你条、播放条、歌词面板、正在播放页的封面舞台与流体背景。

修法分三层，并用可测的断言固定下来（`test/ui_rebuild_seek_test.dart` 用
`debugOnRebuildDirtyWidget` 数重建次数）：

| 层 | 改动 | 修后每次 tick 的重建 |
|---|---|---|
| 快照 | `PlaybackSnapshot` 补 `==`/`hashCode`（`PlaybackFailure` 仍按实例身份比较，保住"同一失败只提示一次"的约定） | — |
| 行/列表 | 曲库、专辑、艺术家行只订阅"这一行是不是当前曲目"（`isCurrentTrackProvider(id)`）；队列面板改为**一次**取全库建 id→Track 映射（原先每行一个 drift 流 = N 条 SQLite 订阅），行组件降级为 `StatelessWidget` | 0 行 / 0 封面 |
| 播放界面 | 迷你条 / 播放条 / 传送器 / 正在播放页拆成"只订阅身份"的外层与"只订阅进度"的内层；进度条是唯一随 tick 重建的东西 | 0 封面 / 0 标题 / 0 按钮 |

另外：播放条此前**边拖边 seek**（引擎位置和手指互相掰手腕，拇指会跳），现在复用
`playback_controls.dart` 里已有的"拖动期间用本地值、松手才 seek"模式（提升为共享 `SeekBar`）。

### 31.4 封面：91% 的字节是重复的

实机封面缓存 353 个文件 / 62.6MB，按内容哈希去重后只需 **5.9MB（省 91%）**——
一张专辑的内嵌封面在该专辑每首歌里都存了一份。改动：

- `CoverStore.save(bytes)` 改为**内容寻址**（FNV-1a over bytes + 扩展名），已存在则跳过写入；
- 本地扫描器在子 isolate 里用同一个 `CoverStore.coverNameFor`，重复扫描不再白写几百 MB；
- 新增 `CoverStore.pruneUnreferenced(keep)` 与 `TrackRepository.coverNamesInUse()`，
  在**完整同步**之后回收孤儿封面（换封面/换来源留下的旧图，以及历史上按 key 命名时代的重复副本）；
- 封面组件按显示尺寸解码（`cacheWidth`/`memCacheWidth` × devicePixelRatio），
  44px 缩略图不再按原图分辨率解码；艺术家头像同理。

### 31.5 数据层

- **schemaVersion 1 → 2**：补 `(artist, album)`、`date_added`、`is_favorite`、
  `playlist_items.track_id` 四个索引，并补上真正的 `onUpgrade`（此前版本号钉死在 1，
  任何索引/表/列的修正都永远到不了老库）。`playlist_items.track_id` 缺索引时，
  曲目删除的 `ON DELETE CASCADE` 会退化成整表扫描。
  实测查询计划（真实库）：专辑聚合 `SCAN tracks USING COVERING INDEX idx_tracks_artist_album`、
  收藏 `SEARCH ... USING INDEX idx_tracks_favorite`、最近添加 `USING INDEX idx_tracks_date_added`。
- **扫描合并走 batch**：`mergeScan` 原先逐条 await 插入/更新（drift 每条语句一次跨 isolate 往返），
  现在整轮压成一个 batch。
- **播放计数原子自增**：`recordPlay` 从"读出来 +1 写回"改为一条 SQL 自增（既省一次往返，也不丢并发计数）。
- **时长回填（两条路）**：夸克/WebDAV 的目录接口不给时长，扫描只能写 0，界面整库显示
  `--:--`（实机 191/196 首）。① 播放器拿到解码器给出的真实时长后**每首只写一次**回库；
  ② 元数据补全的搜索候选里本来就带时长（`MetadataCandidate.duration`），现在会在
  "库里还没有时长"时写回 —— 不播放也能补齐。为避免"整库几百首一起联网"，自动补全一次
  会话最多补 60 首（先封面、再歌词、最后时长），剩下的留给下次会话或来源页手动补全。
- 曲库库文件本身：迁移与索引变更都在真实库副本上验证过（196 首、歌单引用完整），再对真实库执行。

### 31.6 来源层与网络

- **每个来源一个长驻适配器**（`SourceAdapterCache`）：夸克的直链缓存（5400s）挂在客户端实例上，
  而 `TrackResolver` 此前**每首歌都新建适配器**，等于这个缓存从未生效、每次播放都要多打一次网盘接口。
  缓存指纹 = 参与构造的来源字段 + `SecureStore.credentialEpoch`（写入凭据即失效），
  构造失败不留在缓存里；删除来源时显式 `evict`。
- **幂等请求的重试与退避**（`HttpRetry`）：列目录 / PROPFIND / 取直链此前一次失败就让整次扫描或
  播放失败。现在对 429/503/5xx 与连接层错误做 2 次指数退避重试（带抖动，避免多个来源同时重放），
  401/403/404 一律不重试。
- **同步进度不再恒为 100%**：`onProgress` 曾把 `done` 同时当成 `total`。扫描阶段拿不到总数
  （夸克/WebDAV 是边翻页边发现），现在如实只报进度数与已扫描数量，进度条走不确定态。
- **重复扫描不再逐文件重解析**：本地目录来源第二次同步时，大小与修改时间都没变的文件直接
  按"文件事实已知"处理，跳过标签解析与内嵌封面落盘（合并层只覆盖文件事实，不会用稀疏结果
  冲掉已刮削的标题 / 时长 / 封面）。SAF（Android）不做这项优化：它的列举本来就要跨平台通道，
  且 mtime 口径不稳定。
- **SAF 调用加了超时**：第三方 DocumentProvider 卡住不返回时，扫描原先会永远停在那一层
  （取消检查发生在目录之间）；现在单次列举 30s、轻量调用 15s 超时，超时按"该目录读不出来"
  记 skipped 并继续，本次扫描因而不算权威快照。
- **歌单曲目数改成一次聚合查询**：歌单列表原先对每个歌单各 JOIN 全表只为印"3 首"。

### 31.7 UI / UX

- **手机端终于有搜索入口**：搜索框此前只存在于桌面侧栏，Android/iOS 上根本没有搜索。
  曲库页在手机布局下自带搜索框（自己持有 controller，别处清空时同步），并且把防抖转发收进
  `SearchQueryController`（两个入口少写一行就会变成"每敲一键查一次全库"或"搜不到"）。
- 手机/桌面布局判断从 `dart:io Platform` 改为 `Theme.of(context).platform`：
  前者只看宿主系统，在桌面跑 widget 测试时手机布局的代码路径根本无法验证。
- **搜索结果不再无声截断**：命中 200 首以上时给一行"命中超过 200 首，仅显示前 200 首"。
- **自动补全元数据不再每次启动全库跑一遍**：改为一个会话最多一次，且 provider 释放后停止遍历。
- 歌单页加载中不再误报"播放列表不存在"，失败有独立错误态与重试；侧栏歌单加载失败也有一行提示 + 重试。
- 手机端 `visualDensity` 用标准密度（`compact` 会把 Material 点击目标压到 48dp 以下），桌面保持原样。
- macOS 菜单「播放 / 暂停」从**空格**改为 ⌘P：AppKit 的菜单 key equivalent 在文本输入之前派发，
  侧栏搜索框里按空格会被菜单吃掉。
- 删除确认死代码：`player_page.dart`、`formatBytes()`、`valueOrAbsent()`。

### 31.8 工程脚手架

| 项 | 改动 |
|---|---|
| Android 正式签名 | `build.gradle.kts` 支持 `app/android/key.properties`（不入库）；没有密钥时退回 debug 签名并打印一行说明。此前 release APK 一律用 debug 密钥签名，而 CI 会把该 APK 发到 GitHub Release |
| CI | 构建矩阵补 **iOS**（`--no-codesign`，只做"能编过"的验证）；release job 仍只打包四大平台 |
| 桌面标题 | Linux/Windows 窗口标题改成「听屿」（macOS/Android 早已是中文）；MSVC 源码里的宽串用 `\u` 转义，不依赖源文件编码 |
| 元数据 | `pubspec.yaml` 的 description 从模板占位改为项目描述 |
| 清理 | 仓库根目录的 0 字节文件 `0`（未被忽略、`git add -A` 会入库）已删除 |
| 退出 | 桌面端退出走 `AppLifecycleListener`：此前 `TingyuAudioHandler.dispose()` **没有任何调用方**，关窗后原生播放器与快照订阅一直留到进程结束；macOS 的「退出听屿」菜单也改走同一出口 |

### 31.9 验证

- `dart analyze`：零问题（`flutter analyze` 在本机非 ASCII 路径下会因 analysis server 的 LSP 解析崩溃，改用 `dart analyze`）。
- `flutter test`：**233 项全绿**（起点 173 项）。新增 14 个测试文件，覆盖：
  快照相等语义、播放序列化与预取竞态、时长落库、just_audio 的 play() 语义、
  media_kit 的 processing 映射、UI 重建次数与拖动 seek、搜索防抖与截断信号、
  歌单状态、主题密度、移动端搜索、来源适配器缓存、HTTP 重试、索引迁移、
  重复扫描跳过解析（含"稀疏结果不覆盖已刮削元数据"这条安全性质）、
  候选时长补齐与自动补全的每会话上限。
  其中"修前会失败"的用例（循环模式下发、失败提示存活、预取竞态、重复扫描、层级截断）
  都是先在旧代码上跑出失败再修的。
- Linux Release 包在 Xvfb 里跑真实进程：曲库 196 首渲染正常、专辑封面正常、来源页正常、
  `dart:io` 侧扫码入库正常；用 `TINGYU_DEBUG_SOURCES` 播了两首本地曲目，
  快照从 `buffering` → `ready`、`position` 正常推进、`duration=8000ms`、无 failure、无未捕获异常。
- 时长补全对真实库 + 真实网络实测：跑一次真实进程（约 2 分钟）后，夸克来源里
  **0/191 → 37/191** 首拿到了真实时长（多张专辑整张补齐，如「八度空间」10/10、
  「十一月的萧邦」10/10），专辑页合计从 `--:--` 变成 `43:07`，单曲为 4:12 / 4:05 / 5:17 …
  这些数字与该专辑的实际曲长一致。
- 迁移在**真实库的副本**上验证（user_version 1→2、四个索引就位、196 首与歌单引用不动），再对真实库执行。

### 31.10 未做（明确记录，避免"以为做了"）

- **Windows / Linux 的全局键盘快捷键**：桌面快捷键目前只有 macOS 菜单栏。做成跨平台需要
  "焦点在输入框时不抢键"的判断，本机无法验证 Windows/Linux 的输入路径，故未动。
- **切 Tab 丢滚动位置**：两套外壳共用 `ShellRoute`，切 Tab 会重建页面（滚动位置丢失）。
  改成 `StatefulShellRoute.indexedStack` 会与"二级页面保留 Tab 栏"的现有导航语义冲突，
  影响 30 节刚定稿的返回手势行为，因此保留现状。
- **iOS/Android 实机回归**：本次验证在 Linux 桌面完成，移动端结论来自单元/组件测试与代码路径分析。
- **元数据补全没有并发化**：一轮补全仍是串行（每首 1–3 次请求到 QQ 音乐 / LRCLIB / 网易云）。
  它已经从"每次打开曲库都跑"改成"一个会话最多一次 + provider 释放即停"，这是主要成本；
  再往上加并发要面对这几家的限流与风控，收益不确定，故未做。
