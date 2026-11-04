#!/usr/bin/env bash
# Fork-only: fm-wake-noise-lib.sh - cut supervisor wakes that carry no new fact (applypass fork).
#
# Sourced by bin/fm-watch.sh. Each wake costs the supervisor one turn, so a notice
# that adds nothing to what the supervisor already knows should not cost one.
#
# Known waits (step 3). A blocked or paused line that names when it ends, either
# "external-wait until=<UTC>" or a note carrying "until <UTC>" (the daily quota stop),
# is a known wait. The first sight of one wakes the supervisor with its clear time.
# The same wait seen again before that time stays quiet: no wake. The daily quota cap
# is one wait for the whole fleet; any other wait belongs to its task.
#
#   fm_noise_span_quiet <state-dir> <task> <events> <span-start-offset>
#       0 when every event in the span is a known wait already announced and not yet
#       over, or a repeat of an open problem. A wait seen for the first time is
#       recorded here and makes the span loud.
#
# Records live under <state-dir>/wake-noise/. They are plain files holding the clear
# time as epoch seconds; an expired one is overwritten on the next look.

fm_noise_iso_epoch() {  # <YYYY-MM-DDTHH:MMZ>: epoch seconds, empty when unparsable
  local v=$1 out
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z) v="${v%Z}:00Z" ;;
  esac
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  out=$(date -u -d "$v" +%s 2>/dev/null) || out=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$v" +%s 2>/dev/null) || return 1
  printf '%s' "$out"
}

# fm_noise_known_wait <task> <event>: prints "<scope-key>|<clear-epoch>" for a known wait.
fm_noise_known_wait() {
  local task=$1 event=$2 verb note stamp epoch scope
  verb=${event%%[[:space:]]*}
  case "$verb" in blocked | paused) ;; *) return 1 ;; esac
  note=${event#*: }
  note=${note#system: }
  local re='(until[ =])([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z)'
  if [[ "$note" =~ $re ]]; then
    stamp=${BASH_REMATCH[2]}
  else
    return 1
  fi
  case "$note" in
    external-wait* | resource-exhausted* | *'daily quota stop'*) ;;
    *) return 1 ;;
  esac
  epoch=$(fm_noise_iso_epoch "$stamp") || return 1
  case "$note" in
    *'(daily quota cap)'* | *'daily quota stop'*) scope=daily-quota-cap ;;
    *) scope="$task" ;;
  esac
  printf '%s|%s' "$scope" "$epoch"
}

fm_noise_span_quiet() {  # <state-dir> <task> <events> <span-start-offset>
  local state=$1 task=$2 events=$3 start=${4:-0} dir ev wait scope epoch key rec now quiet=0 seen=0 rest open folded=0
  dir="$state/wake-noise"
  now=$(date +%s)
  rest=$events
  while [ -n "$rest" ]; do
    case "$rest" in
      *' ; '*) ev=${rest%% ; *}; rest=${rest#* ; } ;;
      *) ev=$rest; rest='' ;;
    esac
    # Any other event keeps the span loud; a known wait beside it still counts as announced.
    if ! wait=$(fm_noise_known_wait "$task" "$ev"); then
      seen=$((seen + 1))
      if [ "$folded" -eq 0 ] && fm_noise_event_key "$ev" >/dev/null; then
        open=$(fm_noise_open_before "$state/$task.status" "$start") || return 1
        folded=1
      fi
      if [ "$folded" -eq 1 ] && fm_noise_open_problem_repeat "$state" "$task" "$ev" "$open"; then quiet=$((quiet + 1)); fi
      continue
    fi
    scope=${wait%%|*}; epoch=${wait#*|}
    key=$(printf '%s|%s' "$scope" "$epoch" | cksum | cut -d' ' -f1)
    rec="$dir/known-wait-$key"
    seen=$((seen + 1))
    if [ -f "$rec" ] && [ "$now" -lt "$epoch" ]; then
      quiet=$((quiet + 1))
    else
      mkdir -p "$dir" 2>/dev/null || return 1
      printf '%s\n' "$epoch" > "$rec" 2>/dev/null || return 1
    fi
  done
  [ "$seen" -gt 0 ] && [ "$quiet" -eq "$seen" ]
}

