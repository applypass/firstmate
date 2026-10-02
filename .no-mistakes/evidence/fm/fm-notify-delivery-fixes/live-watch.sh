#!/usr/bin/env bash
# Live: the real bin/fm-watch.sh against a disposable lab home (tmux is not on
# PATH on this host, so the worker pane is absent; the silent-handled check
# runs before any pane read). A request moved to handled/ with no status line
# must wake the supervisor, and the drain must show every record next to an
# ordinary status wake for the same task.
set -u
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
S="$LAB/state"
printf 'window=lab:fm-t1\nkind=ship\nharness=claude\n' > "$S/t1.meta"
w() { FM_HOME="$LAB" bash -c '. bin/fm-task-inbox-lib.sh; fm_task_inbox_write "$1" t1 "$2"' _ "$S" "$1"; }
run_watch() { FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 timeout "$1" bin/fm-watch.sh 2>"$LAB/err"; echo "[watcher exit=$?]"; }
r1=$(w "do the classify follow-up"); r2=$(w "and re-run row 3")
echo "requests: ${r1##*/} ${r2##*/}"
echo "--- watcher pass 0 (requests still pending, worker working) ---"
run_watch 4 | grep -c silent-handled | sed 's/^/silent-handled wakes: /'
mv "$r1" "$r2" "$S/t1.inbox/handled/"; echo "worker moved both to handled/, appended NO status line"
echo "--- watcher pass 1 (move only, turn not ended) ---"
run_watch 4 | grep -c silent-handled | sed 's/^/silent-handled wakes: /'
touch "$S/t1.turn-ended"; echo "worker turn ended"
echo "--- watcher pass 2 ---"
run_watch 20
echo "--- ordinary status wake for t1 queued before the supervisor drains ---"
FM_HOME="$LAB" bash -c '. bin/fm-wake-lib.sh; fm_wake_append signal t1.status "signal: t1.status working: on next"'
echo "--- supervisor drain ---"
FM_HOME="$LAB" bin/fm-wake-drain.sh 2>&1 | grep -E '^[0-9]+	'
echo "--- watcher pass 3 (each record reported once) ---"
run_watch 4 | grep -c silent-handled | sed 's/^/silent-handled wakes: /'
