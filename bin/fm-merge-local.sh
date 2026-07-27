#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's ready branch (discovered from the
# task worktree's checked-out HEAD, so it works for any branch name).
#
# When the worktree cannot supply the branch - meta has no worktree=, the
# worktree directory is gone (a pruned pool worktree), or its HEAD is detached
# after a rebase - pass --branch <name> to name the ready branch directly. The
# crewmate reports it as "done: ready in branch <name>" in the task's status log.
# The override only replaces branch DISCOVERY: every merge guard below still
# applies, so an unlanded or diverged branch is refused exactly as before.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id> [--branch <name>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id> [--branch <name>]}
shift
BRANCH_OVERRIDE=
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)
      BRANCH_OVERRIDE=${2:?error: --branch needs a branch name}
      shift 2
      ;;
    --branch=*)
      BRANCH_OVERRIDE=${1#--branch=}
      [ -n "$BRANCH_OVERRIDE" ] || { echo "error: --branch needs a branch name" >&2; exit 1; }
      shift
      ;;
    *)
      echo "error: unknown argument \"$1\"; usage: fm-merge-local.sh <task-id> [--branch <name>]" >&2
      exit 1
      ;;
  esac
done

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
WT=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# The crewmate's ready branch is whatever the task worktree has checked out; the
# branch name is no longer a fixed fm/<id> (see bin/fm-brief.sh branch convention).
# An explicit --branch wins, and is also the recovery path when the worktree can
# no longer answer the question - approved work must always be landable.
BRANCH=$BRANCH_OVERRIDE
if [ -z "$BRANCH" ]; then
  why=
  if [ -z "$WT" ]; then
    why="meta for task $ID is missing worktree="
  elif [ ! -d "$WT" ]; then
    why="worktree for task $ID is missing: $WT"
  else
    BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ -n "$BRANCH" ] || why="worktree $WT for task $ID is detached"
  fi
  [ -n "$BRANCH" ] || {
    echo "error: $why; cannot determine the ready branch" >&2
    echo "Pass the branch the crewmate reported ready: bin/fm-merge-local.sh $ID --branch <name>" >&2
    exit 1
  }
fi
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
