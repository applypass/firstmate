#!/usr/bin/env bash
# fm-release.sh - open or merge a project's dev-to-main release PR (applypass fork).
#
# Usage:
#   fm-release.sh open <project|owner/repo>
#   fm-release.sh merge <release-pr-url> --captain-authorized "<captain's words>"
#
# open: opens a PR from dev into main on GitHub and prints its URL. The project
# is a name under projects/ (its origin remote names the repository) or an
# owner/repo. Dev is never frozen: the PR is opened straight from the branch,
# and an already-open dev-to-main PR is printed instead of a second one.
#
# merge: writes the release task's meta (state/release-main-<repo>-<number>.meta,
# the same shape as a hand-written one) and merges through bin/fm-pr-merge.sh
# with its guards unchanged: open, not a draft, mergeable, every check green at
# the exact head, every required check reported. A red or unreported check makes
# fm-pr-merge.sh refuse, and so does this script. The merge method is --merge so
# dev and main keep a shared history; squashing a release would leave dev behind.
# Merging into main needs the captain's word, so the merge refuses without
# --captain-authorized and a non-empty quote of that word. The PR must be
# dev into main. After a landed merge it prints the next step, the Shortcut
# release-done command to run once production is confirmed.
#
# FM_RELEASE_MERGE overrides the merge command (tests).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MERGE_CMD="${FM_RELEASE_MERGE:-$SCRIPT_DIR/fm-pr-merge.sh}"
DEV_BRANCH=dev
MAIN_BRANCH=main

usage() {
  echo "usage: fm-release.sh open <project|owner/repo>" >&2
  echo "       fm-release.sh merge <release-pr-url> --captain-authorized \"<captain's words>\"" >&2
  exit 2
}

die() {
  echo "error: $*" >&2
  exit 1
}

{ command -v gh && command -v jq; } >/dev/null 2>&1 || die "gh and jq are required"
[ "$#" -ge 1 ] || usage
SUB=$1
shift

release_open() {
  [ "$#" -eq 1 ] || usage
  local target=$1 slug remote existing commits body
  case "$target" in
    */*) slug=$target ;;
    *)
      case "$target" in ''|.*|*[!A-Za-z0-9._-]*) die "invalid project name" ;; esac
      remote=$(git -C "$FM_HOME/projects/$target" remote get-url origin 2>/dev/null) \
        || die "no clone of $target under projects/"
      slug=$(printf '%s\n' "$remote" | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
      ;;
  esac
  case "$slug" in
    */*/*|/*|*/|*[!A-Za-z0-9._/-]*) die "cannot resolve an owner/repo from $target" ;;
  esac
  existing=$(gh pr list --repo "$slug" --base "$MAIN_BRANCH" --head "$DEV_BRANCH" --state open \
    --json url --jq '.[0].url // empty') || die "could not list release PRs for $slug"
  if [ -n "$existing" ]; then
    echo "release PR already open: $existing" >&2
    echo "$existing"
    return 0
  fi
  commits=$(gh api "repos/$slug/compare/$MAIN_BRANCH...$DEV_BRANCH" \
    --jq '.commits[] | "- " + (.commit.message | split("\n")[0])') \
    || die "could not compare $MAIN_BRANCH and $DEV_BRANCH on $slug"
  [ -n "$commits" ] || die "$DEV_BRANCH has nothing $MAIN_BRANCH lacks on $slug"
  body=$(printf '## Release\n\nPromote %s to %s.\n\n## Commits\n\n%s\n' "$DEV_BRANCH" "$MAIN_BRANCH" "$commits")
  gh pr create --repo "$slug" --base "$MAIN_BRANCH" --head "$DEV_BRANCH" \
    --title "Release: $DEV_BRANCH to $MAIN_BRANCH" --body "$body"
}

release_merge() {
  [ "$#" -ge 1 ] || usage
  local url=$1 authorized='' pr head_oid base head id meta project out rc=0
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --captain-authorized)
        [ "$#" -ge 2 ] || usage
        authorized=$2
        shift 2
        ;;
      *) usage ;;
    esac
  done
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  fm_pr_url_parse "$url" || die "invalid PR URL"
  [ "$FM_PR_PROVIDER" = github ] || die "releases are GitHub only"
  url=$FM_PR_URL
  case "$authorized" in
    *[![:space:]]*) ;;
    *) die "merging to $MAIN_BRANCH needs the captain's word: pass --captain-authorized \"<captain's words>\"" ;;
  esac

  pr=$(gh pr view "$url" --json baseRefName,headRefName,headRefOid,state) || die "could not read $url"
  base=$(jq -r '.baseRefName' <<<"$pr")
  head=$(jq -r '.headRefName' <<<"$pr")
  head_oid=$(jq -r '.headRefOid' <<<"$pr")
  [ "$base" = "$MAIN_BRANCH" ] && [ "$head" = "$DEV_BRANCH" ] \
    || die "$url is $head into $base, not a $DEV_BRANCH-to-$MAIN_BRANCH release"
  [ "$(jq -r '.state' <<<"$pr")" = OPEN ] || die "$url is not open"
  fm_pr_head_valid "$head_oid" || die "could not read the PR head commit"

  id="release-$MAIN_BRANCH-$FM_PR_REPO-$FM_PR_NUMBER"
  meta="$STATE/$id.meta"
  project="$FM_HOME/projects/$FM_PR_REPO"
  mkdir -p "$STATE"
  if [ -f "$meta" ]; then
    [ "$(grep '^pr=' "$meta" | tail -1 | cut -d= -f2-)" = "$url" ] \
      || die "$meta records a different PR"
  fi
  printf 'project=%s\nkind=ship\nmode=direct-PR\nyolo=off\nworktree=%s\npr=%s\npr_head=%s\n' \
    "$project" "$project" "$url" "$head_oid" > "$meta.tmp.$$"
  mv "$meta.tmp.$$" "$meta"

  out=$("$MERGE_CMD" "$id" "$url" --merge 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || exit "$rc"
  if printf '%s\n' "$out" | grep -qF "verified: $url is merged"; then
    echo "release merged: $url"
    echo "next, once production is confirmed: bin/fm-shortcut-ticket.sh release-done $url"
  else
    echo "release accepted but not landed yet: $url; re-check it before running release-done" >&2
  fi
}

case "$SUB" in
  open) release_open "$@" ;;
  merge) release_merge "$@" ;;
  *) usage ;;
esac
