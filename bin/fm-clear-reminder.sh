#!/usr/bin/env bash
# Fork-only: hourly one-line reminder to /stow then /clear the primary session (applypass fork).
#
# usage: fm-clear-reminder.sh [--state DIR]
#
# Prints one Claude hook JSON object whose systemMessage the captain sees, at
# most once an hour, and nothing otherwise. The last reminder time lives in
# <state>/.clear-reminder-epoch (default $FM_HOME/state), so a restart does not
# reset the limit. The caller decides which session may remind: bin/fm-host-mirror.sh
# runs this only for a captain prompt in the lock-owning primary session, so
# workers, secondmate homes, and the supervision host's headless sessions never
# reach it. FM_CLEAR_REMINDER=off disables it (tests/lib.sh sets it);
# FM_CLEAR_REMINDER_NOW overrides the clock for tests.
set -u

[ "${FM_CLEAR_REMINDER:-}" != off ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 0
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$SCRIPT_DIR/..}/state}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) [ "$#" -gt 1 ] || exit 0; STATE=$2; shift 2 ;;
    *) exit 0 ;;
  esac
done
[ -d "$STATE" ] || exit 0

INTERVAL=3600
NOW=${FM_CLEAR_REMINDER_NOW:-$(date +%s)}
STAMP="$STATE/.clear-reminder-epoch"
LAST=0
[ ! -f "$STAMP" ] || IFS= read -r LAST < "$STAMP" || true
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
[ $((NOW - LAST)) -ge "$INTERVAL" ] || exit 0

TMP=$(mktemp "$STAMP.XXXXXX" 2>/dev/null) || exit 0
if ! { printf '%s\n' "$NOW" > "$TMP" && mv -f "$TMP" "$STAMP"; }; then rm -f "$TMP"; exit 0; fi
jq -cn --arg m 'This session is long and each turn re-reads it all. Run /stow, then /clear, to start fresh; the lock carries over.' '{systemMessage: $m}'
