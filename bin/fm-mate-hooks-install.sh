#!/usr/bin/env bash
# Fork-only: register the second mate hooks in a mate home's untracked Claude settings (applypass fork).
#
# usage: fm-mate-hooks-install.sh <dir>
#
# Merges two hooks into <dir>/.claude/settings.local.json, keeping every other setting:
#   UserPromptSubmit  bin/fm-captain-direct.sh --claude   the captain typing into the mate's pane
#   PreToolUse (.*)   bin/fm-reply-first.sh pretool --claude   answer first, then dig
# Both scripts stay silent outside a secondmate home, so a stray registration is harmless.
# Idempotent: a hook already pointing at a script is left alone. bin/fm-spawn.sh runs
# it for every Claude secondmate launch and relaunch. docs/captain-direct-mate-access.md
# owns the operator view.
set -u

[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: fm-mate-hooks-install.sh <dir>" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-mate-hooks-install: jq is required" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
DIR=$(CDPATH='' cd -- "$1" && pwd -P) || exit 1
PROMPT_CMD="$(printf %q "$SCRIPT_DIR/fm-captain-direct.sh") --claude"
TOOL_CMD="$(printf %q "$SCRIPT_DIR/fm-reply-first.sh") pretool --claude"
FILE="$DIR/.claude/settings.local.json"

mkdir -p "$DIR/.claude" || exit 1
[ -f "$FILE" ] || printf '{}\n' >"$FILE"
TMP=$(mktemp "$FILE.XXXXXX") || exit 1
if ! jq --arg prompt "$PROMPT_CMD" --arg tool "$TOOL_CMD" '
  def has($event; $script): any(.hooks[$event][]?.hooks[]?; (.command // "") | contains($script));
  .hooks //= {}
  | .hooks.UserPromptSubmit //= []
  | .hooks.PreToolUse //= []
  | if has("UserPromptSubmit"; "fm-captain-direct.sh") then .
    else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$prompt,"timeout":10}]}] end
  | if has("PreToolUse"; "fm-reply-first.sh") then .
    else .hooks.PreToolUse += [{"matcher":".*","hooks":[{"type":"command","command":$tool,"timeout":10}]}] end' "$FILE" >"$TMP"; then
  rm -f "$TMP"
  echo "fm-mate-hooks-install: could not merge into $FILE" >&2
  exit 1
fi
mv "$TMP" "$FILE"
