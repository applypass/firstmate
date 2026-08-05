#!/usr/bin/env bash
# ONE owner of "is the session holding this home's helm actually working, and may
# a fresh session take it?".
#
# WHY: the session lock used to test only whether the holder's process was alive.
# A forked or resumed background window stays alive indefinitely while doing
# nothing, and because watcher continuity is repaired at turn end, a holder that
# never ends a turn never repairs it either. The captain lost hours of monitoring
# to exactly that: a live holder, a dead fleet, and a fresh session that could
# only refuse. Liveness is not activity.
#
# TWO INDEPENDENT PROOFS, BOTH REQUIRED for an automatic takeover:
#   SILENCE     - measurable, from the turn-end activity marker this lib stamps.
#   UNATTENDED  - the holder has no controlling terminal at all.
# A timer alone is never sufficient. An attended session that has simply been
# quiet keeps the helm, and the refusal names what holds it and how to clear it.
#
# FAIL-CLOSED ON EVIDENCE: silence is measured ONLY from positive proof of work -
# the marker this lib stamps, and the transcript that marker names. Absence of
# evidence is never read as silence. The session lock is deliberately NOT an
# evidence source: bin/fm-lock.sh writes state/.lock once at acquisition and
# nothing anywhere refreshes it, so its mtime is the session's AGE, not its
# quietness, and a live busy holder measured as 7200s silent through it. A holder
# that cannot prove it is working therefore keeps the helm, and the captain
# clears it by hand with the command the refusal prints.
#
# ONE DEFINITION OF ADMISSIBLE EVIDENCE, and it is enforced at the WRITE: a
# marker is only ever written with a transcript that exists, so no reader needs a
# second gate. When a stamp is refused, the reason is recorded beside the marker
# and a later refusal quotes it, because a safety mechanism that quietly stops
# working is worse than one that never ran.
#
# WHY "no controlling terminal" is the unattended proof: a harness the captain is
# sitting in front of owns a terminal device and is the foreground process group
# of it, while any session the harness itself forked inherits neither. Measured
# on this fleet: an attended primary reads `ttys005 S+` from
# `ps -o tty=,stat=`, and a process spawned by that session's own tool calls
# reads `?? Ss`. The tty is the conservative half of that pair and is the only
# gate here: a named terminal always means "refuse", whatever the process-group
# flag says, because handing the helm away from a session someone is using is far
# worse than one extra refusal. docs/session-handover.md owns the tradeoff and
# docs/verification/session-handover.md records the measurement.
#
# Every unreadable input degrades to "attended" or "unmeasurable", never to a
# takeover, so an unprovable case always refuses.
#
# This file is sourced by scripts and has no side effects on source.
# It expects fm-wake-lib.sh (fm_path_mtime) to be sourced by the caller.

# Seconds of silence a provably unattended holder must accumulate before a fresh
# session may take the helm. Deliberately long: a takeover is a loud, rare event.
FM_HELM_IDLE_TAKEOVER_DEFAULT=1800

fm_helm_idle_threshold() {
  local secs=${FM_HELM_IDLE_TAKEOVER:-$FM_HELM_IDLE_TAKEOVER_DEFAULT}
  case "$secs" in
    ''|*[!0-9]*|0) secs=$FM_HELM_IDLE_TAKEOVER_DEFAULT ;;
  esac
  printf '%s\n' "$secs"
}

# fm_helm_marker <state>: path of the turn-end activity marker.
fm_helm_marker() {
  printf '%s\n' "$1/.helm-activity"
}

# fm_helm_declination <state>: path of the record saying why the last stamp was
# declined. It sits beside the marker and is overwritten, never appended: one
# current answer to "why is there no marker", not a log nobody prunes.
fm_helm_declination() {
  printf '%s\n' "$1/.helm-activity-declined"
}

