#!/usr/bin/env bash
# Fork-only: register the daily quota stop hook in a worktree's untracked Claude settings (applypass fork).
#
# usage: fm-daily-quota-guard-install.sh <dir> [--home DIR] [--status-file FILE]
#
# Merges a PreToolUse Bash hook that runs bin/fm-daily-quota-pretool-check.sh
# into <dir>/.claude/settings.local.json, keeping every other setting.
# --home names the firstmate home that launched the worker and --status-file the worker's status file, so a
# refusal reports into the right channel. Idempotent: a hook already pointing
# at this script is left alone. bin/fm-spawn.sh runs it for every Claude worker.
set -u

[ "$#" -ge 1 ] && [ -d "$1" ] || { echo "usage: fm-daily-quota-guard-install.sh <dir> [--home DIR] [--status-file FILE]" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-daily-quota-guard-install: jq is required" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
DIR=$(CDPATH='' cd -- "$1" && pwd -P) || exit 1
shift
HOOK_CMD="$(printf %q "$SCRIPT_DIR/fm-daily-quota-pretool-check.sh") --claude"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home|--status-file) [ "$#" -gt 1 ] || { echo "error: $1 requires a value" >&2; exit 2; }; HOOK_CMD="$HOOK_CMD $1 $(printf %q "$2")"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
FILE="$DIR/.claude/settings.local.json"

mkdir -p "$DIR/.claude" || exit 1
[ -f "$FILE" ] || printf '{}\n' >"$FILE"
TMP=$(mktemp "$FILE.XXXXXX") || exit 1
if ! jq --arg cmd "$HOOK_CMD" '
  .hooks //= {}
  | .hooks.PreToolUse //= []
  | if any(.hooks.PreToolUse[]?.hooks[]?; (.command // "") | contains("fm-daily-quota-pretool-check.sh"))
    then .
    else .hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":$cmd}]}]
    end' "$FILE" >"$TMP"; then
  rm -f "$TMP"
  echo "fm-daily-quota-guard-install: could not merge into $FILE" >&2
  exit 1
fi
mv "$TMP" "$FILE"
