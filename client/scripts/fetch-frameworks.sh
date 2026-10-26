#!/usr/bin/env bash
# Downloads the pinned LGPL mpv 0.36 + FFmpeg xcframeworks that bundle.sh copies
# into Contents/Frameworks: the same artifact the Flutter client's
# media_kit_libs_macos_audio 1.1.4 fetches in its pod Makefile (version and
# checksum are copied from that Makefile, so both clients play through the same
# binaries).
#
#   ./scripts/fetch-frameworks.sh                 # → build/frameworks
#   DEST=/tmp/frameworks ./scripts/fetch-frameworks.sh
#   FRAMEWORK_SRC=$(./scripts/fetch-frameworks.sh) ./scripts/bundle.sh
#
# It prints the directory on stdout (progress on stderr), so it composes with
# bundle.sh, and does nothing when the frameworks are already there. A clean
# machine and CI have no Flutter pub cache, which is why this exists: bundle.sh
# alone looks in ~/.pub-cache.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=v0.6.0
SHA256=916220b7b4fe9209de41264382966ac90a2de2ac11956a4b6041cf66a8110732
DEST=${DEST:-build/frameworks}
URL="https://github.com/media-kit/libmpv-darwin-build/releases/download/${VERSION}/libmpv-xcframeworks_${VERSION}_macos-universal-audio-default.tar.gz"

if [ -d "$DEST/Mpv.xcframework" ]; then
	echo "$DEST"
	exit 0
fi

echo "fetch-frameworks: downloading $VERSION into $DEST" >&2
mkdir -p "$DEST/.cache"
trap 'rm -f "$DEST/.cache/libmpv.tar.gz"' EXIT
curl -fL --retry 3 "$URL" -o "$DEST/.cache/libmpv.tar.gz" >&2
if ! echo "$SHA256  $DEST/.cache/libmpv.tar.gz" | shasum -a 256 -c - >/dev/null 2>&1; then
	echo "fetch-frameworks: checksum mismatch, refusing to use the download" >&2
	exit 1
fi
# The archive holds one top-level directory of .xcframework bundles.
tar -xzf "$DEST/.cache/libmpv.tar.gz" --strip-components 1 -C "$DEST"
rm -rf "$DEST/.cache"
[ -d "$DEST/Mpv.xcframework" ] || {
	echo "fetch-frameworks: $DEST/Mpv.xcframework is missing after unpacking" >&2
	exit 1
}
echo "$DEST"
