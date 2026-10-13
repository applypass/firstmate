#!/usr/bin/env bash
# fm-auto-dev-merge.sh - merge our own green PR to dev without waiting for a word (applypass fork).
#
# Usage: fm-auto-dev-merge.sh <task-id> <pr-url>
#
# Called by bin/fm-pr-check.sh when a ship's ready status is recorded. The merge
# itself is bin/fm-pr-merge.sh, so every merge-time guard (live green checks at
# the exact head, required checks reported, no draft, captain holds, the away
# record) still applies; this script only decides whether the standing dev-merge
# authority covers the PR, and refuses quietly when it does not. A refusal is a
# skip, never an error: it prints one "auto-dev-merge: skipped" line to stderr
# and exits 0, so the ready registration that called it is unaffected.
#
# Merges only when all hold:
#   - the task's latest status line is its ready report for this PR (a
#     no-mistakes ship needs "checks green"; "ready for final validation" is not)
#   - the PR is open, not a draft, and its base branch is dev
#   - the PR's author is the account gh is signed in as (a PR we opened)
#   - every check on the head reads green (none red, none pending, none absent)
#   - the PR carries no destructive, irreversible, or security label
# Any other base, including main, is the captain's to merge.
#
# Prints "auto-dev-merge: merged <url> to dev" on success. Set
# FM_AUTO_DEV_MERGE=off to disable. FM_AUTO_DEV_MERGE_MERGE overrides the merge
# command (tests).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DEV_BRANCH=dev
MERGE_CMD="${FM_AUTO_DEV_MERGE_MERGE:-$SCRIPT_DIR/fm-pr-merge.sh}"

[ "${FM_AUTO_DEV_MERGE:-on}" != off ] || exit 0
[ "$#" -eq 2 ] || { echo "usage: fm-auto-dev-merge.sh <task-id> <pr-url>" >&2; exit 2; }
ID=$1
URL=$2

skip() {
  echo "auto-dev-merge: skipped $URL: $*" >&2
  exit 0
}

{ command -v gh && command -v jq; } >/dev/null 2>&1 || skip "gh and jq are required"
case "$ID" in ''|*[!A-Za-z0-9._-]*) skip "invalid task id" ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] || skip "no task metadata"
MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
[ "${KIND:-ship}" = ship ] || skip "not a ship task"
[ "$MODE" != local-only ] || skip "local-only task has no PR"

# The ready report must be the task's latest status line, for this PR.
LAST=$(grep -v '^[[:space:]]*$' "$STATE/$ID.status" 2>/dev/null | tail -1 || true)
case "$LAST" in
  done*) ;;
  *) skip "latest status is not a ready report" ;;
esac
case "$LAST" in
  *"PR $URL"*) ;;
  *) skip "latest status does not name this PR" ;;
esac
if [ "$MODE" = no-mistakes ]; then
  case "$LAST" in
    *"checks green"*) ;;
    *) skip "validation has not reported checks green" ;;
  esac
fi

PR=$(gh pr view "$URL" --json state,isDraft,baseRefName,author,labels,statusCheckRollup 2>/dev/null) \
  || skip "could not read the PR"
ME=$(gh api user -q .login 2>/dev/null) && [ -n "$ME" ] || skip "could not read the signed-in account"

[ "$(jq -r '.state' <<<"$PR")" = OPEN ] || skip "PR is not open"
[ "$(jq -r '.isDraft' <<<"$PR")" = false ] || skip "PR is a draft"
BASE=$(jq -r '.baseRefName' <<<"$PR")
[ "$BASE" = "$DEV_BRANCH" ] || skip "base is $BASE, not $DEV_BRANCH"
[ "$(jq -r '.author.login' <<<"$PR")" = "$ME" ] || skip "PR was not opened by $ME"
if jq -e '[.labels[].name | ascii_downcase | select(test("destructive|irreversible|security"))] | length > 0' <<<"$PR" >/dev/null; then
  skip "PR carries a destructive, irreversible, or security label"
fi
# A check that has not completed green is red or pending; no checks at all is
# unverified. fm-pr-merge.sh re-reads this live and stays the final authority.
if ! jq -e '(.statusCheckRollup | length) > 0 and all(.statusCheckRollup[];
    (.status // "COMPLETED") == "COMPLETED"
    and ((.conclusion // .state // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED")))' <<<"$PR" >/dev/null; then
  skip "checks are not all green"
fi

if OUT=$("$MERGE_CMD" "$ID" "$URL" 2>&1); then
  echo "auto-dev-merge: merged $URL to $DEV_BRANCH"
else
  skip "merge refused: $(printf '%s\n' "$OUT" | tail -1)"
fi
