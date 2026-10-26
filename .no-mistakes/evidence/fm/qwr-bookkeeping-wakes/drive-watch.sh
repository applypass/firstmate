#!/usr/bin/env bash
# Drive the real bin/fm-watch.sh in a disposable lab FM_HOME for one scenario.
# usage: drive-watch.sh <scenario> <hold-secs> <watch-seconds>
#   scenario: quiet | closed-by-main
set -u
ROOT=${ROOT:?}
scen=$1 hold=$2 budget=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
state="$LAB/state"; status="$state/hibit.status"
clean() { [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; wait 2>/dev/null; rm -rf "$LAB"; }
trap clean EXIT
run_env() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" \
  FM_PENDING_REPLY_ACK_SECS=0 FM_PENDING_REPLY_WAKE_HOLD_SECS="$hold" "$@"; }
# A delivered request to second mate hibit that acknowledged with working: and went quiet.
corr=$(UNKNOWN=${UNKNOWN:-} run_env bash -c '. "$1/bin/fm-pending-reply-lib.sh"
  c=$(fm_pending_reply_create "$FM_HOME" "$FM_HOME/state" hibit "check the PR 367 canvas")
  if [ "${UNKNOWN:-}" = 1 ]; then fm_pending_reply_prepare_delivery "$FM_HOME/state" "$c" >/dev/null; fm_pending_reply_mark_delivery_unknown "$FM_HOME/state" "$c" >/dev/null
  else fm_pending_reply_mark_delivered "$FM_HOME/state" "$c" >/dev/null; fi
  printf "%s" "$c"' _ "$ROOT")
if [ "${UNKNOWN:-}" = 1 ]; then : > "$status"; else printf 'working [corr=%s]: on it\n' "$corr" > "$status"; fi
run_env bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_try_resolve "$FM_HOME/state" "$2" || true' _ "$ROOT" "$corr"
run_env bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$2" "$3" && echo "== baseline announced"' _ "$ROOT" "$state" "$status"
echo "== record before watcher: phase=$(grep '^phase=' "$state"/pending-replies/* | cut -d= -f2)"
if [ "$scen" = closed-by-main ]; then
  # First tick escalates quietly; then main closes the key exactly as fm-send --resolve-key writes it.
  run_env bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$FM_HOME/state"' _ "$ROOT"
  key="pending-reply-$corr"
  note=$(run_env bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_close_note_for_key "$2" hibit operator-resolve-key handled' _ "$ROOT" "$key")
  printf 'resolved [key=%s]: %s\n' "$key" "$note" >> "$status"
  run_env bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$2" "$3" && echo "== baseline announced"' _ "$ROOT" "$state" "$status"
  echo "== main closed $key; open decisions now: [$(run_env bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$status")]"
fi
if [ "$scen" = reply-in-hold ]; then
  run_env bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$FM_HOME/state"' _ "$ROOT"
  echo "== quiet escalation open: [$(run_env bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$status" | cut -f1)]"
  printf 'done [corr=%s]: canvas fixed in PR 367\n' "$corr" >> "$status"
  echo "== mate hibit replies inside the hold: done [corr=$corr]"
fi
out="$LAB/watch.out"; start=$(date +%s)
run_env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>"$LAB/watch.err" &
WPID=$!
while kill -0 "$WPID" 2>/dev/null && [ $(( $(date +%s) - start )) -lt "$budget" ]; do sleep 0.5; done
if kill -0 "$WPID" 2>/dev/null; then echo "== watcher still blocking after ${budget}s (NO WAKE)"; kill "$WPID"; else
  echo "== watcher EXITED (WAKE) after $(( $(date +%s) - start ))s; stdout:"; cat "$out"; fi
WPID=
drain() {  # run fm-wake-drain as the supervisor does, then ack it
  local err="$LAB/drain.err" seq gen
  echo "== supervisor runs fm-wake-drain.sh:"
  run_env "$ROOT/bin/fm-wake-drain.sh" 2>"$err" | sed 's/^/   | /'
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  if [ -n "$seq" ]; then run_env "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 && echo "== drain acked through $seq"; fi
}
if [ -n "${RESTART:-}" ]; then
  drain
  echo "== restarting watcher for ${RESTART}s"
  start=$(date +%s)
  run_env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>>"$LAB/watch.err" &
  WPID=$!
  while kill -0 "$WPID" 2>/dev/null && [ $(( $(date +%s) - start )) -lt "$RESTART" ]; do sleep 0.5; done
  if kill -0 "$WPID" 2>/dev/null; then echo "== second watcher still blocking after ${RESTART}s (NO REPEAT WAKE)"; kill "$WPID"; else
    echo "== second watcher EXITED (WAKE) after $(( $(date +%s) - start ))s; stdout:"; cat "$out"; fi
  WPID=
fi
echo "== hibit.status:"; sed 's/^/   /' "$status"
echo "== open decisions:"; run_env bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$status" | sed 's/^/   /'
echo "== record: $(grep -E '^(phase|escalated_epoch|escalation_wake_due_epoch)=' "$state"/pending-replies/* | tr '\n' ' ')"
