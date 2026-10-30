#!/usr/bin/env bash
# fm-fast-lib.sh - fewer forks and no whole-log fold on the hot status paths
# (applypass fork only; sourced, never run).
#
# bin/fm-classify-lib.sh sources this file from a Fork-only block at its end, so
# every definition below replaces the one that file just made. Each replacement
# returns the same value for the same input; only the number of processes and
# the amount of the log read change. Why they are here: the wake drain and the
# answer send call these helpers a few hundred times per run, and a fork costs
# about 4 ms on this host, so the helpers decide the captain's wait.
#
#   _fm_open_decisions_file_ident   one stat instead of three
#   _fm_open_decisions_cursor_path  parameter expansion instead of dirname and basename
#   fm_fast_status_open_decisions   the open set read through the per-log cursor
#                                   (status_open_decisions_incremental), not a
#                                   bash fold over the whole log; fm-send's
#                                   --resolve-key checks use it
#   fm_full_status_open_decisions   the whole-log fold, kept for an explicit kind
#   IFS=$(printf '\t')              a literal tab in the two manifest readers that fork for it
#
# tests/fm-scripts-fast.test.sh pins the equality with the whole-log fold and the
# time bounds.

# The upstream whole-log fold under a second name, before any caller replaces
# status_open_decisions with the wrapper below.
if command -v status_open_decisions >/dev/null 2>&1 && ! command -v fm_full_status_open_decisions >/dev/null 2>&1; then
  eval "fm_full_status_open_decisions() $(declare -f status_open_decisions | tail -n +2)"
fi

# `IFS=$(printf '\t') read ...` forks a subshell on every pass of a loop; the
# presentation and backstop cursor readers run it once per manifest row, about
# 1,500 times per drain. Rewrite those two functions with the tab as a literal. If
# upstream words the line differently the pattern misses and the functions stay
# as they were: slower, never different.
_fm_fast_literal_tab() {
  local body
  body=$(declare -f status_presentation_cursor_offset status_outcome_backstop_cursor_offset 2>/dev/null)
  case "$body" in
    *"IFS=\$(printf '\\t')"*) ;;
    *) return 0 ;;
  esac
  eval "$(printf '%s\n' "$body" | sed "s/IFS=\$(printf '\\\\t')/IFS=\$'\\\\t'/g")"
}
_fm_fast_literal_tab
unset -f _fm_fast_literal_tab

# Same contract as upstream: "strong:<dev>:<inode>:<birth>" when the file system
# reports a birth time, else "weak:<dev>:<inode>"; nonzero when the file cannot
# be read or the value would hold a tab or newline.
_fm_open_decisions_file_ident() {  # <file> -> strongest available identity
  local f=$1 out ident epoch birth
  if [ -n "${FM_STATUS_IDENTITY_READER:-}" ]; then
    "$FM_STATUS_IDENTITY_READER" "$f"
    return
  fi
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    out=$(LC_ALL=C /usr/bin/stat -f '%d:%i %B %FB' "$f" 2>/dev/null) || return 1
  else
    out=$(LC_ALL=C stat -c '%d:%i %W %w' "$f" 2>/dev/null) || return 1
  fi
  ident=${out%% *}
  out=${out#* }
  epoch=${out%% *}
  birth=${out#* }
  [ "$epoch" != 0 ] || birth=''
  case "$ident$birth" in *$'\t'* | *$'\n'* | '') return 1 ;; esac
  if [ -n "$birth" ]; then printf 'strong:%s:%s' "$ident" "$birth"; else printf 'weak:%s' "$ident"; fi
}

_fm_open_decisions_cursor_path() {  # <status-file>
  local f=$1 dir base
  case "$f" in
    */*) dir=${f%/*}; [ -n "$dir" ] || dir=/ ;;
    *) dir=. ;;
  esac
  base=${f##*/}
  printf '%s/.%s.open-decisions-cursor' "$dir" "${base%.status}"
}

# The open set of one status log, read through its cursor: only bytes appended
# since the last fold are folded again. An explicit kind keeps the whole-log
# fold, because the cursor records the kind the log itself implies.
fm_fast_status_open_decisions() {  # <status-file> [<kind>]
  if [ -n "${2:-}" ]; then
    fm_full_status_open_decisions "$@"
    return
  fi
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ] || return 0
  status_open_decisions_incremental "$1"
}
