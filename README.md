# 听屿 TINGYU

连接本地文件夹与 WebDAV 私人曲库的桌面音乐播放器。桌面端基于 Tauri 2，界面使用 React + TypeScript，文件扫描与音频流由本地 Rust 后端处理。

## 已完成

- 响应式桌面/移动端播放器界面
- 原生 macOS 菜单栏，支持曲库、播放、歌词、搜索和音乐源快捷操作
- 曲库搜索（支持 `⌘/Ctrl + K` 聚焦）、收藏与播放队列
- 本地音乐文件夹选择、递归扫描与启动时自动恢复
- 本地音频 Range 流式读取，并限制在用户选择的目录内
- 真实 WebDAV Basic Auth / 应用密码连接
- 递归 `PROPFIND` 音频扫描（最多 8 层、5,000 首）
- MP3、FLAC、M4A、AAC、WAV、OGG、OPUS 文件识别
- 本地随机令牌音频代理，不向前端暴露 WebDAV 凭据
- Range 请求透传，支持流式播放、拖动进度和切歌
- WebDAV 地址边界检查，阻止代理访问授权目录以外的地址
- macOS Keychain 保存应用密码，配置文件不落盘明文凭据
- SQLite 本地曲库缓存，启动时先读缓存再后台刷新
- 基于 ETag / 修改时间 / 文件大小的增量扫描
- MP3 ID3v2 与 FLAC Vorbis Comment 标签、内嵌封面解析
- 缺失封面自动通过 iTunes Search 匹配并缓存到本地
- 通过 LRCLIB 自动匹配普通/时间轴歌词，中文歌词自动转为简体并同步高亮
- 本地封面文件缓存与随机令牌图片代理

## 下载与发布

GitHub Actions 会在推送 `v*` 标签时自动构建 macOS `.app` 和 `.dmg`，并发布到 GitHub Releases：

```bash
git tag v0.2.0
git push origin v0.2.0
```

当前未配置 Apple Developer 签名。下载后首次打开需要在 Finder 中右键应用并选择“打开”。配置仓库中的 `APPLE_CERTIFICATE`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_SIGNING_IDENTITY`、`APPLE_ID`、`APPLE_PASSWORD` 和 `APPLE_TEAM_ID` Secrets 后，工作流会自动使用签名与公证凭据。

## 桌面端开发

需要 Node.js、Xcode Command Line Tools 和 Rust stable：

```bash
npm install
npm run desktop:dev
```

仅运行浏览器界面：

```bash
npm run dev
```

浏览器版本可以查看 UI，但真实 WebDAV 连接需要 Tauri 后端。

## 质量检查

```bash
npm run lint
npm run build

cd src-tauri
cargo fmt --check
cargo test
cargo clippy -- -D warnings
```

## 目录

```text
src/
├── components/       播放器与 WebDAV 设置界面
├── data/             曲库显示工具
├── providers/        本地文件夹与 WebDAV 前端适配器
├── stores/           动态曲库与播放状态
└── types/            曲目类型定义

src-tauri/src/
├── credentials.rs    macOS Keychain 与非敏感连接配置
├── library_cache.rs  SQLite WebDAV 曲库缓存和增量更新
├── local_library.rs  本地文件扫描、缓存与安全音频代理
├── metadata.rs       本地/远程音频标签、封面及时长解析
├── scraper.rs        LRCLIB 歌词与 iTunes Search 封面刮削
├── lib.rs            Tauri 初始化与本地代理服务
└── webdav.rs         WebDAV 扫描、校验和 Range 音频代理
```

## 音乐源使用说明

在侧栏“音乐源”旁点击 `+` 打开音乐源管理器。未添加来源时侧栏不会显示占位项；添加时需要设置一个名称，之后点击该名称即可只查看对应来源中的歌曲，也可以在管理器中删除来源。当前支持一个本地文件夹和一个 WebDAV 来源。

添加本地来源后，选择包含音乐的目录。听屿会递归扫描最多 8 层、5,000 首歌曲，缓存标签并在下次启动时自动恢复；符号链接会被跳过，播放代理只允许访问已选择目录内的文件。

添加 WebDAV 来源时，输入来源名称、WebDAV 根地址、用户名和应用专用密码。启用“记住此连接”后，密码保存在 macOS Keychain；本地 JSON 只保存来源名称、服务器地址、用户名和目录。

曲库索引保存在应用数据目录的 `library.sqlite3`。再次启动时会先展示缓存，然后使用 ETag 或修改时间执行增量扫描，未变化的歌曲不会重新下载标签。每次同步会并发补全一批缺失元数据，开始播放尚未处理的歌曲时也会自动补全；内嵌封面始终优先于网络匹配结果。

歌词匹配会把歌曲名、艺术家、专辑名和时长发送给 LRCLIB；封面匹配会把艺术家和专辑名发送给 iTunes Search API。不会向这些服务发送 WebDAV 地址、账号、密码或音频内容。

建议优先使用 HTTPS 和应用专用密码。当前版本支持 Basic Auth；Digest Auth 和自签名 TLS 证书暂不支持。

## 下一阶段

1. 加入可视化扫描进度与取消扫描
2. 提取码率、采样率、位深等音质信息
3. 支持编辑曲目信息和手动替换封面
4. 接入 Media Session、全局快捷键及系统媒体控制
