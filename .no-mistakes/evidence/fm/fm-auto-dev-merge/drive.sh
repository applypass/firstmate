#!/usr/bin/env bash
# drive.sh <scenario-name> [extra env assignments...]: run the real fm-pr-check.sh
# in a fresh lab home for task t1 on applypass/firstmate PR #28.
set -u
WT=/Users/uayyagari/.no-mistakes/worktrees/c5d69c01912a/01M4T0QHD45JT3SKXM3HMAV78V
EV=/Users/uayyagari/.no-mistakes/evidence/01M4T0QHD45JT3SKXM3HMAV78V
NAME=$1; shift
URL=https://github.com/applypass/firstmate/pull/28
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
printf "%s\n" "kind=ship" "mode=no-mistakes" "worktree=$WT" > "$LAB/state/t1.meta"
printf '%s\n' "working [at=1]: go" "${READY_STATUS:-done [at=2]: PR $URL checks green}" > "$LAB/state/t1.status"
export GH_LOG="$LAB/gh.log"; : > "$GH_LOG"
{
echo "### scenario: $NAME"
echo "### env: $*"
echo "### status before:"; cat "$LAB/state/t1.status"
echo "### \$ bin/fm-pr-check.sh t1 $URL"
( cd "$WT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
   -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
   PATH="$EV/guardbin:$PATH" FM_HOME="$LAB" "$@" bin/fm-pr-check.sh t1 "$URL" 2>&1 ); echo "### exit=$?"
echo "### status after:"; cat "$LAB/state/t1.status"
echo "### gh calls:"; cat "$GH_LOG"
echo "### armed files:"; ls "$LAB/state"
} | sed "s#$LAB#<lab>#g" | tee "$EV/$NAME.log"
rm -rf "$LAB"
