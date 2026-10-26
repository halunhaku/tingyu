#!/usr/bin/env bash
# Builds and runs the M3 acceptance harness against the production source layer.
#
#   ./scripts/run-m3-accept.sh
#
# The frameworks come from the app bundle built by scripts/bundle.sh; the
# harness binary gets the same LC_RPATH plus an ad-hoc signature, because an
# unsigned arm64 binary cannot dlopen libmpv. Mock servers are local (httptest),
# so no real WebDAV or Quark account is used.
set -uo pipefail
cd "$(dirname "$0")/.."
export CGO_ENABLED=0

GO=${GO:-go}

app=build/darwin-arm64/听屿.app
if [ ! -d "$app/Contents/Frameworks" ]; then
	./scripts/bundle.sh >/tmp/m3-bundle.log 2>&1 || { echo "run-m3-accept: bundle failed, see /tmp/m3-bundle.log" >&2; exit 2; }
fi
frameworks="$PWD/$app/Contents/Frameworks"

mkdir -p build
"$GO" build -o build/sourceaccept ./cmd/sourceaccept || exit 2
install_name_tool -add_rpath "$frameworks" build/sourceaccept 2>/dev/null
codesign -f -s - build/sourceaccept >/dev/null 2>&1 || { echo "run-m3-accept: codesign failed" >&2; exit 2; }

stamp=$(date +%Y%m%d-%H%M%S)
OUT=${OUT:-build/m3-evidence/$stamp}
mkdir -p "$OUT"
MPV_LIB="$frameworks/Mpv.framework/Versions/A/Mpv" \
	./build/sourceaccept -out "$OUT" "$@" 2>&1 | tee "$OUT/log.txt"
status=${PIPESTATUS[0]}
echo "evidence: $OUT"
exit $status
