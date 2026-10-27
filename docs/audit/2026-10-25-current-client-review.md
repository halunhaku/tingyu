# 听屿 Flutter 客户端技术底账

> 历史记录：旧 Swift 客户端及其一次性导出工具已从当前工作树清理；下文相关路径描述的是当时的状态。

审查日期：2026-10-25（Asia/Shanghai）。审查对象为现役 `app/`，按 macOS、Windows、Linux、Android、iOS 五平台记录；`legacy-swift/` 仅用于核对历史能力，不计入当前实现规模。本文是迁移评估输入，不作是否迁移或目标技术选型的判断。

## 1. 基线、方法与证据边界

| 核验项 | 本轮实测结果 |
|---|---|
| 工作区 HEAD | `19ae15c9114f463123bfe45a24f98f1b9af44e66`，PR #2 合并提交 |
| GitHub main | 通过平台只读 git 的 `ls-remote origin refs/heads/main` 查询，返回同一完整 SHA；未使用旧的 origin/main 推断 |
| `app/pubspec.yaml` | `version: 2.0.0-preview+5` |
| 重设计目录 | `docs/ui-redesign/` 存在 |
| 工具链 | `flutter --version`：Flutter 3.47.2 / Dart 3.13.2；framework `d3b14c8769`，engine `a804b26164` |
| 审查开始时工作树 | `git status --short` 为空 |
| 本机运行曲库 | 对运行进程打开的 SQLite 使用 `mode=ro` 查询：178 首曲目、1 个来源、0 个歌单；未读取或输出账号凭据 |
| 本轮执行边界 | 阅读与测量代码、锁定依赖解析、静态分析和既有测试；未修改应用/测试/平台代码，未生成替换数据库代码，未重建或操作正在运行的产品 |

代码统计只取 `git ls-files` 跟踪的文件；行数为逐文件字节中的换行符数量，等价于 `wc -l`，**包含空行和注释，不等于有效代码行**。生成代码单列，排除 build、Pods、ephemeral、pub cache 和冻结 Swift 旧版。原生代码包括 `.swift/.kt/.java/.m/.mm/.c/.cc/.cpp/.h`；配置文件另记，不把图片、工程 XML 当原生源代码。

本文区分：**本轮实测**、**当前代码路径分析**、**仓库历史记录**和**尚未验证**。目录/导入分类比例只是有明确口径的迁移规模代理，不能当作可自动复用比例或工期。

## 2. 架构与分层

### 2.1 职责与依赖

| 层/目录 | 当前职责 | 主要耦合点 |
|---|---|---|
| `main.dart` | Flutter binding、错误守卫、平台引擎初始化、AudioSession、Android 通知权限、AudioService、ProviderScope、MaterialApp.router、macOS 菜单与退出释放；还含调试/验证入口 | 入口同时承担平台启动、依赖装配和界面根节点；不是纯业务代码 |
| `lib/app/` | Riverpod providers、偏好、路由、PlaybackController、TrackResolver、来源适配器缓存 | 控制器直接依赖 `Ref`、drift 实体、系统 AudioHandler；没有完全独立的领域层 |
| `lib/data/` | drift schema/迁移、repositories、扫描结果模型、封面文件缓存、设置、凭据、旧库导入、元数据落库 | UI 和控制器直接使用生成 `Track` 等类型；CoverStore、SecureStore、SettingsStore 依赖平台目录或插件 |
| `lib/sources/` | 本地/SAF/iOS 书签、WebDAV、夸克、元数据抓取、AI 接口与解析 | `SourceAdapter.scan()` 返回事实，`open()` 返回 URI/headers；协议层可分离，但文件访问、凭据及授权有平台依赖 |
| `lib/playback/` | 统一 PlaybackEngine、两个具体引擎、播放快照/条目/错误、TingyuAudioHandler 系统媒体桥 | 接口统一命令，不统一底层平台能力；基类仍导入 Flutter foundation，AudioHandler 依赖 audio_service |
| `lib/design/` | 语义令牌、Material 主题、响应式外壳、交互与可复用组件 | 与 Flutter widget/rendering/theme/semantics 深度绑定 |
| `lib/features/` | 曲库、搜索、来源、舞台、专辑、艺术家、歌单、设置、引导、共享动作 | ConsumerWidget/State、路由与 repositories/providers 直接相连；来源同步编排还放在 features 内 |
| `packages/` | 自有移动目录桥 `tingyu_saf`、vendor 的 Windows 媒体会话后端 | MethodChannel、Swift/Kotlin/C++ 与 Flutter plugin 注册 |

调用主线：页面 → Riverpod/PlaybackController → TrackResolver/SourceAdapter → PlaybackEngine；系统媒体命令经 TingyuAudioHandler 转发。扫描主线：SourceSyncController → SourceAdapter.scan → TrackRepository.mergeScan → SQLite → providers → 页面。元数据抓取结果经 LibraryEnrichmentService 写入 repository/CoverStore。

### 2.2 状态与路由

[providers.dart](../../app/lib/app/providers.dart) 集中装配 Provider、StreamProvider、FutureProvider.family 和 Notifier。数据库与文件 store 随容器提供，AudioHandler 由启动入口 override；页面的选择、页数、搜索框、滚动控制器等留在 ConsumerState。搜索输入分即时状态与 250ms 防抖状态；最近搜索保存在进程内。

[router.dart](../../app/lib/app/router.dart) 使用一个 `ShellRoute` 包裹浏览页；`/stage`、`/queue`、`/lyrics`、`/onboarding` 位于根 Navigator。根目的地用 `go`，详情/舞台用 `push`；曲库排序与来源筛选写入 query，专辑键是 artist+album。当前没有 StatefulShellRoute 多分支保活，切换页面的滚动位置需要单独评估，不能因有路由库就认为已保留。

### 2.3 数据层

[database.dart](../../app/lib/data/db/database.dart) 的 `schemaVersion` 为 2，含 `tracks`、`music_sources`、`playlists`、`playlist_items` 四张表。默认连接在应用支持目录的 `library.sqlite`，由 `NativeDatabase.createInBackground` 执行数据库操作。日期按文本存储；外键开启，歌单条目引用级联删除；迁移补齐缺表、索引和部分旧列，并处理旧 `sources` 表。

[TrackRepository](../../app/lib/data/repositories/track_repository.dart) 承担查询、分页、聚合、扫描合并、收藏/历史/时长与富化写回。扫描以 sourceId+filePathOrUrl 对齐；只有完整、无跳过/取消/截断的扫描才删除旧曲目。封面二进制不入库，CoverStore 使用内容哈希文件名并清理无引用图片。迁移时必须保留这些数据语义，不能只复制表字段。

