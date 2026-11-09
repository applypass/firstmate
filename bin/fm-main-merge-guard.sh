#!/usr/bin/env bash
# fm-main-merge-guard.sh - refuse a merge into main without the captain's word (applypass fork).
#
# Usage: fm-main-merge-guard.sh github <owner>/<repo> <pr-number> <release-main: true|false>
#        GITLAB_HOST=<host> fm-main-merge-guard.sh gitlab <project-url> <mr-number> <release-main: true|false>
#
# Called by bin/fm-pr-merge.sh before any GitHub or GitLab merge call. Merges
# into main deploy prod, and agents act as the captain's admin login, so the
# forge cannot stop a wrong main merge. This reads the base branch (GitLab's
# target branch) live from the forge, never from task metadata, and exits 1
# when it is main and the fourth argument is not true. Any other base exits 0
# unchanged. A base that cannot be read exits 1 too, so an unreadable forge
# never lets a main merge through. The fourth argument is true only when the
# caller passed --release-main, which is passed only after the captain's
# explicit word for that specific merge. A GitHub merge then runs
# bin/fm-release-gate.sh check on the PR and exits 1 when that check fails. A GitHub
# merge into dev runs bin/fm-release-gate.sh row on the PR first and exits 1 when
# the PR's release row fails, so the auto-dev-merge path and a direct fm-pr-merge.sh
# both stop a PR with no decision row or audit.
set -u

usage() {
  echo "usage: fm-main-merge-guard.sh <github <owner>/<repo>|gitlab <project-url>> <number> <true|false>" >&2
  exit 2
}
[ "$#" -eq 4 ] || usage
PROVIDER=$1
REPO=$2
NUMBER=$3
RELEASE_MAIN=$4

case "$PROVIDER" in
  github)
    NAME="$REPO#$NUMBER"
    base=$(gh api "repos/$REPO/pulls/$NUMBER" --jq '.base.ref' 2>/dev/null) || base=
    ;;
  gitlab)
    NAME="$REPO/-/merge_requests/$NUMBER"
    base=$(glab mr view "$NUMBER" -R "$REPO" -F json 2>/dev/null | jq -r '.target_branch // empty' 2>/dev/null) || base=
    ;;
  *) usage ;;
esac
if [ -z "$base" ]; then
  echo "error: could not read the base branch of $NAME from the forge, so the main-merge guard refuses the merge" >&2
  exit 1
fi
# Fork-only: a dev-base merge needs the PR's release row (bin/fm-release-gate.sh row),
# so a PR cannot reach dev without its decision and audit. GitHub only; uncovered repos pass.
if [ "$base" = dev ]; then
  [ "$PROVIDER" != github ] ||
    "${FM_RELEASE_GATE_CMD:-$(dirname "${BASH_SOURCE[0]}")/fm-release-gate.sh}" row "https://github.com/$REPO/pull/$NUMBER" || exit 1
  exit 0
fi
[ "$base" = main ] || exit 0
if [ "$RELEASE_MAIN" = true ]; then
  # The release gate refuses a release whose PRs lack a current decision or a needed
  # reader and writer audit (bin/fm-release-gate.sh). GitHub only; uncovered repos pass.
  if [ "$PROVIDER" = github ]; then
    "${FM_RELEASE_GATE_CMD:-$(dirname "${BASH_SOURCE[0]}")/fm-release-gate.sh}" check "https://github.com/$REPO/pull/$NUMBER" || exit 1
  fi
  exit 0
fi
echo "error: $NAME targets main, and a merge into main deploys prod; pass --release-main only after the captain's explicit word for this specific merge" >&2
exit 1
