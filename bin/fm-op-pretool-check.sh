#!/usr/bin/env bash
# Fork-only: PreToolUse transport for the op guard (applypass fork).
#
# Refuses a Bash command that runs the 1Password `op` CLI unless
# OP_SERVICE_ACCOUNT_TOKEN is set. Without it, `op` falls back to the 1Password
# desktop app and pops its full-account "allow CLI access" prompt; agents must
# only use the vault-scoped service account (bin/fm-op-service-account-lib.sh).
# bin/fm-op-command-policy.mjs owns the decision (an inline assignment, `env X=1
# op`, or an earlier `export` on the same command line also counts as loaded);
# this wrapper checks the hook's own environment, acquires the harness payload,
# invokes the policy, and renders the deny. It never executes, sources, or
# expands the command and never prints a token. Unlike the cd guard it is not
# scoped to the primary checkout: it applies wherever it is registered, which is
# firstmate's home (bin/fm-op-guard-install.sh) and every Claude worker and
# secondmate worktree bin/fm-spawn.sh launches. Codex workers run with hooks
# disabled and other harnesses have no registration, so they are not covered.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-op-pretool-check.sh [--claude]
#   bin/fm-op-pretool-check.sh --command '<cmd>' [--claude]
#
# --claude marks the Claude PreToolUse registration; it is the only harness
# this guard is registered in, so the output shape is the same with or
# without it.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2 and a Claude-shaped deny object on stderr; stdout stays empty.
#   FAIL OPEN - malformed or empty stdin, missing jq or Node, missing policy.
set -u

CMD=""
CMD_SET=0

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude) shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# The service account is loaded: every op call in this session is scoped.
[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || exit 0

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
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only): without the letters "op" after
# quote and escape bytes are stripped, no command word can be op. An ANSI-C or
# locale quote marker delegates because the classifier decodes those.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *op*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
POLICY="$SCRIPT_DIR/fm-op-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "[$CODE] $REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2
