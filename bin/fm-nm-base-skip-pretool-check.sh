#!/usr/bin/env bash
# Fork-only: PreToolUse check that makes a new no-mistakes run follow its PR's
# base branch (applypass fork).
#
# Decision (2026-10-26): dev-bound PRs merge on green GitHub CI, which already
# runs the unit and integration suites, so the local final run skips the test
# step and keeps review, document and lint. PRs to any other base (main) keep
# the full run with tests. A local test step on a loaded machine hung for 30-45
# minutes while GitHub CI was green.
#
# Rule, applied to a command that starts a NEW run (`no-mistakes axi run` with
# --intent, as in bin/fm-nm-mirror-pretool-check.sh):
#   base branch dev: the command must pass `--skip test` (alone or inside a
#     comma list), else it is refused.
#   any other base: the command must not skip `test`, else it is refused.
#   base unknown: allowed unchanged, so the full run with tests stays the default.
# The base is the command's --base-branch when given, else the base of the open
# PR for the current branch read from the forge (gh, 20s bound). A bare `axi
# run`, `axi status`, `axi respond` and every other command are never checked.
# Only Claude workers get this check (bin/fm-op-guard-install.sh); other workers
# keep the full run with tests.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-nm-base-skip-pretool-check.sh [--claude]
#   bin/fm-nm-base-skip-pretool-check.sh --command '<cmd>' [--cwd <dir>] [--claude]
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2 and a Claude-shaped deny object on stderr naming the base and
#     the exact flag to add or drop; stdout stays empty.
#   FAIL OPEN - malformed or empty stdin, missing jq, or an unreadable base.
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

case "$CMD" in
  *no-mistakes*axi*run*--intent*) ;;
  *) exit 0 ;;
esac

# Base branch: the command's own --base-branch, else the open PR's base.
BASE=$(printf '%s' "$CMD" | sed -n 's/.*--base-branch[= ]\{1,\}["'\'']\{0,1\}\([^ "'\'']*\).*/\1/p' | head -1)
if [ -z "$BASE" ]; then
  command -v gh >/dev/null 2>&1 || exit 0
  TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
  if [ -n "$TIMEOUT_BIN" ]; then
    BASE=$(cd "$CWD" 2>/dev/null && "$TIMEOUT_BIN" 20 gh pr view --json baseRefName -q .baseRefName 2>/dev/null) || BASE=""
  else
    BASE=$(cd "$CWD" 2>/dev/null && gh pr view --json baseRefName -q .baseRefName 2>/dev/null) || BASE=""
  fi
fi
BASE=$(printf '%s' "$BASE" | tr -d '[:space:]')
[ -n "$BASE" ] || exit 0

# Steps named by --skip, as ",a,b,".
SKIPS=$(printf '%s' "$CMD" | sed -n 's/.*--skip[= ]\{1,\}["'\'']\{0,1\}\([^ "'\'']*\).*/\1/p' | head -1)
SKIPS=",$SKIPS,"
SKIPS_TEST=0
case "$SKIPS" in *,test,*) SKIPS_TEST=1 ;; esac

IS_SKIP_BASE=0
[ "$BASE" = "dev" ] && IS_SKIP_BASE=1

REASON=""
if [ "$IS_SKIP_BASE" -eq 1 ] && [ "$SKIPS_TEST" -eq 0 ]; then
  REASON="This PR targets $BASE, which merges on green GitHub CI that already runs the tests, so the final no-mistakes run skips the local test step. Re-run the same command with the test step added to --skip (for example '--skip test', or '--skip push,pr,ci,test' when the brief already skips those). Review, document and lint still run."
elif [ "$IS_SKIP_BASE" -eq 0 ] && [ "$SKIPS_TEST" -eq 1 ]; then
  REASON="This PR targets $BASE, so the final no-mistakes run keeps the test step. Re-run the same command without 'test' in --skip."
fi
[ -n "$REASON" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[nm-base-skip] %s"}\n' "$(json_escape "$REASON")" >&2
exit 2
