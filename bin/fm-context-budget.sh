#!/usr/bin/env bash
# Context-budget guardrail for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. Crew subagent turns are inert (see the scoping block
# and the sidechain filter below, and docs/context-budget.md).
#
# WHY: the captain's sessions balloon toward ~800,000 tokens before the runtime's
# own auto-compaction fires. This guard is a deliberate keep-it-lean cost and
# reasoning-quality policy that stops that balloon far earlier than anything the
# harness does on its own. It is NOT overflow prevention - nothing crashes at the
# ceiling on a 1M-context session.
#
# WHAT IT MEASURES: no hook payload on any harness carries a token count, so the
# number comes from the transcript the payload points at. transcript_path is read
# from the PAYLOAD and never derived from $HOME, because a non-default Claude
# config dir puts it somewhere $HOME cannot predict. The context total is the sum
# of input_tokens + cache_creation_input_tokens + cache_read_input_tokens +
# output_tokens on the LAST non-sidechain type=="assistant" entry. That formula
# reproduces Claude Code's own accounting exactly; docs/verification/context-
# budget.md records the cross-validation.
#
# Two correctness rules the measurement must keep:
#   1. Take LAST, never max and never a sum. Compaction RESETS the running total,
#      so a max implementation would latch the pre-compaction peak and disable
#      the guard forever after the first compaction, and a sum would report a
#      multiple of the real total. Taking the last entry also subsumes
#      multi-block dedupe for free: every JSONL line of one multi-block turn
#      carries that turn's own cumulative usage, so the last line IS the turn's
#      total and no requestId grouping is needed.
#   2. Exclude sidechains. isSidechain==true marks subagent turns, which must
#      never inflate the primary's measurement.
# The measurement is ONE streaming jq pass that filters and projects as it reads,
# so a multi-hundred-megabyte transcript costs constant memory on a hook that
# runs at every single turn end.
#
# TWO STAGES, ONE POLICY NUMBER: the ceiling is the only policy number. The
# advisory notice is DERIVED as ceiling - headroom, so there is never a second
# threshold to keep in sync. Both are env-overridable for tests and live proof.
#
# WARNING ONLY BY DEFAULT: at the ceiling the shipped default WARNS and allows
# the turn end. Enforcement is fully implemented and switched on with
# FM_CONTEXT_BUDGET_ENFORCE=1, because a first release must observe the real
# frequency of ceiling crossings before it is allowed to interrupt anyone.
#
# THE ONE VALVE: write a handoff and clear. This guard instructs and never types
# into a pane: it never injects /compact, /clear, or any other command, and it
# never spawns a replacement agent. docs/context-budget.md records the away-mode
# consequence this creates.
#
# NEVER WEDGE A SESSION: every measurement failure - absent jq, missing or
# unreadable transcript_path, missing or corrupt transcript, no assistant usage,
# empty or malformed stdin - is a silent exit 0. When enforcement is on, blocking
# is bounded by FM_CONTEXT_BUDGET_BLOCK_BUDGET and then STANDS DOWN STICKILY for
# the rest of the session, re-arming only once the measurement drops back below
# the advisory. That is deliberately unlike bin/fm-turnend-guard.sh, which resets
# its budget on every allow: a blind turn end is a repairable condition and a
# forced continuation is the repair prompt, whereas the context ceiling cannot
# clear without a captain keystroke, so blocking again would only re-run the
# handoff and grow the very context this guard exists to cap.
#
# Ships as a TRACKED Stop hook, so this file is checked out into every worktree
# of this repo, including crewmate and scout task worktrees. It therefore scopes
# itself at runtime through the shared primary predicate and stays a silent, fast
# no-op inside child task worktrees.
#
# Per-harness support is claude only in this slice. docs/context-budget.md owns
# the honest per-harness table.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CLAUDE_MODE=0

