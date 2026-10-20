#!/usr/bin/env bash
# Fork-only: PreToolUse check that refuses a NEW no-mistakes run on a diverged
# private mirror branch (applypass fork).
#
# no-mistakes keeps a private mirror of each pushed branch in the per-repo bare
# gate (~/.no-mistakes/repos/<id>.git, remote `no-mistakes`). After a rebase the
# mirror branch can still hold pre-rebase commits. The run then reviews for an
# hour or more and fails at the push step with "refusing to reconcile private
# mirror ref ... at-risk commit(s) contain content absent from live head", and
# each retry repeats the whole review. This check compares the mirror branch
# and the forge branch (origin/<branch>) with the local HEAD in a few git calls
# and refuses before the run starts.
#
# Refused, naming every SHA and the safe fix:
#   - the mirror branch is not an ancestor of HEAD and holds a commit whose
#     patch is not already in HEAD (`git cherry`), or
#   - origin/<branch> exists and has commits that HEAD lacks.
# Allowed: no mirror branch yet, no origin/<branch> yet, mirror equal to or
# behind HEAD, mirror commits that HEAD carries as rebased copies.
#
# Intercept point: a PreToolUse Bash hook on the worker side, the same point as
# the op guard (bin/fm-op-guard-install.sh registers it with that guard). Only
# a command that starts a NEW run is checked: `no-mistakes axi run` carrying
# --intent, which the CLI requires for a new run and rejects on none. A bare
# `axi run`, `axi status`, `axi respond`, `rerun`, `sync` and every other
# command reattach to or manage an existing run and are never blocked. The
# check only reads: it never fetches, never force-pushes, resets or deletes the
# mirror branch, and reads the gate's objects with the worktree's object store
# as a read-only alternate.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-nm-mirror-pretool-check.sh [--claude]
#   bin/fm-nm-mirror-pretool-check.sh --command '<cmd>' [--cwd <dir>] [--claude]
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2 and a Claude-shaped deny object on stderr; stdout stays empty.
#   FAIL OPEN - malformed or empty stdin, missing jq, no repo, detached HEAD, no
#     no-mistakes remote, or any git error.
set -u

CMD=""
CMD_SET=0
CWD=""

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2; CMD_SET=1; shift 2 ;;
    --command=*) CMD=${1#--command=}; CMD_SET=1; shift ;;
    --cwd)
      [ "$#" -gt 1 ] || { echo "error: --cwd requires a value" >&2; exit 2; }
      CWD=$2; shift 2 ;;
    --cwd=*) CWD=${1#--cwd=}; shift ;;
    --claude) shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
  [ -n "$CWD" ] || CWD=$(printf '%s' "$PAYLOAD" | jq -r '(.cwd // empty)' 2>/dev/null) || exit 0
fi
[ -n "$CMD" ] || exit 0
[ -n "$CWD" ] || CWD=$PWD

# Only a command that starts a new run: `no-mistakes axi run ... --intent`.
case "$CMD" in
  *no-mistakes*axi*run*--intent*) ;;
  *) exit 0 ;;
esac

g() { git -C "$CWD" "$@" 2>/dev/null; }

BRANCH=$(g symbolic-ref --short -q HEAD) || exit 0
[ -n "$BRANCH" ] || exit 0
HEAD_SHA=$(g rev-parse --verify -q 'HEAD^{commit}') || exit 0
GATE=$(g config --get remote.no-mistakes.url) || exit 0
[ -d "$GATE" ] || exit 0
OBJECTS=$(g rev-parse --path-format=absolute --git-path objects) || exit 0

# Read-only view of the gate that can also see the worktree's commits.
gate_git() { GIT_ALTERNATE_OBJECT_DIRECTORIES=$OBJECTS git --git-dir="$GATE" "$@" 2>/dev/null; }

MIRROR_SHA=$(gate_git rev-parse --verify -q "refs/heads/$BRANCH^{commit}") || MIRROR_SHA=""
FORGE_SHA=$(g rev-parse --verify -q "refs/remotes/origin/$BRANCH^{commit}") || FORGE_SHA=""

PROBLEMS=""
if [ -n "$MIRROR_SHA" ] && [ "$MIRROR_SHA" != "$HEAD_SHA" ] \
  && ! gate_git merge-base --is-ancestor "$MIRROR_SHA" "$HEAD_SHA"; then
  # Not an ancestor: harmless only when HEAD carries every mirror commit as a
  # rebased copy (no-mistakes refuses on commits whose content is absent).
  UNIQUE=$(gate_git cherry "$HEAD_SHA" "$MIRROR_SHA" | sed -n 's/^+ //p' | wc -l | tr -d ' ')
  if [ "${UNIQUE:-0}" -gt 0 ]; then
    PROBLEMS="${PROBLEMS}- the private mirror branch (gate refs/heads/$BRANCH, $MIRROR_SHA) holds $UNIQUE commit(s) that local HEAD ($HEAD_SHA) does not contain, for example pre-rebase commits or commits from an earlier run that were never synced back.
"
  fi
fi
if [ -n "$FORGE_SHA" ] && [ "$FORGE_SHA" != "$HEAD_SHA" ]; then
  AHEAD=$(g rev-list --count "$HEAD_SHA..$FORGE_SHA") || AHEAD=0
  if [ "${AHEAD:-0}" -gt 0 ]; then
    PROBLEMS="${PROBLEMS}- the forge branch (origin/$BRANCH, $FORGE_SHA) has $AHEAD commit(s) that local HEAD ($HEAD_SHA) does not contain.
"
  fi
fi
[ -n "$PROBLEMS" ] || exit 0

REASON="Refusing to start a no-mistakes run for branch $BRANCH: the run would review for a long time and then fail at the push step.
${PROBLEMS}Safe fix: run 'no-mistakes sync --check' to see the proof, then 'no-mistakes sync' (or 'no-mistakes sync --recover') to bring the branch to the pipeline head, or merge/rebase origin/$BRANCH into the branch and retry. Never force-push, reset or delete the mirror branch yourself; report blocked to firstmate if sync refuses."

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[nm-mirror-diverged] %s"}\n' "$(json_escape "$REASON")" >&2
exit 2
