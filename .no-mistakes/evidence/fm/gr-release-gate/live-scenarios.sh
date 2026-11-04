#!/usr/bin/env bash
# Live release-gate scenarios against real GitHub (read-only), disposable FM_HOME per scenario.
set -u
W=/Users/uayyagari/.no-mistakes/worktrees/c5d69c01912a/01M6JRPHQJH1TF4ZBQRS1Q16DK
REL=https://github.com/applypass/apply_pass_backend/pull/826
LABS=()
lab() { local L; L=$(mktemp -d "${TMPDIR:-/tmp}/fm-gate-lab.XXXXXX"); mkdir -p "$L/data" "$L/config"; : > "$L/data/decided.md"; printf '# Backlog\n' > "$L/data/backlog.md"; LABS+=("$L"); LAB=$L; }
dec() { printf -- '- [%s] 2026-11-04 %s\n' "$1" "$2" >> "$LAB/data/decided.md"; }
gate() { env -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" "$W/bin/fm-release-gate.sh" "$@"; }
show() { echo "\$ fm-release-gate.sh $*"; gate "$@" 2>&1; echo "[exit $?]"; echo; }
hdr() { echo "=================== $* ==================="; }

hdr "S1 no decision recorded: check refuses and prints waiver commands"
lab; show check $REL

hdr "S2 decisions stamped on each PR's story; schema.sql change without audit still fails"
lab
dec plan-try-cap-rollback "approved: undo the try cap (shortcut: sc-8728 u)"
dec plan-alt-language-revert "approved: one alt language (shortcut: sc-9299 u)"
show table $REL; show check $REL

hdr "S3 sc-9018 replay: a later reversal stamped on PR 830's own story supersedes its decision -> NOT CURRENT"
lab
dec plan-alt-language-revert "approved: one alt language (shortcut: sc-9299 u)"
dec plan-try-cap-rollback "approved (shortcut: sc-8728 u)"
dec multi-select-again "multi-select after all (shortcut: sc-9299 u) (supersedes: plan-alt-language-revert, sc-9299)"
dec release-waiver-apply_pass_backend-826-829 "waived: Captain 2026-11-04: ship apply_pass_backend#829 without audit"
show table $REL; show check $REL

hdr "S3b reversal names the PR as REPO#N (case-insensitive) -> NOT CURRENT"
lab
dec plan-alt-language-revert "approved: one alt language (shortcut: sc-9299 u)"
dec flip "multi-select after all (shortcut: sc-9299 u) (supersedes: APPLY_PASS_BACKEND#830)"
show check $REL

hdr "S4 general 'ship as is' waiver waives nothing"
lab
dec release-waiver-apply_pass_backend-826-829 "waived: Captain 2026-11-04: ship as is"
dec release-waiver-apply_pass_backend-826-830 "waived: Captain 2026-11-04: ship as is"
show check $REL

hdr "S5 waivers that name each PR pass every row"
lab
dec release-waiver-apply_pass_backend-826-829 "waived: Captain 2026-11-04: ship apply_pass_backend#829 as is"
dec release-waiver-apply_pass_backend-826-830 "waived: Captain 2026-11-04: PR 830 ships, revert is safe"
show check $REL

hdr "S6 merge guard with --release-main: refuses when the gate fails, passes when waived (no merge is made)"
lab
echo '$ fm-main-merge-guard.sh github applypass/apply_pass_backend 826 true   (gate fails)'
env -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$LAB" "$W/bin/fm-main-merge-guard.sh" github applypass/apply_pass_backend 826 true 2>&1 | tail -4; echo "[exit ${PIPESTATUS[0]}]"
dec release-waiver-apply_pass_backend-826-829 "waived: Captain 2026-11-04: ship apply_pass_backend#829 as is"
dec release-waiver-apply_pass_backend-826-830 "waived: Captain 2026-11-04: ship #830"
echo '$ fm-main-merge-guard.sh github applypass/apply_pass_backend 826 true   (all waived)'
env -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$LAB" "$W/bin/fm-main-merge-guard.sh" github applypass/apply_pass_backend 826 true 2>&1 | tail -4; echo "[exit ${PIPESTATUS[0]}]"
echo '$ fm-main-merge-guard.sh github applypass/apply_pass_backend 826 false  (no captain word)'
env -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$LAB" "$W/bin/fm-main-merge-guard.sh" github applypass/apply_pass_backend 826 false 2>&1 | tail -2; echo "[exit ${PIPESTATUS[0]}]"
echo

hdr "S7 uncovered repo / non-main base pass with a note"
lab
show check https://github.com/applypass/apply_pass_backend/pull/830
show check https://github.com/applypass/firstmate/pull/80

hdr "S8 data/API glob stays a pattern when cwd holds a matching file"
lab; mkdir -p "$LAB/cwd"; : > "$LAB/cwd/schema.sql.bak"; mkdir -p "$LAB/cwd/scripts"; : > "$LAB/cwd/scripts/a.sql"
(cd "$LAB/cwd" && show table $REL)

hdr "S9 unreadable forge fails closed"
lab; echo '$ GH stub that always fails'; mkdir -p "$LAB/bin"; printf '#!/bin/sh\nexit 1\n' > "$LAB/bin/gh"; chmod +x "$LAB/bin/gh"
PATH="$LAB/bin:$PATH" gate check $REL 2>&1; echo "[exit $?]"
rm -rf "${LABS[@]}"
