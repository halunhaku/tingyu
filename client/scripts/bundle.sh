#!/usr/bin/env bash
# Assembles 听屿.app reproducibly from the client module: compiles with
# CGO_ENABLED=0, copies the libmpv/FFmpeg frameworks M1 plays through, gives
# the executable an LC_RPATH to them, signs each binary ad-hoc, and verifies
# the result.
#
#   ./scripts/bundle.sh                 # darwin/arm64 into build/
#   PLATFORM=darwin/universal ./scripts/bundle.sh
#   FRAMEWORK_SRC=/path/to/Frameworks ./scripts/bundle.sh
#   OUT=/tmp/m1 ./scripts/bundle.sh
#
# The frameworks are the same LGPL build of mpv 0.36 + FFmpeg that
# media_kit_libs_macos_audio ships to the Flutter client (spike record §1.2).
# Unsigned copies cannot be dlopen'd on arm64, so each one is signed here.
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

# libmpv and its FFmpeg frameworks. Prefer an explicit source, then the pub
# cache the Flutter client already resolves (newest version if several).
framework_src=${FRAMEWORK_SRC:-}
if [ -z "$framework_src" ]; then
	for candidate in "$HOME"/.pub-cache/hosted/pub.dev/media_kit_libs_macos_audio-*/macos/Frameworks; do
		[ -d "$candidate" ] || continue
		framework_src=$candidate
	done
fi
[ -n "$framework_src" ] && [ -d "$framework_src" ] || {
	echo "bundle: libmpv frameworks not found; set FRAMEWORK_SRC to a media_kit_libs_macos_audio/macos/Frameworks directory" >&2
	exit 1
}

echo "bundle: $name $version ($identifier), minimum macOS $minimum, $PLATFORM"
"$GO" tool mygo build -platform "$PLATFORM" -skip-dmg -o "$OUT"

app="$OUT/${PLATFORM/\//-}/$name.app"
plist="$app/Contents/Info.plist"
[ -d "$app" ] || { echo "bundle: $app was not produced" >&2; exit 1; }
exe="$app/Contents/MacOS/$name"

# Copy the frameworks, sign each nested binary, and point the executable at
# them. DYLD_FRAMEWORK_PATH does not work for a signed binary (spike §6.4), so
# the LC_RPATH is the only reliable lookup path.
frameworks=(Avcodec Avfilter Avformat Avutil Mbedcrypto Mbedtls Mbedx509 Mpv Swresample Swscale)
mkdir -p "$app/Contents/Frameworks"
for f in "${frameworks[@]}"; do
	src="$framework_src/$f.xcframework/macos-arm64_x86_64/$f.framework"
	dst="$app/Contents/Frameworks/$f.framework"
	[ -d "$src" ] || { echo "bundle: missing $src" >&2; exit 1; }
	rm -rf "$dst"
	cp -R "$src" "$dst"
	codesign -f -s - "$dst/Versions/A/$f" >/dev/null 2>&1 || { echo "bundle: cannot sign $f" >&2; exit 1; }
done
if ! otool -l "$exe" | grep -q "@executable_path/../Frameworks"; then
	install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe"
fi
codesign -f -s - "$exe" >/dev/null 2>&1
codesign -f -s - "$app" >/dev/null 2>&1 || true

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
[ -f "$app/Contents/Frameworks/Mpv.framework/Versions/A/Mpv" ] || { echo "bundle: no libmpv in Frameworks" >&2; fail=1; }
for f in "${frameworks[@]}"; do
	codesign --verify --strict "$app/Contents/Frameworks/$f.framework/Versions/A/$f" 2>/dev/null || {
		echo "bundle: $f signature does not verify" >&2
		fail=1
	}
done
codesign --verify --strict "$app" || { echo "bundle: signature does not verify" >&2; fail=1; }
otool -l "$exe" | grep -q "@executable_path/../Frameworks" || { echo "bundle: executable has no Frameworks rpath" >&2; fail=1; }

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "bundle: $app (frameworks from $framework_src)"
for key in CFBundleIdentifier CFBundleShortVersionString LSMinimumSystemVersion CFBundleIconFile; do
	printf '  %-28s %s\n' "$key" "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
done
