#!/usr/bin/env bash
# Fork-only: fm-task-ledger.sh - the append-only per-task event ledger (applypass fork).
#
# usage:
#   fm-task-ledger.sh record <id> <event> [--at EPOCH] [--session ID] [--note TEXT] [--once]
#   fm-task-ledger.sh show <id>
#   fm-task-ledger.sh require <spawn|merge> <id>
#   fm-task-ledger.sh has <id> <event>
#   fm-task-ledger.sh wait-start <id> [--at EPOCH] [--note TEXT]
#   fm-task-ledger.sh wait-end <id> [--at EPOCH]
#   fm-task-ledger.sh summary <id> [--now EPOCH]
#
# record   appends one JSON line {at, event, session, note} to
#          data/ticket-ledger/<id>.jsonl in the firstmate home. The file is
#          append-only, lives in data/ rather than state/, and so outlives the
#          task's cleanup. --session defaults to $FM_LEDGER_SESSION, then
#          $CLAUDE_SESSION_ID, then "none"; --at defaults to now. --once
#          appends nothing when the task already has that event.
# show     prints the task's events, oldest first.
# require  exits 0 when the events a step needs are all recorded and 1 when one
#          is missing. The refusal names each missing event and the one command
#          that records it. spawn needs intake-start and planning-done; merge
#          needs pr-ready and captain-approval. The gate is on by default:
#          FM_TASK_LEDGER=off turns it off, and tests/lib.sh sets that for
#          fixtures that do not model the ledger.
#
# has      exits 0 when the task has that event.
# wait-start / wait-end  record captain-wait-start and captain-wait-end. The
#          captain wait clock runs from the recorded ask to the recorded
#          answer on the wall clock, away time included; a second ask before
#          the answer does not restart it. An answer to an ask opened after
#          pr-ready also records captain-approval at the answer time, because
#          the only ask left once the work is ready is the merge call.
#          bin/fm-captain-hold.sh calls them around hold and answer.
# summary  prints key=value lines from the events: captain_wait_seconds,
#          open_captain_wait, grill_seconds, blocked_seconds, planning_seconds
#          (intake-start to planning-done, less the grill and captain wait
#          inside it). An open interval counts up to --now (default now).
#
# Events: intake-start grill-start grill-end planning-done spawn first-action
# pr-open check-start pr-ready captain-approval captain-wait-start
# captain-wait-end merged turn blocked-start blocked-end.
#
# Callers: bin/fm-spawn.sh (require spawn, then spawn), bin/fm-pr-merge.sh and
# bin/fm-merge-local.sh (require merge, then merged). docs/configuration.md
# "Task ledger" owns the operator view.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)

EVENTS="intake-start grill-start grill-end planning-done spawn first-action pr-open check-start pr-ready captain-approval captain-wait-start captain-wait-end merged turn blocked-start blocked-end"

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

fm_ledger_home() { printf '%s' "${FM_HOME:-$ROOT}"; }
fm_ledger_dir() { printf '%s/ticket-ledger' "${FM_DATA_OVERRIDE:-$(fm_ledger_home)/data}"; }
fm_ledger_file() { printf '%s/%s.jsonl' "$(fm_ledger_dir)" "$1"; }

