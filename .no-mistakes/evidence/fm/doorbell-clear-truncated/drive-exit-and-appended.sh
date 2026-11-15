#!/usr/bin/env bash
# Live driver 2: exit with a clipped own doorbell (claude hosted in a shell,
# as a fleet window is), and own doorbell + appended user text in a clipped pane.
set -u
ROOT=$1; EV=$2
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
SES=fmlab; CTL="$ROOT/bin/fm-control.sh"
mktask() { printf '%s\n' "window=$SES:fm-$1" "endpoint_task_id=$1" "worktree=$ROOT" "project=$ROOT" harness=claude kind=ship mode=no-mistakes yolo=off "tasktmp=/tmp/fm-$1" model=default effort=default > "$LAB/state/$1.meta"; }
cstate() { bash -c '. "$1/bin/fm-control-doorbell-lib.sh"; fm_backend_composer_state tmux "$2" "$3" 2>/dev/null || printf unknown' _ "$ROOT" "$SES:fm-$1" "fm-$1"; }
waitfor() { local n=0; while [ "$n" -lt "$3" ] && [ "$(cstate "$1")" != "$2" ]; do sleep 1; n=$((n+1)); done; [ "$(cstate "$1")" = "$2" ]; }
doorbell() { bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_doorbell_line "$2/state/$3.inbox/x.msg"' _ "$ROOT" "$LAB" "$1"; }
launch() {
  mktask "$1"
  if tmux has-session -t $SES 2>/dev/null; then tmux new-window -d -t $SES -n "fm-$1" -c "$ROOT" /bin/bash
  else tmux new-session -d -s $SES -n "fm-$1" -x "$2" -y "$3" -c "$ROOT" /bin/bash; fi
  tmux set-option -t $SES window-size manual >/dev/null 2>&1; tmux resize-window -t "$SES:fm-$1" -x "$2" -y "$3"
  sleep 1; tmux send-keys -t "$SES:fm-$1" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions" Enter
  waitfor "$1" empty 90 || { echo "FAIL: never empty"; tmux capture-pane -p -t "$SES:fm-$1"; return 1; }
}
shot() { { echo "=== $2 (pane $(tmux display -p -t "$SES:fm-$1" '#{pane_width}x#{pane_height}')) ==="; tmux capture-pane -p -t "$SES:fm-$1"; echo "=== end ==="; } | tee -a "$EV/pane-captures-2.txt"; }
run() { echo "\$ bin/fm-control.sh $*"; out=$("$CTL" "$@" 2>&1); rc=$?; echo "$out"; echo "exit=$rc"; }
: > "$EV/pane-captures-2.txt"

launch ex1 152 7 || exit 1
tmux send-keys -t "$SES:fm-ex1" -l "$(doorbell ex1)"; waitfor ex1 pending 10
shot ex1 "S6 before exit: clipped own doorbell"
run ex1 exit; s6=$rc
sleep 1; shot ex1 "S6 after exit"
[ "$s6" = 0 ] && echo "RESULT S6: pass" || echo "RESULT S6: FAIL rc=$s6"

launch ap1 152 7 || exit 1
tmux send-keys -t "$SES:fm-ap1" -l "$(doorbell ap1) ALSO MY OWN DRAFT: remember to tell the captain the release-delay root cause is the cache key"; waitfor ap1 pending 10
shot ap1 "S8 before: own doorbell + appended user text, clipped"
run ap1 clear-doorbell; s8=$rc
sleep 1; shot ap1 "S8 after clear-doorbell"
if [ "$s8" != 0 ]; then echo "RESULT S8: pass (refused)"; else echo "RESULT S8: FAIL - appended user text was cleared (rc=0)"; fi
tmux resize-window -t "$SES:fm-ap1" -x 152 -y 30; sleep 1; shot ap1 "S8 after clear, pane enlarged to 152x30 to show the full composer"
