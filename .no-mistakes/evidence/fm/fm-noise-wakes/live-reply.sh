#!/usr/bin/env bash
# Live drive of step 4: the running watcher's reply timer, with and without progress since the request.
set -u
ROOT=$1; cd "$ROOT"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
export FM_HOME=$LAB; S=$LAB/state
HOOK=$LAB/send-hook; printf '#!/usr/bin/env bash\nexit 0\n' > "$HOOK"; chmod +x "$HOOK"
T0=$(date +%s)
mk() {  # <task> : create and deliver a marked request at T0, then a correlated working ack
  : > "$S/$1.meta"
  local corr
  corr=$(FM_PENDING_REPLY_NOW=$T0 bash -c '. bin/fm-pending-reply-lib.sh; c=$(fm_pending_reply_create "$1" "$1/state" "$2" "status of phase 7"); fm_pending_reply_mark_delivered "$1/state" "$c" >/dev/null; printf %s "$c"' _ "$LAB" "$1")
  printf 'working [corr=%s] [at=%s]: on it\n' "$corr" "$((T0+10))" >> "$S/$1.status"
  echo "$corr"
}
run_watch() {  # <now> <secs>
  local out=$LAB/w.out i=0 lim=$(( $2 * 10 ))
  FM_PENDING_REPLY_NOW=$1 FM_PENDING_REPLY_ACK_SECS=900 FM_PENDING_REPLY_WAKE_HOLD_SECS=0 FM_PENDING_REPLY_GRACE_SECS=0 \
  FM_PENDING_REPLY_SEND_HOOK=$HOOK FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 FM_NEVER_WAIT=off bash bin/fm-watch.sh > "$out" 2>&1 &
  local pid=$!
  while [ $i -lt $lim ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid 2>/dev/null; echo "  watcher stayed up ${2}s"; else wait $pid 2>/dev/null; echo "  watcher woke: $(head -3 "$out" | tr '\n' ' ')"; fi
  rm -f "$S/.wake-queue" "$S/.watcher-down"
}
phase() { bash -c '. bin/fm-pending-reply-lib.sh; fm_pending_reply_get "$(fm_pending_reply_path "$1" "$2")" phase' _ "$S" "$1"; }

echo "=== A: acknowledged, progress since the request (working at T0+600), checked at T0+1000"
A=$(mk ra)
run_watch "$T0" 8 >/dev/null   # watcher absorbs the initial span and sees the ack
echo "  phase after ack pass: $(phase "$A")"
printf 'working [at=%s]: halfway through the tests\n' "$((T0+600))" >> "$S/ra.status"
run_watch "$T0" 8 >/dev/null
run_watch "$((T0+1000))" 8
echo "  phase at T0+1000: $(phase "$A")  (expect acknowledged: not a missed reply)"
echo "  ra.status:"; sed 's/^/    /' "$S/ra.status"
echo "=== B (adversarial): acknowledged, NO progress since the ack (ack stamped T0+10)"
rm -rf "$LAB"; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null; export FM_HOME=$LAB; S=$LAB/state
B=$(mk rb)
run_watch "$T0" 8 >/dev/null
echo "  phase after ack pass: $(phase "$B")"
run_watch "$((T0+1000))" 8
echo "  phase at T0+1000 (ack line still inside the 1200s activity window): $(phase "$B")"
run_watch "$((T0+1300))" 12
echo "  phase at T0+1300 (past the window, no progress): $(phase "$B")  (expect escalated)"
echo "  rb.status:"; sed 's/^/    /' "$S/rb.status"
