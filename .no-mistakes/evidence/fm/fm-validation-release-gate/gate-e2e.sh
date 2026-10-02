#!/usr/bin/env bash
# Manual end-to-end drive of the validation release gate against a gate that
# runs no-mistakes v1.79.0's real managed pre-receive (copied verbatim; only
# NM_BIN points at /usr/bin/true so admit-push needs no daemon).
set -u
WT_ROOT=$1
G="$WT_ROOT/bin/fm-validation-gate.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
step() { printf '\n$ %s\n' "$*"; }
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
"$WT_ROOT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null
export FM_HOME="$LAB/home"
git init -q --bare "$LAB/origin.git"
git init -q -b main "$LAB/proj"; echo hi >"$LAB/proj/README.md"; git -C "$LAB/proj" add .; git -C "$LAB/proj" commit -qm init
git -C "$LAB/proj" remote add origin "$LAB/origin.git"; git -C "$LAB/proj" push -q origin main
git -C "$LAB/proj" worktree add -q -b fm/demo "$LAB/wt"
git init -q --bare "$LAB/gate.git"
sed "s#^NM_BIN=.*#NM_BIN='/usr/bin/true'#" "$HOME/.no-mistakes/repos/c5d69c01912a.git/hooks/pre-receive" >"$LAB/gate.git/hooks/pre-receive"
printf '#!/bin/sh\nwhile read o n r; do echo "pipeline started $r $n" >>"%s/pipeline.log"; done\n' "$LAB" >"$LAB/gate.git/hooks/post-receive"
chmod +x "$LAB/gate.git/hooks/"*
git -C "$LAB/proj" remote add no-mistakes "$LAB/gate.git"
S="$FM_HOME/state"
echo "Switch: config/validation-gate absent; tracked defaults/validation-gate = $(cat "$WT_ROOT/defaults/validation-gate")"
step "fm-validation-gate.sh enabled   (fork default, no config)"; "$G" enabled; echo "exit=$?"
step "fm-brief.sh demo proj --mode no-mistakes   (real brief, default switch)"
mkdir -p "$FM_HOME/data"
"$WT_ROOT/bin/fm-brief.sh" demo proj --mode no-mistakes >/dev/null 2>&1; echo "exit=$?"
sed -n '/^# Definition of done/,/^If you change the branch/p' "$FM_HOME/data/demo/brief.md"
step "prepare --kind ship --mode no-mistakes --forge none --brief brief.md"
"$G" prepare --config "$FM_HOME/config" --state "$S" --kind ship --mode no-mistakes --forge none --worktree "$LAB/wt" --id demo --brief "$FM_HOME/data/demo/brief.md"; echo "exit=$?"
echo "state/demo.validation-gate: $(cat "$S/demo.validation-gate")"; ls -l "$LAB/gate.git/hooks/pre-receive.no-mistakes-user" | awk '{print $1, $NF}'
printf 'worktree=%s\nkind=ship\nmode=no-mistakes\nbranch=fm/demo\nvalidation_gate=on\nwindow=lab:fm-demo\nharness=claude\n' "$LAB/wt" >"$S/demo.meta"
export FM_VALIDATION_GATE="$S/demo.validation-gate"
echo change >>"$LAB/wt/README.md"; git -C "$LAB/wt" commit -qam "feat: iterate"
step "worker pushes branch to origin while PR iterates"; git -C "$LAB/wt" push origin HEAD:refs/heads/fm/demo 2>&1 | tail -1; echo "exit=${PIPESTATUS[0]}"
step "worker runs no-mistakes-style push to the gate (--no-verify) before release"; git -C "$LAB/wt" push --no-verify no-mistakes HEAD:refs/heads/fm/demo 2>&1; echo "exit=$?"
step "bypass attempt: -c core.hooksPath=/dev/null + GIT_CONFIG_* + --no-verify"; GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git -C "$LAB/wt" -c core.hooksPath=/dev/null push --no-verify no-mistakes HEAD:refs/heads/fm/demo 2>&1 | grep -E 'firstmate|rejected|->' ; echo "exit=${PIPESTATUS[0]}"
echo "pipeline.log: $(cat "$LAB/pipeline.log" 2>/dev/null || echo '(none - no pipeline started)')"
step "worker reports ready; supervision tries a captain verdict before release"
printf 'done [at=%s]: PR https://example.invalid/pr/7 ready for final validation\n' "$(date +%s)" >>"$S/demo.status"
"$WT_ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict captain --summary "PR 7 ready" 2>&1; echo "exit=$?"
step "fm-validation-gate.sh release demo   (no tmux on this host, so fm-send's steer cannot reach a pane)"
"$G" release demo 2>&1; echo "exit=$?"; echo "state/demo.validation-gate: $(tr '\n' '|' <"$S/demo.validation-gate")"
step "captain verdict after release"
"$WT_ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict captain --summary "PR https://example.invalid/pr/7 is ready to merge to dev; final validation is running" 2>&1; echo "exit=$?"
step "worker runs /no-mistakes push of the released head"; git -C "$LAB/wt" push --no-verify no-mistakes HEAD:refs/heads/fm/demo 2>&1 | tail -1; echo "exit=${PIPESTATUS[0]}"
echo more >>"$LAB/wt/README.md"; git -C "$LAB/wt" commit -qam "feat: post-release change"
step "worker pushes a NEW head after release without a new release"; git -C "$LAB/wt" push --no-verify no-mistakes HEAD:refs/heads/fm/demo 2>&1 | grep -E 'firstmate|rejected'; echo "exit=${PIPESTATUS[0]}"
step "non-fleet push (no FM_VALIDATION_GATE) is upstream behaviour"; env -u FM_VALIDATION_GATE git -C "$LAB/wt" push --no-verify no-mistakes HEAD:refs/heads/other 2>&1 | tail -1; echo "exit=${PIPESTATUS[0]}"
echo; echo "pipeline.log:"; cat "$LAB/pipeline.log"
step "ungated home: config/validation-gate=off -> brief ungated, prepare prints nothing"
echo off >"$FM_HOME/config/validation-gate"; "$G" enabled; echo "enabled exit=$?"
"$WT_ROOT/bin/fm-brief.sh" plain proj --mode no-mistakes >/dev/null 2>&1
grep -c 'ready for final validation' "$FM_HOME/data/plain/brief.md"
out=$("$G" prepare --config "$FM_HOME/config" --state "$S" --kind ship --mode no-mistakes --forge none --worktree "$LAB/wt" --id plain --brief "$FM_HOME/data/plain/brief.md"); echo "prepare exit=$? output='$out'"; ls "$S/plain.validation-gate" 2>&1
step "invalid switch value"; echo On >"$FM_HOME/config/validation-gate"; "$WT_ROOT/bin/fm-brief.sh" bad proj --mode no-mistakes 2>&1 | tail -2; echo "exit=${PIPESTATUS[0]}"
