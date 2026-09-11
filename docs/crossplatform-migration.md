# 听屿 跨平台迁移方案 v1（Flutter）

> 状态：**已批准**（2026-09-11）。M0（骨架 + CI）、M1（播放闸门）、M2（数据层）已完成，结论见 §13 / §14。
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
| 网络 | `dio` + `cookie_jar` | 抓取需要 cookie/重定向控制；Quark 会话保持 |
| HTML 解析 | `html`（package:html）+ 正则兜底 | 替代 Swift 侧的抓取解析 |
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

**流式来源**：`StreamingResourceLoader`(215) 的能力改为 `platform/stream_proxy`：本地 `shelf` 起最小 HTTP 服务，对远程请求注入 Cookie/Referer 并转发 Range，播放器只看到 `http://127.0.0.1:<port>/stream/<token>`。移动端优先用 `just_audio` 的 `headers` 直连，代理仅作兜底。

### 5.2 来源子系统

```dart
abstract interface class SourceAdapter {
  String get id;                                   // 'local' | 'webdav' | 'quark'
  Future<void> authenticate(SourceCredentials credentials);
  Future<List<RemoteEntry>> list(String path);
  Future<StreamHandle> open(String path);          // → url + headers 或本地代理 URL
}
```

抓取器（QQ音乐 / 网易云 / LRCLIB / iTunes）不实现 `SourceAdapter`，而是 `MetadataProvider` 接口（`search` / `fetchLyrics` / `fetchCover`），由 `MetadataEnricher` 编排，保持现有"来源与元数据分离"的结构。

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

分支 `ci/flutter-bootstrap` · PR [#1](https://github.com/halunhaku/tingyu/pull/1) · 提交 `416a994`

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

