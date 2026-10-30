#!/usr/bin/env bash
# Fork-only (applypass): keep a retired second-mate home from haunting a reused pool slot.
#
# `treehouse return --force` resets tracked files only. A leased second-mate
# home keeps its gitignored `.fm-secondmate-home` marker and `state/.lock`
# in the returned slot, so a later ship worker given that slot looks like a
# second-mate primary to the Stop hooks and loops rearm-resurface wakes.
#
# fm_slot_home_retire <home> <id>
#   Rename the home markers to `<marker>.retired-<id>` and remove the home's
#   `state/.lock`. Call it while teardown still holds the lease, after every
#   refusal check and just before `treehouse return`, so a refusal never
#   retires anything. Nothing else in the slot is touched or deleted.
# fm_slot_home_refuse <worktree>
#   Return 1 and print the offending path when a worktree handed to a ship or
#   scout worker still carries a live second-mate marker or a state/.lock whose
#   recorded pid is alive. A lock that is empty, unreadable or names a dead pid
#   belongs to a retired home and does not block. It never deletes: the owner of
#   a live home might be running.
# This file is sourced and has no side effects on source.

FM_SLOT_HOME_MARKERS=".fm-secondmate-home .fm-secondmate-parent"
# shellcheck source=bin/fm-session-lock-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-session-lock-lib.sh"

# fm_slot_home_lock_live <lock-file>: 0 iff the file records a live holder pid.
# A tagged Windows pid is outside this process table, so the session-lock
# library answers for it; a local pid is a plain kill -0.
fm_slot_home_lock_live() {  # <lock-file>
  local pid
  pid=$(head -n 1 "$1" 2>/dev/null || true)
  fm_session_pid_valid "$pid" || return 1
  case "$pid" in
    "$FM_WIN_PID_PREFIX"*) fm_harness_pid_alive "$pid" ;;
    *) kill -0 "$pid" 2>/dev/null ;;
  esac
}
fm_slot_home_retire() {  # <home> <id>
  local home=$1 id=${2:-home} name
  [ -n "$home" ] && [ -d "$home" ] && [ ! -L "$home" ] || return 0
  for name in $FM_SLOT_HOME_MARKERS; do
    if [ -e "$home/$name" ] || [ -L "$home/$name" ]; then
      mv -f -- "$home/$name" "$home/$name.retired-$id" || return 1
    fi
  done
  rm -f -- "$home/state/.lock"
  return 0
}

fm_slot_home_refuse() {  # <worktree>
  local wt=$1 path
  [ -n "$wt" ] || return 0
  for path in "$wt/.fm-secondmate-home" "$wt/state/.lock"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      case "$path" in
        */state/.lock) fm_slot_home_lock_live "$path" || continue ;;
      esac
      echo "error: pool slot $wt carries a second-mate home leftover ($path); refusing to launch a worker there. Retire the home or remove the leftover by hand once its owner is confirmed gone" >&2
      return 1
    fi
  done
  return 0
}