# Recent activity (step 4). A mate that answered "working" and has done something since is
# not a missed reply. fm_noise_task_recently_active <state-dir> <task> <now> [<since>]: 0 when the
# task's latest sign of life is within FM_NOISE_ACTIVE_SECS (default 1200) of <now> and after <since>.
# A sign of life is a status line stamped [at=N] or a turn event in the mate home's task ledger.
fm_noise_task_recently_active() {
  local state=$1 task=$2 now=$3 since=${4:-0} window=${FM_NOISE_ACTIVE_SECS:-1200} latest=0 at home f
  case "$window" in '' | *[!0-9]*) window=1200 ;; esac
  case "$since" in '' | *[!0-9]*) since=0 ;; esac
  [ -n "$task" ] && [ -n "$now" ] || return 1
  if [ -f "$state/$task.status" ]; then
    # The system's own lines (machine keys, system: notes) are not the mate's activity.
    at=$(tail -n 20 "$state/$task.status" 2>/dev/null \
      | grep -Ev '\[key=(pending-reply|remote-reply-continuity|branch-outcome|child-outcome|captain-hold)-|\]: system:' \
      | grep -o '\[at=[0-9]*\]' | tr -dc '0-9\n' | sort -n | tail -1)
    [ -z "$at" ] || latest=$at
  fi
  if [ -f "$state/$task.meta" ]; then
    home=$(sed -n 's/^home=//p' "$state/$task.meta" | head -1)
    if [ -n "$home" ] && [ -d "$home/data/ticket-ledger" ]; then
      for f in "$home"/data/ticket-ledger/*.jsonl; do
        [ -f "$f" ] || continue
        at=$(grep '"event":"turn"' "$f" 2>/dev/null | tail -n 1 | sed -n 's/.*"at":\([0-9][0-9]*\).*/\1/p')
        [ -z "$at" ] || [ "$at" -le "$latest" ] || latest=$at
      done
    fi
  fi
  [ "$latest" -gt "$since" ] && [ $((now - latest)) -le "$window" ] && [ "$latest" -le "$now" ]
}

# Open problems (step 5). A blocked or needs-decision line with a key opens a problem. The shared
# decision fold (status_open_decisions in bin/fm-classify-lib.sh) owns open and closed: a line is a
# repeat only when the fold over the status bytes before its span already holds its key open with
# the same verb and note. Anything that closes the key there (resolved, captain-held, a terminal
# done/failed) or a new status file makes the next line a new problem, and a changed verb or note
# is a new fact. Outcome keys are one report each and never coalesce.
# The count of held repeats lives in state/wake-noise/problem-<cksum>, as "<repeats> <key>".
fm_noise_event_key() {  # <event>: the [key=...] of a blocked or needs-decision line
  local ev=$1 verb key
  status_line_verb "$ev" verb
  case "$verb" in blocked | needs-decision) ;; *) return 1 ;; esac
  key=$(_fm_decision_key "$ev" '')
  case "$key" in '' | branch-outcome-* | child-outcome-*) return 1 ;; esac
  printf '%s' "$key"
}

fm_noise_open_before() {  # <status-file> <offset>: the shared fold's open set over the bytes before <offset>
  local f=$1 off=$2 tmp
  case "$off" in '' | *[!0-9]*) return 0 ;; esac
  [ -f "$f" ] && [ "$off" -gt 0 ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-noise-open.XXXXXX") || return 1
  head -c "$off" "$f" > "$tmp" 2>/dev/null && status_open_decisions "$tmp" "$(_fm_status_kind "$f")"
  rm -f "$tmp"
}

# fm_noise_open_problem_repeat <state-dir> <task> <event> <open-set>: 0 for a repeat of an open
# problem (counted, to stay quiet); 1 for a new problem or any other event.
fm_noise_open_problem_repeat() {
  local state=$1 task=$2 ev=$3 open=$4 key verb note rec dir repeats rest
  key=$(fm_noise_event_key "$ev") || return 1
  status_line_verb "$ev" verb
  note=$(status_line_note "$ev")
  dir="$state/wake-noise"
  rec="$dir/problem-$(printf '%s|%s' "$task" "$key" | cksum | cut -d' ' -f1)"
  case $'\n'"$open"$'\n' in
    *$'\n'"$key"$'\t'"$verb"$'\t'"$note"$'\n'*) ;;
    *) rm -f "$rec" 2>/dev/null; return 1 ;;
  esac
  repeats=0
  [ ! -f "$rec" ] || read -r repeats rest < "$rec" || true
  case "$repeats" in '' | *[!0-9]*) repeats=0 ;; esac
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s %s\n' "$((repeats + 1))" "$key" > "$rec" 2>/dev/null || return 1
  return 0
}

