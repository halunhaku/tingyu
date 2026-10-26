#!/usr/bin/env bash
# Builds and runs the seek-on-release probe against a local Range source.
#
#   ./scripts/run-scrub-probe.sh              # legacy and view policies
#   STEPS=40 ./scripts/run-scrub-probe.sh     # a longer drag
#
# The probe plays build/m2-media/remote/tone.flac from the M2 Range server and
# drags the progress slider `steps` frames. The frameworks come from the app
# bundle built by scripts/bundle.sh; the binary gets the same LC_RPATH plus an
# ad-hoc signature, because an unsigned arm64 binary cannot dlopen libmpv.
set -uo pipefail
cd "$(dirname "$0")/.."
export CGO_ENABLED=0

GO=${GO:-go}
STEPS=${STEPS:-30}
GAP=${GAP:-40ms}
media=build/scrub-media
if [ ! -f "$media/remote/long.flac" ]; then
	# A 180 s, 96 kHz/24-bit FLAC is far bigger than mpv's demuxer cache, so a
	# seek must ask the Range server for bytes (generate: ffmpeg).
	command -v ffmpeg >/dev/null || { echo "run-scrub-probe: ffmpeg not found; set PATH" >&2; exit 2; }
	mkdir -p "$media/remote"
	ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=180 \
		-ar 96000 -c:a flac -sample_fmt s32 "$media/remote/long.flac" || exit 2
fi

app=build/darwin-arm64/听屿.app
if [ ! -d "$app/Contents/Frameworks" ]; then
	./scripts/bundle.sh >/tmp/scrub-bundle.log 2>&1 || { echo "run-scrub-probe: bundle failed, see /tmp/scrub-bundle.log" >&2; exit 2; }
fi
frameworks="$PWD/$app/Contents/Frameworks"

mkdir -p build
"$GO" build -o build/scrubprobe ./cmd/scrubprobe || exit 2
install_name_tool -add_rpath "$frameworks" build/scrubprobe 2>/dev/null
codesign -f -s - build/scrubprobe >/dev/null 2>&1 || { echo "run-scrub-probe: codesign failed" >&2; exit 2; }

stamp=$(date +%Y%m%d-%H%M%S)
OUT=${OUT:-build/scrub-evidence/$stamp}
mkdir -p "$OUT"
status=0
for policy in legacy view; do
	echo "== policy $policy"
	MPV_LIB="$frameworks/Mpv.framework/Versions/A/Mpv" \
		./build/scrubprobe -media "$media" -policy "$policy" -steps "$STEPS" \
		-gap "$GAP" -out "$OUT/$policy.json" 2>&1 | tee "$OUT/$policy.txt" || status=1
done
echo "evidence: $OUT"
exit $status
