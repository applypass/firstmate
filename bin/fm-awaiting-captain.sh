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
# Usage: fm-awaiting-captain.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

MAX=${FM_AWAITING_MAX:-20}
case "$MAX" in ''|*[!0-9]*|0) MAX=20 ;; esac

case "${1:-}" in
  -h|--help) sed -n '2,${/^set -u/q;p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
  '') : ;;
  *) echo "usage: $(basename "$0")" >&2; exit 2 ;;
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
  printf 'HANDOVER WAITING: a previous session prepared and released one. Read data/handover.md,\n'
  printf '  reconcile it against the durable records it points at, then run bin/fm-handover.sh consume.\n'
fi

# --- decisions held for the captain -----------------------------------------
printf 'Decisions held for you:\n'
if [ -f "$DATA/backlog.md" ]; then
  awk '
    /^## Done/ { done_section = 1 }
    done_section { next }
    /^- \[ \]/ && /hold-kind: captain/ {
      line = $0
      id = line
      sub(/^- \[ \] /, "", id)
      sub(/ .*$/, "", id)
      title = line
      sub(/^- \[ \] [^ ]* - /, "", title)
      sub(/ \(repo:.*$/, "", title)
      printf "- %s - %s\n", id, title
    }
  ' "$DATA/backlog.md" | print_capped "held decision(s)"
else
  printf '(no backlog record)\n'
fi

# --- work recorded as waiting for the captain's merge -----------------------
printf 'Recorded pull requests waiting to land:\n'
{
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    pr=$(sed -n 's/^pr=//p' "$meta" 2>/dev/null | head -1)
    [ -n "$pr" ] || continue
    printf -- '- %s (%s)\n' "$pr" "$(basename "$meta" .meta)"
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
