#!/usr/bin/env bash
# Measures M0 cold start: process start (kernel time, not main) to the
# window's first frame, which MyGo reports with OnReadyToShow.
#
#   ./scripts/measure-coldstart.sh            # 10 runs
#   RUNS=20 ./scripts/measure-coldstart.sh
#   APP=build/darwin-arm64/听屿.app ./scripts/measure-coldstart.sh
#
# It always runs against a throwaway copy of the source library, never the
# production file (plan §8.1 rule 2). Build the app first with
# ./scripts/bundle.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS=${RUNS:-10}
APP=${APP:-build/darwin-arm64/听屿.app}
BIN="$APP/Contents/MacOS/听屿"
SOURCE=${SOURCE:-"$HOME/Library/Application Support/com.halunhaku.tingyu/library.sqlite"}

[ -x "$BIN" ] || { echo "measure: $BIN not found; run ./scripts/bundle.sh" >&2; exit 1; }
[ -f "$SOURCE" ] || { echo "measure: source library $SOURCE not found" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/tingyu-coldstart-XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$SOURCE" "$work/library.sqlite"

echo "measure: $APP"
echo "measure: library copy $work/library.sqlite"
values=()
for i in $(seq 1 "$RUNS"); do
	log="$work/run-$i.log"
	: >"$log"
	TINGYU_DATA_DIR="$work" TINGYU_STARTUP_LOG="$log" "$BIN" >/dev/null 2>&1 &
	pid=$!
	line=""
	for _ in $(seq 1 250); do
		line=$(grep -m1 'startup ready' "$log" || true)
		[ -n "$line" ] && break
		sleep 0.02
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	if [ -z "$line" ]; then
		echo "measure: run $i never reported ready; log:" >&2
		cat "$log" >&2
		exit 1
	fi
	case "$line" in
	*"since process"*) ;;
	*) echo "measure: run $i has no process-start mark: $line" >&2; exit 1 ;;
	esac
	ms=$(awk '{print $3}' <<<"$line" | tr -d 'ms')
	values+=("$ms")
	printf 'run %2d  %7.1f ms\n' "$i" "$ms"
done

printf '%s\n' "${values[@]}" | sort -n | awk '
	{a[NR]=$1; sum+=$1}
	END {
		median = (a[int((NR+1)/2)] + a[int((NR+2)/2)]) / 2
		printf "cold start %d runs: min %.1f ms, median %.1f ms, max %.1f ms, mean %.1f ms\n", NR, a[1], median, a[NR], sum/NR
	}'
