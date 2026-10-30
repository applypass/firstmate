#!/usr/bin/env bash
# Fork-only: fm-ask-order.sh - the one mutation a read-only side session may make (applypass fork).
#
# usage: fm-ask-order.sh <order text...>
#
# In a bin/fm-ask.sh session on a second mate's home, the captain may give an
# order. The session does not run it and does not refuse it outright: it queues
# the order to the owning mate's steering inbox through the normal bin/fm-send.sh
# path, run against the mate's parent home exactly as the parent firstmate would
# send it, then tells the captain "queued" with what the mate is doing now.
# Nothing else about the session changes: every other send, spawn, merge, drain,
# hold, decide, backlog write, teardown, control call, and file write stays refused.
#
# The target is fixed, never chosen by the caller. bin/fm-ask.sh exports
#   FM_ASK_ORDER_HOME    the mate's parent home (from the mate's .fm-secondmate-parent)
#   FM_ASK_ORDER_TARGET  the mate's id (from its .fm-secondmate-home)
# and this script refuses to run without both, so it cannot reach any other task or
# home. A main home has no owning mate, so a main-home session sets neither and
# every order there is refused.
#
# The message carries a plain-words label that the captain gave the order in a
# read-only session. Output: the fm-send result, the mate's current state
# (bin/fm-crew-state.sh in the parent home), and the mate's newest status line,
# for the session to relay. Exit status is fm-send's.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
case "${1:-}" in -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ "$#" -ge 1 ] && [ -n "$*" ] || { echo "usage: fm-ask-order.sh <order text...>" >&2; exit 2; }
[ -n "${FM_ASK_READONLY:-}" ] && [ -n "${FM_ASK_ORDER_HOME:-}" ] && [ -n "${FM_ASK_ORDER_TARGET:-}" ] || {
  echo "fm-ask-order: no owning second mate to queue an order to in this session; hand the order to the real firstmate" >&2
  exit 1
}

MESSAGE="The captain gave this order in a read-only side session on your home (the session cannot act, so it queued the order here). Treat it as the captain's instruction: $*"
FM_HOME="$FM_ASK_ORDER_HOME" "$SCRIPT_DIR/fm-send.sh" "$FM_ASK_ORDER_TARGET" "$MESSAGE"
RC=$?
echo "queued-to: $FM_ASK_ORDER_TARGET (exit $RC)"
echo "mate-state: $(FM_HOME="$FM_ASK_ORDER_HOME" FM_CREW_STATE_NO_FORGE=1 "$SCRIPT_DIR/fm-crew-state.sh" "$FM_ASK_ORDER_TARGET" 2>&1 | head -n 3 | tr '\n' ' ')"
STATUS="$FM_ASK_ORDER_HOME/state/$FM_ASK_ORDER_TARGET.status"
[ ! -f "$STATUS" ] || echo "latest-status: $(tail -n 1 "$STATUS")"
exit "$RC"
