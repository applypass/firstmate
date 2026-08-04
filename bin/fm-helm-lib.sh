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

# fm_helm_stamp <state> <pid> [transcript]: record that the holder just finished
# a turn. The transcript path is recorded, not copied, so a later silence check
# can see mid-turn growth in it and not mistake a busy session for an idle one.
# A write failure is never fatal: a missing marker only costs measurability, and
# the caller is a turn-end hook that must never wedge a session.
fm_helm_stamp() {
  local state=$1 pid=$2 transcript=${3:-} marker
  marker=$(fm_helm_marker "$state")
  [ -d "$state" ] || return 1
  {
    printf 'pid=%s\n' "$pid"
    printf 'epoch=%s\n' "$(date +%s)"
    printf 'transcript=%s\n' "$transcript"
  } > "$marker" 2>/dev/null || return 1
}

# fm_helm_marker_field <state> <field>: read one marker field.
fm_helm_marker_field() {
  local state=$1 field=$2 marker
  marker=$(fm_helm_marker "$state")
  [ -f "$marker" ] || return 1
  sed -n "s/^$field=//p" "$marker" 2>/dev/null | head -1
}

# fm_helm_silence_seconds <state> <holder_pid>: set FM_HELM_SILENCE to how long
# the holder has shown no sign of work, and FM_HELM_SILENCE_SOURCE to the evidence
# used. Globals rather than output, for the same reason as fm_helm_attendance: a
# command substitution would strip the companion value.
#
# Evidence is the NEWEST of three mtimes, so any one of them being fresh proves
# activity:
#   marker      - the holder's last completed turn.
#   transcript  - grows DURING a turn, so a long single turn still reads as busy.
#   lock        - written when the session claimed the helm, the baseline for a
#                 holder that has not ended a turn yet or predates the marker.
# Returns non-zero when no evidence exists at all, which is unmeasurable and must
# never be read as silence.
fm_helm_silence_seconds() {
  local state=$1 holder=$2 marker newest='' newest_src='' m mpid transcript now
  # shellcheck disable=SC2034 # Read by callers (fm-lock.sh) after this returns.
  FM_HELM_SILENCE_SOURCE=none
  FM_HELM_SILENCE=
  marker=$(fm_helm_marker "$state")
  mpid=$(fm_helm_marker_field "$state" pid 2>/dev/null || true)
  # A marker left by a DIFFERENT session says nothing about this holder.
  if [ -f "$marker" ] && [ "$mpid" = "$holder" ]; then
    m=$(fm_path_mtime "$marker" 2>/dev/null || true)
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
  fi
  m=$(fm_path_mtime "$state/.lock" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) m= ;; esac
  if [ -n "$m" ] && { [ -z "$newest" ] || [ "$m" -gt "$newest" ]; }; then
    newest=$m; newest_src=lock
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
    FM_HELM_REFUSE_REASON="it has no recorded activity at all, so its silence cannot be measured"
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
