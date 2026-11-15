#!/usr/bin/env bash
# Live driver: real claude in a lab FM_HOME on a private tmux server, driven
# only through bin/fm-control.sh. Args: <repo-root> <evidence-dir>
set -u
ROOT=$1; EV=$2
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
SES=fmlab
CTL="$ROOT/bin/fm-control.sh"

mktask() {  # <id>
  cat > "$LAB/state/$1.meta" <<EOF
window=$SES:fm-$1
endpoint_task_id=$1
worktree=$ROOT
project=$ROOT
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$1
model=default
effort=default
EOF
}
cstate() { bash -c '. "$1/bin/fm-control-doorbell-lib.sh"; fm_backend_composer_state tmux "$2" "$3" 2>/dev/null || printf unknown' _ "$ROOT" "$SES:fm-$1" "fm-$1"; }
waitfor() {  # <id> <state> <secs>
  local n=0; while [ "$n" -lt "$3" ] && [ "$(cstate "$1")" != "$2" ]; do sleep 1; n=$((n+1)); done
  [ "$(cstate "$1")" = "$2" ]
}
doorbell() { bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_doorbell_line "$2/state/$3.inbox/x.msg"' _ "$ROOT" "$LAB" "$1"; }
launch() {  # <id> <cols> <rows>
  mktask "$1"
  if tmux has-session -t $SES 2>/dev/null; then
    tmux new-window -d -t $SES -n "fm-$1" -c "$ROOT" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions"
  else
    tmux new-session -d -s $SES -n "fm-$1" -x "$2" -y "$3" -c "$ROOT" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions"
  fi
  tmux set-option -t $SES window-size manual >/dev/null 2>&1
  tmux resize-window -t "$SES:fm-$1" -x "$2" -y "$3"
  waitfor "$1" empty 90 || { echo "FAIL: $1 claude never reached an empty composer"; tmux capture-pane -p -t "$SES:fm-$1"; return 1; }
}
shot() {  # <id> <label>
  { echo "=== $2 (pane $(tmux display -p -t "$SES:fm-$1" '#{pane_width}x#{pane_height}')) ==="; tmux capture-pane -p -t "$SES:fm-$1"; echo "=== end ==="; } | tee -a "$EV/pane-captures.txt"
}
run() {  # <label> <args...>
  local label=$1; shift
  echo "\$ bin/fm-control.sh $*"; out=$("$CTL" "$@" 2>&1); rc=$?; echo "$out"; echo "exit=$rc"
}
: > "$EV/pane-captures.txt"
result() { echo "RESULT $1: $2"; }

# S1: the reported shape - a short, wide pane clips the doorbell to its first row.
launch clip1 152 7 || exit 1
tmux send-keys -t "$SES:fm-clip1" -l "$(doorbell clip1)"; waitfor clip1 pending 10
shot clip1 "S1 before: clipped own doorbell"
run s1 clip1 clear-doorbell; s1=$rc; s1o=$out
sleep 1; shot clip1 "S1 after clear-doorbell"
st=$(cstate clip1); pc=$(tmux display -p -t "$SES:fm-clip1" '#{pane_current_command}')
[ "$s1" = 0 ] && case "$s1o" in doorbell-cleared*) true;; *) false;; esac && [ "$st" = empty ] && ! tmux capture-pane -p -t "$SES:fm-clip1" | grep -q "Firstmate instruction" \
  && result S1 "pass (composer=$st, pane still running $pc)" || result S1 "FAIL rc=$s1 composer=$st"

# S2: empty composer reports no-doorbell.
run s2 clip1 clear-doorbell
[ "$rc" = 0 ] && case "$out" in no-doorbell*) true;; *) false;; esac && result S2 pass || result S2 FAIL

# S3: another task's clipped doorbell (the line names clip2's inbox) in clip1's pane refuses and survives.
mktask other2
tmux send-keys -t "$SES:fm-clip1" -l "$(doorbell other2)"; waitfor clip1 pending 10
run s3 clip1 clear-doorbell; s3=$rc
sleep 1; shot clip1 "S3 after refused clear (another task's doorbell)"
tmux capture-pane -p -t "$SES:fm-clip1" | grep -q "other2.inbox" && [ "$s3" != 0 ] && result S3 pass || result S3 "FAIL rc=$s3"
tmux send-keys -t "$SES:fm-clip1" C-u C-u C-u C-u C-u C-u C-u C-u; waitfor clip1 empty 10

# S4: a user draft that is a prefix-looking long sentence refuses and survives.
tmux send-keys -t "$SES:fm-clip1" -l "please remember to rerun the migration on test before the release goes out, and also double check the inbox handling for every queued message today"; waitfor clip1 pending 10
run s4 clip1 clear-doorbell; s4=$rc
sleep 1; shot clip1 "S4 after refused clear (user draft)"
tmux capture-pane -p -t "$SES:fm-clip1" | grep -q "please remember" && [ "$s4" != 0 ] && result S4 pass || result S4 "FAIL rc=$s4"
tmux send-keys -t "$SES:fm-clip1" C-u C-u C-u C-u C-u C-u C-u C-u; waitfor clip1 empty 10

# S5: truncated own doorbell typed by hand (a partial line that stops before the composer edge, box closed under it) refuses.
part=$(doorbell clip1); part=${part%% read and act*}
tmux send-keys -t "$SES:fm-clip1" -l "$part"; waitfor clip1 pending 10
shot clip1 "S5 before: partial own doorbell fully visible with the box closed under it"
run s5 clip1 clear-doorbell; s5=$rc
tmux capture-pane -p -t "$SES:fm-clip1" | grep -q "steering inbox" && [ "$s5" != 0 ] && result S5 pass || result S5 "FAIL rc=$s5"
tmux send-keys -t "$SES:fm-clip1" C-u C-u C-u C-u C-u C-u C-u C-u; waitfor clip1 empty 10

# S6: exit (the first half of relaunch) with a clipped own doorbell clears it and stops the agent.
tmux send-keys -t "$SES:fm-clip1" -l "$(doorbell clip1)"; waitfor clip1 pending 10
shot clip1 "S6 before exit: clipped own doorbell"
run s6 clip1 exit; s6=$rc
[ "$s6" = 0 ] && result S6 pass || result S6 "FAIL rc=$s6"

# S7: full wrapped doorbell in a narrow tall pane (unchanged path) via the verb.
launch wrap1 60 40 || exit 1
tmux send-keys -t "$SES:fm-wrap1" -l "$(doorbell wrap1)"; waitfor wrap1 pending 10
shot wrap1 "S7 before: full wrapped own doorbell"
run s7 wrap1 clear-doorbell; s7=$rc
[ "$s7" = 0 ] && [ "$(cstate wrap1)" = empty ] && result S7 pass || result S7 "FAIL rc=$s7"
