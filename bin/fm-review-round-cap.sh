#!/usr/bin/env bash
# fm-review-round-cap.sh - cap no-mistakes fix rounds and fail fast on agent timeouts (applypass fork).
#
# Usage:
#   fm-review-round-cap.sh fix <task-id> <run> <step> [--findings FILE]
#   fm-review-round-cap.sh timeout <task-id> <run> <step> [--error TEXT]
#   fm-review-round-cap.sh cap
#   fm-review-round-cap.sh brief-rule <task-id>
#
# A worker calls `fix` before it answers a gate with `fix`, passing the gate's
# remaining findings (one per line). Rounds are counted per task, run and step in
# state/<task-id>.fix-rounds. Under the cap the call records the round, prints
# "fix-allowed: round N of CAP" and exits 0, and the worker sends the fix. At the
# cap it exits 3 without recording a round: it writes data/<task-id>/nm-<run>-<step>-rounds.txt
# (round count, themes seen in more than one round, remaining findings), appends
# `needs-decision [key=nm-<run>-<step>-cap]` to the task's status file, and the
# worker stops and waits for firstmate. A finding's theme is the first file-like
# token on its line, else its first four words lowercased.
#
# The cap is FM_REVIEW_FIX_CAP, else the first line of config/review-fix-cap,
# else 2. It must be a non-negative integer; 0 sends every review gate to
# firstmate. Only `fix` rounds count: approve and skip never do.
#
# Firstmate answers a capped gate with approve, skip, or a steer.
#
# `timeout` is for a step that failed with an agent timeout (the 30-minute wall
# clock). With --error TEXT it exits 1, doing nothing, unless TEXT reads like a
# timeout. Otherwise it appends `needs-decision [key=nm-<run>-<step>-timeout]`
# and exits 3, so the worker reports at once rather than retrying silently.
#
# `brief-rule` prints the worker instruction that bin/fm-dod-lib.sh adds to a
# no-mistakes brief. Both keys start with nm-<run>-, the shape the watcher
# binds to a run parked at a human-owed gate (bin/fm-classify-lib.sh).
# Paths follow FM_HOME (default: the repo root), like bin/fm-brief.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DEFAULT_CAP=2

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "fm-review-round-cap: $*" >&2; exit 2; }

valid_word() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

cap_value() {
  local v=${FM_REVIEW_FIX_CAP:-}
  if [ -z "$v" ] && [ -f "$CONFIG/review-fix-cap" ]; then
    v=$(head -1 "$CONFIG/review-fix-cap" | tr -d '[:space:]')
  fi
  v=${v:-$DEFAULT_CAP}
  case "$v" in *[!0-9]*) die "review fix cap must be a non-negative integer, got '$v'" ;; esac
  printf '%s\n' "$v"
}

# Same append the brief hands workers, so the ledger sees the line at once.
append_status() {  # <task-id> <line>
  local file="$STATE/$1.status"
  printf '%s\n' "$2" >> "$file" || die "cannot append to $file"
  [ ! -e "$CONFIG/fleet-ledger" ] || "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$file" >/dev/null 2>&1 || true
}

theme_of() {  # <finding line>
  local line=$1 tok
  tok=$(printf '%s\n' "$line" | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | head -1 || true)
  if [ -n "$tok" ]; then printf '%s\n' "$tok"; return; fi
  printf '%s\n' "$line" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' ' ' | awk '{ print $1, $2, $3, $4 }'
}

themes_of_file() {  # <findings file>: unique themes, one per line
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "${line//[[:space:]]/}" ] || continue
    theme_of "$line"
  done < "$1" | sort -u
}

parse_ids() {  # <task-id> <run> <step>
  valid_word "$1" || die "invalid task id '$1'"
  valid_word "$2" || die "invalid run id '$2'"
  valid_word "$3" || die "invalid step '$3'"
}

