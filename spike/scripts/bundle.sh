#!/bin/bash
# 构建 spike 的全部分可执行文件，并组装成 .app：
#   build/听屿Spike.app          —— MyGo 窗口 + 进程内 libmpv + Now Playing（S1+S2 共存验证）
#   build/听屿SpikeSess.app      —— 只做 Now Playing 的最小 harness（LSUIElement，无窗口）
#   build/spike-audio            —— 纯 Go（无窗口）的 S1 阈值 harness
#
# 为什么必须打包：Mpvframeworks 之间是 @rpath 引用，可执行文件需要 LC_RPATH 指向
# Contents/Frameworks；另外 macOS 的 Now Playing 需要一个真正的 .app bundle（有
# CFBundleIdentifier）。两个都在这里做。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
BUILD="$ROOT/build"
FRAMEWORK_SRC=${FRAMEWORK_SRC:-"$HOME/.pub-cache/hosted/pub.dev/media_kit_libs_macos_audio-1.1.4/macos/Frameworks"}
GO=${GO:-$HOME/sdk/go/bin/go}
export CGO_ENABLED=${CGO_ENABLED:-0}
RACE=${RACE:-}

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "== 1/4 编译（CGO_ENABLED=$CGO_ENABLED RACE=${RACE:-off}）"
"$GO" build $RACE -trimpath -o "$BUILD/spike-audio" ./cmd/spike-audio
"$GO" build $RACE -trimpath -o "$BUILD/spike-session" ./cmd/spike-session
"$GO" build $RACE -trimpath -o "$BUILD/spike-app" ./cmd/spike-app
"$GO" build $RACE -trimpath -o "$BUILD/spike-np" ./cmd/spike-np

echo "== 2/4 组装 frameworks"
FRAMEWORKS=("Avcodec" "Avfilter" "Avformat" "Avutil" "Mbedcrypto" "Mbedtls" "Mbedx509" "Mpv" "Swresample" "Swscale")
copy_frameworks() { # $1 = 目标 Contents 目录
  local contents=$1
  mkdir -p "$contents/Frameworks"
  for f in "${FRAMEWORKS[@]}"; do
    cp -R "$FRAMEWORK_SRC/$f.xcframework/macos-arm64_x86_64/$f.framework" "$contents/Frameworks/"
    codesign -f -s - "$contents/Frameworks/$f.framework/Versions/A/$f" >/dev/null 2>&1
  done
}

make_app() { # $1=app名 $2=可执行名 $3=LSUIElement
  local app="$BUILD/$1"
  local exe=$2
  local lsuielement=$3
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BUILD/$exe" "$app/Contents/MacOS/$exe"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/$exe"
  copy_frameworks "$app/Contents"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$exe</string>
  <key>CFBundleDisplayName</key><string>听屿 Spike</string>
  <key>CFBundleIdentifier</key><string>com.halunhaku.tingyu.spike.$exe</string>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><${lsuielement}/>
  <key>NSMicrophoneUsageDescription</key><string>spike 用麦克风回环验证音频真的从扬声器出声</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
  codesign -f -s - "$app/Contents/MacOS/$exe" >/dev/null 2>&1
  codesign -f -s - "$app" >/dev/null 2>&1 || echo "   （app 级签名失败，ad-hoc 单文件签名仍在）"
}

echo "== 3/4 打包 .app"
make_app "听屿Spike.app" spike-app false
make_app "听屿SpikeSess.app" spike-session true

# 独立可执行文件（不进 .app 的）也要能解析 @rpath/Avcodec.framework 之类：
# 给它们加 LC_RPATH=@executable_path/Frameworks，并把 frameworks 目录软链到 build/Frameworks。
echo "== 3.5/4 给独立可执行文件补 rpath"
ln -sfn "听屿Spike.app/Contents/Frameworks" "$BUILD/Frameworks"
for exe in spike-audio spike-session spike-np; do
  install_name_tool -add_rpath "@executable_path/Frameworks" "$BUILD/$exe" 2>/dev/null
  codesign -f -s - "$BUILD/$exe" >/dev/null 2>&1
done

echo "== 4/4 校验 dyld 依赖"
for exe in "$BUILD/听屿Spike.app/Contents/MacOS/spike-app" "$BUILD/spike-audio"; do
  echo "-- $exe"
  otool -l "$exe" | grep -A2 LC_RPATH | grep "path " || echo "   (无 LC_RPATH，需靠 MPV_LIB + 手工 rpath)"
done

echo "完成：$BUILD"
ls -la "$BUILD"