# The ceiling is the enforce point and the ONLY policy number.
CEILING=${FM_CONTEXT_BUDGET_CEILING:-180000}
# The advisory notice is derived: ceiling - headroom. Headroom buys the session
# one warning while it still has room to run the valve. The default 30,000 is
# about two worst-case turns (measured max single-turn delta 17,050) on top of
# the valve's own cost.
HEADROOM=${FM_CONTEXT_BUDGET_HEADROOM:-30000}
BLOCK_BUDGET=${FM_CONTEXT_BUDGET_BLOCK_BUDGET:-3}
# Enforcement is opt-in. Anything other than an exact 1 leaves the shipped
# warning-only default in place, so a typo can never start blocking sessions.
ENFORCE=0
[ "${FM_CONTEXT_BUDGET_ENFORCE:-}" = 1 ] && ENFORCE=1
case "$CEILING" in ''|*[!0-9]*|0) CEILING=180000 ;; esac
case "$HEADROOM" in ''|*[!0-9]*) HEADROOM=30000 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac
ADVISORY=$((CEILING - HEADROOM))
[ "$ADVISORY" -gt 0 ] || ADVISORY=$CEILING

for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    -h|--help) sed -n '2,${/^set -u/q;p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: $(basename "$0") --claude" >&2; exit 0 ;;
  esac
done

# --claude is the only supported mode in this slice, and it is required rather
# than a default. Claude is the only harness whose turn-end payload carries a
# transcript pointer this guard can measure; docs/context-budget.md owns the
# per-harness table. A bare or misconfigured invocation is inert rather than a
# usage error, because this runs as a Stop hook and must never wedge a session.
if [ "$CLAUDE_MODE" -ne 1 ]; then
  echo "usage: $(basename "$0") --claude" >&2
  exit 0
fi

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# The consecutive-block record doubles as the STICKY stand-down record: once the
# count passes the budget it stays past it, and only a measurement back below the
# advisory removes the file.
BUDGET_FILE="$STATE/.context-budget-blocks"
# Which visible notice stage this session has already been shown, so neither the
# advisory nor the warning-only ceiling notice repeats inside one episode.
NOTICE_FILE="$STATE/.context-budget-notice"
RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# Read the whole turn-end hook payload once; never block on unreadable or absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Scope precisely to a PRIMARY checkout, before any JSON work. A genuinely-marked
# secondmate home runs its OWN primary firstmate session and is force-included;
# an unmarked linked worktree (every crewmate and scout task worktree) falls
# through and exits. Scoping first keeps the common case in a busy fleet - a
# crewmate turn end - down to a couple of git calls with no jq spawn at all.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# jq is the repo's established JSON dependency (bin/fm-turnend-guard.sh:95 uses
# the same "missing jq -> silent no-op" degrade). Without it we cannot read the
# payload or the transcript at all, so we must never block.
command -v jq >/dev/null 2>&1 || exit 0

TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
[ -n "$TRANSCRIPT" ] || exit 0
[ -f "$TRANSCRIPT" ] || exit 0
[ -r "$TRANSCRIPT" ] || exit 0

