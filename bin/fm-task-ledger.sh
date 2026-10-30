#!/usr/bin/env bash
# Fork-only: fm-task-ledger.sh - the append-only per-task event ledger (applypass fork).
#
# usage:
#   fm-task-ledger.sh record <id> <event> [--at EPOCH] [--session ID] [--note TEXT] [--once]
#   fm-task-ledger.sh show <id>
#   fm-task-ledger.sh require <spawn|merge> <id>
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
  *) usage >&2; exit 2 ;;
esac
