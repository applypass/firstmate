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
#     command substitution is allowed only if each part is). Scripts: exact names,
#     run by bare name or from a bin/ path. One rule: a script is listed only when
#     AGENTS.md, an agent skill, or the emitted supervision protocol directs the main
#     firstmate to run it. The reason for each (the list is ALLOWED_SCRIPTS in
#     bin/fm-main-orchestration-policy.mjs, and a test keeps the two equal):
#       fm-wake-drain.sh - AGENTS.md section 8: drain the wake queue first
#       fm-send.sh - AGENTS.md section 7: steer a worker
#       fm-spawn.sh - AGENTS.md section 7: dispatch a worker
#       fm-control.sh - AGENTS.md section 7: interrupt, exit, relaunch a worker
#       fm-decide.sh - the only writer of data/decided.md (decisions)
#       fm-captain-hold.sh - AGENTS.md section 10: hold a task for the captain
#       fm-pr-merge.sh - AGENTS.md section 7: every task PR merge
#       fm-tasks-axi.sh - AGENTS.md section 10: the backlog
#       fm-crew-state.sh - AGENTS.md section 2: current crew state
#       fm-peek.sh - stuck-crewmate-recovery: read a worker's endpoint
#       fm-update.sh - updatefirstmate skill: self-update
#       fm-fleet-sync.sh - AGENTS.md section 8: refresh a clone after a merged PR
#       fm-dispatch-resolve.sh - AGENTS.md section 4: resolve the dispatch profile
#       fm-project-mode.sh - AGENTS.md section 7: delivery mode at intake
#       fm-brief.sh - AGENTS.md section 11: write a worker's instructions
#       fm-home-seed.sh - secondmate-provisioning: create a secondmate home
#       fm-branch-outcome.sh - supervision protocol: list branch outcomes for the captain
#       fm-teardown.sh - ship-landing: cleanup after landing
#       fm-pr-check.sh - ship-landing: arm merge monitoring on a PR
#       fm-shortcut-ticket.sh - backlog intake creates the Shortcut story
#       fm-fleet-view.sh - AGENTS.md section 8: the fleet view on a heartbeat
#       fm-lease.sh - supervision protocol: claim a task lease before steering
#       fm-watch-arm.sh - supervision protocol: arm the live supervision cycle
#       fm-session-start.sh - AGENTS.md section 3: session start
#       fm-afk-return.sh - afk skill: the return brief
#       fm-secondmate-restart.sh - secondmate lifecycle: restart a secondmate
#       fm-backlog-handoff.sh - AGENTS.md section 10: hand backlog to a secondmate
#       fm-check-register.sh - ship-landing: bind a custom check
#       fm-inbox.sh - AGENTS.md section 8: the captain inbox
#       fm-merge-local.sh - AGENTS.md section 7: approved local-only landing
#       fm-capacity.sh - AGENTS.md section 10: lane capacity report
#       fm-task-ledger.sh - merge path: record pr-ready and captain-approval, which fm-pr-merge.sh requires
#       fm-afk-launch.sh - afk and quiet skills: enter, stop, and check the away or quiet posture
#       fm-afk-contract.sh - afk and quiet skills: read or record the posture record
#       fm-afk-start.sh - afk skill: the away daemon entry, run through the native background tool
#       fm-operational-input.sh - afk skill: open an operational input doorbell
#   - tasks-axi and quota-axi (backlog; AGENTS.md section 4 dispatch intake); shell
#     builtins and echo, printf, date, test; readers (cat, head, tail, grep, sed, ls,
#     jq, find, ...) and writers (mkdir, cp, mv, rm, touch, tee, > redirects) whose
#     every path is a fleet record: data/, state/, or config/ of the main home, or
#     the main home's own project memory dir (<config>/projects/<home path with
#     non-alphanumerics as "-">/memory); filters that read only a pipe.
#   - READ ONLY (Read, and the readers cat, head, tail, grep, sed, wc, ...): any file
#     under the data/ dir of a registered second mate home (the home: field of each
#     data/secondmates.md line), and main's own background-task output files, from any
#     session (<tmp>/claude-<uid>/<home path with non-alphanumerics as "-">/<session>/
#     tasks/*.output), never another project's. Never a write or edit, never HTML,
#     never a mate's projects/ or worktrees.
#   - Read, Grep, Glob, Edit, Write on those same records; Read of a .png or .mp4 file
#     (frames a worker hands over); Read of this session's own tool-results files
#     (the harness directory named by the payload's session id); the
#     Skill, ToolSearch, ReadNotifications, SendUserFile, and AskUserQuestion tools.
#   - Artifact publish only for a file a mate produced: its path is under a
#     registered second mate's home data/ (data/secondmates.md) or is a worker
#     report path, data/<id>/report*.
#   - QUICK LOOKUPS, 2 per captain message (a typed or mid-turn message resets the
#     count; each command in a compound command counts once): `gh pr view`, `gh pr status`, `gh-axi pr view`, `gh-axi pr status`, and
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
# override. A turn with no captain message (a wake, a notification, a doorbell) gets the
# same allowance of 2 quick lookups, counted per turn: the turn starts at the latest
# user prompt or queued_command in the transcript (state/.reply-first-wake keeps the
# count and resets when a new turn starts). The reply-first 3-call window stays
# captain-only. With an unreadable transcript no turn can be found and the lookup
# is not counted.
#
# LOG. state/main-orchestration-refusals.log is append-only, one line per refusal:
#   <UTC time> tool=<name> group=<kind of work> msg=<message id> args=<short summary>
# The message id is the transcript's own: the queued_command attachment's source_uuid
# (else its uuid) for a mid-turn message, the prompt entry's uuid for a typed one, the
# latest turn-start entry's id on a turn with no captain message, and "-" when the
# transcript holds none. The summary is the command name, flags, and path-like operands
# only: no quoted text, no file contents, nothing near a token or password word.
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
  local payload verdict group summary tool transcript state window count override msg reason quick_n
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
  quick_n=$(printf '%s' "$verdict" | jq -r '.quickCount // 1' 2>/dev/null) || quick_n=1
  case "$quick_n" in ''|*[!0-9]*|0) quick_n=1 ;; esac
  [ "$state" != allow ] || exit 0
  case "$state" in quick|deny) ;; *) exit 0 ;; esac
  # The window's lookup count and override; a quick lookup counts as it is read.
  if [ "$state" = quick ]; then
    window=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-reply-first.sh" lookup --count "$quick_n" --transcript "$transcript" 2>/dev/null) || exit 0
  else
    window=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-reply-first.sh" lookup --peek --transcript "$transcript" 2>/dev/null) || exit 0
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
