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
# the same shape as a hand-written one, plus the captain's words as
# captain_authorized) and merges through bin/fm-pr-merge.sh
# with its guards unchanged: open, not a draft, mergeable, every check green at
# the exact head, every required check reported. A red or unreported check makes
# fm-pr-merge.sh refuse, and so does this script. The merge method is --merge so
# dev and main keep a shared history; squashing a release would leave dev behind.
# Merging into main needs the captain's word, so the merge refuses without
# --captain-authorized and a non-empty quote of that word, and the merge passes
# --release-main to fm-pr-merge.sh, whose main-base guard refuses without it. The PR must be
# dev into main, and a clone under projects/ must have it as its origin. After
# a landed merge, when bin/fm-shortcut-ticket.sh supports release-done, it
# prints that command as the next step, to run once production is confirmed.
#
# FM_RELEASE_MERGE and FM_RELEASE_SHORTCUT override the merge and Shortcut
# commands (tests).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MERGE_CMD="${FM_RELEASE_MERGE:-$SCRIPT_DIR/fm-pr-merge.sh}"
SHORTCUT_CMD="${FM_RELEASE_SHORTCUT:-$SCRIPT_DIR/fm-shortcut-ticket.sh}"
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

origin_slug() {  # <clone-dir>
  git -C "$1" remote get-url origin 2>/dev/null \
    | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##'
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

release_open() {
  [ "$#" -eq 1 ] || usage
  local target=$1 slug existing commits body
  case "$target" in
    */*) slug=$target ;;
    *)
      case "$target" in ''|.*|*[!A-Za-z0-9._-]*) die "invalid project name" ;; esac
      slug=$(origin_slug "$FM_HOME/projects/$target")
      [ -n "$slug" ] || die "no clone of $target under projects/"
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
  local url=$1 authorized='' pr head_oid base head id meta project='' want dir out rc=0
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
  want=$(lower "$FM_PR_OWNER/$FM_PR_REPO")
  for dir in "$FM_HOME"/projects/*/; do
    [ "$(lower "$(origin_slug "$dir")")" = "$want" ] || continue
    project=${dir%/}
    break
  done
  [ -n "$project" ] || die "no clone of $FM_PR_OWNER/$FM_PR_REPO under projects/"
  mkdir -p "$STATE"
  if [ -f "$meta" ]; then
    [ "$(grep '^pr=' "$meta" | tail -1 | cut -d= -f2-)" = "$url" ] \
      || die "$meta records a different PR"
  fi
  printf 'project=%s\nkind=ship\nmode=direct-PR\nyolo=off\nworktree=%s\ncaptain_authorized=%s\npr=%s\npr_head=%s\n' \
    "$project" "$project" "$(printf '%s' "$authorized" | tr '\r\n' '  ')" "$url" "$head_oid" > "$meta.tmp.$$"
  mv "$meta.tmp.$$" "$meta"

  out=$("$MERGE_CMD" "$id" "$url" --release-main --merge 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || exit "$rc"
  if printf '%s\n' "$out" | grep -qF "verified: $url is merged"; then
    echo "release merged: $url"
    if grep -q 'release-done' "$SHORTCUT_CMD" 2>/dev/null; then
      echo "next, once production is confirmed: $SHORTCUT_CMD release-done $url"
    fi
  else
    echo "release accepted but not landed yet: $url; re-check it" >&2
  fi
}

case "$SUB" in
  open) release_open "$@" ;;
  merge) release_merge "$@" ;;
  *) usage ;;
esac
