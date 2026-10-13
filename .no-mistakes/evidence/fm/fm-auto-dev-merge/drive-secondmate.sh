#!/usr/bin/env bash
# Secondmate home ordering: real fm-pr-check.sh; the merge command is a stub that
# records a landed merge on the parent channel the way fm-merge-outcome-lib does
# (a real gh pr merge on GitHub is out of bounds for this gate).
set -u
WT=/Users/uayyagari/.no-mistakes/worktrees/c5d69c01912a/01M4T0QHD45JT3SKXM3HMAV78V
EV=/Users/uayyagari/.no-mistakes/evidence/01M4T0QHD45JT3SKXM3HMAV78V
URL=https://github.com/applypass/firstmate/pull/28
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
PARENT=$(mktemp -d "${TMPDIR:-/tmp}/fm-parent.XXXXXX"); mkdir -p "$PARENT/state"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
echo mate1 > "$LAB/.fm-secondmate-home"
printf '%s\n' "schema=fm-secondmate-parent.v1" "route=local" "parent_home=$PARENT" > "$LAB/.fm-secondmate-parent"
printf "%s\n" "kind=ship" "mode=no-mistakes" "worktree=$WT" > "$LAB/state/t1.meta"
printf '%s\n' "working [at=1]: go" "done [at=2]: PR $URL checks green" > "$LAB/state/t1.status"
cat > "$LAB/merge-stub" <<M
#!/usr/bin/env bash
printf 'done [at=%s]: child t1 PR merged: %s\n' "\$(date +%s)" "\$2" >> "$PARENT/state/mate1.status"
echo "verified: \$2 is merged (state=MERGED, merged=true, isInMergeQueue=false)" >&2
M
chmod +x "$LAB/merge-stub"
export GH_LOG="$LAB/gh.log"; : > "$GH_LOG"
{
echo "### scenario: secondmate-ready-line-before-merge (merge command stubbed, GH_FAKE_BASE=dev)"
( cd "$WT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
   -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
   PATH="$EV/guardbin:$PATH" FM_HOME="$LAB" GH_FAKE_BASE=dev FM_AUTO_DEV_MERGE_MERGE="$LAB/merge-stub" \
   bin/fm-pr-check.sh t1 "$URL" 2>&1 ); echo "### exit=$?"
echo "### parent channel (parent state/mate1.status), in order:"; cat "$PARENT/state/mate1.status"
echo "### child status after:"; cat "$LAB/state/t1.status"
} | grep -v '^●' | sed -e "s#$LAB#<lab>#g" -e "s#$PARENT#<parent>#g" | tee "$EV/secondmate-ordering.log"
rm -rf "$LAB" "$PARENT"
