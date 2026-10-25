#!/bin/bash
# 生成 S1/S2 用的测试音频与封面。全部由 ffmpeg 现场合成，不入库
# （避免仓库里躺二进制；checksums 入库，保证可复现）。
#
# 用 ffmpeg 的原因：需要真 24-bit/96 kHz 的 FLAC 与 24-bit/48 kHz 的同专辑两首，
# macOS 自带的 afconvert 也能转 flac，但位深/采样率控制不如 ffmpeg 明确。
set -euo pipefail

OUT=${1:-"$(cd "$(dirname "$0")/.." && pwd)/testdata/media"}
FFMPEG=${FFMPEG:-/opt/homebrew/bin/ffmpeg}
mkdir -p "$OUT"

if [ ! -x "$FFMPEG" ]; then
  echo "缺少 ffmpeg：$FFMPEG（brew install ffmpeg）" >&2
  exit 1
fi

gen_sine() { # name freq rate duration
  local name=$1 freq=$2 rate=$3 dur=$4
  "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=$freq:sample_rate=$rate:duration=$dur" \
    -ac 2 -c:a flac -sample_fmt s32 "$OUT/$name"
}

# 阈值 1：本地 FLAC，24/96 与 24/48 两种采样率
gen_sine tone96.flac 440 96000 6
gen_sine tone48.flac 660 48000 6
# 阈值 2：结束回调用的短文件（1.5 s，跑 3 次也不慢）
gen_sine short.flac 1000 48000 1.5
# 阈值 3：远端 Range 用的长文件（20 s；短文件会被 mpv 整段缓存，seek 不触发 Range 请求）
gen_sine long96.flac 440 96000 20
# 阈值 5：同专辑两首（同采样率/声道/位深，不同频率以便区分），用于 gapless
gen_sine album1.flac 1000 48000 3
gen_sine album2.flac 1200 48000 3

# S2 封面：512x512 PNG（纯色 + 一条竖条，够 MPMediaItemArtwork 用）
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=0x2a6f97:s=512x512:d=1" \
  -vf "drawbox=x=200:y=0:w=112:h=512:color=0xd62828:t=fill" \
  -frames:v 1 "$OUT/cover.png"

( cd "$OUT" && shasum -a 256 tone96.flac tone48.flac short.flac long96.flac album1.flac album2.flac cover.png > checksums.txt )
echo "生成于 $OUT"
cat "$OUT/checksums.txt"
for f in "$OUT"/*.flac; do
  "$FFMPEG" -hide_banner -loglevel error -i "$f" -f null - 2>/dev/null || true
done
