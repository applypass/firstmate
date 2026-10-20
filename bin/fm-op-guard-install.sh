#!/usr/bin/env bash
# Fork-only: register the op guard in a directory's untracked Claude settings (applypass fork).
#
# usage: fm-op-guard-install.sh <dir>
#
# Merges PreToolUse Bash hooks that run bin/fm-op-pretool-check.sh and
# bin/fm-nm-mirror-pretool-check.sh (diverged no-mistakes mirror) into
# <dir>/.claude/settings.local.json, keeping every other setting. Idempotent: a
# hook already pointing at this script is left alone. bin/fm-spawn.sh runs it for
# every Claude worker and secondmate worktree it wires; run it once by hand in
# firstmate's own home to cover the primary session. The file is untracked, so
# the shared .claude/settings.json is never touched.
set -u

[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: fm-op-guard-install.sh <dir>" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-op-guard-install: jq is required" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
HOOK_CMD="$(printf %q "$SCRIPT_DIR/fm-op-pretool-check.sh") --claude"
NM_HOOK_CMD="$(printf %q "$SCRIPT_DIR/fm-nm-mirror-pretool-check.sh") --claude"
DIR=$(CDPATH='' cd -- "$1" && pwd -P) || exit 1
FILE="$DIR/.claude/settings.local.json"

mkdir -p "$DIR/.claude" || exit 1
[ -f "$FILE" ] || printf '{}\n' >"$FILE"
TMP=$(mktemp "$FILE.XXXXXX") || exit 1
if ! jq --arg cmd "$HOOK_CMD" --arg nm "$NM_HOOK_CMD" '
  .hooks //= {}
  | .hooks.PreToolUse //= []
  | if any(.hooks.PreToolUse[]?.hooks[]?; (.command // "") | contains("fm-op-pretool-check.sh"))
    then .
    else .hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":$cmd}]}]
    end
  | if any(.hooks.PreToolUse[]?.hooks[]?; (.command // "") | contains("fm-nm-mirror-pretool-check.sh"))
    then .
    else .hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":$nm}]}]
    end' "$FILE" >"$TMP"; then
  rm -f "$TMP"
  echo "fm-op-guard-install: could not merge into $FILE" >&2
  exit 1
fi
mv "$TMP" "$FILE"