### 2.4 双引擎与系统会话

[engine_factory.dart](../../app/lib/playback/engine_factory.dart) 明确按平台选择：macOS/Windows/Linux → MediaKitEngine（libmpv）；Android/iOS → JustAudioEngine（ExoPlayer/AVPlayer）。这是平台分工，**不是运行失败自动切换备用引擎**。

PlaybackController 管理完整来源队列、懒解析与后续 2 首预取、随机/循环、世代号与并发闸门、播放历史/时长回填。两个引擎将底层事件转为 PlaybackSnapshot，TingyuAudioHandler 则将快照转换为系统 playbackState/mediaItem，并把媒体键命令送回引擎。macOS 用 audio_service 自带实现，Windows 用本地 audio_service_win，Linux 用 audio_service_mpris。

耦合风险集中在队列身份、并行索引数组、completed/playing 差异、短期直链缓存、iOS 安全作用域生命周期和系统媒体元数据更新。更换界面后，这些行为契约仍需保留；单看播放器页面大小不能代表播放系统的迁移工作量。

## 3. 代码量与分布

### 3.1 总量

| 范围 | Dart 文件 | 物理行 | 其中生成行 |
|---|---:|---:|---:|
| `app/lib` | 134 | 37,680 | 4,436 |
| `app/lib` 排除 `database.g.dart` | 133 | 33,244 | 0 |
| `app/packages/tingyu_saf` | 1 | 155 | 0 |
| `app/packages/audio_service_win`（补充纳入） | 1 | 120 | 0 |
| `app/test` | 71 | 15,180 | 0 |

### 3.2 按模块统计

同级直属文件归入该目录一行，子模块独立列出；各行互不重复，合计等于 `app/lib` 总量。

| 目录/模块 | Dart 文件 | 物理行 |
|---|---:|---:|
| `app/lib/app` | 6 | 1,715 |
| `app/lib/data` | 5 | 812 |
| `app/lib/data/db` | 3 | 4,749 |
| `app/lib/data/models` | 6 | 376 |
| `app/lib/data/repositories` | 3 | 1,077 |
| `app/lib/design` | 2 | 386 |
| `app/lib/design/components` | 23 | 8,453 |
| `app/lib/design/layout` | 2 | 1,207 |
| `app/lib/design/tokens` | 6 | 759 |
| `app/lib/features/albums` | 2 | 486 |
| `app/lib/features/artists` | 2 | 450 |
| `app/lib/features/library` | 4 | 1,929 |
| `app/lib/features/onboarding` | 1 | 150 |
| `app/lib/features/player` | 10 | 2,137 |
| `app/lib/features/playlists` | 2 | 568 |
| `app/lib/features/search` | 3 | 1,142 |
| `app/lib/features/settings` | 2 | 909 |
| `app/lib/features/shared` | 6 | 617 |
| `app/lib/features/sources` | 6 | 3,169 |
| `app/lib/main.dart` | 1 | 463 |
| `app/lib/playback` | 8 | 1,211 |
| `app/lib/sources` | 2 | 137 |
| `app/lib/sources/ai` | 5 | 601 |
| `app/lib/sources/local` | 5 | 662 |
| `app/lib/sources/quark` | 7 | 1,660 |
| `app/lib/sources/scraper` | 9 | 1,205 |
| `app/lib/sources/webdav` | 3 | 650 |

| 测试/插件子目录 | Dart 文件 | 物理行 |
|---|---:|---:|
| `app/test` 直属测试 | 66 | 14,030 |
| `app/test/golden` | 1 | 416 |
| `app/test/support` | 4 | 734 |
| `app/packages/tingyu_saf/lib` | 1 | 155 |
| `app/packages/audio_service_win/lib` | 1 | 120 |

### 3.3 最大文件

| 文件 | 物理行 | 责任/评估含义 |
|---|---:|---|
| `lib/data/db/database.g.dart` | 4,436 | drift 生成代码，不作为手写业务复杂度 |
| `lib/features/sources/sources_page.dart` | 1,420 | 来源添加/编辑、目录挑选、登录分流及页面呈现聚集 |
| `lib/features/library/library_page.dart` | 1,374 | 列表、分页、排序、选择、菜单、响应式与播放全部 |
| `lib/design/components/transport.dart` | 1,150 | 播放控制、进度/音量及布局 |
| `lib/design/components/track.dart` | 865 | 行、表格、虚拟列表、选择及交互 |
| `lib/features/search/search_page.dart` | 852 | 多组搜索及分页呈现 |
| `lib/sources/quark/quark_drive_client.dart` | 811 | 网盘 API、分页、直链与错误处理 |
| `lib/data/repositories/track_repository.dart` | 729 | 核心数据查询与写回 |
| `lib/design/layout/app_shell.dart` | 666 | 桌面/移动外壳与导航 |
| `lib/app/providers.dart` | 657 | 集中状态装配与查询刷新机制 |
| `lib/design/components/structure.dart` | 600 | 页面/分组/面板等骨架 |
| `lib/app/playback_controller.dart` | 572 | 队列与播放会话编排 |
| `test/quark_test.dart` | 968 | 最大测试文件，网盘相关 |
| `test/webdav_test.dart` | 932 | WebDAV 回归 |

文件路径在本节省略共同前缀 `app/`。

## 4. 平台专属代码与原生边界

### 4.1 已跟踪原生源代码

“宿主/实现”包含模板 runner，不表示全部手写；生成注册器、测试分列。未计 pub cache 中插件原生代码，因此本表不是应用完整原生依赖总量。

| 目录 | 总文件/行 | 宿主或实现文件/行 | 生成注册文件/行 | 测试文件/行 |
|---|---:|---:|---:|---:|
| `app/macos` | 4 / 81 | 2 / 41 | 1 / 28 | 1 / 12 |
| `app/ios` | 4 / 35 | 3 / 23 | 0 / 0 | 1 / 12 |
| `app/android` | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| `app/windows` | 10 / 685 | 8 / 641 | 2 / 44 | 0 / 0 |
| `app/linux` | 5 / 232 | 3 / 190 | 2 / 42 | 0 / 0 |
| `packages/tingyu_saf/android` | 1 / 312 | 1 / 312 | 0 / 0 | 0 / 0 |
| `packages/tingyu_saf/ios` | 1 / 159 | 1 / 159 | 0 / 0 | 0 / 0 |
| `packages/audio_service_win/windows` | 5 / 458 | 4 / 415 | 0 / 0 | 1 / 43 |

