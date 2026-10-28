#!/usr/bin/env bash
# Fork-only (applypass): keep a retired second-mate home from haunting a reused pool slot.
#
# `treehouse return --force` resets tracked files only. A leased second-mate
# home keeps its gitignored `.fm-secondmate-home` marker and `state/.lock`
# in the returned slot, so a later ship worker given that slot looks like a
# second-mate primary to the Stop hooks and loops rearm-resurface wakes.
#
# fm_slot_home_scrub <home>
#   Remove the home markers and the home-only gitignored state/, data/, and
#   config/ trees. Call it only after a successful, non-refused retirement
#   and a successful `treehouse return`; it never runs on a refusal.
# fm_slot_home_refuse <worktree>
#   Return 1 and print the offending path when a worktree handed to a ship or
#   scout worker still carries a second-mate marker or a home state/.lock.
#   It never deletes: the owner of that home might be live.
# This file is sourced and has no side effects on source.

FM_SLOT_HOME_MARKERS=".fm-secondmate-home .fm-secondmate-parent"
FM_SLOT_HOME_TREES="state data config"

fm_slot_home_scrub() {  # <home>
  local home=$1 name
  [ -n "$home" ] && [ -d "$home" ] && [ ! -L "$home" ] || return 0
  for name in $FM_SLOT_HOME_MARKERS; do
    rm -f -- "$home/$name"
  done
  for name in $FM_SLOT_HOME_TREES; do
    if [ -L "$home/$name" ]; then
      rm -f -- "$home/$name"
    elif [ -d "$home/$name" ]; then
      chmod -R u+w -- "$home/$name" 2>/dev/null || true
      rm -rf -- "$home/$name"
    fi
  done
  return 0
}

fm_slot_home_refuse() {  # <worktree>
  local wt=$1 path
  [ -n "$wt" ] || return 0
  for path in "$wt/.fm-secondmate-home" "$wt/state/.lock"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      echo "error: pool slot $wt carries a second-mate home leftover ($path); refusing to launch a worker there. Retire the home or remove the leftover by hand once its owner is confirmed gone" >&2
      return 1
    fi
  done
  return 0
}
