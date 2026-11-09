#!/usr/bin/env bash
# fm-new-task-guard.sh - one task, one second mate (applypass fork).
#
# Usage: fm-new-task-guard.sh check <target-id>
#        <PreToolUse JSON on stdin> | fm-new-task-guard.sh hook [--claude]
#
# The rule: each task gets its own second mate. Main sending a second piece of
# new work to a mate that is already busy breaks it, so this script is the one
# owner of the refusal. bin/fm-send.sh --new-task calls `check`; the main
# session's PreToolUse hook (.claude/settings.json) calls `hook`, which calls
# the same `check`.
#
# check <target>   the --new-task rule; exit 1 with the remedy on stderr when:
#   - the target is a registered secondmate (data/secondmates.md) and its home
#     backlog has any In flight item; or its backlog cannot be read (the
#     message names what could not be read; a remote mate counts as unreadable);
#   - the fleet is at the cap: active entries = registered mates with an In
#     flight item + main's own In flight items. The cap is the number in
#     config/fleet-wip-cap (default 8). This refusal applies even when the
#     target mate is idle. The message lists each counted entry and flags every
#     registered mate with no In flight item as "idle - retire first". Another
#     mate whose backlog cannot be read (remote, or a stale home) counts as
#     active and is listed as "unreadable - counted as active: <reason>".
#   A target that is not a registered secondmate (an ordinary worker) passes.
# The mate backlog is read through bin/fm-tasks-axi.sh with FM_HOME set to the
# mate's home: a read-only `list --state in_flight`.
#
# hook: Claude PreToolUse for Bash, MAIN session only. It denies (exit 2, reason
# on stderr) an fm-send.sh call whose message starts "From firstmate (captain"
# when the call carries neither --new-task nor --same-task and the target mate
# has in-flight work. It is inert in a secondmate home (.fm-secondmate-home), in
# a linked task worktree, and outside a firstmate checkout. Malformed input
# fails open.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_HOME=${FM_HOME:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

REGISTRY="$FM_HOME/data/secondmates.md"

# inflight_ids <home>: prints the In flight item ids, one per line; returns 1
# and prints the reason on stderr when the backlog cannot be read.
inflight_ids() {
  local home=$1 out
  [ -d "$home" ] || { echo "home $home is not a directory" >&2; return 1; }
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE='' "$SCRIPT_DIR/fm-tasks-axi.sh" list --state in_flight 2>&1) || {
    echo "backlog read failed: $(printf '%s' "$out" | head -1)" >&2
    return 1
  }
  printf '%s\n' "$out" | sed -n 's/^  \([^ ,]*\),in_flight,.*/\1/p'
}

mate_field() { # <id> <field>
  secondmate_registry_field "$REGISTRY" "$1" "$2" 2>/dev/null
}

registered_ids() {
  [ -f "$REGISTRY" ] || return 0
  sed -n 's/^- \([A-Za-z0-9._-]*\) - .*/\1/p' "$REGISTRY"
}

remedy() {
  cat <<'EOF'
Each task gets its own second mate. Create one for this task instead:
  bin/fm-brief.sh <new-id> --secondmate ...        (write the charter brief)
  bin/fm-home-seed.sh <new-id> - ...               (seed the isolated home)
  bin/fm-spawn.sh <new-id> --secondmate            (launch it)
If this message continues the work already under way, resend it with --same-task.
EOF
}

check_busy() { # <target>: 0 passes, 1 refuses
  local target=$1 home remote ids
  secondmate_registry_line_for_id "$REGISTRY" "$target" || return 0
  remote=$(mate_field "$target" remote)
  home=$(mate_field "$target" home)
  if [ "$remote" = 1 ]; then
    echo "fm-new-task-guard: refused - cannot read the backlog of remote mate '$target' (no local home); resend with --same-task if this continues its work" >&2
    return 1
  fi
  if ! ids=$(inflight_ids "$home" 2>&1); then
    echo "fm-new-task-guard: refused - could not read the home backlog of mate '$target': $ids" >&2
    return 1
  fi
  [ -n "$ids" ] || return 0
  {
    echo "fm-new-task-guard: refused - mate '$target' already has in-flight work:"
    printf '%s\n' "$ids" | sed 's/^/  - /'
    remedy
  } >&2
  return 1
}

fleet_cap() {
  local v=
  [ -f "$FM_HOME/config/fleet-wip-cap" ] && v=$(tr -d '[:space:]' < "$FM_HOME/config/fleet-wip-cap")
  case "$v" in ''|*[!0-9]*) v=8 ;; esac
  printf '%s\n' "$v"
}