macOS 的 AppDelegate/MainFlutterWindow 负责退出/窗口及注册，最小窗口为 900×600，默认 1180×760。iOS 为 AppDelegate、SceneDelegate、桥接头。Android 无自有 MainActivity 是当前设计：Manifest 直接使用 `com.ryanheise.audioservice.AudioServiceActivity`，实际 Kotlin 业务桥在本地插件中。Windows 为窗口消息、FlutterViewController 与启动；Linux 为 GTK runner、窗口/图标及调试尺寸等。iOS 未跟踪生成注册器不等于构建时没有插件注册。

补充配置规模（均为上述源代码表之外的跟踪文本）：macOS 的 xcconfig 6 文件/35 行、Podfile 1/42、plist 2/40、entitlements 2/28；iOS 的 plist 3/107、xcconfig 2/4、Podfile 1/43；Android 的 Gradle `.kts` 3/131、XML 8/174、properties 2/11；Windows 的 CMakeLists 3/266、cmake 1/30；Linux 的 CMakeLists 3/242、cmake 1/28。此补充仅覆盖列出的配置类别，不是全部工程文件总数。

### 4.2 无法由普通 UI 绘制替代的能力

| 能力 | 当前落点 | 更换 UI 宿主仍需承担的系统责任 |
|---|---|---|
| 后台播放/音频焦点 | `main.dart`、audio_session/audio_service、Android Manifest；iOS Info.plist 的 `UIBackgroundModes=audio` | Android 前台媒体服务、通知和媒体按钮；iOS 音频会话/后台声明；播放不中断及打断恢复 |
| 媒体键/Now Playing | TingyuAudioHandler + Apple 后端/Windows SMTC/Linux MPRIS | 系统媒体 API 或 D-Bus，不是仅重绘播放条 |
| Android 用户目录 | `tingyu_saf` 的 `tingyu/saf` 通道、DocumentsContract、持久 URI 权限 | 系统目录选择器、授权恢复/撤销、content:// 播放；当前实现枚举而非复制整个曲库 |
| iOS 用户目录 | 同一通道的 `UIDocumentPickerViewController`、书签解析与 scopedURLs | 安全作用域的开启/释放及生命周期；当前 Swift 保持进程内授权到释放来源 |
| 凭据 | SecureStore + flutter_secure_storage | 系统安全存储、账号键兼容与签名/权限；不随 UI 自动迁移 |
| 文件/窗口/菜单 | file_selector、平台 runner、Flutter PlatformMenuBar、Process 文件管理器命令 | 平台对话框、窗口约束、菜单快捷键和退出资源释放 |
| 分发/商店 | entitlements、plist、Gradle 签名、打包脚本 | macOS 当前明确非沙盒、计划 Developer ID+公证，不是 Mac App Store 已就绪；其他平台签名/安装链同样独立 |

[macOS entitlements](../../app/macos/Runner/Release.entitlements) 的 `com.apple.security.app-sandbox=false`，release 允许 network.client；debug 另有 JIT/network.server。当前桌面本地目录按路径访问，不能套用“macOS 已具持久安全书签授权”的说法。WidgetKit、App Intents/Siri 和原生 AirPlay 路由选择器在 README 中明确尚未迁移，不作为已完成能力。

## 5. 依赖用途与风险

版本基准取 `app/pubspec.lock`；“线上最新/发布日期”由本轮逐包读取 `https://pub.dev/api/packages/<包名>` 的 latest.version/latest.published 得到，日期按 UTC 截取。该接口显示本节查询包的 `isDiscontinued` 均为 false。**未标停用不等于安全或维护活跃；发布时间也不等于最后提交时间。** 本轮未审计所有传递依赖的漏洞或许可证。