# Routine notices (step 6). A "done" line for a child outcome (key child-outcome-*) says a piece
# of delegated work finished and needs no decision. It should not cost a turn by itself, so a span
# made only of such lines is held: the watcher marks it seen, but remembers where the held span
# began, and the next span is read from there. It carries the held notices together with whatever
# real event comes next. A hold ends after FM_NOISE_HOLD_SECS (default 1800) so a lone routine
# notice still arrives.
#
#   fm_noise_held_expired <state-dir> <task> [<now>]
#       0 when the task holds a span past the hold limit; the watcher then reads the file
#       again even with no new bytes, so the held notices arrive on their own.
#   fm_noise_held_start <state-dir> <task> <seen-offset>
#       the offset to read the next span from: where the held span began, else <seen-offset>.
#   fm_noise_span_routine <state-dir> <task> <events> <span-start-offset>
#       0 when every event is routine and the oldest held one is younger than the hold limit.
#       The first held span records its start; a loud span clears the hold.
#   fm_noise_span_held_by_captain <state-dir> <task> <status-file> <span-start-offset>
#       0 when the span holds a captain-held transfer. The classifier reports that only as a
#       needs-decision marker, never as an event, so no noise cut may absorb such a span; the
#       span wakes and any hold on the task ends with it.
fm_noise_span_held_by_captain() {  # <state-dir> <task> <status-file> <span-start-offset>
  local line start=${4:-0}
  case "$start" in '' | *[!0-9]*) start=0 ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    status_is_captain_held "$line" || continue
    rm -f "$1/wake-noise/held-$2" 2>/dev/null
    return 0
  done < <(tail -c "+$((start + 1))" "$3" 2>/dev/null)
  return 1
}

fm_noise_event_is_routine() {  # <event>
  case "$1" in
    done\ *"[key=child-outcome-"*) return 0 ;;
  esac
  return 1
}

fm_noise_held_expired() {  # <state-dir> <task> [<now>]
  local rec="$1/wake-noise/held-$2" now=${3:-} first hold=${FM_NOISE_HOLD_SECS:-1800}
  case "$hold" in '' | *[!0-9]*) hold=1800 ;; esac
  [ -f "$rec" ] || return 1
  read -r first _ < "$rec" || true
  case "$first" in '' | *[!0-9]*) return 0 ;; esac
  [ -n "$now" ] || now=$(date +%s)
  [ $((now - first)) -ge "$hold" ]
}

fm_noise_held_start() {  # <state-dir> <task> <seen-offset>
  local rec="$1/wake-noise/held-$2" first start
  if [ -f "$rec" ]; then
    read -r first start < "$rec" || true
    case "$start" in '' | *[!0-9]*) ;; *) [ "$start" -le "$3" ] && { printf '%s' "$start"; return 0; } ;; esac
  fi
  printf '%s' "$3"
}

fm_noise_span_routine() {  # <state-dir> <task> <events> <span-start-offset>
  local state=$1 task=$2 events=$3 start=$4 ev rest dir rec now seen=0
  dir="$state/wake-noise"
  rec="$dir/held-$task"
  rest=$events
  while [ -n "$rest" ]; do
    case "$rest" in
      *' ; '*) ev=${rest%% ; *}; rest=${rest#* ; } ;;
      *) ev=$rest; rest='' ;;
    esac
    fm_noise_event_is_routine "$ev" || { rm -f "$rec" 2>/dev/null; return 1; }
    seen=$((seen + 1))
  done
  [ "$seen" -gt 0 ] || return 1
  now=$(date +%s)
  if [ -f "$rec" ]; then
    if fm_noise_held_expired "$state" "$task" "$now"; then rm -f "$rec" 2>/dev/null; return 1; fi
  else
    mkdir -p "$dir" 2>/dev/null || return 1
    printf '%s %s\n' "$now" "$start" > "$rec" 2>/dev/null || return 1
  fi
  return 0
}