# fm_helm_record_declination <state> <pid> <reason>: remember that a stamp was
# refused and why. Written atomically for the same reason the marker is, and
# every failure is silent: the caller is a turn-end hook that must never wedge a
# session, and a missing declination record only costs an explanation.
fm_helm_record_declination() {
  local state=$1 pid=$2 reason=$3 path tmp
  path=$(fm_helm_declination "$state")
  [ -d "$state" ] || return 1
  tmp="$path.tmp.$$"
  if ! {
    printf 'pid=%s\n' "$pid"
    printf 'epoch=%s\n' "$(date +%s 2>/dev/null || printf 0)"
    printf 'at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf unknown)"
    printf 'reason=%s\n' "$reason"
  } > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# fm_helm_declination_note <state>: one captain-readable clause naming the last
# declined stamp and its reason, or non-zero when nothing was declined. This is
# what a refusal quotes, so "why did this not take the helm" is answerable from
# the refusal itself rather than from a file the reader has to know about.
fm_helm_declination_note() {
  local state=$1 path reason pid at
  path=$(fm_helm_declination "$state")
  [ -s "$path" ] || return 1
  reason=$(sed -n 's/^reason=//p' "$path" 2>/dev/null | head -1)
  [ -n "$reason" ] || return 1
  pid=$(sed -n 's/^pid=//p' "$path" 2>/dev/null | head -1)
  at=$(sed -n 's/^at=//p' "$path" 2>/dev/null | head -1)
  printf 'pid %s declined to stamp one at %s: %s\n' \
    "${pid:-unknown}" "${at:-unknown}" "$reason"
}

# fm_helm_stamp <state> <pid> <transcript>: record that the holder just finished
# a turn. The transcript path is recorded, not copied, so a later silence check
# can see mid-turn growth in it and not mistake a busy session for an idle one.
# A write failure is never fatal: a missing marker only costs measurability, and
# the caller is a turn-end hook that must never wedge a session.
#
# A MARKER ALWAYS NAMES A RESOLVABLE TRANSCRIPT, and that is enforced here so
# that admissible evidence has exactly one definition, in this file. Without the
# transcript, silence rests on the marker's mtime alone, which proves a turn
# ENDED once and not that the session is working now: a holder genuinely working
# through one turn longer than the threshold would measure as silent and lose the
# helm mid-turn. So a stamp with no resolvable transcript is refused outright,
# the refusal is recorded next to the marker, and the holder degrades to
# unmeasurable - which keeps the helm, the fail-closed direction.
#
# The write is ATOMIC - built in a temp file beside the marker and moved into
# place - so a concurrent reader sees either the whole previous marker or the
# whole new one. A truncating redirect leaves the marker zero-length for the
# width of the fork that produces the timestamp, and an empty marker reads as
# "this holder cannot prove it is working", which is a takeover decision made on
# a race. On any failure the temp file goes and the existing marker stands.
fm_helm_stamp() {
  local state=$1 pid=$2 transcript=${3:-} marker tmp now reason=
  marker=$(fm_helm_marker "$state")
  [ -d "$state" ] || return 1
  if [ -z "$transcript" ]; then
    if command -v jq >/dev/null 2>&1; then
      reason='the turn-end payload carried no transcript path'
    else
      reason='jq is unavailable, so the transcript path in the turn-end payload could not be read'
    fi
  elif [ ! -f "$transcript" ]; then
    reason="the recorded transcript $transcript does not exist"
  fi
  if [ -n "$reason" ]; then
    fm_helm_record_declination "$state" "$pid" "$reason"
    return 1
  fi
  now=$(date +%s 2>/dev/null) || return 1
  [ -n "$now" ] || return 1
  tmp="$marker.tmp.$$"
  if ! {
    printf 'pid=%s\n' "$pid"
    printf 'epoch=%s\n' "$now"
    printf 'transcript=%s\n' "$transcript"
  } > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  if ! mv -f "$tmp" "$marker" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  rm -f "$(fm_helm_declination "$state")" 2>/dev/null || true
}

# fm_helm_marker_field <state> <field>: read one marker field. An empty marker
# has no fields: it proves nothing and must not read as a match.
fm_helm_marker_field() {
  local state=$1 field=$2 marker
  marker=$(fm_helm_marker "$state")
  [ -s "$marker" ] || return 1
  sed -n "s/^$field=//p" "$marker" 2>/dev/null | head -1
}

# fm_helm_silence_seconds <state> <holder_pid>: set FM_HELM_SILENCE to how long
# the holder has shown no sign of work, and FM_HELM_SILENCE_SOURCE to the evidence
# used. Globals rather than output, for the same reason as fm_helm_attendance: a
# command substitution would strip the companion value.
#
# Evidence is POSITIVE PROOF OF WORK only, and the newest of these two mtimes
# wins, so either one being fresh proves activity:
#   marker      - the holder's last completed turn, from a readable, non-empty
#                 state/.helm-activity whose pid matches this holder.
#   transcript  - the file that marker names, which grows DURING a turn, so a
#                 long single turn still reads as busy rather than idle.
# The session lock is NOT evidence: its mtime is written once at acquisition and
# never refreshed, so it measures the session's age, not its quietness. Nothing
# weaker is substituted for a missing marker. Without a pid-matched, non-empty
# marker the silence is UNMEASURABLE and this returns non-zero, which refuses the
# takeover rather than permitting one on absent evidence.
fm_helm_silence_seconds() {
  local state=$1 holder=$2 newest='' newest_src='' m mpid transcript now
  # shellcheck disable=SC2034 # Read by callers (fm-lock.sh) after this returns.
  FM_HELM_SILENCE_SOURCE=none
  FM_HELM_SILENCE=
  mpid=$(fm_helm_marker_field "$state" pid 2>/dev/null || true)
  # A marker left by a DIFFERENT session says nothing about this holder.
  [ -n "$mpid" ] && [ "$mpid" = "$holder" ] || return 1
  m=$(fm_path_mtime "$(fm_helm_marker "$state")" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) m= ;; esac
  if [ -n "$m" ]; then newest=$m; newest_src=marker; fi
  transcript=$(fm_helm_marker_field "$state" transcript 2>/dev/null || true)
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    m=$(fm_path_mtime "$transcript" 2>/dev/null || true)
    case "$m" in ''|*[!0-9]*) m= ;; esac
    if [ -n "$m" ] && { [ -z "$newest" ] || [ "$m" -gt "$newest" ]; }; then
      newest=$m; newest_src=transcript
    fi
  fi
  [ -n "$newest" ] || return 1
  now=$(date +%s)
  FM_HELM_SILENCE_SOURCE=$newest_src
  if [ "$now" -lt "$newest" ]; then
    FM_HELM_SILENCE=0
  else
    FM_HELM_SILENCE=$((now - newest))
  fi
}

