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
#   fm_noise_span_quiet <state-dir> <task> <events>
#       0 when every event in the span is a known wait already announced and not yet
#       over. A wait seen for the first time is recorded here and makes the span loud.
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

fm_noise_span_quiet() {  # <state-dir> <task> <events>
  local state=$1 task=$2 events=$3 dir ev wait scope epoch key rec now quiet=0 seen=0 rest
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
      if fm_noise_open_problem_repeat "$state" "$task" "$ev"; then quiet=$((quiet + 1)); fi
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
# not a missed reply. fm_noise_task_recently_active <state-dir> <task> <now>: 0 when the
# task's latest sign of life is within FM_NOISE_ACTIVE_SECS (default 1200) of <now>.
# A sign of life is a status line stamped [at=N] or a turn event in the mate home's task ledger.
fm_noise_task_recently_active() {
  local state=$1 task=$2 now=$3 window=${FM_NOISE_ACTIVE_SECS:-1200} latest=0 at home f
  case "$window" in '' | *[!0-9]*) window=1200 ;; esac
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
  [ "$latest" -gt 0 ] && [ $((now - latest)) -le "$window" ] && [ "$latest" -le "$now" ]
}

# Open problems (step 5). A blocked or needs-decision line with a key opens a problem; the same
# key stated again while the problem is still open adds nothing, so it stays quiet and is
# counted instead. A "resolved" line for the key closes the problem, and the next line for the
# key is a new problem. Outcome keys are one report each and never coalesce.
# The count of held repeats lives in state/wake-noise/problem-<cksum>, as "<announced-at> <repeats> <key>".
fm_noise_event_key() {  # <event>: the [key=...] of a blocked or needs-decision line
  local ev=$1 verb re='\[key=([^]]+)\]'
  verb=${ev%%[[:space:]]*}
  case "$verb" in blocked | needs-decision) ;; *) return 1 ;; esac
  [[ "$ev" =~ $re ]] || return 1
  case "${BASH_REMATCH[1]}" in branch-outcome-* | child-outcome-*) return 1 ;; esac
  printf '%s' "${BASH_REMATCH[1]}"
}

# fm_noise_open_problem_repeat <state-dir> <task> <event>: 0 for a repeat of an open problem
# (counted, to stay quiet); 1 for a new problem or any other event (recorded as announced).
fm_noise_open_problem_repeat() {
  local state=$1 task=$2 ev=$3 key at rec dir sum announced repeats rest re='\[at=([0-9]+)\]'
  key=$(fm_noise_event_key "$ev") || return 1
  at=0; [[ "$ev" =~ $re ]] && at=${BASH_REMATCH[1]}
  dir="$state/wake-noise"
  sum=$(printf '%s|%s' "$task" "$key" | cksum | cut -d' ' -f1)
  rec="$dir/problem-$sum"
  if [ -f "$rec" ]; then
    read -r announced repeats rest < "$rec" || true
    case "$announced$repeats" in *[!0-9]* | '') announced=0; repeats=0 ;; esac
    # Still open when no resolved line for the key came after the announcement.
    if ! fm_noise_key_resolved_after "$state/$task.status" "$key" "$announced"; then
      printf '%s %s %s\n' "$announced" "$((repeats + 1))" "$key" > "$rec" 2>/dev/null || return 1
      return 0
    fi
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s 0 %s\n' "$at" "$key" > "$rec" 2>/dev/null || return 1
  return 1
}

# fm_noise_key_resolved_after <status-file> <key> <epoch>: 0 when a resolved line for the key is stamped later.
fm_noise_key_resolved_after() {
  local f=$1 key=$2 since=$3 line at re='\[at=([0-9]+)\]'
  [ -f "$f" ] || return 1
  while IFS= read -r line; do
    case "$line" in resolved*"[key=$key]"*) ;; *) continue ;; esac
    at=0; [[ "$line" =~ $re ]] && at=${BASH_REMATCH[1]}
    [ "$at" -ge "$since" ] && return 0
  done < <(grep -F "[key=$key]" "$f" 2>/dev/null)
  return 1
}
