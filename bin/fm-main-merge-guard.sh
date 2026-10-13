#!/usr/bin/env bash
# fm-main-merge-guard.sh - refuse a merge into main without the captain's word (applypass fork).
#
# Usage: fm-main-merge-guard.sh <owner> <repo> <pr-number> <release-main: true|false>
#
# Called by bin/fm-pr-merge.sh before any GitHub merge call. Merges into main
# deploy prod, and agents act as the captain's admin login, so GitHub cannot
# stop a wrong main merge. This reads the PR's base branch live from the forge
# (never from task metadata) and exits 1 when the base is main and the fourth
# argument is not true. Any other base exits 0 unchanged. A base that cannot be
# read exits 1 too, so an unreadable forge never lets a main merge through.
# The fourth argument is true only when the caller passed --release-main, which
# is passed only after the captain's explicit word for that specific merge.
set -u

[ "$#" -eq 4 ] || { echo "usage: fm-main-merge-guard.sh <owner> <repo> <pr-number> <true|false>" >&2; exit 2; }
OWNER=$1
REPO=$2
NUMBER=$3
RELEASE_MAIN=$4

if ! base=$(gh api "repos/$OWNER/$REPO/pulls/$NUMBER" --jq '.base.ref' 2>/dev/null) || [ -z "$base" ]; then
  echo "error: could not read the base branch of $OWNER/$REPO#$NUMBER from GitHub, so the main-merge guard refuses the merge" >&2
  exit 1
fi
[ "$base" = main ] || exit 0
[ "$RELEASE_MAIN" = true ] && exit 0
echo "error: $OWNER/$REPO#$NUMBER targets main, and a merge into main deploys prod; pass --release-main only after the captain's explicit word for this specific merge" >&2
exit 1
