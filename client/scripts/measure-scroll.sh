#!/usr/bin/env bash
# Reproduces the M4 scroll gate: 10,000 rows, whole-list traversal, per-frame
# timings from MyGo's own frame statistics (MYGO_FRAME_STATS=all) through
# ui.Tester (build + layout + paint + in-memory present; no GPU rasterization).
#
#   ./scripts/measure-scroll.sh [output-file]
#
# Exits non-zero when the p95 frame time exceeds 16.7 ms.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-/tmp/tingyu-m4-scroll-frames.txt}
export CGO_ENABLED=0
log=$(mktemp)
trap 'rm -f "$log"' EXIT
MYGO_FRAME_STATS=all go test -count=1 ./internal/shell/ -run TestLibraryScrollP95 -v >"$log" 2>&1
grep -q 'scroll_p95' "$log" || { cat "$log"; exit 1; }
grep 'scroll_p95' "$log"
python3 - "$log" "$out" <<'PY'
import re, sys
log, out = sys.argv[1], sys.argv[2]
frames = []
for line in open(log):
    m = re.search(r'mygo: frame (\d+) took ([\d.]+) ms: build ([\d.]+), layout ([\d.]+), paint ([\d.]+), present ([\d.]+)', line)
    if m:
        frames.append(tuple(float(v) for v in m.groups()))
# Frames 1..30 are startup and the first layout; the scroll frames follow.
scroll = [f for f in frames if f[0] > 30]
if not scroll:
    print('no frame statistics in the test log', file=sys.stderr)
    sys.exit(1)
for i, name in enumerate(['total', 'build', 'layout', 'paint', 'present'], start=1):
    vals = sorted(f[i] for f in scroll)
    pct = lambda q: vals[int((len(vals) - 1) * q)]
    print(f'{name:8s} p50={pct(.5):.3f} p95={pct(.95):.3f} p99={pct(.99):.3f} max={vals[-1]:.3f} ms')
p95 = sorted(f[1] for f in scroll)[int((len(scroll) - 1) * .95)]
with open(out, 'w') as f:
    f.write('# M4 10,000-row scroll samples (MYGO_FRAME_STATS=all, ui.Tester)\n')
    f.write('# frame\ttotal_ms\tbuild_ms\tlayout_ms\tpaint_ms\tpresent_ms\n')
    for row in scroll:
        f.write('%.0f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\n' % row)
print(f'{len(scroll)} frame samples -> {out}')
if p95 > 16.7:
    print(f'FAIL: p95 {p95:.3f} ms > 16.7 ms', file=sys.stderr)
    sys.exit(1)
print(f'PASS: p95 {p95:.3f} ms <= 16.7 ms')
PY
