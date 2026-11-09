#!/usr/bin/env bash
# Fork-only: fm-main-orchestration-guard.sh - the main firstmate orchestrates, a mate digs (applypass fork).
#
# usage:
#   <PreToolUse JSON on stdin> | fm-main-orchestration-guard.sh [--claude]
#   fm-main-orchestration-guard.sh enabled
#
# Decision main-orchestration-default-deny (sc-10268). The main session routes work
# and answers the captain; reading projects, running scripts, querying prod, and
# calling outside systems belong to a second mate or a worker. This PreToolUse hook
# is DEFAULT DENY: only the allowlist below runs, and every other call is refused
# and logged, so a new kind of work shows up in the log instead of slipping through.
# The refusal says: hand this to the owning mate via fm-send and tell the captain
# who has it.
#
# ALLOWED
#   - Bash where every part is allowed (a compound command, subshell, loop body, or
#     command substitution is allowed only if each part is): these exact scripts,
#     run by bare name or from a bin/ path, bin/fm-wake-drain.sh, fm-send.sh,
#     fm-spawn.sh, fm-control.sh, fm-decide.sh, fm-captain-hold.sh, fm-pr-merge.sh,
#     fm-tasks-axi.sh, fm-crew-state.sh, fm-peek.sh, fm-update.sh, fm-fleet-sync.sh,
#     fm-dispatch-resolve.sh, fm-project-mode.sh, fm-brief.sh, fm-home-seed.sh,
#     fm-branch-report.sh, fm-branch-outcome.sh, fm-teardown.sh, fm-pr-check.sh,
#     fm-shortcut-ticket.sh, fm-fleet-view.sh, fm-lease.sh, fm-watch-arm.sh,
#     fm-session-start.sh, fm-afk-return.sh, fm-secondmate-restart.sh,
#     fm-backlog-handoff.sh, fm-task-ledger.sh, fm-check-register.sh, fm-inbox.sh
#     (the list is ALLOWED_SCRIPTS in bin/fm-main-orchestration-policy.mjs); tasks-axi
#     and quota-axi; shell builtins and echo, printf, date, test; readers (cat, head,
#     tail, grep, sed, ls, jq, find, ...) and writers (mkdir, cp, mv, rm, touch, tee,
#     > redirects) whose every path is a fleet record: data/, state/, or config/ of
#     the main home, or the memory dir; filters that read only a pipe.
#   - Read, Grep, Glob, Edit, Write on those same records; Read of any png, jpg, gif,
#     webp, mp4, mov, or webm file (frames a worker hands over); the Skill,
#     ToolSearch, ReadNotifications, SendUserFile, and AskUserQuestion tools.
#   - Artifact publish only for a file a mate produced: its path is under a
#     registered second mate's home data/ (data/secondmates.md) or is a worker
#     report path, data/<id>/report*.
#   - QUICK LOOKUPS, 2 per captain message (a typed or mid-turn message resets the
#     count): `gh pr view`, `gh pr status`, `gh-axi pr view`, `gh-axi pr status`, and
#     Artifact list. The third in one message is refused.
#
# REFUSED AND LOGGED: Agent and Workflow subagents, MCP tools (SigNoz, Vercel,
# Metabase, Stripe, Gmail, Krisp, Shortcut, browsers), browser tools, WebSearch and
# WebFetch, sleep and poll loops, edits to hooks, settings, and sys-config, running
# tests or scripts, any read or edit of a project clone or worktree, git, prod
# psql, doctl, vercel, and deploys, and any command not named above.
#
# OVERRIDE. A captain message containing one of these phrases lifts the whole check
# for the rest of that message's window: "look yourself", "look it up yourself",
# "look at it yourself", "check yourself", "check it yourself", "dig yourself",
# "dig in yourself" (any case). The next captain message restores it.
#
# WINDOW. The captain-message window is bin/fm-reply-first.sh's (state/.reply-first):
# this hook calls `fm-reply-first.sh midturn` first, so a message typed at the prompt
# and a message the captain sent mid-turn both reset the lookup count and the
# override. With no window (a wake turn, after the Stop hook), quick lookups are not
# counted; everything else is classified the same way.
#
# LOG. state/main-orchestration-refusals.log is append-only, one line per refusal:
#   <UTC time> tool=<name> group=<kind of work> msg=<window epoch or -> args=<short summary>
# The summary is the command name, flags, and path-like operands only: no quoted
# text, no file contents, nothing near a token or password word.
#
# SCOPE. The primary firstmate home only. It is inert in a second mate home (a
# .fm-secondmate-home marker), in a linked task worktree, and outside a firstmate
# checkout (bin/fm-primary-scope-lib.sh). The word "off" in
# config/main-orchestration-guard turns it off for a home. A payload it cannot read,
# a missing jq or node, or a policy error allows the call silently: a broken hook
# never blocks work. Existing guards (fm-cd-pretool-check.sh, fm-subagent-pretool-check.sh,
# fm-op-pretool-check.sh, fm-new-task-guard.sh) run alongside it unchanged.
#
# Registered by bin/fm-mate-hooks-install.sh --main (PreToolUse, matcher .*).
# docs/captain-direct-mate-access.md owns the operator view.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${CLAUDE_PROJECT_DIR:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
LOG="$STATE/main-orchestration-refusals.log"
LIMIT=${FM_MAIN_LOOKUP_LIMIT:-2}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=2 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# 0 when the guard is on for this home: the primary home, never a mate or worktree.
enabled() {
  [ -d "$STATE" ] || return 1
  [ -f "$CONFIG/main-orchestration-guard" ] && [ "$(tr -d '[:space:]' < "$CONFIG/main-orchestration-guard")" = off ] && return 1
  fm_root_is_secondmate_home "$FM_HOME" && return 1
  fm_primary_root_matches "$FM_HOME"
}

