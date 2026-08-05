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
# ONE DEFINITION OF ADMISSIBLE EVIDENCE, and it lives on the READ side, in
# fm_helm_silence_seconds. A marker is a persisted claim that outlives the file
# it names, so no check at write time can establish "this marker names a
# transcript that exists": the marker may predate the check, and the transcript
# can be deleted or moved after it. The reader therefore decides, every time.
# The pulse's record of a failed resolution is diagnostics that explain a
# refusal; it never causes one.
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

# fm_helm_declination <state>: path of the record saying why the last turn end
# could not resolve a transcript. It sits beside the marker and is overwritten,
# never appended: one current answer to "why does the marker name no transcript",
# not a log nobody prunes. It is DIAGNOSTICS ONLY - it explains a refusal and
# never causes one, because the reader decides on the marker alone.
fm_helm_declination() {
  printf '%s\n' "$1/.helm-activity-declined"
}

# fm_helm_clear_declination <state>: drop the record. Called when a turn end does
# resolve a transcript, and wherever the helm changes hands, so a later holder
# never inherits its predecessor's explanation.
fm_helm_clear_declination() {
  rm -f "$(fm_helm_declination "$1")" 2>/dev/null || true
}

# fm_helm_record_declination <state> <pid> <reason>: remember that a turn end
# could not resolve a transcript, and why. Written atomically for the same reason
# the marker is, and every failure is silent: the caller is a turn-end hook that
# must never wedge a session, and a missing record only costs an explanation.
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

# fm_helm_declination_note <state> <holder_pid>: one captain-readable clause
# naming when this HOLDER last failed to resolve a transcript and why, or
# non-zero when there is no such record for it. This is what a refusal quotes, so
# "why did this not take the helm" is answerable from the refusal itself rather
# than from a file the reader has to know about.
#
# Pid-matched exactly as the marker read is: the record outlives the session that
# wrote it, and attributing a dead session's jq problem to the current holder
# sends the operator to fix something that is not broken.
fm_helm_declination_note() {
  local state=$1 holder=$2 path reason pid at
  path=$(fm_helm_declination "$state")
  [ -s "$path" ] || return 1
  pid=$(sed -n 's/^pid=//p' "$path" 2>/dev/null | head -1)
  [ -n "$pid" ] && [ "$pid" = "$holder" ] || return 1
  reason=$(sed -n 's/^reason=//p' "$path" 2>/dev/null | head -1)
  [ -n "$reason" ] || return 1
  at=$(sed -n 's/^at=//p' "$path" 2>/dev/null | head -1)
  printf 'its own turn end at %s could not resolve one: %s\n' \
    "${at:-unknown}" "$reason"
}

# fm_helm_stamp <state> <pid> [transcript]: record that the holder just finished
# a turn. The transcript path is recorded, not copied, so a later silence check
# can see mid-turn growth in it and not mistake a busy session for an idle one.
# A write failure is never fatal: a missing marker only costs measurability, and
# the caller is a turn-end hook that must never wedge a session.
#
# IT ALWAYS STAMPS, even when the caller has no transcript to name, and that is a
# safety property rather than laziness. A stamp that refused to write would leave
# the PREVIOUS marker on disk: turn 1 stamps pid=A naming transcript T, turn 2
# cannot resolve a transcript and writes nothing, and the turn-1 marker is still
# there, still pid-matched, still naming T. The holder is then working on a turn
# nothing observes while the reader measures silence from stale turn-1 evidence
# and may take the helm from a live session. Overwriting with this turn's truth -
# including "no transcript this time" - makes that case fail closed instead,
# because fm_helm_silence_seconds treats a marker naming no usable transcript as
# unmeasurable. Never reintroduce a write-time refusal here.
#
# The write is ATOMIC - built in a temp file beside the marker and moved into
# place - so a concurrent reader sees either the whole previous marker or the
# whole new one. A truncating redirect leaves the marker zero-length for the
# width of the fork that produces the timestamp, and an empty marker reads as
# "this holder cannot prove it is working", which is a takeover decision made on
# a race. On any failure the temp file goes and the existing marker stands.
fm_helm_stamp() {
  local state=$1 pid=$2 transcript=${3:-} marker tmp now
  marker=$(fm_helm_marker "$state")
  [ -d "$state" ] || return 1
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
# THIS IS THE SOLE AUTHORITY on what counts as evidence. Silence is measurable
# only from a marker that is readable, non-empty, pid-matched to this holder, and
# names a transcript file that still exists. Anything short of that is
# UNMEASURABLE: this returns non-zero and sets FM_HELM_UNMEASURABLE to which part
# was missing, which refuses the takeover rather than permitting one on evidence
# that proves less than it appears to.
#
# A marker naming no usable transcript is NOT evidence, and no fallback to the
# marker's own mtime is allowed: that mtime proves a turn ended once, not that
# the session is working now, so an unattended holder working through one turn
# longer than the threshold would measure as silent and lose the helm mid-turn.
# The check must happen here rather than where the marker is written, because a
# marker outlives the file it names: it may predate any write-time rule, and the
# transcript can be deleted, rotated, or moved afterwards.
#
# With both present, the NEWER of the two mtimes wins, so either being fresh
# proves activity:
#   marker      - the holder's last completed turn.
#   transcript  - the file that marker names, which grows DURING a turn, so a
#                 long single turn still reads as busy rather than idle.
# The session lock is NOT evidence: its mtime is written once at acquisition and
# never refreshed, so it measures the session's age, not its quietness.
fm_helm_silence_seconds() {
  local state=$1 holder=$2 newest='' newest_src='' m mpid transcript now
  # shellcheck disable=SC2034 # Read by callers (fm-lock.sh) after this returns.
  FM_HELM_SILENCE_SOURCE=none
  FM_HELM_SILENCE=
  # shellcheck disable=SC2034 # Read by callers (fm-lock.sh) after this returns.
  FM_HELM_UNMEASURABLE=
  mpid=$(fm_helm_marker_field "$state" pid 2>/dev/null || true)
  # A marker left by a DIFFERENT session says nothing about this holder.
  if [ -z "$mpid" ] || [ "$mpid" != "$holder" ]; then
    FM_HELM_UNMEASURABLE="no readable turn-end activity marker of its own"
    return 1
  fi
  transcript=$(fm_helm_marker_field "$state" transcript 2>/dev/null || true)
  if [ -z "$transcript" ]; then
    FM_HELM_UNMEASURABLE="its activity marker names no transcript, so nothing there can show work in progress"
    return 1
  fi
  if [ ! -f "$transcript" ]; then
    FM_HELM_UNMEASURABLE="its activity marker names the transcript $transcript, which no longer exists"
    return 1
  fi
  m=$(fm_path_mtime "$(fm_helm_marker "$state")" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) m= ;; esac
  if [ -n "$m" ]; then newest=$m; newest_src=marker; fi
  m=$(fm_path_mtime "$transcript" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) m= ;; esac
  if [ -n "$m" ] && { [ -z "$newest" ] || [ "$m" -gt "$newest" ]; }; then
    newest=$m; newest_src=transcript
  fi
  if [ -z "$newest" ]; then
    FM_HELM_UNMEASURABLE="neither its activity marker nor the transcript it names has a readable timestamp"
    return 1
  fi
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
    FM_HELM_REFUSE_REASON="it has not proved it is doing any work (${FM_HELM_UNMEASURABLE:-no readable turn-end activity marker of its own}), so it keeps the helm"
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
