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
# fm_control_clear_own_doorbell returns 0 only when the composer is proven empty
# afterwards, and nonzero (touching nothing) in every other case. It reads the
# caller's STATE, ID, BACKEND, T, LABEL, HARNESS and POLL.

_FM_CONTROL_DOORBELL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$_FM_CONTROL_DOORBELL_LIB_DIR/fm-task-inbox-lib.sh"

# Enough presses for the doorbell wrapped on a very narrow pane.
FM_CONTROL_DOORBELL_CLEAR_MAX=${FM_CONTROL_DOORBELL_CLEAR_MAX:-8}

fm_control_clear_own_doorbell() {
  local line n=0 verdict
  [ "${HARNESS-}" = claude ] || return 1
  line=$(fm_task_inbox_doorbell_line "$(fm_task_inbox_dir "$STATE" "$ID")/x.msg") || return 1
  fm_task_inbox_composer_holds "$BACKEND" "$T" "$line" "${LABEL-}" || return 1
  while [ "$n" -lt "$FM_CONTROL_DOORBELL_CLEAR_MAX" ]; do
    fm_backend_send_key "$BACKEND" "$T" C-u "${LABEL-}" || return 1
    n=$((n + 1))
    sleep "${POLL:-0.5}"
    verdict=$(fm_backend_composer_state "$BACKEND" "$T" "${LABEL-}" 2>/dev/null) || return 1
    [ "$verdict" = empty ] && return 0
  done
  return 1
}
# Fork-only end