| 包（上游链接） | 本地锁定 | 线上最新稳定 / 发布日期 | 当前用途与具体风险 |
|---|---|---|---|
| [`audio_metadata_reader`](https://pub.dev/packages/audio_metadata_reader) | `1.8.0` | `1.8.1` / 2026-10-14 | 读取本地音频标签与内嵌封面。格式兼容、损坏文件与内存开销是主要风险；桌面扫描已有 isolate 隔离，SAF 路径另走适配。 |
| [`audio_service`](https://pub.dev/packages/audio_service) | `0.18.19` | `0.18.19` / 2026-06-29 | 后台播放和系统媒体会话。Flutter 插件、Android 服务及 Apple 媒体 API 都是替换边界；升级须验证锁屏、媒体键及退出释放。 |
| [`audio_service_mpris`](https://pub.dev/packages/audio_service_mpris) | `0.2.1` | `0.2.1` / 2026-03-15 | Linux 的 audio_service 后端。独立维护、依赖 D-Bus 和桌面环境；上游支持表并非完整实现所有 MPRIS 方法，不能把编译通过当系统集成验收。 |
| [`audio_service_win`](https://pub.dev/packages/audio_service_win) | `0.0.3+tingyu.1` | `0.0.3` / 2026-03-29 | Windows SMTC；当前使用本地 vendor，不能直接回退 hosted 版本。自维护缩略图线程与空 artUri 修复；该补丁与 Flutter 无障碍引擎修复是两件事。 |
| [`audio_session`](https://pub.dev/packages/audio_session) | `0.2.4` | `0.2.4` / 2026-06-29 | 移动音频焦点、打断与会话配置。后台、电话/蓝牙切换依赖系统行为；与引擎及 audio_service 联合验证。 |
| [`cached_network_image`](https://pub.dev/packages/cached_network_image) | `4.0.0` | `4.0.5` / 2026-10-21 | 远程封面与缩略缓存。Flutter ImageProvider 与磁盘缓存依赖；当前 TyCover 已指定解码/磁盘缓存宽度，仍需处理失效和缓存生命周期。 |
| [`drift`](https://pub.dev/packages/drift) | `2.35.0` | `2.35.3` / 2026-10-23 | SQLite ORM、响应式查询与迁移。业务直接使用生成 Track/MusicSource 等类型；换语言需保留 schema、ID、时间文本和迁移语义。 |
| [`file_selector`](https://pub.dev/packages/file_selector) | `1.1.0` | `1.1.0` / 2025-11-21 | 桌面选曲库目录。依赖各平台系统文件对话框；macOS 当前非沙盒，不能把选中路径误当商店沙盒的持久授权。 |
| [`flutter_riverpod`](https://pub.dev/packages/flutter_riverpod) | `3.4.3` | `3.4.3` / 2026-09-03 | 依赖装配、异步数据与播放状态。app 控制器和 features 均使用 Ref/Notifier；属于应用运行时耦合，非 UI 目录也不能直接搬走。 |
| [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) | `11.1.0` | `11.2.0` / 2026-09-16 | 系统凭据存储。平台实现、Keychain entitlement、Linux libsecret 和旧账号键迁移敏感；本仓库非 release 另有明文文件回退，见正文。 |
| [`go_router`](https://pub.dev/packages/go_router) | `18.0.1` | `18.1.1` / 2026-10-20 | ShellRoute、详情栈、URL query 与舞台覆盖层。重写需保留返回、焦点、深链和页面状态语义；当前不是多分支保活路由。 |
| [`just_audio`](https://pub.dev/packages/just_audio) | `0.10.6` | `0.10.6` / 2026-06-29 | 移动音频解码与队列。content://、鉴权头本地代理、completed/playing 与列表循环语义均已有适配；替换须保留回归契约。 |
| [`media_kit`](https://pub.dev/packages/media_kit) | `1.2.6` | `1.2.6` / 2025-12-13 | 桌面 libmpv 播放引擎。FFI/原生库、系统打包、解码器兼容属于持续成本；最近稳定发布较早不等于已停止维护。 |
| [`media_kit_libs_audio`](https://pub.dev/packages/media_kit_libs_audio) | `1.0.7` | `1.0.7` / 2025-10-05 | 原生音频二进制聚合包；网页标为 unlisted，API 未标 discontinued。须核对各平台传递二进制、架构、许可证与安全更新，不能只审 Dart 包版本。 |
| [`path_provider`](https://pub.dev/packages/path_provider) | `2.1.6` | `2.1.6` / 2026-06-15 | 数据库、封面和设置根目录。依赖平台目录定位；更换宿主时需保持或迁移目录和凭据位置。 |
| [`permission_handler`](https://pub.dev/packages/permission_handler) | `11.4.0` | `13.0.2` / 2026-09-04 | 目前用于 Android 通知授权。锁定版本落后最新主版本，平台 SDK/权限变化需专项验证；不据此直接升级。 |
| [`qr_flutter`](https://pub.dev/packages/qr_flutter) | `4.1.0` | `4.1.0` / 2023-05-14 | 夸克扫码二维码绘制，纯 Flutter widget/painter。稳定版本发布较久，应关注新 Flutter 兼容；功能窄，发布间隔不足以证明弃维护。 |
| [`url_launcher`](https://pub.dev/packages/url_launcher) | `6.3.2` | `6.3.3` / 2026-10-02 | 外链与浏览器跳转。Android 包可见性、URI scheme 与平台处理差异需保留；Android 夸克原生跳转另在 tingyu_saf。 |
| [`webview_flutter`](https://pub.dev/packages/webview_flutter) | `4.14.1` | `4.14.1` / 2026-07-07 | 夸克官方登录页与 Cookie 提取。官方支持 Android/iOS/macOS，不支持 Windows/Linux；当前网页入口只在桌面 macOS 提供，触控入口走 QR。 |
| [`webview_flutter_android`](https://pub.dev/packages/webview_flutter_android) | `4.14.1` | `4.14.1` / 2026-08-28 | Android WebView 专属配置。是独立直接依赖，但当前生产登录分流已偏向 QR，仍有平台配置代码；需与 WebView 主包协同升级，不能只凭依赖存在判定页面在用。 |
| [`drift_dev`](https://pub.dev/packages/drift_dev) | `2.35.0` | `2.35.2` / 2026-10-23 | 数据库生成器，仅开发依赖；必须与 drift 和已提交 database.g.dart 一起校验，CI 有重新生成后无 diff 门禁。 |
| [`build_runner`](https://pub.dev/packages/build_runner) | `2.16.1` | `2.17.1` / 2026-10-14 | 开发期代码生成链。SDK、analyzer 与 builder 版本兼容敏感；非应用运行时代码。 |
| [`sqlite3`](https://pub.dev/packages/sqlite3) | `3.5.2` | `3.8.0` / 2026-10-23 | pubspec 列在开发依赖，供内存库测试；运行时 drift/native 仍使用 SQLite 传递实现，不能理解为产品不依赖 SQLite 原生库。 |

本地 `tingyu_saf` 为 `0.0.1`，由项目自行维护，Dart 桥 155 行、Android 实现 312 行、iOS 实现 159 行；没有单独的插件测试目录，app/test 的 SAF/书签测试以替身为主，不覆盖真实系统文档提供者。

其他直接运行依赖 `dio`（锁定 `5.11.1`）、`path`（`1.9.1`）、`xml`（`7.0.1`）用于 HTTP、路径和 XML，不是原生 UI 桥；风险主要是网络协议、路径编码、解析兼容及服务端行为。Flutter SDK 决定 widget/平台 ABI；flutter_test、flutter_lints、path_provider_platform_interface 属于开发/测试链。

需特别分清两个 Windows 维护点：[vendor 补丁说明](../../app/packages/audio_service_win/TINGYU_PATCHES.md) 修的是 SMTC 缩略图并发/空 URI；[Windows 引擎补丁](../../tools/engine-patches/windows-engine.json) 修的是 Flutter 无障碍树。仓库已纠正早期把崩溃都归于 SMTC 线程的说法。后者固定 framework/engine/Windows SDK、补丁哈希并自行编译引擎，属于明显的构建维护负担。不能据旧文档的临时禁用无障碍方案判定当前产品仍禁用读屏。

`media_kit_libs_audio` 的 [pub.dev 页面](https://pub.dev/packages/media_kit_libs_audio) 标为 unlisted，并列出平台二进制包；`media_kit` 的 [说明](https://pub.dev/packages/media_kit) 仍给出该音频组合。应保留“发布周期与二进制供应需关注”的判断，不能仅凭 unlisted 就宣称已废弃。[audio_service_mpris 支持表](https://pub.dev/packages/audio_service_mpris) 也表明接口覆盖有边界。

SecureStore 当前用 macOS 登录钥匙串选项；遇缺 entitlement 或 MissingPlugin 时，**非 release** 可回退到应用支持目录的凭据文本文件，并以 chmod 600 限制 POSIX 权限，设置页有 usedFallback 状态。release 遇失败会抛出，不读该明文回退。因此 README“凭据只进安全存储”的描述需加开发构建例外；本轮未读取凭据文件。

## 6. 性能、体积与可定位风险

### 6.1 debug 包实测

当前 todo 工作区没有已有产物。通过 `ps`/`lsof` 定位正在运行的同版本产物：

`/Users/halunhaku/Documents/tingyu/app/build/macos/Build/Products/Debug/听屿.app`

所属 checkout 的 HEAD 同为 `19ae15c9114f463123bfe45a24f98f1b9af44e66`，`git status --short` 为空；Info.plist 为 `CFBundleShortVersionString=2.0.0`、`CFBundleVersion=5`。这是**现存 debug 产物测量**，不是本轮重新构建验证；产物没有本轮生成的提交溯源证明。

| 测量项 | 结果 | 口径 |
|---|---:|---|
| 整个 .app | 201,576 KiB = 196.85 MiB | `du -sk`，磁盘占用 |
| 普通文件逻辑大小合计 | 206,210,769 字节 = 196.66 MiB | 递归文件 stat.st_size，排除符号链接，避免 framework 软链接重复计数 |
| Contents/Frameworks | 197,968 KiB | `du -sk` |
| Contents/MacOS | 2,756 KiB | 同上 |
| Contents/Resources | 832 KiB | 同上 |
| `kernel_blob.bin` | 128,395,808 字节 | debug Dart kernel，最大文件 |
| `FlutterMacOS` 引擎二进制 | 48,877,280 字节 | 文件 stat |
| `isolate_snapshot_data` | 11,647,016 字节 | 文件 stat |
| `Mpv` | 3,551,712 字节 | 文件 stat，不代表所有解码库合计 |

debug kernel 是大头；以上不能外推 release 包大小、内存占用、启动耗时或另一 UI 技术栈的体积。当前尚无本轮 release 对照、CPU/内存/帧时间采样、耗电或长时播放测量。

### 6.2 178 首曲库的实际数据与渲染路径

运行进程 `lsof` 指向 `~/Library/Application Support/com.halunhaku.tingyu/library.sqlite`；只读 SQL 的 `count(*)` 确认曲目数为 178。该计数是本机瞬时状态，不是仓库 fixture 数量。

| 环节 | 实现位置 | 当前行为 |
|---|---|---|
| 每页大小 | `lib/app/providers.dart:498` 的 `libraryPageSize` | 40 首；SearchPageRequest/LibraryPageRequest 作为 family key |
| SQL 分页 | `lib/data/repositories/track_repository.dart:200` 的 `listTracksPaged` | WHERE+ORDER BY+id 稳定排序，LIMIT/OFFSET；另行 COUNT，不在此方法中全量取数再切片 |
| 页面拼装 | `lib/features/library/library_page.dart:305` 的 build | `_pages` 从 1 开始，每页一个 provider，拼接已加载页 |
| 更多/自动加载 | 同文件 `_onScroll`、`_loadMore`、`_footer` | 距底 600 逻辑像素内调用下一页；另有“加载更多”、错误重试和全部加载计数 |
| 桌面列表 | `lib/design/components/track.dart:575` | `ListView.builder` + 固定 itemExtent，按可见行构建；不是整张 DataTable 一次构建 |
| 窄屏列表 | 同文件 `TyTrackList` | CustomScrollView + SliverFixedExtentList + builder delegate；窄屏行高按内容/字体配置 |
| 播放全部 | `library_page.dart` 的 `_playAll` | 逐页补齐当前查询全部曲目后启动，防止“播放全部”只播放当前已加载页 |

按 178/40 的实测输入与常量计算，正常完整分页需要 5 页（40/40/40/40/18）；这是算术推导，**不是本轮滚动实机录制的请求序列**。普通行点击传入当前已加载 tracks；“播放全部”有独立补齐路径。

已有保护包括：SQLite 后台 isolate、本地扫描 Isolate.run、未变文件跳过标签解析、整轮扫描 batch 合并；TyCover 按显示尺寸×DPR 设置 memory/file cacheWidth 和网络 memCacheWidth/maxWidthDiskCache，并有 RepaintBoundary；行高亮与传输进度通过细粒度 provider/select 隔离。舞台目前传 `animate:false`，不能继续按早期注释称现界面始终有漂移动画。

### 6.3 可定位问题与验证程度

下列均为本轮发现的**代码路径风险**，未改实现；未完成真实产品复现的项目明确标注，不把潜在问题写成已测帧率下降。

| 级别 | 位置 | 发现与影响 | 证据强度/后续验证 |
|---|---|---|---|
| 高，刷新正确性 | `providers.dart` 的 `libraryFingerprintProvider`（length/favorites/latest） | 标题、艺术家、专辑、封面、歌词、时长更新不改变该指纹。分页 FutureProvider 不直接订阅对应行；手动匹配/富化写库后，可能继续显示旧分页内容或旧排序。歌单搜索也依赖曲库指纹，歌单改名不必然触发刷新 | 已核对写回路径与依赖键，未做本轮 UI 复现；应优先补“元数据/歌单改名后当前列表刷新”回归 |
| 中，滚动请求 | `library_page.dart:141–154` | `_onScroll` 仅检查距底距离，`_loadMore` 无 loading/hasMore/total 闸门，每次滚动回调都可增加 `_pages`；全部加载后仍可能建立空页查询/保留 provider | 代码确认没有闸门；未测真实触控/滚轮的多余查询次数，不能给出耗时倍率 |
| 中，全表工作 | `allTracksProvider`、`libraryFingerprintProvider`，artistTracksProvider/albumTracksProvider | 页查询虽是 SQL 分页，指纹仍订阅完整 Track 列表并遍历；专辑/艺术家详情从 watchAll 再筛选排序。曲目表更新会带来全量对象与聚合工作 | 当前架构确认；178 首下未测出卡顿，增长风险不能等同当前性能失败 |
| 中，状态保留 | `router.dart` 单 ShellRoute；各页自持 ScrollController | 离开目的地再返回未实现统一分支保活；页数/滚动位置可能重置 | 与迁移文档遗留项一致，未做本轮 GUI 复现 |
| 中，局部重建 | `features/sources/source_page.dart:159` | 来源详情直接 watch 整个 playbackProvider 后取 playing，可能随位置 tick 触发其 Consumer 重建；主曲库已有细粒度 PlaybackTrackRow，不能泛化为全应用每 tick 重绘 | 静态订阅位置确认；需对该页面单独测重建范围 |
| 中，平台主线程 | `tingyu_saf` Kotlin 的 `onMethodCall` → `listChildren` | 默认通道 handler 中同步 ContentResolver.query 与游标枚举，未看到 worker/task queue；慢文档提供者或大目录可能阻塞 Android 平台线程 | 代码路径确认；本轮未跑 Android 设备，不声称已有 ANR |
| 待验证，取色执行 | `features/player/stage_palette.dart` 的 compute → `_extractPalette` | 后台回调使用 dart:ui 的 ImmutableBuffer/ImageDescriptor/Codec；错误会被吞并回退中性配色。应验证此 SDK 上该 isolate 解码路径是否成功，避免把“用了 compute”当作正确性证明 | [Flutter isolate 限制文档](https://docs.flutter.dev/perf/isolates#no-rootbundle-access-or-dartui-methods) 提示根 isolate 限制；本轮未复现，不定性为已确认故障 |

搜索中 `%LIKE%`、聚合排序、逐页 COUNT，以及 provider family 未 autoDispose 的缓存都值得大库采样；现有数据不足以认定它们是当前瓶颈。缩略图已有尺寸解码，不能按“原图全尺寸解码”泛泛报问题。`performance_regression_test.dart` 的大列表测试关注虚拟化结构与内容重建，不是吞吐/帧率基准；它将大量 fixture 放在同一个页面返回值中，不能证明真实 SQL 多页自动加载没有上述闸门问题。

## 7. 质量现状、CI 与遗留项

### 7.1 本轮质量实测

| 项目 | 结果/计数 | 口径 |
|---|---:|---|
| `flutter pub get --enforce-lockfile` | 退出码 0 | 只解析既有锁定依赖；未升级依赖，结束后无跟踪代码 diff |
| `flutter analyze --no-pub` | 退出码 0，No issues found | 记录输出运行时间 4.3s |
| `flutter test --no-pub --exclude-tags golden --reporter json` | 374 个可见用例通过、0 失败、0 跳过；退出码 0 | JSON testDone 过滤 hidden；另有 66 个隐藏加载事件，不当作用例；done.success=true |
| 非 Golden 测试 suite | 66 | 本轮 reporter 的 suite 事件计数 |
| 源码测试声明 | test 259 处、testWidgets 112 处 | 正则按行首调用统计，含 12 处 Golden；参数化/循环使声明数不同于运行用例数 |
| `_test.dart` 文件 | 67 | git 跟踪；其中 1 个 Golden 文件，其余 66 个非 Golden 文件 |
| Golden | 12 张 PNG、12 处 testWidgets 声明 | `test/golden/goldens`；`dart_test.yaml` 默认 skip，需 Windows `--run-skipped -t golden` |
| 本轮 Golden 运行 | 未运行 | 保持固定 Windows 字体/渲染基准；不能用 macOS 跑普通测试代替视觉回归 |

覆盖主题包含：数据库迁移/查询/歌单、来源扫描权威性与取消、WebDAV/夸克协议和 loopback HTTP、凭据/设置、元数据/AI 解析、队列循环/随机/解析失败、播放快照和时长、路由路径、搜索防抖、布局/语义/交互与重建边界。多数播放器测试使用 fake/抽象替身，不证明真实 AVPlayer/ExoPlayer、系统后台、蓝牙或外部账号可用；未生成覆盖率百分比。

### 7.2 CI 实际配置

仅发现 `.github/workflows/flutter.yml` 一个工作流。main push、v* tag、匹配 app/tools/质量门禁路径的 PR 与手动触发。此报告只改 docs/audit，**不在当前 PR paths 的触发范围内**，不能承诺提交报告会自动跑 CI。

| job | 配置覆盖 | 边界 |
|---|---|---|
| analyze（Ubuntu） | 已批准资产 SHA256、单指定文件格式检查、build_runner 后 git diff 无漂移、flutter analyze、排除 golden 的 flutter test | 格式门禁当前仅 `lib/data/secure_store.dart`；Golden 默认排除；没有全仓格式/覆盖率阈值 |
| build（依赖 analyze） | macOS release、Windows release、Linux release、Android release APK、iOS release --no-codesign；构建产物上传 | 五目标编译，非五平台端到端测试；iOS 不签名，Android 无 key.properties 则退回 debug 签名 |
| Windows 特殊构建 | 固定 SDK 预检、源码引擎同步/配置/编译/缓存、无障碍引擎测试、本地引擎构建应用 | 比普通 Flutter 构建多一套源码引擎供应链；本轮未运行 Windows 引擎/CI |
| release | v* tag 汇总产物并发布 GitHub Release | 当前未执行，也未创建 tag；iOS 不进入发布包 |

Windows 专项的 runtime matrix、MSAA/语义、真实 WAV 播放和 Golden 脚本在 tools/与 P6A 文档中有历史证据，不能全部当成上述 GitHub workflow 自动执行内容。此轮未查询 Actions 运行结果，不把 workflow 配置或历史绿灯写成 HEAD 上远端 CI 已绿。

### 7.3 TODO/FIXME 与文档中的实际缺口

| 搜索范围 | TODO | FIXME | 主题 |
|---|---:|---:|---|
| 跟踪的 `app/lib`、`app/packages`、`app/test` 文本 | 0 | 0 | 没有标记不代表没有技术债 |
| 跟踪的五个平台目录文本 | 2 | 0 | Windows/Linux `flutter/CMakeLists.txt:9` 同一模板项：将更多构建内容移到 ephemeral；不是两项产品功能缺陷 |

文档不能简单把所有“未做”累加为现状。[crossplatform-migration.md](../crossplatform-migration.md) 是按阶段追加的日志，早期“iOS 目录桥未实现”“Android 本地不可构建”“夸克未实机验证”等有后续章节覆盖；当前代码也已含 iOS 书签。采用较新的明确记录，并标明本轮是否验证：

| 项目 | 当前可据证据记录的状态 |
|---|---|
| macOS WidgetKit、App Intents/Siri、原生 AirPlay 路由选择器 | README 与迁移文档 M6 标为未开始；当前入口未见对应现役实现 |
| 分发、签名与商店 | M7 未完成；macOS 非沙盒，CI 无公证步骤，Android 缺正式密钥回退 debug，iOS CI 只编译 |
| iOS 真实目录端到端 | 文档 §24 仍待“选目录→入库→播放”真机核验；Swift 桥已存在，不能说功能尚未编码 |
| 移动端/多平台本次改版验收 | P6A 文档限定 Windows 自动验收；P6B 的真实设备、账号、触控与人工读屏仍需补。历史 Android 真机成功不自动覆盖最新 UI 改版 |
| Windows 状态文档漂移 | README“Windows 只有 CI 构建”早于 Windows 崩溃文档的本地引擎、真实曲库导航与 MSAA 记录；后者是较新历史证据，本轮未在 Windows 复测 |
| 全局键盘快捷键/滚动保留 | 迁移文档 §31.10 留有 Windows/Linux 全局快捷键与切页滚动位置问题；需按当前 UI 的局部 Shortcuts 与全局注册区别验证 |
| 元数据补全 | 仍串行；自动曲库补全每会话最多 60 首，来源显式补全可无上限串行。不是并发抓取，UI/网络响应仍需实测 |
| 元数据/歌词能力上限 | 未支持 DRM 解密；OpenCC 为逐字转换，不做词组消歧；不把这些产品边界列为 Flutter 自身限制 |

[README](../../README.md) 的“红粉强调色/流体舞台”文字与旧截图也不是当前所有主页面的准确视觉说明，现版“声档”以已迁移页面内的局部令牌为准。

## 8. UI 现状与复用资产

### 8.1 设计令牌、主题与响应式

令牌位于 `lib/design/tokens/`：color、metrics、motion、typography、tokens 与 voice_archive。`TyTokens` 作为 ThemeExtension，`TyTheme.build` 映射到 Material 3 ColorScheme/文字/控件主题，关闭默认染色和水波纹，统一交互/焦点/圆角。typography 不捆绑自定义字体，按平台使用系统字体回退，解释了 Golden 固定环境的必要性。

“声档”批准令牌源在 `docs/ui-redesign/tokens/voice-archive.v0.1.json` 与 flutter-mapping 文件，Dart 适配为 VoiceArchiveColors。曲库/来源/舞台在已迁移区域构建局部主题；不是所有旧页面都已经用同一套新配色，迁移应保留页面级差异，不只搬全局 ThemeData。

[form_factor.dart](../../app/lib/design/layout/form_factor.dart) 以逻辑宽度区分 compact <640、medium 640–1023、expanded ≥1024；外壳分别为底部导航+迷你条、NavigationRail+传输条、侧栏+传输条/面板，并包含密度、输入特性、安全区、字号与导航手势适配。macOS 原生窗口最小宽度意味着常规运行不直接进入手机外壳，调试入口可以强制模拟。

### 8.2 可复用组件清单

`design/components` 实测 23 个 Dart 文件/8,453 行；下表按文件完整列出主要公开组件及相关模型，**不是把每个类都算作独立 widget**。

| 文件 | 主要复用项 |
|---|---|
| `album_card.dart` | TyAlbumCard |
| `artist_row.dart` | TyArtistRow |
| `buttons.dart` | TyButton、TyIconAction |
| `chips.dart` | TyChip、TySegmentedControl |
| `command_palette.dart` | TyCommandPalette、TyPaletteEntry |
| `context_menu.dart` | TyContextMenu、TyMenuAction |
| `cover.dart` | TyCover、TyAvatar、TyCoverPalette |
| `detail_hero.dart` | TyDetailHero |
| `dialogs.dart` | TyDialog、TySheet |
| `feedback.dart` | TySkeleton、TyProgressBar、TyBadge、TyEmptyState、TyErrorView、TyAsyncView、TyFocusable、TySnack |
| `highlight.dart` | TyHighlightedText |
| `inputs.dart` | TySearchField、TyTextField |
| `interactive.dart` | TyInteractive、TyFocusRing、TyFocusRingPainter、TyInteractionState |
| `lyrics_view.dart` | TyLyricsView、TyLyricLine |
| `mini_player.dart` | TyMiniPlayer、TyMiniPlayerSize |
| `navigation.dart` | TySidebar、TyNavRail、TyBottomNav、TySidebarSection、TyNavDestination |
| `player_stage.dart` | TyPlayerStage、TyPlayerStageSize、TyHeroTags |
| `playlist_card.dart` | TyPlaylistCard、TyNewPlaylistCard |
| `sort_menu.dart` | TySortMenu、TySortOption |
| `source_card.dart` | TySourceCard、TySourceAction、TySourceStatusDot |
| `structure.dart` | TyPageHeader、TyPageHeaderSliver、TySectionHeader、TyPanel、TyInsetGroup、TySettingsRow、TyDivider |
| `track.dart` | TyTrackRow、TyTrackTable、TyTrackList、TyEqualizer、TyDividerThin |
| `transport.dart` | TyTransportRow、TySeekBar、TyVolumeControl、TyTransportBar、TyPlayerSize |

features/shared 另复用当前曲目派生、PlaybackTrackRow、曲目菜单、加歌单、骨架与播放失败监听；player 内的 PlayerBar/MiniPlayer/QueuePanel/LyricsPanel 负责 provider 绑定，design 内同名或近名组件负责呈现，不能简单看成重复实现。

### 8.3 关键页面构成

| 页面组 | 构成/路由 |
|---|---|
| 曲库/收藏 | `/library/songs`、`/favorites`；标题统计、排序/来源筛选、歌曲表/窄屏行、封面、收藏/更多、分页脚注、选择与批量操作；收藏有专辑分段 |
| 专辑/艺术家 | `/library/albums`、`/library/artists` 与 `/album/:name`、`/artist/:name`；聚合卡/行、详情 hero、曲目与播放入口 |
| 歌单 | `/library/playlists`、`/playlist/:id`；歌单卡/创建、详情与有序曲目 |
| 搜索 | `/search` 与命令面板；空态/最近项、多类型预览、全部结果分页；输入共享防抖 |
| 来源 | `/sources`、`/source/:id`；本地/WebDAV/夸克添加、QR/网页/粘贴分流、目录挑选、同步/补全/重登录/错误/删除与来源曲目 |
| 播放 | 常驻传输条/迷你条，根级 `/stage`，以及 `/queue`、`/lyrics`；封面、元数据、进度、传输、循环/随机、收藏、队列/歌词、关闭/返回与 compact 手势 |
| 设置/引导 | `/settings`、`/settings/:section`、`/ai`、`/onboarding`；外观/密度/偏好、凭据状态、AI 配置、数据/初次使用 |

本轮是 UI 结构审查，未重新操作界面或采集视觉评分；已批准截图和 Golden 的保留不等于完成 macOS 人工交互或 VoiceOver 审查。

## 9. 迁移相关硬数据与边界

### 9.1 UI/非 UI 比例的可复查估算

分母固定为 `app/lib` 手写 Dart 的 33,244 行，不含测试/插件/生成代码。第一种按目录职责归类，不把它伪装成逐语句语义分析：

| 分类口径 | 文件 | 行 | 占手写 Dart 行数 |
|---|---:|---:|---:|
| 界面相关目录 `design/` + `features/` | 71 | 22,362 | 67.27% |
| 非 UI 主目录 `app/` + `data/` + `sources/` + `playback/` | 61 | 10,419 | 31.34% |
| 混合入口 `main.dart` | 1 | 463 | 1.39% |

敏感性检查：匹配直接导入 `package:flutter/(material|widgets|cupertino|rendering|painting|gestures).dart` 或 `dart:ui` 的文件，得到 67 文件/22,526 行，占 67.76%；其余为 66 文件/10,718 行。两种口径都显示界面相关代码约占手写代码三分之二，**“三分之一非 UI”不是“三分之一可直接搬到别的语言”**。

目录口径误差已知：features 内的 lrc_parser、library_view_state、library_table_columns、search_scope、current_track、source_sync 没有上述视觉导入，但含模型/状态编排；main 与部分 app 文件则包含视觉 API。非 UI 主目录中，直接导入 Flutter SDK 的有 23 文件/4,152 行，导入 flutter_riverpod 的有 5 文件/1,599 行，导入 flutter/services 的有 3 文件/478 行，导入 dart:io 的有 16 文件/2,952 行；这些集合相互重叠，不能相加。统计仅是直接导入，不含传递依赖。

### 9.2 与 Flutter 强绑定的能力/资产

| 资产 | 绑定方式 | 迁移时必须重新证明的内容 |
|---|---|---|
| widget UI、主题、响应式与输入 | Material/Cupertino、ThemeExtension、MediaQuery、Focus/Shortcuts/Actions、手势、Semantics、CustomPainter | 布局、字体、键盘/鼠标/触控、安全区、缩放与无障碍 |
| 状态/依赖装配 | flutter_riverpod 的 Ref/Notifier/异步 provider | 生命周期、取消、family 缓存、刷新和当前曲目身份 |
| 路由/舞台导航 | go_router + Flutter Navigator/ShellRoute | 深链、query、返回栈、Esc/拖动关闭、状态保留 |
| 播放与后台服务 | audio_service 插件回调、Flutter 平台注册、两个引擎桥 | 原生会话、通知、媒体键、后台/退出、错误与循环语义 |
| 自有授权桥 | `MethodChannel('tingyu/saf')`，Swift/Kotlin plugin；另有 `audio_service_win` channel | 通道协议/错误、平台授权和异步生命周期；更换宿主仍可借鉴原生实现但需重接桥 |
| 数据及文件 | drift 生成实体/查询、path_provider、secure storage、内容寻址封面 | SQLite 兼容迁移、用户资产、凭据键、路径/授权迁移 |
| 图像/歌词渲染 | ImageProvider、cached_network_image、dart:ui 取色、滚动控制 | 尺寸解码、缓存、同步高亮和可见行性能 |
| 测试资产 | flutter_test widget 测试、12 张 Golden、固定字体的运行时基准 | 业务断言可转写；widget finder/像素基准不能直接作为另一渲染器的通过证据 |
| Windows 引擎修复 | Flutter 固定源码引擎与无障碍补丁 | 当前维护成本真实存在；换栈后是否消失或被其他平台问题替代，需目标栈实证 |

较容易独立研究的业务单元包括 LRC/标题/AI 元数据/繁简解析、HTTP/XML/夸克协议、扫描合并与队列规则；它们也可能引用 drift 模型、Flutter foundation 或 Dart IO，需按实际依赖拆解。本文不提供语言间自动复用率、预估人日或假定迁移收益。

### 9.3 后续决策仍缺的证据

需用户另定目标平台范围；在此之前保持五平台底账。可比较的下一步输入是：release 包体/启动/内存/滚动帧时间的同条件数据，当前刷新与滚动闸门问题的定向复现，以及目标宿主对真实播放后台、授权、凭据与系统无障碍的原型验证。现有 178 首实库计数、静态结构测试和 debug 包大小无法替代这些对照。

## 10. 复查命令与本轮关键输出

以下命令在仓库根目录执行；统计不扫描第三方缓存，SQLite 只读。依赖解析与测试会生成被忽略的工具缓存，不改跟踪实现代码。

```sh
git rev-parse HEAD
git status --short
rg '^version:' app/pubspec.yaml
test -d docs/ui-redesign
flutter --version
# GitHub main 通过平台只读 git 查询：ls-remote origin refs/heads/main

# 对每个模块重复；本文用 Python 对 git ls-files 分组批量生成表格
git ls-files 'app/lib/*.dart' 'app/lib/**/*.dart' | wc -l
python3 - <<'PY_STATS'
from pathlib import Path
import subprocess
for root in ('app/lib', 'app/packages/tingyu_saf',
             'app/packages/audio_service_win', 'app/test'):
    fs = [f for f in subprocess.check_output(
        ['git', 'ls-files', root], text=True).splitlines()
        if f.endswith('.dart')]
    print(root, len(fs), sum(Path(f).read_bytes().count(b'\n') for f in fs))
PY_STATS

cd app
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub --exclude-tags golden --reporter json
```

```text
app/lib                         134 37680
app/packages/tingyu_saf            1   155
app/packages/audio_service_win    1   120
app/test                         71 15180
No issues found! (ran in 4.3s)
testDone: visible success=374, hidden loader success=66
final event: {"success":true,"type":"done","time":23736}
```

产物与实际运行数据测量：

```sh
ps -axo pid,command | rg '听屿.app/Contents/MacOS'
lsof -p <运行进程PID> -Fn | rg 'library.sqlite'
git -C /Users/halunhaku/Documents/tingyu rev-parse HEAD
git -C /Users/halunhaku/Documents/tingyu status --short
du -sk /Users/halunhaku/Documents/tingyu/app/build/macos/Build/Products/Debug/听屿.app
python3 - <<'PY_DB'
from pathlib import Path
import sqlite3
p = Path.home() / 'Library/Application Support/com.halunhaku.tingyu/library.sqlite'
c = sqlite3.connect(p.as_uri() + '?mode=ro', uri=True)
for table in ('tracks', 'music_sources', 'playlists'):
    print(table, c.execute('select count(*) from ' + table).fetchone()[0])
c.close()
PY_DB
```

```text
19ae15c9114f463123bfe45a24f98f1b9af44e66
201576  .../Debug/听屿.app
tracks 178
music_sources 1
playlists 0
```

TODO/FIXME 采用跟踪文本逐行 `\bTODO\b`、`\bFIXME\b` 匹配；测试声明按行首 `test(`/`testWidgets(` 匹配；用例数取运行 reporter，避免把循环注册或 suite 加载事件算错。依赖表的原始字段可通过每行包链接对应的 `https://pub.dev/api/packages/<包名>` 复查，网络数据只代表本次查询时点。
