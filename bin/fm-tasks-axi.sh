#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
# Otherwise the exit status is tasks-axi's own.
#
# After a successful `add` (or `create`) with the Shortcut ticket feature on,
# bin/fm-shortcut-ticket.sh gives the new item a Shortcut story; its failure
# only warns and never changes the add's exit status.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
# Fork-only: cancelling (rm) or parking (hold --kind parked) an item sends its
# story back to Backlog with the reason (best-effort), once tasks-axi succeeds.
# rm resolves the story first because the item is gone afterwards.
SC_ITEM='' SC_KIND='' SC_REASON='' sc_prev=''
for arg in "${@:2}"; do
  case "$sc_prev" in
    --kind) SC_KIND=$arg; sc_prev=; continue ;;
    --reason) SC_REASON=$arg; sc_prev=; continue ;;
    --until) sc_prev=; continue ;;
  esac
  case "$arg" in
    --kind | --reason | --until) sc_prev=$arg ;;
    --kind=*) SC_KIND=${arg#*=} ;;
    --reason=*) SC_REASON=${arg#*=} ;;
    -*) ;;
    *) [ -n "$SC_ITEM" ] || SC_ITEM=$arg ;;
  esac
done
SC_PARK=''
case "${1:-}" in
  rm | delete)
    [ -z "$SC_ITEM" ] || SC_ITEM=$("$SCRIPT_DIR/fm-shortcut-ticket.sh" --linked "$SC_ITEM" --best-effort 2>/dev/null)
    SC_PARK="cancelled: removed from the backlog"
    ;;
  hold) [ "$SC_KIND" != parked ] || SC_PARK="parked: $SC_REASON" ;;
esac
case "${1:-}" in
  add | create) ;;
  rm | delete | hold)
    tasks-axi ${ARGS[@]+"${ARGS[@]}"}
    RC=$?
    [ "$RC" -ne 0 ] || [ -z "$SC_PARK" ] || [ -z "$SC_ITEM" ] ||
      "$SCRIPT_DIR/fm-shortcut-ticket.sh" park "$SC_ITEM" --reason "$SC_PARK" --best-effort >&2 || true
    exit "$RC"
    ;;
  *) exec tasks-axi ${ARGS[@]+"${ARGS[@]}"} ;;
esac

OUT=$(tasks-axi ${ARGS[@]+"${ARGS[@]}"})
RC=$?
printf '%s\n' "$OUT"
if [ "$RC" -eq 0 ] && "$SCRIPT_DIR/fm-shortcut-ticket.sh" --enabled; then
  NEW_ID=$(printf '%s\n' "$OUT" | sed -n 's/^  id: *//p' | head -1)
  [ -n "$NEW_ID" ] || NEW_ID=$(printf '%s\n' "$OUT" | jq -r '.task.id // empty' 2>/dev/null)
  if [ -n "$NEW_ID" ]; then
    "$SCRIPT_DIR/fm-shortcut-ticket.sh" "$NEW_ID" >&2 ||
      printf 'fm-tasks-axi: warning: no Shortcut ticket for %s; retry with bin/fm-shortcut-ticket.sh %s\n' "$NEW_ID" "$NEW_ID" >&2
  fi
fi
exit "$RC"