# fm_helm_attendance <pid>: set FM_HELM_ATTENDANCE to attended, unattended, or
# unknown, and FM_HELM_TTY to the controlling terminal ps reported. Only a
# readable, absent terminal proves unattended; anything unreadable is unknown, and
# both unknown and attended must refuse a takeover.
#
# It sets globals instead of printing, because a caller that read it through a
# command substitution would lose FM_HELM_TTY to the subshell.
fm_helm_attendance() {
  local pid=$1 tty
  # shellcheck disable=SC2034 # Both are read by callers (fm-lock.sh) after this returns.
  FM_HELM_TTY=
  FM_HELM_ATTENDANCE=unknown
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  tty=$(ps -o tty= -p "$pid" 2>/dev/null) || return 0
  tty=${tty//[[:space:]]/}
  FM_HELM_TTY=$tty
  case "$tty" in
    '') FM_HELM_ATTENDANCE=unknown ;;
    '??'|'?'|'-') FM_HELM_ATTENDANCE=unattended ;;
    *) FM_HELM_ATTENDANCE=attended ;;
  esac
}

# fm_helm_takeover_allowed <state> <holder_pid>: decide whether a fresh session
# may take the helm from this live holder. Sets FM_HELM_REFUSE_REASON on refusal
# and FM_HELM_TAKEOVER_REASON on approval, both as one captain-readable clause.
# Returns 0 only when the holder is provably unattended AND measurably silent
# past the threshold.
fm_helm_takeover_allowed() {
  # shellcheck disable=SC2034 # Both reasons are read by callers (fm-lock.sh) after this returns.
  local state=$1 holder=$2 silence threshold
  FM_HELM_REFUSE_REASON=
  FM_HELM_TAKEOVER_REASON=
  threshold=$(fm_helm_idle_threshold)
  fm_helm_attendance "$holder"
  case "$FM_HELM_ATTENDANCE" in
    attended)
      FM_HELM_REFUSE_REASON="it is attended on terminal $FM_HELM_TTY"
      return 1
      ;;
    unknown)
      FM_HELM_REFUSE_REASON="its terminal could not be read, so it cannot be proven unattended"
      return 1
      ;;
  esac
  if ! fm_helm_silence_seconds "$state" "$holder"; then
    FM_HELM_REFUSE_REASON="it has not proved it is doing any work (no readable turn-end activity marker of its own), so it keeps the helm"
    return 1
  fi
  silence=$FM_HELM_SILENCE
  if [ "$silence" -lt "$threshold" ]; then
    # shellcheck disable=SC2034 # Read by callers (fm-lock.sh) after this returns.
    FM_HELM_REFUSE_REASON="it is unattended but was active ${silence}s ago (takeover needs ${threshold}s of silence)"
    return 1
  fi
  # shellcheck disable=SC2034 # Read by callers (fm-lock.sh) after this returns.
  FM_HELM_TAKEOVER_REASON="it has no terminal and has been silent for ${silence}s (threshold ${threshold}s, newest evidence: $FM_HELM_SILENCE_SOURCE)"
  return 0
}
