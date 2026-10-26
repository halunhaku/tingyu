#!/usr/bin/env bash
# Assembles 听屿.app reproducibly from the client module: compiles with
# CGO_ENABLED=0, copies the libmpv/FFmpeg frameworks M1 plays through, signs
# every nested binary from the inside out, and verifies the result.
#
#   ./scripts/bundle.sh                     # ad-hoc, darwin/arm64 into build/
#   PLATFORM=darwin/universal ./scripts/bundle.sh
#   FRAMEWORK_SRC=$(./scripts/fetch-frameworks.sh) ./scripts/bundle.sh
#   OUT=/tmp/m1 ./scripts/bundle.sh
#
# Release path (plan §6 M6):
#
#   SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
#   NOTARY_PROFILE=notary DMG=1 ./scripts/bundle.sh
#
#   SIGN_IDENTITY      codesign identity; "-" (default) signs ad-hoc. A real
#                      identity adds the hardened runtime and a secure timestamp,
#                      which notarization requires.
#   SIGN_ENTITLEMENTS  entitlements file for the executable and the app. Defaults
#                      to mygo.json macos.entitlements when that key exists. The
#                      client needs none today (CGO_ENABLED=0, no JIT).
#   DMG=1              also build a disk image: the app, an /Applications
#                      symlink, signed with the identity when there is one.
#   NOTARY_PROFILE     keychain profile made by
#                      `xcrun notarytool store-credentials`; notarizes the DMG,
#                      staples the ticket to the DMG and to the app, and runs
#                      spctl. Needs a real SIGN_IDENTITY: this script never
#                      pretends a build was notarized.
#
# The frameworks are the pinned LGPL mpv 0.36 + FFmpeg build that
# scripts/fetch-frameworks.sh downloads (version and sha256 are pinned there;
# the provenance is in the spike record §1.2). Unsigned copies cannot be
# dlopen'd on arm64, so each one is signed here.
#
# Signing order is inside out (research §5.5): each framework's Mach-O binary,
# then the framework bundle, then the executable, then the app. Never --deep
# when signing: it would overwrite the inner signatures made here. MyGo's own
# signing pass covers Contents/Resources only (cmd/mygo/resources.go), which is
# why Contents/Frameworks is this script's job.
set -euo pipefail
cd "$(dirname "$0")/.."

GO=${GO:-go}
PLATFORM=${PLATFORM:-darwin/arm64}
OUT=${OUT:-build}
SIGN_IDENTITY=${SIGN_IDENTITY:-}
DMG=${DMG:-0}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
export CGO_ENABLED=0

command -v "$GO" >/dev/null || { echo "bundle: $GO not found; set GO=/path/to/go" >&2; exit 1; }

name=$(plutil -extract name raw -o - mygo.json)
identifier=$(plutil -extract identifier raw -o - mygo.json)
version=$(plutil -extract version raw -o - mygo.json)
minimum=$(plutil -extract macos.minimumSystemVersion raw -o - mygo.json)
icon=$(plutil -extract icon raw -o - mygo.json 2>/dev/null || echo resources/icon.png)

identity=${SIGN_IDENTITY}
if [ -z "$identity" ]; then
	identity=$(plutil -extract macos.signingIdentity raw -o - mygo.json 2>/dev/null || echo "-")
fi
[ -n "$identity" ] || identity=-
adHoc=0
[ "$identity" = "-" ] && adHoc=1

entitlements=${SIGN_ENTITLEMENTS:-}
if [ -z "$entitlements" ]; then
	entitlements=$(plutil -extract macos.entitlements raw -o - mygo.json 2>/dev/null || true)
fi
[ -n "$entitlements" ] || entitlements=""

if [ "$NOTARY_PROFILE" != "" ] && [ "$adHoc" = 1 ]; then
	echo "bundle: notarization needs a Developer ID identity; set SIGN_IDENTITY (or macos.signingIdentity)" >&2
	exit 1
fi

