#!/bin/bash
# S1（音频链路）的可复现证据采集：阈值 1–5 + 阈值 7（-race 压测）+ 阈值 6（构建/vet/test）。
# 阈值 8（30 分钟资源）单列，因为它要跑半小时：LONG=1 ./scripts/s1-verify.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
export PATH=${GOBIN_DIR:-$HOME/sdk/go/bin}:$PATH
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/evidence/s1-$STAMP"
mkdir -p "$OUT"

[ -f "$ROOT/testdata/media/tone96.flac" ] || "$ROOT/scripts/gen-media.sh"

echo "== 1/5 无 cgo 构建 + vet + 单测（阈值 6）"
{
  echo "\$ CGO_ENABLED=0 go build ./..."
  CGO_ENABLED=0 go build ./... && echo "exit=0"
  echo "\$ go vet ./..."
  go vet ./... && echo "exit=0"
  echo "\$ gofmt -l ."
  gofmt -l .
  echo "\$ CGO_ENABLED=0 go test -race ./..."
  CGO_ENABLED=0 go test -race ./... 2>&1 | tail -20
} > "$OUT/threshold6-build.txt" 2>&1
tail -3 "$OUT/threshold6-build.txt"

echo "== 2/5 打包（含 frameworks 与 .app）"
./scripts/bundle.sh > "$OUT/bundle.log" 2>&1 || { echo "bundle 失败，见 $OUT/bundle.log"; exit 1; }
LIB="$ROOT/build/听屿Spike.app/Contents/Frameworks/Mpv.framework/Versions/A/Mpv"
export MPV_LIB="$LIB"

echo "== 3/5 S1 阈值 1–5"
"$ROOT/build/spike-audio" -phase s1 -out "$OUT/s1" 2>&1 | tee "$OUT/s1-console.txt"

echo "== 3b/5 队列重建语义（SetQueue 契约）"
"$ROOT/build/spike-audio" -phase queue -out "$OUT/queue" 2>&1 | tee "$OUT/queue-console.txt"

echo "== 4/5 阈值 7：-race 构建的 200 次压测"
RACE=-race ./scripts/bundle.sh > "$OUT/bundle-race.log" 2>&1 || { echo "race bundle 失败"; exit 1; }
install_name_tool -add_rpath "@executable_path/../Frameworks" "$ROOT/build/spike-audio" 2>/dev/null
codesign -f -s - "$ROOT/build/spike-audio" >/dev/null 2>&1
MPV_LIB="$LIB" "$ROOT/build/spike-audio" -phase stress -iterations 200 -out "$OUT/stress" 2>&1 | tee "$OUT/stress-console.txt"

echo "== 5/5 复原非 race 构建"
./scripts/bundle.sh > "$OUT/bundle-restore.log" 2>&1

if [ "${MIC:-0}" = "1" ]; then
  echo "== 附加：麦克风回环（出声的离屏证据，会请求麦克风权限）"
  MPV_LIB="$LIB" "$ROOT/build/spike-audio" -phase acoustic -out "$OUT/acoustic" 2>&1 | tee "$OUT/acoustic-console.txt"
fi

if [ "${LONG:-0}" = "1" ]; then
  echo "== 附加：阈值 8（30 分钟资源采样）"
  MPV_LIB="$LIB" "$ROOT/build/spike-audio" -phase long -minutes "${MINUTES:-30}" -out "$OUT/long" 2>&1 | tee "$OUT/long-console.txt"
fi

echo
echo "证据目录: $OUT"
