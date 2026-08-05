#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
#
# A live holder does not automatically keep the helm. bin/fm-helm-lib.sh owns the
# "is that holder actually working, and may this session take over?" decision;
# acquisition takes the helm from a provably unattended, measurably silent holder
# and reports it loudly. Every other conflict refuses, and the refusal names what
# holds the helm, how long it has been quiet, and the one command that clears it -
# never a bare "someone else has it".
#
# Usage: fm-lock.sh                 acquire; exit 1 unless ownership is verified
#        fm-lock.sh status          print holder and liveness; always exits 0
#        fm-lock.sh release         release the helm, but only if this session
#                                   holds it; already-free is success
#        fm-lock.sh clear --pid N   captain override: drop the helm recorded for
#                                   pid N without touching that session. Refuses
#                                   unless N is the recorded holder.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# fm_path_mtime, used by the helm activity measurement below.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-helm-lib.sh
. "$SCRIPT_DIR/fm-helm-lib.sh"

# holder_description <pid>: one line naming what holds the helm, its terminal,
# and how long it has been quiet. This is what the captain needs to decide
# whether to clear it, so it never degrades to a bare pid.
holder_description() {
  local pid=$1 comm silence
  comm=$(basename "$(ps -o comm= -p "$pid" 2>/dev/null || printf unknown)")
  fm_helm_attendance "$pid"
  silence=''
  fm_helm_silence_seconds "$STATE" "$pid" 2>/dev/null && silence=$FM_HELM_SILENCE
  printf 'holder: pid %s (%s), terminal %s (%s)' \
    "$pid" "$comm" "${FM_HELM_TTY:-unknown}" "$FM_HELM_ATTENDANCE"
  if [ -n "$silence" ]; then
    printf ', last sign of work %ss ago (%s)\n' "$silence" "$FM_HELM_SILENCE_SOURCE"
  else
    printf ', no recorded activity\n'
  fi
}

# print_declination_note <pid>: when silence is unmeasurable and the holder's
# pulse recorded WHY it never stamped a marker, say so here. A person debugging
# "why did this not take the helm" reads the refusal, not a file they do not
# know exists.
print_declination_note() {
  local note
  fm_helm_silence_seconds "$STATE" "$1" 2>/dev/null && return 0
  note=$(fm_helm_declination_note "$STATE" 2>/dev/null) || return 0
  printf 'no activity marker exists because %s\n' "$note"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_harness_pid_alive "$old"; then
    echo "lock: held by live harness pid $old"
    holder_description "$old"
    # A takeover verdict about the caller's OWN helm reads as an invitation to
    # take the helm from itself, so the usual caller - the holder - is told it
    # holds it instead. The verdict is only meaningful about another session.
    mine=$(fm_harness_ancestry_pid 2>/dev/null || printf '')
    if [ -n "$mine" ] && [ "$mine" = "$old" ]; then
      printf 'takeover: not applicable - this session holds the helm\n'
    elif fm_helm_takeover_allowed "$STATE" "$old"; then
      printf 'takeover: available - %s\n' "$FM_HELM_TAKEOVER_REASON"
    else
      printf 'takeover: refused - %s\n' "$FM_HELM_REFUSE_REASON"
      print_declination_note "$old"
    fi
  else
    echo "lock: stale (pid $old dead or not a harness)"
  fi
  exit 0
fi

if [ "${1:-}" = "release" ]; then
  if [ ! -e "$LOCK" ]; then echo "lock: already free"; exit 0; fi
  if ! fm_session_lock_owned_by_self "$STATE"; then
    echo "error: this session does not hold the lock, so it cannot release it; run 'fm-lock.sh status' to see what does" >&2
    exit 1
  fi
  rm -f "$LOCK" 2>/dev/null || {
    echo "error: cannot remove the session lock $LOCK" >&2
    exit 1
  }
  echo "lock released: this session no longer holds the helm"
  exit 0
fi

if [ "${1:-}" = "clear" ]; then
  shift
  want=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pid) shift; want=${1:-} ;;
      *) echo "usage: fm-lock.sh clear --pid <holder-pid>" >&2; exit 2 ;;
    esac
    shift
  done
  case "$want" in
    ''|*[!0-9]*) echo "usage: fm-lock.sh clear --pid <holder-pid>" >&2; exit 2 ;;
  esac
  if [ ! -f "$LOCK" ]; then echo "lock: already free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; remove $LOCK by hand after checking what holds it" >&2
    exit 1
  }
  if [ "$old" != "$want" ]; then
    echo "error: pid $want does not hold the lock (pid $old does); re-read 'fm-lock.sh status' before clearing" >&2
    exit 1
  fi
  rm -f "$LOCK" 2>/dev/null || {
    echo "error: cannot remove the session lock $LOCK" >&2
    exit 1
  }
  printf 'lock cleared: pid %s no longer holds the helm. That session is still running and was not touched - quit it so two sessions do not work the same fleet.\n' "$old"
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$CLAIM_LOCK"
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    # A live holder keeps the helm unless it is provably unattended AND
    # measurably silent. Both proofs are required; an unreadable input refuses.
    if fm_helm_takeover_allowed "$STATE" "$old"; then
      TAKEOVER_FROM=$old
      TAKEOVER_WHY=$FM_HELM_TAKEOVER_REASON
    else
      {
        echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved"
        holder_description "$old"
        printf 'refused to take the helm: %s\n' "$FM_HELM_REFUSE_REASON"
        print_declination_note "$old"
        printf 'clear it with: %s clear --pid %s\n' "$0" "$old"
        printf '  That drops the recorded helm without touching the other session, so quit that session too.\n'
      } >&2
      exit 1
    fi
  fi
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
echo "lock acquired: harness pid $me"
if [ -n "${TAKEOVER_FROM:-}" ]; then
  # Loud on purpose: a takeover is rare, and the session that lost the helm may
  # still be running, so this must never read as an ordinary acquisition.
  printf 'HELM TAKEN OVER: pid %s held it and %s.\n' "$TAKEOVER_FROM" "$TAKEOVER_WHY"
  printf 'That session was NOT stopped. Quit it if it is still open, so two sessions do not work the same fleet.\n'
  printf 'helm-takeover %s from=%s to=%s reason=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$TAKEOVER_FROM" "$me" "$TAKEOVER_WHY" \
    >> "$STATE/.helm-takeover" 2>/dev/null || true
fi
