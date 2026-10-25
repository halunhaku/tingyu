# spike：进程内 libmpv + macOS 媒体键验证小样

对应方案 [`docs/plan/2026-10-25-macos-mygo-migration-plan.md`](../../docs/plan/2026-10-25-macos-mygo-migration-plan.md) §7，
结论与逐条阈值见 [`docs/plan/2026-10-25-macos-mygo-spike-record.md`](../../docs/plan/2026-10-25-macos-mygo-spike-record.md)。

**这是一个用完就该删的验证目录，不是产品代码。** 它不改 `app/`、不并入未来的 `client/`。

## 它验证什么

| 相位 | 问题 | 程序 |
|---|---|---|
| S1 | `purego` 在进程内 dlopen libmpv，能不能无 cgo 出声、走 Range+鉴权头、gapless、结束回调、跑得住 | `cmd/spike-audio` |
| S2 | `purego/objc` 直调 MediaPlayer，系统认不认这个进程的 Now Playing、媒体键能不能收到、App Nap 断言在不在 | `cmd/spike-session`（无窗口）、`cmd/spike-app`（MyGo 窗口内同进程） |
| 交叉 | 内核与媒体会话同进程时（MyGo AppKit 主循环 + mpv 线程 + ObjC 回调）是否互相干扰 | `cmd/spike-app` |

## 目录

```
internal/mpv/           libmpv 的最小 purego 绑定（事件循环、按曲目下发的 http-header-fields）
internal/mediasession/  MPNowPlayingInfoCenter / MPRemoteCommandCenter / App Nap（purego/objc，P1 路线）
internal/mainq/         主线程投递（dispatch 主队列）
internal/httpsrv/       要求 Range 且校验 Authorization 的本地 HTTP 服务（+ 请求 JSONL 日志）
internal/probe/         CoreAudio 设备状态、RSS/CPU 采样、WAV 分析（静音段/单音 SNR）
cmd/spike-audio/        S1 阈值 harness（-phase s1|local|eof|remote|gapless|stress|long|acoustic|props）
cmd/spike-session/      S2 无窗口自检（--verify / --listen）
cmd/spike-app/          MyGo 原生窗口 + 进程内 mpv + 媒体会话（-auto 跑一遍证据序列）
cmd/spike-np/           系统侧 Now Playing 探针（**私有** MediaRemote API，仅用于验证）
scripts/gen-media.sh    生成 24/96、24/48 测试 FLAC 与封面（ffmpeg 现场合成，不入库）
scripts/bundle.sh       编译 + 组装 .app（frameworks、LC_RPATH、ad-hoc 签名）
scripts/s2-verify.sh    S2 一次性证据采集（含 mediaremoted 日志）
evidence/               原始证据（报告、mpv JSONL、HTTP JSONL、采样、日志）
```

## 怎么跑

```bash
export PATH=$HOME/sdk/go/bin:$PATH          # go1.27.3
./scripts/gen-media.sh                       # 需要 ffmpeg
./scripts/bundle.sh                          # 产出 build/*.app 与 build/spike-audio

# 一条命令跑完 S1 的阈值 1–7 + 构建/vet/单测，并把证据写进 evidence/s1-<时间戳>/
./scripts/s1-verify.sh
MIC=1 ./scripts/s1-verify.sh          # 再加麦克风回环（出声的离屏证据，会要麦克风权限）
LONG=1 ./scripts/s1-verify.sh         # 再加 30 分钟资源采样（阈值 8）

# 单相位（MPV_LIB 指到 .app 里的 Mpv.framework；脚本已自动加 LC_RPATH）
export MPV_LIB="$PWD/build/听屿Spike.app/Contents/Frameworks/Mpv.framework/Versions/A/Mpv"
./build/spike-audio -phase s1          # 阈值 1–5
./build/spike-audio -phase queue       # SetQueue 换队列语义
./build/spike-audio -phase stress -iterations 200
./build/spike-audio -phase long -minutes 30
./build/spike-audio -phase acoustic    # 麦克风回环

# S2：一条命令采全部证据（含 mediaremoted 日志），RACE=-race 可先打 race 版
./scripts/s2-verify.sh
```

## 几个必须知道的坑（详细版见记录文档）

1. `Mpv.framework` 是 audio-only 构建、对 libass 符号未解析 → **必须 `RTLD_LAZY`**，`RTLD_NOW` 直接 dlopen 失败。
2. frameworks 之间是 `@rpath` 引用 → 可执行文件要有 `LC_RPATH=@executable_path/../Frameworks`；`DYLD_FRAMEWORK_PATH` 对已签名二进制不生效。
3. 从 pub-cache 解出来的 framework 没有有效签名 → arm64 无法 dlopen，必须 `codesign -f -s -`。
4. mpv 0.36 的 `loadfile` **不接受第 4 个 options 参数**（"invalid parameter"）→ 按曲目下发 `http-header-fields` 要用 `on_load` 钩子（media_kit 同样做法）。
5. `mpv_event` 的 id 不要自己猜：用 `mpv_event_name()` 的返回值做分发；`mpv_end_file_reason` 没有 1。
6. `MPV_FORMAT_STRING` 的 data 是 `char**`，`mpv_get_property_string` 的返回值是 mpv 拥有的内存（要不就 `mpv_free`，要不就立刻复制）。
7. macOS 上 `changePlaybackPosition` 无法用 `MRMediaRemoteSendCommand` 注入（其余命令可以），拖动进度只能人工在控制中心拖。
8. MyGo 默认「最后一个窗口关闭即退出」；`mygo.App.OnWindowAllClosed` 挂监听即可保住进程继续播放（方案 §5.6 靠这个）。
