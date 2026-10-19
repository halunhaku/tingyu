# tingyu 对 `audio_service_win` 的补丁说明

上游：https://github.com/HemantKArya/audio_service_win ，版本 0.0.3（MIT，见 `LICENSE`）。
本目录是上游 0.0.3 的完整 vendor（含原 LICENSE），另加以下两处修复。
上游若合并等价修复，可删目录、把 `app/pubspec.yaml` 指回 hosted 版本。

## P1：消除缩略图后台线程对共享 DisplayUpdater 的并发访问

- 上游 `windows/audio_service_win_plugin.cpp` 把
  `updater.Thumbnail() / updater.Update()` 扔进
  `std::thread(...).detach()`，与后一次 `setMediaItem` 的
  `ClearAll() / Update()` 在无同步的情况下抢同一个 SMTC
  `DisplayUpdater`，存在并发访问风险。
  **2026-10-06 归因更正**：加载匹配 Flutter PDB 后，三份 dump 实际均指向
  `AccessibilityBridge::CreateRemoveReparentedNodesUpdate` 的空父节点解引用，
  不能作为缩略图线程造成堆破坏的证据。详见
  [Windows 播放页崩溃调查](../../../docs/windows-now-playing-crash.md)。
- macOS（MPNowPlaying）/ Android（MediaSession）走各自后端，不受影响；
  Windows CI 只有编译验证，所以一直没爆，真机一播网盘歌几秒就崩。
- 修复：缩略图改在平台线程**同步**设置（`CreateFromUri` 本就是 lazy
  引用不走网络，本地文件 `.get()` 也很快，不卡 UI），失败只记日志，
  元数据照常更新。

## P2：`artUri` 为 null 时透传成字符串 `"null"`

- 上游 Dart 侧 `'artUri': request.mediaItem.artUri.toString()`，
  null 会变成字符串 `"null"`，原生侧把它当成本地文件路径去
  `GetFileFromPathAsync("null")`，每次播无封面曲目都刷一条
  `Failed to set thumbnail`（并顺带触发 P1 的野线程）。
- 修复：Dart 侧改 `?.toString()` 传真正的 null，原生侧 `IsNull`
  检查本来就有，直接跳过缩略图；原生侧再加一道
  `empty / "null" / "undefined"` 防线。
- 另修 `file://` 本地路径剥离：`file:///C:/...` 去 scheme 后剩
  `/C:/...`，多余的前导 `/` 去掉一个（只去一个，UNC 不受影响），
  否则 `GetFileFromPathAsync("\\C\\...")` 必抛。

历史验证：公开 https MP3 连播 5 分半零报错存活；此前同样条件 1 分钟内崩溃。
这次存活观察不证明页面快速返回问题已经修复，该问题需要独立回归。
