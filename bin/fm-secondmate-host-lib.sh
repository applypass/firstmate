#!/usr/bin/env bash
# fm-secondmate-host-lib.sh - supervision-host rules for secondmate homes
# (applypass fork-only; docs/supervision-host.md "Secondmate homes" owns the
# design). Sourced by bin/fm-supervision-host.sh from a `# Fork-only:` block.
#
# A secondmate home runs an Opus session whose context every wake re-reads, so
# a routine wake the host can take must never reach it. The home gate already
# runs the host there (docs/configuration.md "Supervision host"); this file adds
# the two places a secondmate home differs from the main home:
#
#   - fm_secondmate_host_routine_check: a close that only asks the session to
#     re-read its queue, which the host absorbs when the queue holds no row.
#   - fm_secondmate_host_acknowledge_published: a captain outcome the engine
#     recorded is already on the parent channel (bin/fm-branch-report.sh), so
#     the host acknowledges it and the mate session is not woken for it.
#
# Everything else the host passes to the session stays as it is: decision and
# blocker closes, a close the engine cannot take, a failed engine turn, and a
# close the home's latch holds.
#
# No side effects on source.

_FM_SECONDMATE_HOST_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_SECONDMATE_HOST_LIB_DIR/fm-parent-channel-lib.sh"

# fm_secondmate_host_home <home>: 0 iff <home> is a marked secondmate home.
fm_secondmate_host_home() {
  fm_parent_channel_home_id "$1" >/dev/null 2>&1
}

# fm_secondmate_host_routine_check <close-reason-line>: 0 for a check close
# that carries no work of its own. check: rearm-resurface is the watcher
# re-announcing the queue after downtime; the rows it announces are judged on
# their own, so with an empty queue it announces nothing.
fm_secondmate_host_routine_check() {
  case "${1%%$'\n'*}" in
    'check: rearm-resurface') return 0 ;;
  esac
  return 1
}

# fm_secondmate_host_outcomes_published <home> <state> <seq>...: 0 when every
# store row named is on the parent channel under its branch-outcome key.
fm_secondmate_host_outcomes_published() {
  local home=$1 state=$2 destination seq
  shift 2
  [ "$#" -gt 0 ] || return 1
  fm_secondmate_host_home "$home" || return 1
  destination=$(fm_parent_channel_destination "$home" "$state" 2>/dev/null) || return 1
  [ -f "$destination" ] || return 1
  for seq in "$@"; do
    case "$seq" in ''|*[!0-9]*) return 1 ;; esac
    grep -F -q -- "[key=branch-outcome-$seq]" "$destination" 2>/dev/null || return 1
  done
}

# fm_secondmate_host_acknowledge_published <home> <state> <seq>...: when every
# captain row the store presents at or below the highest seq named, and every
# seq named, is on the parent channel, mark the store read and processed
# through that seq (bin/fm-branch-outcome.sh) so the mate's drain does not
# present them again. Fails, changing nothing, when any of them is missing.
fm_secondmate_host_acknowledge_published() {
  local home=$1 state=$2 top=0 seq presented
  shift 2
  for seq in "$@"; do
    case "$seq" in ''|*[!0-9]*) return 1 ;; esac
    [ "$seq" -le "$top" ] || top=$seq
  done
  presented=$("$_FM_SECONDMATE_HOST_LIB_DIR/fm-branch-outcome.sh" present 2>/dev/null \
    | jq -r --argjson top "$top" 'select(.verdict == "captain" and .seq <= $top) | .seq') || return 1
  # shellcheck disable=SC2086 # the store rows are space-free numbers
  fm_secondmate_host_outcomes_published "$home" "$state" "$@" $presented || return 1
  "$_FM_SECONDMATE_HOST_LIB_DIR/fm-branch-outcome.sh" mark-read --through "$top" >/dev/null 2>&1 || return 1
  "$_FM_SECONDMATE_HOST_LIB_DIR/fm-branch-outcome.sh" mark-processed --through "$top" >/dev/null 2>&1
}
