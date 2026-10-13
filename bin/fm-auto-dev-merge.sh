#!/usr/bin/env bash
# fm-auto-dev-merge.sh - merge our own green PR to dev without waiting for a word (applypass fork).
#
# Usage: fm-auto-dev-merge.sh <task-id> <pr-url>
#
# Called by bin/fm-pr-check.sh when a ship's ready status is recorded, once and
# with no retry. The merge itself is bin/fm-pr-merge.sh, which stays the one
# authority on the PR's live state: open, not a draft, mergeable, and every
# check green at the exact head, judged by its current run. It gates on every
# check, required or not, so a non-required check that never finishes (a
# deploy preview) also blocks it. This script only decides whether the standing
# dev-merge authority covers the PR.
#
# Tries the merge only when all hold:
#   - the task's latest status line is its ready report for this PR (a
#     no-mistakes ship needs "checks green"; "ready for final validation" is not)
#   - the PR's author is the account gh is signed in as (a PR we opened)
#   - the PR carries no destructive, irreversible, or security label
#   - the PR's base branch is dev; any other base, including main, is the
#     captain's to merge
#
# Every outcome exits 0, so the ready registration that called it is
# unaffected. A PR the authority does not cover (not a ship, no ready report,
# foreign author, flagged label, disabled) is a quiet skip: one
# "auto-dev-merge: skipped" line on stderr. A covered PR that cannot merge now
# (base not dev, or fm-pr-merge.sh refused) is a loud skip: the same line, plus
# a paused line appended to state/<task-id>.status that names the PR and every
# refusal reason. On success fm-pr-merge.sh's own lines pass through, and
# "auto-dev-merge: merged <url> to dev" prints only when it proved the merge
# landed; a queued PR is not reported as merged. Set FM_AUTO_DEV_MERGE=off to
# disable. FM_AUTO_DEV_MERGE_MERGE overrides the merge command (tests).
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

pause() {
  printf 'paused [at=%s]: auto-dev-merge skipped %s: %s; merge it with bin/fm-pr-merge.sh once green\n' \
    "$(date +%s)" "$URL" "$*" >> "$STATE/$ID.status" || true
  skip "$*"
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

PR=$(gh pr view "$URL" --json baseRefName,author,labels 2>/dev/null) \
  || skip "could not read the PR"
ME=$(gh api user -q .login 2>/dev/null) && [ -n "$ME" ] || skip "could not read the signed-in account"

[ "$(jq -r '.author.login' <<<"$PR")" = "$ME" ] || skip "PR was not opened by $ME"
if jq -e '[.labels[].name | ascii_downcase | select(test("destructive|irreversible|security"))] | length > 0' <<<"$PR" >/dev/null; then
  skip "PR carries a destructive, irreversible, or security label"
fi
BASE=$(jq -r '.baseRefName' <<<"$PR")
[ "$BASE" = "$DEV_BRANCH" ] || pause "base is $BASE, not $DEV_BRANCH"

if ! OUT=$("$MERGE_CMD" "$ID" "$URL" 2>&1); then
  REASON=$(printf '%s\n' "$OUT" | awk 'NF { sub(/^[[:space:]]+/, ""); printf "%s%s", (n++ ? "; " : ""), $0 }')
  case "$OUT" in
    *"is not green"*) REASON="$REASON; fm-pr-merge.sh gates on every check, required or not" ;;
  esac
  pause "merge refused: ${REASON:-no reason given}"
fi
[ -z "$OUT" ] || printf '%s\n' "$OUT" >&2
if printf '%s\n' "$OUT" | grep -qF "verified: $URL is merged"; then
  echo "auto-dev-merge: merged $URL to $DEV_BRANCH"
else
  echo "auto-dev-merge: $URL was accepted but has not landed on $DEV_BRANCH yet"
fi
