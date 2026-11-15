#!/usr/bin/env bash
# Fork-only: fm-control-doorbell-lib.sh - lets exit and relaunch clear their own unsent doorbell (applypass fork).
#
# An idle worker whose context is full cannot read its steering inbox, so the
# doorbell line fm-send typed stays unsent in its composer. The exit step of
# bin/fm-control.sh refuses to type over pending text, so that worker could never
# be relaunched. This lib clears that one line, and nothing else:
#   - the composer must hold exactly this task's doorbell line, judged by the
#     shared matcher in bin/fm-task-inbox-lib.sh (fm_task_inbox_composer_holds);
#   - only Claude is covered, because only its clear mechanics were verified
#     (docs/verification/runtime-backends.md "Claude own-doorbell clear");
#   - Ctrl-U deletes one wrapped row per press on Claude 2.1.x, so it is pressed
#     a bounded number of times, stopping at the first proven-empty composer;
#   - the result is trusted only when the composer then classifies empty.
# Escape twice also empties the composer but opens the rewind picker when it is
# already empty, and Ctrl-C can exit the agent, so neither is used.
# The doorbell is never submitted.
#
# A pane can show only the first rows of a long doorbell: Claude draws the
# composer from its top row, so a pane too short for every wrapped row (the
# herdr pane that prompted this) clips the rest off the bottom. The shared
# matcher then reads a partial line and refuses. fm_control_composer_holds_truncated_doorbell
# accepts that one shape and no other: the composer text is a proper prefix of
# this task's doorbell, long enough to include the task's own inbox name (so it
# cannot be another task's line), and the composer is the last thing on screen
# (no closing rule or footer under it), the sign that more text runs off-screen.
# Anything else, including other text and another task's truncated line, stays
# a refusal.
#
# fm_control_clear_own_doorbell returns 0 only when the composer is proven empty
# afterwards, and nonzero in every other case. It touches nothing unless the
# composer holds exactly the doorbell (or its proven truncated view), but once Ctrl-U presses start a failed
# clear can leave part of the doorbell behind (a pane too narrow for the press
# bound, or a composer read that fails mid-clear); the operator then clears it by
# hand. It reads the caller's STATE, ID, BACKEND, T, LABEL, HARNESS and POLL.
#
# `fm-control.sh <id> clear-doorbell` runs fm_control_do_clear_doorbell: only
# that proven clear, reported as its own result, with no exit and no relaunch.
# The verb is added to the control plane's allowlist here, by wrapping the
# upstream functions, so bin/fm-control-lib.sh stays untouched.

_FM_CONTROL_DOORBELL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$_FM_CONTROL_DOORBELL_LIB_DIR/fm-task-inbox-lib.sh"


# Whether the composer shows a clipped view of <line>: see the header.
fm_control_composer_holds_truncated_doorbell() {  # <backend> <target> <line> [expected-label]
  local cap held plain last hs ls pre min
  fm_backend_source "$1" || return 1
  cap=$(fm_backend_capture "$1" "$2" 60 "${4:-}" 2>/dev/null) || return 1
  held=$(fm_composer_extract_selected_content styled=0 "$cap") || return 1
  hs=$(printf '%s' "$held" | tr -d '[:space:]')
  ls=$(printf '%s' "$3" | tr -d '[:space:]')
  [ -n "$hs" ] && [ "${#hs}" -lt "${#ls}" ] || return 1
  case "$ls" in "$hs"*) ;; *) return 1 ;; esac
  # The shortest accepted text ends at the template's "steering inbox", so it
  # always contains the task's own quoted inbox name.
  pre=${ls%steeringinbox*}
  min=$(( ${#pre} + 13 ))
  [ "${#hs}" -ge "$min" ] || return 1
  # Continuation sign: the last non-blank row is composer text still running
  # (the tail of what was read), not a closing rule, footer, or any other row.
  plain=$(printf '%s\n' "$cap" | fm_composer_strip_ansi)
  last=$(printf '%s\n' "$plain" | awk 'NF { row = $0 } END { print row }')
  last=$(printf '%s' "$last" | tr -d '[:space:]')
  last=${last#❯}
  [ -n "$last" ] && [ "${#last}" -ge 8 ] || return 1
  case "$hs" in *"$last") return 0 ;; esac
  return 1
}

fm_control_composer_holds_own_doorbell() {  # <line>
  fm_task_inbox_composer_holds "$BACKEND" "$T" "$1" "${LABEL-}" \
    || fm_control_composer_holds_truncated_doorbell "$BACKEND" "$T" "$1" "${LABEL-}"
}

fm_control_clear_own_doorbell() {
  local line n=0 verdict
  [ "${HARNESS-}" = claude ] || return 1
  line=$(fm_task_inbox_doorbell_line "$(fm_task_inbox_dir "$STATE" "$ID")/x.msg") || return 1
  fm_control_composer_holds_own_doorbell "$line" || return 1
  while [ "$n" -lt 8 ]; do
    fm_backend_send_key "$BACKEND" "$T" C-u "${LABEL-}" || return 1
    n=$((n + 1))
    sleep "${POLL:-0.5}"
    verdict=$(fm_backend_composer_state "$BACKEND" "$T" "${LABEL-}" 2>/dev/null) || return 1
    [ "$verdict" = empty ] && return 0
  done
  return 1
}

# The standalone `clear-doorbell` verb. Prints `doorbell-cleared` or
# `no-doorbell` (the composer was already empty) and returns 0; any other
# composer content, harness, or a clear that does not prove empty is a refusal.
fm_control_do_clear_doorbell() {
  local state composer
  [ "${HARNESS-}" = claude ] \
    || die "task $ID runs $HARNESS; clear-doorbell is verified on claude only (see bin/fm-control-doorbell-lib.sh)"
  state=$(agent_state)
  [ "$state" = alive ] \
    || die "task $ID's endpoint reads '$state'; clear-doorbell needs a running agent whose composer it can read"
  composer=$(fm_backend_composer_state "$BACKEND" "$T" "${LABEL-}" 2>/dev/null) || composer=unknown
  case "$composer" in
    empty) printf 'no-doorbell'; return 0 ;;
    pending) ;;
    *) die "task $ID's composer state is '$composer', not proven pending; refusing to clear it" ;;
  esac
  fm_control_clear_own_doorbell \
    || die "task $ID's composer does not hold exactly this task's own doorbell, or the clear did not empty it; nothing else is ever cleared, so clear or submit it by hand"
  printf 'doorbell-cleared'
}

# Add the verb to the allowlist by wrapping the upstream functions once.
if declare -F fm_control_verbs >/dev/null 2>&1 && declare -F fm_control_verb_allowed >/dev/null 2>&1 \
   && ! declare -F _fm_control_upstream_fm_control_verbs >/dev/null 2>&1; then
  eval "_fm_control_upstream_$(declare -f fm_control_verbs)"
  eval "_fm_control_upstream_$(declare -f fm_control_verb_allowed)"
  fm_control_verbs() { _fm_control_upstream_fm_control_verbs; printf 'clear-doorbell\n'; }
  fm_control_verb_allowed() {  # <verb>
    [ "${1-}" = clear-doorbell ] || _fm_control_upstream_fm_control_verb_allowed "$@"
  }
fi
# Fork-only end