# --- the measurement ---------------------------------------------------------
# ONE streaming pass: jq -R reads a line at a time, drops it unless it parses to
# a JSON OBJECT that is a countable assistant entry, and emits just that entry's
# total. Nothing is slurped, so cost is constant in the transcript's size rather
# than proportional to it - this runs at every turn end, including the common
# case far below the advisory.
#   fromjson? drops malformed or truncated lines instead of aborting, so a
#   partially written transcript degrades to "measure what parsed".
#   select(type == "object") drops a line that parses to a valid JSON SCALAR,
#   which would otherwise make the .isSidechain lookup a hard jq error and abort
#   the whole measurement.
# sed takes the last emitted total, which is the LAST rule; the trailing sed is
# already a dependency of this script, so the pass adds no new tool.
measure_context() {
  jq -R -c '
    def usage_total:
      (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
      + (.cache_read_input_tokens // 0) + (.output_tokens // 0);
    (fromjson? // empty)
    | select(type == "object")
    | select((.isSidechain != true)
      and (.type == "assistant")
      and ((.message.usage | type) == "object"))
    | .message.usage
    | usage_total
    | floor
  ' "$TRANSCRIPT" 2>/dev/null | sed -n '$p'
}

TOTAL=$(measure_context) || exit 0
case "$TOTAL" in
  ''|*[!0-9]*) exit 0 ;;
esac

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')

# True when this session has already been shown the named notice stage.
notice_seen() {  # <stage>
  local seen_session seen_stage
  seen_session=$(sed -n '1s/^session=//p' "$NOTICE_FILE" 2>/dev/null || true)
  seen_stage=$(sed -n '2s/^stage=//p' "$NOTICE_FILE" 2>/dev/null || true)
  [ "$seen_session" = "$SESSION_ID" ] && [ "$seen_stage" = "$1" ]
}

notice_record() {  # <stage>
  printf 'session=%s\nstage=%s\n' "$SESSION_ID" "$1" > "$NOTICE_FILE" 2>/dev/null || true
}

budget_count() {
  local old_session old_count
  old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$old_count" in
    ''|*[!0-9]*) old_count=0 ;;
  esac
  [ "$old_session" = "$SESSION_ID" ] || old_count=0
  printf '%s' "$old_count"
}

budget_record() {  # <count>
  printf 'session=%s\ncount=%s\n' "$SESSION_ID" "$1" > "$BUDGET_FILE" 2>/dev/null || true
}

valve_lines() {
  printf '●  Take the valve now, before any other work:\n'
  printf '●    1. Run /stow to write durable knowledge, decisions, and unfinished work to disk.\n'
  printf '●    2. Write a handoff note naming what you were doing and the exact next step.\n'
  printf '●    3. Clear the context and resume from the stowed record.\n'
}

# --- below the advisory: silent, and re-arm the whole episode -----------------
# This is the ONLY place the sticky stand-down is cleared, so a session that has
# already spent its block budget is never blocked again until it genuinely drops
# back under the advisory.
if [ "$TOTAL" -lt "$ADVISORY" ]; then
  rm -f "$BUDGET_FILE" "$NOTICE_FILE" 2>/dev/null || true
  exit 0
fi

# --- between advisory and ceiling: one non-blocking notice per episode ---------
if [ "$TOTAL" -lt "$CEILING" ]; then
  notice_seen advisory && exit 0
  notice_record advisory
  {
    printf '●%s\n' "$RULE"
    printf '●  CONTEXT BUDGET ADVISORY - %s tokens, ceiling %s\n' "$TOTAL" "$CEILING"
    printf '●  About %s tokens of headroom left before the ceiling.\n' "$((CEILING - TOTAL))"
    printf '●  Prefer cheap actions now and avoid large reads.\n'
    printf '●  Run /stow, write a handoff note, and clear before the ceiling is reached.\n'
    printf '●%s\n' "$RULE"
  } >&2
  exit 0
fi

# --- at or above the ceiling, shipped default: warn once, never block ---------
if [ "$ENFORCE" -ne 1 ]; then
  notice_seen ceiling && exit 0
  notice_record ceiling
  {
    printf '●%s\n' "$RULE"
    printf '●  CONTEXT BUDGET CEILING REACHED - HAND OFF AND CLEAR\n'
    printf '●  This session measures %s tokens, over the %s ceiling.\n' "$TOTAL" "$CEILING"
    valve_lines
    printf '●  This is a warning: the ceiling does not block by default.\n'
    printf '●  This is a cost and reasoning-quality policy, not an overflow warning.\n'
    printf '●%s\n' "$RULE"
  } >&2
  exit 0
fi

# --- at or above the ceiling with enforcement on: block, bounded, then stand
# --- down stickily ------------------------------------------------------------
COUNT=$(($(budget_count) + 1))

if [ "$COUNT" -gt "$BLOCK_BUDGET" ]; then
  # Never wedge, and never nag: the ceiling cannot clear without the captain, so
  # once the budget is spent this guard stands down for the rest of the session
  # rather than oscillating between blocking and allowing. Clamp the recorded
  # count so the stand-down is a stable state, and say so exactly once.
  already_stood_down=0
  [ "$COUNT" -gt $((BLOCK_BUDGET + 1)) ] && already_stood_down=1
  budget_record $((BLOCK_BUDGET + 1))
  if [ "$already_stood_down" -eq 0 ]; then
    printf '{"systemMessage":"firstmate context budget: this session measures %s tokens, over the %s ceiling, and the block budget is exhausted so this guard now stands down for the rest of the session. Run /stow, write a handoff note, and clear before continuing."}\n' \
      "$TOTAL" "$CEILING"
  fi
  exit 0
fi
budget_record "$COUNT"

{
  printf '●%s\n' "$RULE"
  printf '●  CONTEXT BUDGET CEILING REACHED - HAND OFF AND CLEAR\n'
  printf '●  This session measures %s tokens, over the %s ceiling.\n' "$TOTAL" "$CEILING"
  valve_lines
  printf '●  This is a cost and reasoning-quality policy, not an overflow warning.\n'
  printf '●%s\n' "$RULE"
} >&2
exit 2
