#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create the ship branch per the repo's branch convention
# (see bin/fm-brief.sh), implement, then report done according to the project's
# delivery mode).
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

# Resolve the concrete branch rule from the project's ticket flag before flipping
# state, so an unresolvable mode aborts cleanly. The scout brief carried no branch
# rule, so the ship instruction spells it out (a ticket-mandated project links its
# tracker ticket first, which gives the branch name its auto-link).
PROJ=$(grep '^project=' "$META" | cut -d= -f2- || true)
BRANCH_HINT="create the ship branch per the branch convention owned by bin/fm-brief.sh"
if [ -n "$PROJ" ]; then
  PROJ_NAME=$(basename "$PROJ")
  if ! MODE_LINE=$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME"); then
    echo "error: cannot resolve delivery mode for $PROJ_NAME; fix the registry bracket before promoting" >&2
    exit 1
  fi
  TICKET=$(printf '%s\n' "$MODE_LINE" | awk '{print $3}')
  if [ -n "$TICKET" ]; then
    BRANCH_HINT="create or link the tracker ticket FIRST (for a Shortcut project, the Shortcut MCP tools), then create the ship branch ${TICKET}-<ticket-id>-<slug>"
  else
    BRANCH_HINT="create the ship branch <type>/<slug> with a conventional-commit type (feat/fix/chore/docs)"
  fi
fi

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; $BRANCH_HINT; implement; report done>'"