cmd_fix() {
  [ $# -ge 3 ] || die "usage: fix <task-id> <run> <step> [--findings FILE]"
  local id=$1 run=$2 step=$3 findings=""
  shift 3
  parse_ids "$id" "$run" "$step"
  while [ $# -gt 0 ]; do
    case "$1" in
      --findings) findings=${2:?--findings needs a file}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -z "$findings" ] || [ -f "$findings" ] || die "findings file not found: $findings"

  local cap log used themes=""
  cap=$(cap_value) || exit 2
  log="$STATE/$id.fix-rounds"
  used=$(awk -F'\t' -v r="$run" -v s="$step" '$1 == r && $2 == s { n++ } END { print n + 0 }' "$log" 2>/dev/null || echo 0)
  [ -z "$findings" ] || themes=$(themes_of_file "$findings")

  if [ "$used" -lt "$cap" ]; then
    mkdir -p "$STATE" || die "cannot create $STATE"
    printf '%s\t%s\t%s\t%s\n' "$run" "$step" "$((used + 1))" "$(printf '%s' "$themes" | paste -sd, -)" >> "$log"
    echo "fix-allowed: round $((used + 1)) of $cap"
    return 0
  fi

  local snap_dir="$DATA/$id" snap repeated
  snap="$snap_dir/nm-$run-$step-rounds.txt"
  mkdir -p "$snap_dir" || die "cannot create $snap_dir"
  # Themes seen in an earlier round and again now (or in two earlier rounds).
  repeated=$({
    awk -F'\t' -v r="$run" -v s="$step" '$1 == r && $2 == s { n = split($4, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") print a[i] }' "$log" 2>/dev/null
    printf '%s\n' "$themes"
  } | grep -v '^$' | sort | uniq -c | awk '$1 > 1 { $1 = ""; sub(/^ /, ""); print }' || true)
  {
    echo "step: $step"
    echo "run: $run"
    echo "fix rounds already sent: $used (cap $cap)"
    echo "repeated finding themes:"
    if [ -n "$repeated" ]; then printf '%s\n' "$repeated" | sed 's/^/  - /'; else echo "  (none)"; fi
    echo "remaining findings:"
    if [ -n "$findings" ]; then sed 's/^/  /' "$findings"; else echo "  (not supplied)"; fi
  } > "$snap"
  append_status "$id" "needs-decision [at=$(date +%s)] [key=nm-$run-$step-cap]: $step fix-round cap reached after $used of $cap rounds; not sending another fix. details file=$snap"
  echo "capped: $used fix rounds already sent on $step (cap $cap); needs-decision recorded, stop and wait for firstmate" >&2
  return 3
}

cmd_timeout() {
  [ $# -ge 3 ] || die "usage: timeout <task-id> <run> <step> [--error TEXT]"
  local id=$1 run=$2 step=$3 err=""
  shift 3
  parse_ids "$id" "$run" "$step"
  while [ $# -gt 0 ]; do
    case "$1" in
      --error) err=${2:?--error needs text}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  if [ -n "$err" ] && ! printf '%s\n' "$err" | grep -qiE 'timed out|timeout|deadline exceeded|wall[- ]?clock|30[- ]?minute'; then
    echo "not an agent timeout: nothing recorded" >&2
    return 1
  fi
  append_status "$id" "needs-decision [at=$(date +%s)] [key=nm-$run-$step-timeout]: $step step failed with an agent timeout (30-minute limit); not retrying, decide whether to retry or narrow the work"
  echo "timeout recorded: needs-decision written, stop and wait for firstmate" >&2
  return 3
}

cmd_brief_rule() {
  [ $# -eq 1 ] || die "usage: brief-rule <task-id>"
  valid_word "$1" || die "invalid task id '$1'"
  local cap me
  cap=$(cap_value) || exit 2
  me="'$SCRIPT_DIR/fm-review-round-cap.sh'"
  cat <<RULE
Review fix rounds are capped at $cap per run and step, and an agent timeout goes straight to firstmate:
- Before you answer any review gate with \`fix\`, write its remaining findings one per line to a scratch file and run \`FM_HOME='$FM_HOME' $me fix $1 <run> <step> --findings <file>\`.
  Exit 0 means send the fix.
  Exit 3 means the cap is reached and a needs-decision is already recorded: stop, send nothing, and wait for firstmate's reply.
- When a review or test step fails with an agent timeout (the 30-minute limit), run \`FM_HOME='$FM_HOME' $me timeout $1 <run> <step> --error "<the failure text>"\`, then stop on exit 3.
  Never retry a timed-out step silently.
RULE
}

case "${1:-}" in
  fix) shift; cmd_fix "$@" ;;
  timeout) shift; cmd_timeout "$@" ;;
  cap) cap_value ;;
  brief-rule) shift; cmd_brief_rule "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