check_fleet_cap() { # 0 passes, 1 refuses
  local cap id home ids n active=0 lines='' idle='' unread='' main_ids
  cap=$(fleet_cap)
  for id in $(registered_ids); do
    home=$(mate_field "$id" home)
    if [ "$(mate_field "$id" remote)" = 1 ]; then
      ids="remote mate, no local home"
    elif ids=$(inflight_ids "$home" 2>&1); then
      if [ -n "$ids" ]; then
        n=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
        active=$((active + 1))
        lines="$lines  - mate $id: in flight ($n item(s): $(printf '%s' "$ids" | tr '\n' ' '))"$'\n'
      else
        idle="$idle  - mate $id: idle - retire first"$'\n'
      fi
      continue
    fi
    active=$((active + 1))
    unread="$unread  - mate $id: unreadable - counted as active: $ids"$'\n'
  done
  if main_ids=$(inflight_ids "$FM_HOME" 2>&1); then
    for id in $main_ids; do
      active=$((active + 1))
      lines="$lines  - main: in flight ($id)"$'\n'
    done
  else
    printf 'fm-new-task-guard: refused - the fleet count is unknown: main backlog could not be read: %s\n' "$main_ids" >&2
    return 1
  fi
  if [ "$active" -lt "$cap" ]; then
    [ -z "$unread" ] || printf 'fm-new-task-guard: note - %s of cap %s active, including:\n%s' "$active" "$cap" "$unread" >&2
    return 0
  fi
  {
    echo "fm-new-task-guard: refused - $active active entries, cap is $cap (config/fleet-wip-cap). Retire finished or idle mates before opening new work."
    printf '%s' "$lines"
    printf '%s' "$unread"
    printf '%s' "$idle"
  } >&2
  return 1
}

cmd_check() {
  local target=${1:-}
  [ -n "$target" ] && [ "$#" -eq 1 ] || { echo "usage: fm-new-task-guard.sh check <target-id>" >&2; return 2; }
  secondmate_registry_line_for_id "$REGISTRY" "$target" || return 0
  check_busy "$target" || return 1
  check_fleet_cap
}

# The hook's view of one command: sets HOOK_TARGET and HOOK_FLAGGED, and returns
# 0 only for an fm-send.sh call whose message starts with the captain prefix.
parse_send() { # <command>
  local rest word prefix='From firstmate (captain'
  HOOK_TARGET=; HOOK_FLAGGED=0
  case "$1" in *fm-send.sh*) ;; *) return 1 ;; esac
  rest=${1#*fm-send.sh}
  rest=${rest//$'\n'/ }
  # shellcheck disable=SC2086 # word splitting is the point; quoting is stripped below.
  set -- $rest
  while [ "$#" -gt 0 ]; do
    word=$1; shift
    case "$word" in
      --new-task|--same-task) HOOK_FLAGGED=1 ;;
      --resolve-key|--fire-and-forget) [ "$#" -eq 0 ] || shift ;;
      --*) ;;
      *)
        if [ -z "$HOOK_TARGET" ]; then
          HOOK_TARGET=${word//[\"\']/}
        else
          # First word of the text: it may be quoted and carries the prefix.
          word=${word//[\"\']/}
          rest="$word $*"
          case "$rest" in "$prefix"*) return 0 ;; esac
          return 1
        fi
        ;;
    esac
  done
  return 1
}

cmd_hook() {
  local claude=0 payload cmd root reason esc
  [ "${1:-}" != --claude ] || claude=1
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cmd=$(printf '%s' "$payload" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || return 0
  [ -n "$cmd" ] || return 0
  parse_send "$cmd" || return 0
  [ "$HOOK_FLAGGED" = 0 ] || return 0
  [ -n "$HOOK_TARGET" ] || return 0
  # Scope: the real primary checkout only.
  root=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || return 0
  [ -f "$root/AGENTS.md" ] || return 0
  [ ! -e "$root/.fm-secondmate-home" ] && [ ! -e "$FM_HOME/.fm-secondmate-home" ] || return 0
  [ "$(git -C "$root" rev-parse --git-dir 2>/dev/null)" = "$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" ] || return 0
  reason=$(check_busy "$HOOK_TARGET" 2>&1) && return 0
  reason="${reason} (A message that opens new work must use --new-task; one that continues work must use --same-task.)"
  esc=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$esc" >&2
  [ "$claude" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$esc"
  return 2
}

case "${1:-}" in
  check) shift; cmd_check "$@"; exit $? ;;
  hook) shift; cmd_hook "$@"; exit $? ;;
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: fm-new-task-guard.sh check <target-id> | hook [--claude]" >&2; exit 2 ;;
esac
