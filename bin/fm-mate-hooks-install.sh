#!/usr/bin/env bash
# Fork-only: register the second mate hooks in a mate home's untracked Claude settings (applypass fork).
#
# usage: fm-mate-hooks-install.sh [--main] <dir>
#
# Merges two hooks into <dir>/.claude/settings.local.json, keeping every other setting:
#   UserPromptSubmit  bin/fm-captain-direct.sh --claude   the captain typing into the mate's pane
#   PreToolUse (.*)   bin/fm-reply-first.sh pretool --claude   answer first, then dig
# fm-captain-direct.sh stays silent outside a secondmate home and fm-reply-first.sh outside
# a secondmate or primary home, so a stray registration is harmless.
# --main registers the primary home's set instead (bin/fm-session-start.sh runs it; a
# secondmate home is skipped):
#   UserPromptSubmit  bin/fm-reply-first.sh prompt --claude   opens a window for the captain's words only
#   PreToolUse (.*)   bin/fm-reply-first.sh pretool --claude
#   Stop              bin/fm-reply-first.sh clear             a wake turn is never counted against a finished one
# Idempotent: a hook already pointing at a script is left alone. bin/fm-spawn.sh runs
# it for every Claude secondmate launch and relaunch. docs/captain-direct-mate-access.md
# owns the operator view.
set -u

MAIN=0
if [ "${1:-}" = --main ]; then MAIN=1; shift; fi
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: fm-mate-hooks-install.sh [--main] <dir>" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-mate-hooks-install: jq is required" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
DIR=$(CDPATH='' cd -- "$1" && pwd -P) || exit 1
PROMPT_CMD="$(printf %q "$SCRIPT_DIR/fm-captain-direct.sh") --claude"
[ "$MAIN" -eq 0 ] || PROMPT_CMD="$(printf %q "$SCRIPT_DIR/fm-reply-first.sh") prompt --claude"
STOP_CMD="$(printf %q "$SCRIPT_DIR/fm-reply-first.sh") clear"
TOOL_CMD="$(printf %q "$SCRIPT_DIR/fm-reply-first.sh") pretool --claude"
FILE="$DIR/.claude/settings.local.json"
# A second mate home gets its set from fm-spawn.sh, never the primary one.
[ "$MAIN" -eq 0 ] || [ ! -e "$DIR/.fm-secondmate-home" ] || exit 0

mkdir -p "$DIR/.claude" || exit 1
[ -f "$FILE" ] || printf '{}\n' >"$FILE"
TMP=$(mktemp "$FILE.XXXXXX") || exit 1
if ! jq --arg prompt "$PROMPT_CMD" --arg tool "$TOOL_CMD" --arg stop "$STOP_CMD" --argjson main "$MAIN" '
  def has($event; $script): any(.hooks[$event][]?.hooks[]?; (.command // "") | contains($script));
  .hooks //= {}
  | .hooks.UserPromptSubmit //= []
  | .hooks.PreToolUse //= []
  | (if $main == 1 then
      (.hooks.Stop //= [])
      | if has("Stop"; "fm-reply-first.sh") then .
        else .hooks.Stop += [{"hooks":[{"type":"command","command":$stop,"timeout":10}]}] end
    else . end)
  | if has("UserPromptSubmit"; (if $main == 1 then "fm-reply-first.sh" else "fm-captain-direct.sh" end)) then .
    else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$prompt,"timeout":10}]}] end
  | if has("PreToolUse"; "fm-reply-first.sh") then .
    else .hooks.PreToolUse += [{"matcher":".*","hooks":[{"type":"command","command":$tool,"timeout":10}]}] end' "$FILE" >"$TMP"; then
  rm -f "$TMP"
  echo "fm-mate-hooks-install: could not merge into $FILE" >&2
  exit 1
fi
mv "$TMP" "$FILE"