# libmpv and its FFmpeg frameworks. Prefer an explicit source, then the copy
# scripts/fetch-frameworks.sh already downloaded into build/frameworks. The
# build is self-contained since M7: nothing is borrowed from a pub cache.
framework_src=${FRAMEWORK_SRC:-}
if [ -z "$framework_src" ] && [ -d "build/frameworks/Mpv.xcframework" ]; then
	framework_src=build/frameworks
fi
[ -n "$framework_src" ] && [ -d "$framework_src" ] || {
	echo "bundle: libmpv frameworks not found; set FRAMEWORK_SRC (or run scripts/fetch-frameworks.sh first)" >&2
	exit 1
}

if [ "$adHoc" = 1 ]; then
	echo "bundle: $name $version ($identifier), minimum macOS $minimum, $PLATFORM, ad-hoc signature"
else
	echo "bundle: $name $version ($identifier), minimum macOS $minimum, $PLATFORM, identity $identity"
fi

build=("$GO" tool mygo build -platform "$PLATFORM" -skip-dmg)
if [ "$adHoc" = 0 ]; then
	build+=(-sign "$identity")
fi
"${build[@]}" -o "$OUT"

app="$OUT/${PLATFORM/\//-}/$name.app"
plist="$app/Contents/Info.plist"
[ -d "$app" ] || { echo "bundle: $app was not produced" >&2; exit 1; }
exe="$app/Contents/MacOS/$name"

# codesign every nested piece with the same policy: a real identity gets the
# hardened runtime and a secure timestamp (notarization rejects a signature
# without them); ad-hoc gets a bare signature, enough to dlopen on arm64.
sign() { # path [entitlements]
	local path=$1 extra=${2:-} args=(-f -s "$identity") out=""
	if [ "$adHoc" = 0 ]; then
		args+=(--options runtime --timestamp)
	fi
	if [ -n "$extra" ]; then
		args+=(--entitlements "$extra")
	fi
	# A signature with --timestamp asks Apple's timestamp server; a network
	# hiccup there is not a reason to fail a build that is otherwise fine, so
	# one retry. The error text is printed: swallowing it hid which binary
	# failed when the signed build first ran.
	for attempt in 1 2; do
		if out=$(codesign "${args[@]}" "$path" 2>&1); then
			return 0
		fi
		if [ "$attempt" = 1 ]; then
			sleep 1
		fi
	done
	echo "bundle: codesign failed for $path: $out" >&2
	return 1
}

# A disk image is signed as data: the hardened runtime is a Mach-O option and
# has no meaning there, only the secure timestamp.
sign_image() { # path
	local out=""
	for attempt in 1 2; do
		if out=$(codesign -f -s "$identity" --timestamp "$1" 2>&1); then
			return 0
		fi
		if [ "$attempt" = 1 ]; then
			sleep 1
		fi
	done
	echo "bundle: codesign failed for $1: $out" >&2
	return 1
}

# Copy the frameworks, sign each nested binary from the inside out, and point
# the executable at them. DYLD_FRAMEWORK_PATH does not work for a signed binary
# (spike §6.4), so the LC_RPATH is the only reliable lookup path.
frameworks=(Avcodec Avfilter Avformat Avutil Mbedcrypto Mbedtls Mbedx509 Mpv Swresample Swscale)
mkdir -p "$app/Contents/Frameworks"
for f in "${frameworks[@]}"; do
	src="$framework_src/$f.xcframework/macos-arm64_x86_64/$f.framework"
	dst="$app/Contents/Frameworks/$f.framework"
	[ -d "$src" ] || { echo "bundle: missing $src" >&2; exit 1; }
	rm -rf "$dst"
	cp -R "$src" "$dst"
	# Inside out: the Mach-O binary, then the bundle around it.
	sign "$dst/Versions/A/$f" || exit 1
	sign "$dst" || exit 1
done
if ! otool -l "$exe" | grep -q "@executable_path/../Frameworks"; then
	install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe"
