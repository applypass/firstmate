#!/usr/bin/env bash
# Live driver 3: real claude in a short Herdr lab pane, driven through bin/fm-control.sh.
# Args: <repo-root> <evidence-dir> <lab-session> <pane-id> <workspace> <tab>
set -u
ROOT=$1; EV=$2; S=$3; P=$4; W=$5; TAB=$6
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
export FM_HOME="$LAB"; trap 'rm -rf "$LAB"' EXIT
H() { "$ROOT/bin/fm-herdr-lab.sh" run "$S" "$@"; }
T="$S:$P"
mktask() { printf '%s\n' "window=$T" "endpoint_task_id=$1" backend=herdr "herdr_session=$S" "herdr_workspace_id=$W" "herdr_tab_id=$TAB" "herdr_pane_id=$P" "worktree=$ROOT" "project=$ROOT" harness=claude kind=ship mode=no-mistakes yolo=off "tasktmp=/tmp/fm-$1" model=default effort=default > "$LAB/state/$1.meta"; }
cstate() { bash -c '. "$1/bin/fm-control-doorbell-lib.sh"; fm_backend_composer_state herdr "$2" "$3" 2>/dev/null || printf unknown' _ "$ROOT" "$T" "fm-$1"; }
waitfor() { local n=0; while [ "$n" -lt "$3" ] && [ "$(cstate "$1")" != "$2" ]; do sleep 1; n=$((n+1)); done; [ "$(cstate "$1")" = "$2" ]; }
doorbell() { bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_doorbell_line "$2/state/$3.inbox/x.msg"' _ "$ROOT" "$LAB" "$1"; }
shot() { { echo "=== $1 ==="; H pane read "$P" --source visible | jq -r '.result.read.text // .result.text // .' 2>/dev/null; echo "=== end ==="; } | tee -a "$EV/herdr-pane-captures.txt"; }
run() { echo "\$ bin/fm-control.sh $*"; out=$("$ROOT/bin/fm-control.sh" "$@" 2>&1); rc=$?; echo "$out"; echo "exit=$rc"; }
: > "$EV/herdr-pane-captures.txt"
ID=release-delay-rca
mktask $ID
H pane run "$P" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions" >/dev/null
waitfor $ID empty 90 || { echo "FAIL never empty: $(cstate $ID)"; shot "never empty"; exit 1; }
H pane send-text "$P" "$(doorbell $ID)" >/dev/null; waitfor $ID pending 10
shot "H1 before: clipped own doorbell in a short herdr pane"
run $ID clear-doorbell; h1=$rc; h1o=$out
sleep 1; shot "H1 after clear-doorbell"
[ "$h1" = 0 ] && case "$h1o" in doorbell-cleared*) true;; *) false;; esac && [ "$(cstate $ID)" = empty ] && echo "RESULT H1: pass" || echo "RESULT H1: FAIL rc=$h1"
mktask other-task
H pane send-text "$P" "$(doorbell other-task)" >/dev/null; waitfor $ID pending 10
run $ID clear-doorbell; h2=$rc
sleep 1; shot "H2 after refused clear (another task's doorbell)"
[ "$h2" != 0 ] && [ "$(cstate $ID)" = pending ] && echo "RESULT H2: pass" || echo "RESULT H2: FAIL rc=$h2"
H pane send-keys "$P" ctrl+u ctrl+u ctrl+u ctrl+u ctrl+u ctrl+u >/dev/null 2>&1
waitfor $ID empty 10
H pane send-text "$P" "$(doorbell $ID)" >/dev/null; waitfor $ID pending 10
run $ID exit; h3=$rc
[ "$h3" = 0 ] && echo "RESULT H3: pass" || echo "RESULT H3: FAIL rc=$h3"
shot "H3 after exit"
