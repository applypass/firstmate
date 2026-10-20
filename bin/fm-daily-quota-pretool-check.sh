#!/usr/bin/env bash
# Fork-only: PreToolUse transport for the daily quota stop (applypass fork).
#
# Refuses `no-mistakes rerun` while the fleet's daily Claude quota stop is in
# force (bin/fm-daily-quota-stop.sh owns the decision). A new run started by a
# push to the no-mistakes gate is checked at the shared pre-receive companion
# (bin/fm-validation-gate-pre-receive.sh), which covers every harness and home;
# `no-mistakes rerun` asks the daemon directly and never reaches that boundary,
# so this Claude PreToolUse hook is its gate. Reattaching (`axi run` with no
# flags), `axi respond`, and `axi status` never match, so an existing run is
# never blocked. Registered per Claude worker by bin/fm-spawn.sh through
# bin/fm-daily-quota-guard-install.sh.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-daily-quota-pretool-check.sh [--claude] [--home DIR] [--status-file FILE]
#   bin/fm-daily-quota-pretool-check.sh --command '<cmd>' [--home DIR] [--status-file FILE]
#
# ALLOW - exit 0, no output. DENY - exit 2 and a Claude-shaped deny object on
# stderr. FAIL OPEN on malformed or empty stdin and a missing jq or gate: this
# guard only ever refuses on a positive quota verdict.
set -u

CMD=""
CMD_SET=0
HOME_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --command) [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }; CMD=$2; CMD_SET=1; shift 2 ;;
    --claude) shift ;;
    --home|--status-file) [ "$#" -gt 1 ] || { echo "error: $1 requires a value" >&2; exit 2; }; HOME_ARGS+=("$1" "$2"); shift 2 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi
[ -n "$CMD" ] || exit 0

# A rerun: `no-mistakes rerun` at a command position. A word preceded by a
# quote, slash, dot, dash, or alphanumeric is not a command.
RERUN_RE='(^|[^A-Za-z0-9_./"'"'"'-])no-mistakes[[:space:]]+rerun([[:space:]]|$)'
[[ "$CMD" =~ $RERUN_RE ]] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
GATE="$SCRIPT_DIR/fm-daily-quota-stop.sh"
[ -x "$GATE" ] || exit 0

REASON=$("$GATE" check nm-run ${HOME_ARGS[@]+"${HOME_ARGS[@]}"} 2>&1 >/dev/null)
RC=$?
[ "$RC" -eq 3 ] || exit 0

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '; }
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$(json_escape "$REASON")" >&2
exit 2