fi
# The executable and the app carry the entitlements; the frameworks do not.
sign "$exe" "$entitlements" || exit 1
sign "$app" "$entitlements" || exit 1

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
	codesign --verify --strict "$app/Contents/Frameworks/$f.framework" 2>/dev/null || {
		echo "bundle: $f signature does not verify" >&2
		fail=1
	}
done
codesign --verify --strict --deep "$app" || { echo "bundle: signature does not verify" >&2; fail=1; }
otool -l "$exe" | grep -q "@executable_path/../Frameworks" || { echo "bundle: executable has no Frameworks rpath" >&2; fail=1; }

if [ "$adHoc" = 1 ]; then
	# Gatekeeper rejects an ad-hoc build; say so here rather than leaving it to
	# whoever installs it. CI that needs a passable build passes SIGN_IDENTITY.
	if spctl -a -vv --type execute "$app" >/dev/null 2>&1; then
		echo "bundle: warning: spctl accepted an ad-hoc build, which it should not" >&2
	fi
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi

dmg=""
if [ "$DMG" = 1 ]; then
	dmg=${DMG_OUT:-"$OUT/${PLATFORM/\//-}/$name-$version.dmg"}
	staging=$(mktemp -d "${TMPDIR:-/tmp}/tingyu-dmg-XXXXXX")
	trap 'rm -rf "$staging"' EXIT
	cp -R "$app" "$staging/$name.app"
	ln -s /Applications "$staging/Applications"
	# UDZO: compressed read-only image, the format Apple's own tools ship.
	rm -f "$dmg"
	hdiutil create -quiet -volname "$name $version" -srcfolder "$staging" \
		-ov -format UDZO "$dmg" >/dev/null
	if [ "$adHoc" = 0 ]; then
		sign_image "$dmg" || exit 1
	fi
fi

if [ "$NOTARY_PROFILE" != "" ]; then
	[ -n "$dmg" ] || { echo "bundle: notarization needs DMG=1 (the notary service takes the image)" >&2; exit 1; }
	submit=$(mktemp "${TMPDIR:-/tmp}/tingyu-notary-XXXXXX.json")
	trap 'rm -f "$submit"; rm -rf "${staging:-}"' EXIT
	echo "bundle: submitting $(basename "$dmg") to the notary service (profile $NOTARY_PROFILE)"
	xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait \
		--output-format json >"$submit" || {
		echo "bundle: notarytool failed" >&2
		cat "$submit" >&2
		exit 1
	}
	status=$(plutil -extract status raw -o - "$submit" 2>/dev/null || echo unknown)
	submission=$(plutil -extract id raw -o - "$submit" 2>/dev/null || echo "")
	case "$status" in
	Accepted) echo "bundle: notarization accepted ($submission)" ;;
	*)
		echo "bundle: notarization $status; the notary log follows" >&2
		[ -n "$submission" ] && xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" >&2 || true
		exit 1
		;;
	esac
	# Staple both: the image people download, and the bare app an update would
	# install (as MyGo's own dmg step does).
	xcrun stapler staple "$dmg" >/dev/null
	xcrun stapler staple "$app" >/dev/null
	xcrun stapler validate "$dmg" >/dev/null || { echo "bundle: the DMG has no ticket" >&2; exit 1; }
	xcrun stapler validate "$app" >/dev/null || { echo "bundle: the app has no ticket" >&2; exit 1; }
	if ! spctl -a -vv --type execute "$app"; then
		echo "bundle: spctl rejected the notarized app" >&2
		exit 1
	fi
fi

echo "bundle: $app (frameworks from $framework_src)"
[ -n "$dmg" ] && echo "bundle: $dmg"
for key in CFBundleIdentifier CFBundleShortVersionString LSMinimumSystemVersion CFBundleIconFile; do
	printf '  %-28s %s\n' "$key" "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
done
if [ "$adHoc" = 1 ]; then
	echo "  signature                    ad-hoc (not distributable; pass SIGN_IDENTITY)"
elif [ "$NOTARY_PROFILE" = "" ]; then
	echo "  signature                    $identity (signed, not notarized)"
else
	echo "  signature                    $identity (notarized, stapled)"
fi