refuse() {  # <tool> <group> <msg> <summary> <reason>
  local tool=$1 group=$2 msg=$3 summary=$4 reason=$5 escaped
  printf '%s tool=%s group=%s msg=%s args=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tool" "$group" "$msg" "$summary" >> "$LOG" 2>/dev/null || true
  escaped=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  exit 2
}

cmd_pretool() {
  local payload verdict group summary tool transcript state window count override msg reason
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  command -v node >/dev/null 2>&1 || exit 0
  enabled || exit 0
  tool=$(printf '%s' "$payload" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
  [ -n "$tool" ] || exit 0
  transcript=$(printf '%s' "$payload" | jq -r '(.transcript_path // empty)' 2>/dev/null) || transcript=
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-reply-first.sh" midturn "$transcript" >/dev/null 2>&1 || true
  verdict=$(printf '%s' "$payload" | node "$SCRIPT_DIR/fm-main-orchestration-policy.mjs" --home "$FM_HOME" 2>/dev/null) || exit 0
  group=$(printf '%s' "$verdict" | jq -r '.group // empty' 2>/dev/null) || exit 0
  state=$(printf '%s' "$verdict" | jq -r '.verdict // empty' 2>/dev/null) || exit 0
  summary=$(printf '%s' "$verdict" | jq -r '.summary // empty' 2>/dev/null) || summary=
  [ "$state" != allow ] || exit 0
  case "$state" in quick|deny) ;; *) exit 0 ;; esac
  # The window's lookup count and override; a quick lookup counts as it is read.
  if [ "$state" = quick ]; then
    window=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-reply-first.sh" lookup 2>/dev/null) || exit 0
  else
    window=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-reply-first.sh" lookup --peek 2>/dev/null) || exit 0
  fi
  read -r count override msg <<< "$window"
  case "$count" in ''|*[!0-9]*) exit 0 ;; esac
  [ "${override:-0}" != 1 ] || exit 0
  reason="[main-orchestration] This call was not run: the main session routes work and answers the captain, and does not do this itself ($group). Hand this to the owning mate via fm-send (or start one with fm-spawn) and tell the captain who has it. For a quick answer the captain can say \"look yourself\" for one message."
  if [ "$state" = quick ]; then
    [ "$count" -gt "$LIMIT" ] || exit 0
    reason="[main-orchestration] This call was not run: $LIMIT quick lookups are used for this captain message. Hand the rest to the owning mate via fm-send and tell the captain who has it, or answer with what you have."
    group=quick-lookup-limit
  fi
  refuse "$tool" "$group" "${msg:--}" "$summary" "$reason"
}

case "${1:-}" in
  --claude|'') cmd_pretool ;;
  enabled) enabled; exit $? ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
