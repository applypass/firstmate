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
# Three correctness rules the measurement must keep:
#   1. Dedupe a multi-block turn by requestId. Several JSONL lines share one
#      turn's usage; summing them would multiply the real total.
#   2. Take LAST, never max. Compaction RESETS the running total, so a max
#      implementation would latch the pre-compaction peak and disable the guard
#      forever after the first compaction.
#   3. Exclude sidechains. isSidechain==true marks subagent turns, which must
#      never inflate the primary's measurement.
#
# TWO STAGES, ONE POLICY NUMBER: the ceiling is the only policy number. The
# advisory notice is DERIVED as ceiling - headroom, so there is never a second
# threshold to keep in sync. Both are env-overridable for tests and live proof.
#
# THE ONE VALVE: write a handoff and clear. This guard instructs and never types
# into a pane: it never injects /compact, /clear, or any other command, and it
# never spawns a replacement agent. docs/context-budget.md records the away-mode
# limitation this creates.
#
# NEVER WEDGE A SESSION: every measurement failure - absent jq, missing or
# unreadable transcript_path, missing or corrupt transcript, no assistant usage,
# empty or malformed stdin - is a silent exit 0. Blocking is bounded by
# FM_CONTEXT_BUDGET_BLOCK_BUDGET and then degrades to a visible warning, the same
# pattern bin/fm-turnend-guard.sh uses for FM_CLAUDE_TURNEND_BLOCK_BUDGET.
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

BUDGET_FILE="$STATE/.context-budget-blocks"
ADVISORY_FILE="$STATE/.context-budget-advisory"
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
# jq -R with fromjson? drops malformed or truncated lines instead of aborting, so
# a partially written transcript degrades to "measure what parsed" rather than to
# an error. The slurped pass then applies the three correctness rules.
measure_context() {
  jq -R 'fromjson? // empty' "$TRANSCRIPT" 2>/dev/null | jq -s '
    def usage_total:
      (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
      + (.cache_read_input_tokens // 0) + (.output_tokens // 0);
    [ .[]
      | select((.isSidechain != true)
        and (.type == "assistant")
        and ((.message.usage | type) == "object")) ]
    | if length == 0 then empty
      else
        # LAST, never max: compaction resets the running total.
        (.[-1].requestId) as $rid
        # Dedupe a multi-block turn: one requestId is one turn, so take the
        # final usage object of that turn rather than summing its blocks.
        | [ .[] | select($rid == null or .requestId == $rid) ][-1]
        | .message.usage
        | usage_total
        | floor
      end
  ' 2>/dev/null
}

TOTAL=$(measure_context) || exit 0
case "$TOTAL" in
  ''|*[!0-9]*) exit 0 ;;
esac

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')

budget_reset() {
  rm -f "$BUDGET_FILE" 2>/dev/null || true
}

# --- below the advisory: silent, and re-arm the advisory for a later episode ---
if [ "$TOTAL" -lt "$ADVISORY" ]; then
  budget_reset
  rm -f "$ADVISORY_FILE" 2>/dev/null || true
  exit 0
fi

# --- between advisory and ceiling: one non-blocking notice per episode ---------
if [ "$TOTAL" -lt "$CEILING" ]; then
  budget_reset
  seen=$(cat "$ADVISORY_FILE" 2>/dev/null || true)
  if [ "$seen" != "$SESSION_ID" ]; then
    printf '%s\n' "$SESSION_ID" > "$ADVISORY_FILE" 2>/dev/null || true
    {
      printf '●%s\n' "$RULE"
      printf '●  CONTEXT BUDGET ADVISORY - %s tokens, ceiling %s\n' "$TOTAL" "$CEILING"
      printf '●  About %s tokens of headroom left before the turn end is blocked.\n' "$((CEILING - TOTAL))"
      printf '●  Prefer cheap actions now and avoid large reads.\n'
      printf '●  Run /stow, write a handoff note, and clear before the ceiling forces it.\n'
      printf '●%s\n' "$RULE"
    } >&2
  fi
  exit 0
fi

# --- at or above the ceiling: block, bounded --------------------------------
COUNT=0
if [ -f "$BUDGET_FILE" ]; then
  old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$old_count" in
    ''|*[!0-9]*) old_count=0 ;;
  esac
  [ "$old_session" = "$SESSION_ID" ] && COUNT=$old_count
fi
COUNT=$((COUNT + 1))

if [ "$COUNT" -gt "$BLOCK_BUDGET" ]; then
  # Never wedge: the session must always be able to end. Degrade to a visible
  # message rather than blocking past the budget.
  budget_reset
  printf '{"systemMessage":"firstmate context budget: this session measures %s tokens, over the %s ceiling, and the block budget is exhausted so this turn end is allowed. Run /stow, write a handoff note, and clear before continuing."}\n' \
    "$TOTAL" "$CEILING"
  exit 0
fi
printf 'session=%s\ncount=%s\n' "$SESSION_ID" "$COUNT" > "$BUDGET_FILE" 2>/dev/null || true

{
  printf '●%s\n' "$RULE"
  printf '●  CONTEXT BUDGET CEILING REACHED - HAND OFF AND CLEAR\n'
  printf '●  This session measures %s tokens, over the %s ceiling.\n' "$TOTAL" "$CEILING"
  printf '●  Take the valve now, before any other work:\n'
  printf '●    1. Run /stow to write durable knowledge, decisions, and unfinished work to disk.\n'
  printf '●    2. Write a handoff note naming what you were doing and the exact next step.\n'
  printf '●    3. Clear the context and resume from the stowed record.\n'
  printf '●  This is a cost and reasoning-quality policy, not an overflow warning.\n'
  printf '●%s\n' "$RULE"
} >&2
exit 2
