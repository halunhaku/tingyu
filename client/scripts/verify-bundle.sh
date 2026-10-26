#!/usr/bin/env bash
# Verifies what M6 promises about a built app or disk image, and reports what it
# actually found instead of what it hoped to find:
#
#   ./scripts/verify-bundle.sh build/darwin-arm64/听屿.app
#   ./scripts/verify-bundle.sh build/darwin-arm64/听屿-0.1.0.dmg
#   ./scripts/verify-bundle.sh build/darwin-arm64/听屿.app --require-notarized
#   ./scripts/verify-bundle.sh build/darwin-arm64/听屿.app --launch --quarantine
#
# What it checks:
#   * `codesign --verify --deep --strict` over the app, and every framework
#     inside Contents/Frameworks on its own (the inner signatures a notary
#     looks at);
#   * `codesign -dv --verbose=4`: identifier, team, hardened runtime, ticket;
#   * `spctl -a -vv --type execute` (Gatekeeper), and for an image
#     `spctl -a -t open --context context:primary-signature`;
#   * `stapler validate` (a ticket that works offline);
#   * a disk image mounts read-only, holds the app and the /Applications
#     symlink, and the app inside verifies;
#   * `--launch`: the app starts from a throwaway HOME and data directory, as a
#     first run on an empty machine does. `--quarantine` first puts the copy
#     under com.apple.quarantine, which is what a download looks like.
#
# `--require-notarized` makes an ad-hoc or merely signed build fail: use it in
# CI where a pass must mean Apple accepted the build. Without it the script
# reports the state and only fails on an invalid signature or a broken image.
set -uo pipefail
cd "$(dirname "$0")/.."

usage() {
	sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

[ $# -ge 1 ] || usage
path=$1
shift
require=0
launch=0
quarantine=0
for arg in "$@"; do
	case "$arg" in
	--require-notarized) require=1 ;;
	--launch) launch=1 ;;
	--quarantine) quarantine=1 ;;
	-h | --help) usage ;;
	*) echo "verify: unknown option $arg" >&2; usage ;;
	esac
done

[ -e "$path" ] || { echo "verify: $path does not exist; build it with ./scripts/bundle.sh" >&2; exit 2; }

