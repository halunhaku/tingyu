#!/usr/bin/env bash
# Builds and runs the M2 acceptance harness against the production kernel.
#
#   ./scripts/run-m2-accept.sh                    # all phases
#   ./scripts/run-m2-accept.sh -phases remote     # one phase
#
# Media is generated on first use (build/m2-media). The frameworks come from the
# app bundle built by scripts/bundle.sh; the harness binary gets the same
# LC_RPATH plus an ad-hoc signature, because an unsigned arm64 binary cannot
# dlopen libmpv.
set -uo pipefail
cd "$(dirname "$0")/.."
export CGO_ENABLED=0

GO=${GO:-go}
[ -d build/m2-media/formats ] || ./scripts/gen-m2-media.sh

app=build/darwin-arm64/听屿.app
if [ ! -d "$app/Contents/Frameworks" ]; then
	./scripts/bundle.sh >/tmp/m2-bundle.log 2>&1 || { echo "run-m2-accept: bundle failed, see /tmp/m2-bundle.log" >&2; exit 2; }
fi
frameworks="$PWD/$app/Contents/Frameworks"

mkdir -p build
"$GO" build -o build/accept ./cmd/accept || exit 2
install_name_tool -add_rpath "$frameworks" build/accept 2>/dev/null
codesign -f -s - build/accept >/dev/null 2>&1 || { echo "run-m2-accept: codesign failed" >&2; exit 2; }

stamp=$(date +%Y%m%d-%H%M%S)
OUT=${OUT:-build/m2-evidence/$stamp}
MPV_LIB="$frameworks/Mpv.framework/Versions/A/Mpv" \
	./build/accept -media build/m2-media -out "$OUT" "$@"
status=$?
echo "evidence: $OUT"
exit $status
