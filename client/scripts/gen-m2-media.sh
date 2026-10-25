#!/usr/bin/env bash
# Generates the M2 acceptance media with ffmpeg. Everything lands under
# build/m2-media (git-ignored); nothing is committed.
#
#   ./scripts/gen-m2-media.sh              # build/m2-media
#   OUT=/tmp/m2-media ./scripts/gen-m2-media.sh
#
# Layout and reasons:
#   formats/tone.*   one 14 s tone per supported extension: 10 s of playback
#                    plus a seek to the middle fits inside it
#   gapless/a,b.flac two 3 s 48 kHz/24 bit FLACs; 440 Hz over 3 s is a whole
#                    number of cycles, so the waveform is continuous across the
#                    track boundary and any silence in the rendered output is a
#                    real gap, not a phase jump
#   queue/trackNNNN.wav 200 chunks of 0.2 s for the queue-integrity run
#   remote/tone.flac 24 s file served over Range, bigger than the demuxer cache
#                    so a seek provokes a real Range request
#   remote/second.flac a second URL, used to prove headers are not leaked
#   remote/nolength.aac ADTS serves with no Content-Length and no duration
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=${OUT:-build/m2-media}
FFMPEG=${FFMPEG:-ffmpeg}

command -v "$FFMPEG" >/dev/null || { echo "gen-m2-media: ffmpeg not found; set FFMPEG" >&2; exit 1; }

run() { "$FFMPEG" -hide_banner -loglevel error -y "$@"; }

mkdir -p "$OUT"/{formats,gapless,queue,remote}
rm -f "$OUT"/formats/tone.* "$OUT"/gapless/*.flac "$OUT"/queue/*.wav "$OUT"/remote/*

echo "gen-m2-media: 9 formats (14 s each)"
tone="-f lavfi -i sine=frequency=440:duration=14"
# shellcheck disable=SC2086
run $tone -c:a libmp3lame -b:a 192k "$OUT/formats/tone.mp3"
# shellcheck disable=SC2086
run $tone -ar 96000 -c:a flac -sample_fmt s32 "$OUT/formats/tone.flac"
# shellcheck disable=SC2086
run $tone -c:a aac -b:a 192k "$OUT/formats/tone.m4a"
# shellcheck disable=SC2086
run $tone -c:a aac -b:a 192k -f adts "$OUT/formats/tone.aac"
# shellcheck disable=SC2086
run $tone -c:a pcm_s16le "$OUT/formats/tone.wav"
# shellcheck disable=SC2086
# ffmpeg's native Vorbis encoder is marked experimental; this build has no
# libvorbis, and mpv only has to decode the result.
# shellcheck disable=SC2086
run $tone -ac 2 -c:a vorbis -strict -2 -q:a 5 "$OUT/formats/tone.ogg"
# shellcheck disable=SC2086
run $tone -c:a libopus -b:a 128k "$OUT/formats/tone.opus"
# shellcheck disable=SC2086
run $tone -c:a pcm_s16be "$OUT/formats/tone.aiff"
# shellcheck disable=SC2086
run $tone -c:a alac -f ipod "$OUT/formats/tone.alac"

echo "gen-m2-media: gapless pair (3 s + 3 s, 48 kHz/24 bit FLAC)"
gapless="-f lavfi -i sine=frequency=440:duration=3"
# shellcheck disable=SC2086
run $gapless -ar 48000 -c:a flac -sample_fmt s32 "$OUT/gapless/a.flac"
# shellcheck disable=SC2086
run $gapless -ar 48000 -c:a flac -sample_fmt s32 "$OUT/gapless/b.flac"

echo "gen-m2-media: 200 queue tracks (0.2 s each)"
run -f lavfi -i sine=frequency=330:duration=40 -ar 22050 -ac 1 -c:a pcm_s16le \
	-f segment -segment_time 0.2 -segment_format wav -reset_timestamps 1 \
	"$OUT/queue/track%04d.wav"
# The segment muxer can emit one extra tail chunk; the harness wants exactly
# 200.
count=$(find "$OUT/queue" -name 'track*.wav' | wc -l | tr -d ' ')
if [ "$count" -gt 200 ]; then
	find "$OUT/queue" -name 'track*.wav' | sort | tail -n $((count - 200)) | while read -r extra; do rm -f "$extra"; done
fi

echo "gen-m2-media: remote sources"
# 96 kHz/24 bit on purpose: the file is bigger than mpv's 1 MB demuxer cache,
# so a seek must ask the server for another byte range.
run -f lavfi -i sine=frequency=440:duration=24 -ar 96000 -c:a flac -sample_fmt s32 "$OUT/remote/tone.flac"
run -f lavfi -i sine=frequency=550:duration=16 -ar 96000 -c:a flac -sample_fmt s32 "$OUT/remote/second.flac"
run -f lavfi -i sine=frequency=440:duration=12 -c:a aac -b:a 128k -f adts "$OUT/remote/nolength.aac"

echo "gen-m2-media: $(find "$OUT" -type f | wc -l | tr -d ' ') files, $(du -sh "$OUT" | cut -f1) in $OUT"
