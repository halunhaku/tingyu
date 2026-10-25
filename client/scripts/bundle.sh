#!/usr/bin/env bash
# Assembles 听屿.app reproducibly from the client module: compiles with
# CGO_ENABLED=0, packages Contents/Frameworks resources (including MyGo's
# SQLite dylib), writes Info.plist, the icon and an ad-hoc signature, then
# verifies what the M0 acceptance asks for.
#
#   ./scripts/bundle.sh                 # darwin/arm64 into build/
#   PLATFORM=darwin/universal ./scripts/bundle.sh
#   OUT=/tmp/m0 ./scripts/bundle.sh
#
# No disk image and no notarization: those are M6 (plan §6).
set -euo pipefail
cd "$(dirname "$0")/.."

GO=${GO:-go}
PLATFORM=${PLATFORM:-darwin/arm64}
OUT=${OUT:-build}
export CGO_ENABLED=0

command -v "$GO" >/dev/null || { echo "bundle: $GO not found; set GO=/path/to/go" >&2; exit 1; }

name=$(plutil -extract name raw -o - mygo.json)
identifier=$(plutil -extract identifier raw -o - mygo.json)
version=$(plutil -extract version raw -o - mygo.json)
minimum=$(plutil -extract macos.minimumSystemVersion raw -o - mygo.json)
icon=$(plutil -extract icon raw -o - mygo.json 2>/dev/null || echo resources/icon.png)

echo "bundle: $name $version ($identifier), minimum macOS $minimum, $PLATFORM"
"$GO" tool mygo build -platform "$PLATFORM" -skip-dmg -o "$OUT"

app="$OUT/${PLATFORM/\//-}/$name.app"
plist="$app/Contents/Info.plist"
[ -d "$app" ] || { echo "bundle: $app was not produced" >&2; exit 1; }

fail=0
check_plist() {
	local key=$1 want=$2 got
	got=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")
	if [ "$got" != "$want" ]; then
		echo "bundle: Info.plist $key = '$got', want '$want'" >&2
		fail=1
	fi
}
check_plist CFBundleIdentifier "$identifier"
check_plist CFBundleName "$name"
check_plist CFBundleShortVersionString "$version"
check_plist LSMinimumSystemVersion "$minimum"

[ -f "$app/Contents/Resources/AppIcon.icns" ] || { echo "bundle: no AppIcon.icns from $icon" >&2; fail=1; }
[ -f "$app/Contents/Resources/libmygo-sqlite3.dylib" ] || { echo "bundle: no SQLite dylib in Resources" >&2; fail=1; }
codesign --verify --strict "$app" || { echo "bundle: signature does not verify" >&2; fail=1; }

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "bundle: $app"
for key in CFBundleIdentifier CFBundleShortVersionString LSMinimumSystemVersion CFBundleIconFile; do
	printf '  %-28s %s\n' "$key" "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
done
