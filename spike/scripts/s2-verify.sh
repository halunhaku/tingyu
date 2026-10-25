#!/bin/bash
# S2（媒体键 / Now Playing）的一次性证据采集：跑 MyGo 窗口版本（进程内 libmpv + MediaPlayer
# 同进程），期间从**系统侧**注入命令并抓 mediaremoted 日志。
#
# 产出（evidence/s2-<时间戳>/）：
#   app.log            被测进程的 MARK 证据行（含命令接收时间、pmset 断言、tile 读回）
#   mediaremoted.log   mediaremoted 的原始日志（系统是否把 Now Playing 归给我们）
#   np-probe.json      私有 MediaRemote API 的读回（在当前 macOS 上不可用，作为对照记录）
#   keys-100.txt       100 次连送的原始输出
#   command-latency.txt 单次命令的注入→回调延迟
#   summary.txt        关键结论的行式摘要
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/evidence/s2-$(date +%Y%m%d-%H%M%S)"
HOLD=${HOLD:-60s}
mkdir -p "$OUT"

APP="$ROOT/build/听屿Spike.app/Contents/MacOS/spike-app"
NP="$ROOT/build/spike-np"
[ -x "$APP" ] || { echo "先跑 scripts/bundle.sh" >&2; exit 1; }

export SPIKE_MEDIA="$ROOT/testdata/media"

echo "== 1/7 启动 mediaremoted 日志采集"
log stream --style compact --predicate 'process == "mediaremoted"' > "$OUT/mediaremoted.log" 2>&1 &
LOGPID=$!

echo "被测二进制: $(ls -l "$APP" | awk '{print $6,$7,$8}')"
echo "== 2/7 启动被测应用（-auto -hold ${HOLD}）"
"$APP" -auto -hold "$HOLD" -log "$OUT/app.log" > "$OUT/app.stdout" 2>&1 &
APPPID=$!

for _ in $(seq 1 100); do
  grep -q "保持播放" "$OUT/app.log" 2>/dev/null && break
  sleep 0.2
done
grep -q "保持播放" "$OUT/app.log" || { echo "应用没进入保持窗口，见 $OUT/app.stdout" >&2; }
sleep 1

echo "== 3/7 私有 MediaRemote API 探针（对照；该 macOS 上预期拿不到数据）"
"$NP" -info > "$OUT/np-probe.json" 2>&1 || true

echo "== 4/7 单次命令延迟（注入时间取自 spike-np，回调时间取自被测进程 MARK）"
: > "$OUT/command-latency.txt"
for cmd in toggle pause play; do
  sent=$("$NP" -send "$cmd" 2>&1 | grep -o 'at [0-9:.]*' | awk '{print $2}')
  sleep 0.5
  got=$(grep "remote-command $cmd" "$OUT/app.log" | tail -1 | awk '{print $1}')
  printf '%s send=%s recv=%s\n' "$cmd" "${sent:-none}" "${got:-none}" >> "$OUT/command-latency.txt"
done
python3 - "$OUT/command-latency.txt" <<'PY' >> "$OUT/command-latency.txt"
import sys
from datetime import datetime
rows=[]
for line in open(sys.argv[1]):
    p=dict(kv.split('=',1) for kv in line.split()[1:])
    if p.get('send','none')!='none' and p.get('recv','none')!='none':
        f='%H:%M:%S.%f'
        d=(datetime.strptime(p['recv'],f)-datetime.strptime(p['send'],f)).total_seconds()*1000
        rows.append(f"{line.split()[0]} {d:.1f} ms")
print("latency:", "; ".join(rows) if rows else "无可用样本")
PY

echo "== 5/7 100 次连送（阈值 6：回调稳定性 + 无崩溃）"
"$NP" -send toggle -repeat 100 -gap 20ms > "$OUT/keys-100.txt" 2>&1
sleep 0.5
recv=$(grep -c "remote-command toggle" "$OUT/app.log")
printf 'sent=100 received=%s\n' "$recv" >> "$OUT/keys-100.txt"

echo "== 6/7 上一首/下一首 + seek 两种注入方式"
for cmd in next prev; do "$NP" -send "$cmd" >> "$OUT/keys-commands.txt" 2>&1; sleep 0.4; done
"$NP" -send seek -seek 1.0 >> "$OUT/keys-commands.txt" 2>&1; sleep 0.4
"$NP" -send seekus -seek 1.0 >> "$OUT/keys-commands.txt" 2>&1; sleep 0.4

echo "== 6b/7 物理功能键（System Events 注入 F8/F9/F7；只有部分机型会把它们当媒体键）"
for kc in 100 101 98; do
  osascript -e "tell application \"System Events\" to key code $kc" >> "$OUT/function-keys.txt" 2>&1
  sleep 0.5
done
printf 'physical function key attempts: F8(100)=1 F9(101)=1 F7(98)=1\n' >> "$OUT/function-keys.txt"

echo "== 7/7 等被测进程自己退出（它会走隐藏窗口 → 关窗 → Clear → Quit 全流程）"
for _ in $(seq 1 300); do
  kill -0 $APPPID 2>/dev/null || break
  sleep 0.2
done
wait $APPPID 2>/dev/null
sleep 1
kill $LOGPID 2>/dev/null
wait $LOGPID 2>/dev/null

{
  echo "应用退出码: 由上面 wait 决定（0=正常）"
  echo "收到的媒体会话命令总数: $(grep -c 'remote-command' "$OUT/app.log")"
  echo "toggle 收到: $(grep -c 'remote-command toggle' "$OUT/app.log")"
  echo "changePlaybackPosition(seek) 收到: $(grep -c 'remote-command seek' "$OUT/app.log")"
  echo "--- 命令延迟 ---"
  tail -1 "$OUT/command-latency.txt"
  echo "--- mediaremoted：我们的进程是否成为 activePlayerPath ---"
  grep -oE "activePlayerPath changed from <[^>]*> to <[^>]*>|Creating nowPlayingClient for 【[^】]*】" "$OUT/mediaremoted.log" \
    | grep -E "spike-app|spike-session" | tail -6
  echo "--- mediaremoted：supportedCommands / CanBeNowPlayingPlayer ---"
  grep -E "CanBeNowPlayingPlayer|setting supportedCommands" "$OUT/mediaremoted.log" | grep -c . \
    | sed 's/^/匹配行数: /'
  echo "--- pmset 断言（来自 app.log）---"
  grep "pmset 断言" "$OUT/app.log" | sed -n '1p;2p' | cut -c1-260
} > "$OUT/summary.txt" 2>&1

echo
cat "$OUT/summary.txt"
echo
echo "证据目录: $OUT"
