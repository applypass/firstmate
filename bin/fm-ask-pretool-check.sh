#!/usr/bin/env bash
# Fork-only: PreToolUse transport for the read-only side session (applypass fork).
#
# usage: <PreToolUse JSON on stdin> | fm-ask-pretool-check.sh
#
# bin/fm-ask.sh registers this hook for the session it launches and sets
# FM_ASK_READONLY=1 and FM_ASK_HOME=<home>. bin/fm-ask-command-policy.mjs owns the
# decision (read-only tools and commands only); this wrapper acquires the
# payload, runs the policy, and renders the Claude deny. It never executes,
# sources, or expands anything from the payload.
#
# Scope: only a session carrying FM_ASK_READONLY, so a copy registered by
# mistake in a normal session is silent and exits 0.
#
# Exit/output contract:
#   INERT  - FM_ASK_READONLY unset: exit 0, no output.
#   ALLOW  - exit 0, no output.
#   DENY   - exit 2 and a Claude-shaped deny object on stderr; stdout stays empty.
#   FAIL CLOSED - inside an ask session an empty or unreadable payload, a missing
#                 jq or Node, or a policy that cannot run is also a deny, because
#                 "read-only" must never rest on a guard that did not run.
set -u

[ -n "${FM_ASK_READONLY:-}" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SCRIPT_DIR=
POLICY="$SCRIPT_DIR/fm-ask-command-policy.mjs"

deny() {  # <code> <reason>
  local escaped
  escaped=$(printf '%s' "[$1] $2" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  exit 2
}

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || deny ask-parse "the read-only side session received no tool payload to check, so the call is refused."
[ -n "${FM_ASK_HOME:-}" ] || deny ask-parse "the read-only side session has no home to read, so the call is refused."
command -v node >/dev/null 2>&1 && [ -f "$POLICY" ] || deny ask-parse "the read-only guard cannot run (node or its policy is missing), so every call is refused."

OUT=$(printf '%s' "$PAYLOAD" | node "$POLICY" --home "$FM_ASK_HOME" 2>/dev/null) || deny ask-parse "the read-only guard failed to run, so the call is refused."
[ "$OUT" != allow ] || exit 0

TAB=$(printf '\t')
[ "${OUT%%"$TAB"*}" = deny ] || deny ask-parse "the read-only guard gave no clear answer, so the call is refused."
REST=${OUT#*"$TAB"}
deny "${REST%%"$TAB"*}" "${REST#*"$TAB"}"
