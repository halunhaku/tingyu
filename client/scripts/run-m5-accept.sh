#!/usr/bin/env bash
# Runs the M5 acceptance (plan §6 M5) and the quality gates:
#
#   ./scripts/run-m5-accept.sh                  # full run against the live sources
#   ./scripts/run-m5-accept.sh -tracks 5        # a quick run
#   ./scripts/run-m5-accept.sh -skip-network    # offline/deterministic phases only
#
# Gates: gofmt, `CGO_ENABLED=0 go build ./...`, `go vet ./...`,
# `go test ./...` and `go test -race ./...`. Then the harness copies the real
# library into build/m5-accept/<timestamp>/data (the production library is only
# read), runs the enrichment pipeline, and writes the report, screenshots and
# the before/after database JSON next to it.
set -uo pipefail
cd "$(dirname "$0")/.."
export CGO_ENABLED=0

GO=${GO:-go}
status=0

step() {
	echo
	echo "== $1 =="
}

step "gofmt -l (client/)"
unformatted=$(gofmt -l ./internal ./cmd ./main.go ./tools)
if [ -n "$unformatted" ]; then
	echo "$unformatted"
	status=1
else
	echo "clean"
fi

step "go build ./..."
if ! "$GO" build ./...; then status=1; fi

step "go vet ./..."
if ! "$GO" vet ./...; then status=1; fi

step "go test ./..."
if ! "$GO" test ./...; then status=1; fi

step "go test -race ./..."
if ! "$GO" test -race ./...; then status=1; fi

step "M5 acceptance harness"
# The harness needs no libmpv; it drives the same packages the app wires.
if ! "$GO" build -o build/m5accept ./cmd/m5accept; then
	echo "run-m5-accept: build failed" >&2
	exit 2
fi

stamp=$(date +%Y%m%d-%H%M%S)
OUT=${OUT:-build/m5-accept/$stamp}
mkdir -p "$OUT"
./build/m5accept -out "$OUT" "$@" 2>&1 | tee "$OUT/log.txt"
harness=${PIPESTATUS[0]}
if [ "$harness" -ne 0 ]; then
	status=$harness
fi

echo
echo "evidence: $OUT"
echo "gates:"
[ "$status" -eq 0 ] && echo "  all passed" || echo "  see failures above"
exit "$status"
