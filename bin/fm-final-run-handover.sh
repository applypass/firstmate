#!/usr/bin/env bash
# fm-final-run-handover.sh - run a ship's final no-mistakes run in a fresh worker conversation (applypass fork).
#
# Usage:
#   fm-final-run-handover.sh write <task-id> --pr <url> --changed <text> --tests <text> [--answers <text>]
#   fm-final-run-handover.sh relaunch-note <task-id> <head-sha>
#   fm-final-run-handover.sh mark-relaunched <task-id> <head-sha>
#   fm-final-run-handover.sh brief-rule <task-id>
#
# The implementation worker's conversation grows through the whole build, and
# every step of the long no-mistakes run re-reads it. So the worker writes a
# short hand-over note instead of starting that run, reports `done: PR <url>
# ready for final validation` as today, and stops. `fm-validation-gate.sh
# release` then relaunches the same task through `fm-control.sh relaunch`: same
# worktree, same harness, model and effort, a fresh conversation whose note is
# this hand-over plus the instruction to run /no-mistakes on the released head.
#
# `write` records data/<task-id>/final-run-handover.md: branch and head commit
# (read from the task's worktree), PR URL, what changed, the related tests run,
# and the review answers still open (default "none"). Every field but
# --answers is required.
# `relaunch-note` prints the relaunch note and exits 0 only when the hand-over
# exists, names <head-sha>, and the task has not been relaunched already. A
# stale or absent note, or a second release, exits 1 and release steers the
# live worker as before. `mark-relaunched` records the relaunch, so a later
# release of a new head steers the fresh worker rather than relaunching again.
#
# No new status key: the existing ready-for-final-validation `done:` is the
# hand-off request, and the fresh worker's CI-ready `done:` passes the usual
# custody check. Paths follow FM_HOME (default: the repo root).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "fm-final-run-handover: $*" >&2; exit 2; }
valid_word() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

note_path() { printf '%s/%s/final-run-handover.md' "$DATA" "$1"; }
mark_path() { printf '%s/%s/final-run-handover.relaunched' "$DATA" "$1"; }

cmd_write() {
  [ $# -ge 1 ] || die "usage: write <task-id> --pr <url> --changed <text> --tests <text> [--answers <text>]"
  local id=$1 pr="" changed="" tests="" answers="none" wt branch head note
  shift
  valid_word "$id" || die "invalid task id '$id'"
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) pr=${2:?--pr needs a value}; shift 2 ;;
      --changed) changed=${2:?--changed needs a value}; shift 2 ;;
      --tests) tests=${2:?--tests needs a value}; shift 2 ;;
      --answers) answers=${2:?--answers needs a value}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$pr" ] && [ -n "$changed" ] && [ -n "$tests" ] || die "--pr, --changed and --tests are required"
  wt=$(sed -n 's/^worktree=//p' "$STATE/$id.meta" 2>/dev/null | head -n 1)
  [ -n "$wt" ] && [ -d "$wt" ] || die "task $id has no readable worktree in $STATE/$id.meta"
  head=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}') || die "$wt has no HEAD commit"
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
  note=$(note_path "$id")
  mkdir -p "$(dirname "$note")" || die "cannot create $(dirname "$note")"
  {
    echo "# Hand-over for the final run of $id"
    echo "- Branch: $branch"
    echo "- Head: $head"
    echo "- PR: $pr"
    echo "- What changed: $changed"
    echo "- Related tests run: $tests"
    echo "- Open review answers: $answers"
  } > "$note.tmp" || die "cannot write $note"
  mv "$note.tmp" "$note" || die "cannot write $note"
  echo "$note"
}

cmd_relaunch_note() {
  [ $# -eq 2 ] || die "usage: relaunch-note <task-id> <head-sha>"
  local id=$1 head=$2 note
  valid_word "$id" || die "invalid task id '$id'"
  note=$(note_path "$id")
  [ -f "$note" ] || exit 1
  [ ! -e "$(mark_path "$id")" ] || exit 1
  grep -qxF -- "- Head: $head" "$note" || exit 1
  cat <<EOF2
You are the fresh worker for the final no-mistakes run of this task. The implementation is complete: do not redo or re-review it. Your starting point is the hand-over note below and the branch checked out in this worktree.
Firstmate released the final validation of $head. Run /no-mistakes now on that exact head, as your Definition of done says, and drive it through to CI green.

EOF2
  cat "$note"
}

cmd_mark_relaunched() {
  [ $# -eq 2 ] || die "usage: mark-relaunched <task-id> <head-sha>"
  valid_word "$1" || die "invalid task id '$1'"
  printf '%s\n' "$2" > "$(mark_path "$1")" || die "cannot write $(mark_path "$1")"
}

cmd_brief_rule() {
  [ $# -eq 1 ] || die "usage: brief-rule <task-id>"
  local id=$1 self="$SCRIPT_DIR/fm-final-run-handover.sh"
  cat <<EOF2

# Fresh worker for the final run
The final no-mistakes run starts in a fresh conversation, not this one.
Before your \`done ... ready for final validation\` line, commit and push, then write the hand-over note:
\`FM_HOME='$FM_HOME' '$self' write $id --pr <url> --changed '<what changed>' --tests '<related tests run>' [--answers '<open review answers>']\`
Keep it short; it records the branch and head commit itself.
After the note, append the done line and stop.
When firstmate releases the head, a fresh worker with your note runs /no-mistakes; you do not.
If a hand-over note is already in your instructions, you are that fresh worker: start from the note and the checked-out branch, and do not redo the implementation.
EOF2
}

CMD=${1:-}
[ "$#" -gt 0 ] && shift
case "$CMD" in
write) cmd_write "$@" ;;
relaunch-note) cmd_relaunch_note "$@" ;;
mark-relaunched) cmd_mark_relaunched "$@" ;;
brief-rule) cmd_brief_rule "$@" ;;
-h|--help|'') usage ;;
*) die "unknown command: $CMD" ;;
esac