fail=0
note() { printf '%s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
ok() { printf 'ok    %s\n' "$*"; }

notarized=0
check_app() { # app path [label]
	local app=$1 label=${2:-$1}
	note "== $label"
	codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 &&
		ok "codesign --verify --deep --strict" || bad "codesign --verify --deep --strict"

	local frameworks="$app/Contents/Frameworks" f
	if [ -d "$frameworks" ]; then
		for f in "$frameworks"/*.framework; do
			[ -d "$f" ] || continue
			codesign --verify --strict "$f" >/dev/null 2>&1 &&
				ok "$(basename "$f") verifies" || bad "$(basename "$f") signature does not verify"
		done
	else
		bad "no Contents/Frameworks (the app cannot play without libmpv)"
	fi

	local info
	info=$(codesign -dv --verbose=4 "$app" 2>&1)
	printf '%s\n' "$info" | sed 's/^/      /'
	case "$info" in
	*"Signature=adhoc"*) note "      signature: ad-hoc — Gatekeeper will reject it, and it is not distributable" ;;
	*"Authority=Developer ID Application"*) note "      signature: Developer ID" ;;
	*) note "      signature: not a Developer ID signature" ;;
	esac
	case "$info" in
	*"flags="*runtime*) ok "hardened runtime" ;;
	*) note "      hardened runtime: not enabled (only needed for notarization)" ;;
	esac
	case "$info" in
	*"Notarization ticket=stapled"*) notarized=1; ok "notarization ticket stapled to the app" ;;
	*) note "      notarization ticket: none on the app" ;;
	esac

	local gatekeeper
	gatekeeper=$(spctl -a -vv --type execute "$app" 2>&1)
	if [ $? -eq 0 ]; then
		ok "spctl: $gatekeeper"
		case "$gatekeeper" in *"source=Notarized Developer ID"*) notarized=1 ;; esac
	else
		note "      spctl rejected the app: $gatekeeper"
	fi

	if xcrun stapler validate "$app" >/dev/null 2>&1; then
		notarized=1
		ok "stapler validate (app)"
	else
		note "      no staple ticket on the app (offline Gatekeeper would need the network)"
	fi
}

check_dmg() { # dmg
	local dmg=$1
	note "== $dmg"
	if ! hdiutil verify "$dmg" >/dev/null 2>&1; then
		bad "the image does not verify (hdiutil verify)"
	fi
	local info
	info=$(codesign -dv --verbose=4 "$dmg" 2>&1) && {
		printf '%s\n' "$info" | sed 's/^/      /'
		ok "the image is signed"
	} || note "      the image has no signature (ad-hoc builds are not signed)"

	local gatekeeper
	gatekeeper=$(spctl -a -t open --context context:primary-signature -vv "$dmg" 2>&1)
	if [ $? -eq 0 ]; then
		ok "spctl (disk image): $gatekeeper"
	else
		note "      spctl rejected the image: $gatekeeper"
	fi

	local mount
	mount=$(mktemp -d "${TMPDIR:-/tmp}/tingyu-mount-XXXXXX")
	if ! hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null 2>&1; then
		bad "the image does not mount"
		rmdir "$mount" 2>/dev/null || true
		return
	fi

	local apps name
	apps=$(find "$mount" -maxdepth 1 -name '*.app' -type d | head -1)
	if [ -z "$apps" ]; then
		bad "the image holds no app"
	else
		name=$(basename "$apps")
		ok "the image holds $name"
		check_app "$apps" "$name inside the image"
	fi
	if [ -L "$mount/Applications" ] && [ "$(readlink "$mount/Applications")" = "/Applications" ]; then
		ok "the image holds the /Applications drag target"
	else
		bad "the image has no /Applications symlink"
	fi
	[ -n "${apps:-}" ] && [ -d "$apps/Contents/Frameworks/Mpv.framework" ] &&
		ok "libmpv ships inside the image" ||
		bad "libmpv is missing from the image"
	hdiutil detach "$mount" >/dev/null 2>&1 || true
	rm -rf "$mount"
}

launch_app() { # app
	local app=$1
	local clean log pid ready
	clean=$(mktemp -d "${TMPDIR:-/tmp}/tingyu-firstrun-XXXXXX")
	log="$clean/startup.log"
	local copy="$clean/$name.app"
	cp -R "$app" "$copy"
	if [ "$quarantine" = 1 ]; then
		xattr -w com.apple.quarantine "0083;$(date +%s);Safari;" "$copy" &&
			ok "marked the copy as downloaded (com.apple.quarantine)"
	fi
	mkdir -p "$clean/data"
	note "== first launch from an empty HOME ($clean)"
	HOME="$clean" TINGYU_DATA_DIR="$clean/data" TINGYU_STARTUP_LOG="$log" \
		"$copy/Contents/MacOS/$name" >/dev/null 2>&1 &
	pid=$!
	ready=""
	for _ in $(seq 1 300); do
		ready=$(grep -m1 'startup ready' "$log" 2>/dev/null || true)
		[ -n "$ready" ] && break
		kill -0 "$pid" 2>/dev/null || break
		# A process killed by Gatekeeper stays a zombie until it is reaped,
		# and kill -0 still succeeds for one: stop waiting for it.
		ps -o stat= -p "$pid" 2>/dev/null | grep -q '^Z' && break
		sleep 0.05
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
	fi
	wait "$pid" 2>/dev/null
	local status=$?
	if [ -n "$ready" ]; then
		ok "the app started: $ready"
	else
		bad "the app did not reach its first frame (exit $status); startup log:"
		sed 's/^/      /' "$log" 2>/dev/null || note "      (no log)"
		if [ "$quarantine" = 1 ]; then
			note "      the copy was quarantined: Gatekeeper holds or kills a build it has no ticket"
			note "      for, which is what an ad-hoc or not-yet-notarized build gets. With NOTARY_PROFILE"
			note "      the same check must pass; until then this is the honest result."
		fi
	fi
	rm -rf "$clean"
}

name=$(plutil -extract name raw -o - mygo.json)

case "$path" in
*.app) check_app "$path" ;;
*.dmg) check_dmg "$path" ;;
*) echo "verify: give a .app or a .dmg" >&2; exit 2 ;;
esac

if [ "$launch" = 1 ]; then
	if [ "${path##*.}" != "app" ]; then
		echo "verify: --launch takes a .app, not an image" >&2
		exit 2
	fi
	launch_app "$path"
fi

note ""
if [ "$require" = 1 ]; then
	if [ "$notarized" = 1 ]; then
		ok "notarized (required)"
	else
		bad "--require-notarized: this build is not notarized"
	fi
else
	if [ "$notarized" = 1 ]; then
		note "result: notarized and stapled"
	else
		note "result: not notarized — acceptable for development, not for distribution"
	fi
fi

[ "$fail" -eq 0 ] || exit 1
