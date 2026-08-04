#!/usr/bin/env bash
# The short list of things waiting on the captain, plus the one-line pointer to
# everything already answered.
#
# WHY IT IS SHORT AND WHY IT IS FIRST: the captain's own rules and two settled
# answers were sitting in a session-start digest several hundred lines down, and
# were skipped. The fix is not more text earlier - it is a few always-actionable
# lines early, and a cheap lookup for the rest. So this block carries only what
# is genuinely waiting on the captain, and one line saying how to search the rest.
#
# LOCAL READS ONLY: no network, no forge calls, no agent-state probes. This runs
# at every session start, so it must stay cheap enough that nobody is tempted to
# skip it. A recorded pull request is listed as recorded, never re-checked here.
#
# HARD LINE CAP: each list is bounded and says how many entries it dropped.
# Silent truncation would read as "nothing else is waiting", which is the exact
# failure this block exists to prevent.
#
# ONE OWNER PER CONTRACT: what counts as a captain hold waiting on the captain,
# and where a task's pull request is recorded, are both defined once in
# bin/fm-backlog-record-lib.sh and consumed here. This file never restates them.
#
# Usage: fm-awaiting-captain.sh [--handover-printed-below]
#   --handover-printed-below: the caller prints the handover record itself, so
#     point at what it printed instead of telling the reader to open the file.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

MAX=${FM_AWAITING_MAX:-20}
case "$MAX" in ''|*[!0-9]*|0) MAX=20 ;; esac

# shellcheck source=bin/fm-backlog-record-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-record-lib.sh"

HANDOVER_PRINTED_BELOW=0
case "${1:-}" in
  -h|--help) sed -n '2,${/^set -u/q;p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
  --handover-printed-below) HANDOVER_PRINTED_BELOW=1 ;;
  '') : ;;
  *) echo "usage: $(basename "$0") [--handover-printed-below]" >&2; exit 2 ;;
esac

# print_capped <label>: read lines from stdin, print at most MAX of them, and
# name what was dropped.
print_capped() {
  local label=$1 total=0 shown=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    if [ "$shown" -lt "$MAX" ]; then
      printf '%s\n' "$line"
      shown=$((shown + 1))
    fi
  done
  if [ "$total" -eq 0 ]; then
    printf '(none)\n'
  elif [ "$total" -gt "$shown" ]; then
    printf -- '--- %s more %s omitted by the %s-line cap; raise FM_AWAITING_MAX to see them ---\n' \
      "$((total - shown))" "$label" "$MAX"
  fi
}

# No banner of its own: bin/fm-session-start.sh heads this block as a digest
# section, and a second title there would just read as a duplicate.
#
# --- a handover the captain already triggered -------------------------------
if "$SCRIPT_DIR/fm-handover.sh" pending 2>/dev/null; then
  if [ "$HANDOVER_PRINTED_BELOW" -eq 1 ]; then
    printf 'HANDOVER WAITING: a previous session prepared and released one. It is printed in full\n'
    printf '  below, so do not re-read the record. Reconcile it against the durable records it\n'
    printf '  points at, then run bin/fm-handover.sh consume.\n'
  else
    printf 'HANDOVER WAITING: a previous session prepared and released one. Read data/handover.md,\n'
    printf '  reconcile it against the durable records it points at, then run bin/fm-handover.sh consume.\n'
  fi
fi

# --- decisions held for the captain -----------------------------------------
# bin/fm-backlog-record-lib.sh decides what is actionable; this only renders it.
printf 'Decisions held for you:\n'
if [ ! -f "$DATA/backlog.md" ]; then
  printf '(no backlog record)\n'
elif ! command -v jq >/dev/null 2>&1; then
  printf '(held decisions unread: jq is not installed, so the backlog record model cannot be read)\n'
else
  fm_backlog_records_json "$DATA/backlog.md" 2>/dev/null \
    | jq -r '.records[]? | select(.captain_actionable == true)
             | "- \(.id) - \(.title // "")"' 2>/dev/null \
    | print_capped "held decision(s)"
fi

# --- work recorded as waiting for the captain's merge -----------------------
# Same owner as the snapshot's pr/pr_source, so a PR recorded only in a status
# event is listed too. Still a local read: nothing here asks a forge anything.
printf 'Recorded pull requests waiting to land:\n'
{
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    record=$(fm_recorded_pr "$meta" "$STATE/$id.status") || continue
    printf -- '- %s (%s, recorded in %s)\n' "${record%%	*}" "$id" "${record#*	}"
  done
} | print_capped "recorded pull request(s)"

# --- the one line about what is already answered ----------------------------
"$SCRIPT_DIR/fm-decided.sh" count 2>/dev/null \
  || printf 'Search before escalating anything: bin/fm-decided.sh search <terms>\n'

# Standing preferences are not decisions and are never summarized here; this is
# only the early pointer to the file that holds them, which prints in full
# further down the digest.
if [ -s "$DATA/captain.md" ]; then
  printf 'The captain'"'"'s standing preferences are in data/captain.md - read them before reporting anything.\n'
fi