valid_id() { case "$1" in '' | */* | .* | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }
valid_event() { case " $EVENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

die_usage() { echo "error: $1" >&2; exit 2; }

fm_ledger_record() {  # <id> <event> [--at E] [--session S] [--note T]
  local id=$1 event=$2 at='' session='' note='' once=0 file line
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --at) [ "$#" -gt 1 ] || die_usage "--at needs a value"; at=$2; shift 2 ;;
      --session) [ "$#" -gt 1 ] || die_usage "--session needs a value"; session=$2; shift 2 ;;
      --note) [ "$#" -gt 1 ] || die_usage "--note needs a value"; note=$2; shift 2 ;;
      --once) once=1; shift ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done
  valid_id "$id" || die_usage "invalid task id: $id"
  valid_event "$event" || die_usage "unknown event '$event'; one of: $EVENTS"
  [ -n "$at" ] || at=$(date +%s)
  case "$at" in '' | *[!0-9]*) die_usage "--at must be epoch seconds" ;; esac
  [ -n "$session" ] || session=${FM_LEDGER_SESSION:-${CLAUDE_SESSION_ID:-none}}
  note=${note:0:500}
  command -v jq >/dev/null 2>&1 || { echo "fm-task-ledger: jq is required" >&2; exit 1; }
  file=$(fm_ledger_file "$id")
  [ "$once" -eq 0 ] || ! fm_ledger_has "$id" "$event" || return 0
  mkdir -p "$(dirname "$file")" || exit 1
  line=$(jq -nc --argjson at "$at" --arg event "$event" --arg session "$session" --arg note "$note" \
    '{at: $at, event: $event, session: $session} + (if $note == "" then {} else {note: $note} end)') || exit 1
  # One short write to an O_APPEND descriptor is atomic, so concurrent
  # recorders never interleave lines and no lock is needed.
  printf '%s\n' "$line" >> "$file"
}

fm_ledger_has() {  # <id> <event>
  local file
  file=$(fm_ledger_file "$1")
  [ -s "$file" ] && jq -e --arg e "$2" 'select(.event == $e)' "$file" >/dev/null 2>&1
}

fm_ledger_require() {  # <spawn|merge> <id>
  local step=$1 id=$2 need missing=0 event
  [ "${FM_TASK_LEDGER:-}" != off ] || return 0
  case "$step" in
    spawn) need="intake-start planning-done" ;;
    merge) need="pr-ready captain-approval" ;;
    *) die_usage "require needs spawn or merge" ;;
  esac
  valid_id "$id" || die_usage "invalid task id: $id"
  for event in $need; do
    fm_ledger_has "$id" "$event" && continue
    missing=1
    printf 'task ledger: task %s has no %s event, so %s is refused; record it with: bin/fm-task-ledger.sh record %s %s\n' \
      "$id" "$event" "$step" "$id" "$event" >&2
  done
  [ "$missing" -eq 0 ]
}

fm_ledger_wait_end() {  # <id> [--at E]
  local id=$1 at='' opened_at ready_at
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --at) [ "$#" -gt 1 ] || die_usage "--at needs a value"; at=$2; shift 2 ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done
  [ -n "$at" ] || at=$(date +%s)
  # The ask that opened this wait: the first captain-wait-start after the last answer.
  opened_at=$(fm_ledger_open_wait_start "$id")
  fm_ledger_record "$id" captain-wait-end --at "$at"
  [ -n "$opened_at" ] || return 0
  ready_at=$(jq -rs '[.[] | select(.event == "pr-ready") | .at] | min // empty' "$(fm_ledger_file "$id")")
  if [ -n "$ready_at" ] && [ "$ready_at" -le "$opened_at" ]; then
    fm_ledger_record "$id" captain-approval --at "$at" --note "answer to the ask opened after pr-ready"
  fi
}

fm_ledger_open_wait_start() {  # <id>: epoch of the open ask, empty when none
  local file
  file=$(fm_ledger_file "$1")
  [ -s "$file" ] || return 0
  jq -rs 'sort_by(.at) | reduce .[] as $e (null;
      if $e.event == "captain-wait-start" then (. // $e.at)
      elif $e.event == "captain-wait-end" then null else . end) // empty' "$file"
}

fm_ledger_summary() {  # <id> [--now E]
  local id=$1 now='' file
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --now) [ "$#" -gt 1 ] || die_usage "--now needs a value"; now=$2; shift 2 ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done
  [ -n "$now" ] || now=$(date +%s)
  valid_id "$id" || die_usage "invalid task id: $id"
  file=$(fm_ledger_file "$id")
  [ -s "$file" ] || { printf 'captain_wait_seconds=0\nopen_captain_wait=0\ngrill_seconds=0\nblocked_seconds=0\nplanning_seconds=0\n'; return 0; }
  jq -rs --argjson now "$now" '
    sort_by(.at) as $ev
    | def intervals($s; $e):
        (reduce $ev[] as $x ({open: null, out: []};
          if $x.event == $s then (if .open == null then .open = $x.at else . end)
          elif $x.event == $e and .open != null then (.out += [[.open, $x.at]] | .open = null)
          else . end)) as $r
        | {list: ($r.out + (if $r.open != null then [[$r.open, $now]] else [] end)), open: ($r.open != null)};
      def total: map(.[1] - .[0]) | add // 0;
      def inside($a; $b): map([(if .[0] > $a then .[0] else $a end), (if .[1] < $b then .[1] else $b end)] | select(.[1] > .[0]));
      intervals("captain-wait-start"; "captain-wait-end") as $w
    | intervals("grill-start"; "grill-end") as $g
    | intervals("blocked-start"; "blocked-end") as $b
    | ([$ev[] | select(.event == "intake-start") | .at] | min) as $in
    | ([$ev[] | select(.event == "planning-done") | .at] | min) as $pd
    | (if $in != null and $pd != null and $pd > $in
        then (($pd - $in) - ($g.list | inside($in; $pd) | total) - ($w.list | inside($in; $pd) | total))
        else 0 end) as $plan
    | "captain_wait_seconds=\($w.list | total)",
      "open_captain_wait=\(if $w.open then 1 else 0 end)",
      "grill_seconds=\($g.list | total)",
      "blocked_seconds=\($b.list | total)",
      "planning_seconds=\($plan)"' "$file"
}

CMD=${1:-}
[ -n "$CMD" ] || { usage >&2; exit 2; }
shift
case "$CMD" in
  -h | --help) usage; exit 0 ;;
  record)
    [ "$#" -ge 2 ] || die_usage "record needs <id> <event>"
    fm_ledger_record "$@"
    ;;
  show)
    [ "$#" -eq 1 ] || die_usage "show needs <id>"
    valid_id "$1" || die_usage "invalid task id: $1"
    [ -f "$(fm_ledger_file "$1")" ] || exit 0
    jq -r '"\(.at) \(.event) \(.session)\(if .note then " " + .note else "" end)"' "$(fm_ledger_file "$1")"
    ;;
  require)
    [ "$#" -eq 2 ] || die_usage "require needs <spawn|merge> <id>"
    fm_ledger_require "$@"
    ;;
  has)
    [ "$#" -eq 2 ] || die_usage "has needs <id> <event>"
    fm_ledger_has "$1" "$2"
    ;;
  wait-start)
    [ "$#" -ge 1 ] || die_usage "wait-start needs <id>"
    id=$1
    shift
    fm_ledger_record "$id" captain-wait-start "$@"
    ;;
  wait-end)
    [ "$#" -ge 1 ] || die_usage "wait-end needs <id>"
    fm_ledger_wait_end "$@"
    ;;
  summary)
    [ "$#" -ge 1 ] || die_usage "summary needs <id>"
    fm_ledger_summary "$@"
    ;;
  *) usage >&2; exit 2 ;;
esac
