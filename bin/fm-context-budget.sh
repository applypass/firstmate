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
#   1. Take LAST, never max and never a sum. Compaction RESETS the running total,
#      so a max implementation would latch the pre-compaction peak and disable
#      the guard forever after the first compaction, and a sum would report a
#      multiple of the real total. Taking the last entry also subsumes
#      multi-block dedupe for free: every JSONL line of one multi-block turn
#      carries that turn's own cumulative usage, so the last line IS the turn's
#      total and no requestId grouping is needed.
#   2. Exclude sidechains. isSidechain==true marks subagent turns, which must
#      never inflate the primary's measurement.
#   3. Ignore zero-total entries. Claude Code writes SYNTHETIC assistant entries
#      - type=="assistant", isSidechain false, model "<synthetic>", all four
#      usage fields 0 - whenever a turn ends abnormally, such as a login or API
#      error or an interrupt, which is exactly when this hook fires. Counting one
#      would read a long session as empty, and that false zero would then look
#      like proof the context had reset.
# The measurement is ONE streaming jq pass that filters and projects as it reads,
# so its MEMORY is constant in the transcript's size. Its TIME is still linear -
# roughly 0.7 s per 80 MB on the measured host - and that cost is paid at every
# single turn end, including far below the advisory.
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
# TWO OUTPUT CHANNELS, CHOSEN BY EXIT STATUS: Claude Code DISCARDS a successful
# Stop hook's stderr - the hook_success attachment renders as null and only the
# SessionStart-family events feed hook output into model context - so every
# non-blocking notice here goes out as a {"systemMessage":...} object on STDOUT,
# the documented channel the runtime actually renders. Only the blocking path,
# which exits 2, uses stderr, because that path IS delivered to the model.
# docs/verification/context-budget.md records both readings.
#
# RECORD IDENTITY IS THE SESSION: both records are named per session_id, which is
# the identity of the context accumulation itself (the transcript file is
# literally <session_id>.jsonl). Two primary sessions in one home therefore
# cannot alias onto one record and wipe each other's stand-down. A missing or
# unsafe session_id makes the turn inert rather than merging distinct sessions
# under one shared identity, and the records are cleared only by a POSITIVE
# measurement back below the advisory - never by a zero, absent, or unreadable
# number, because losing a stand-down costs repeated forced handoffs while
# keeping a stale one costs at most one missed warning.
#
# THE ONE VALVE: write a handoff and clear. This guard instructs and never types
# into a pane: it never injects /compact, /clear, or any other command, and it
# never spawns a replacement agent. docs/context-budget.md records the away-mode
# consequence this creates.
#
# NEVER WEDGE A SESSION: every measurement failure - absent jq, missing or
# unreadable transcript_path, missing or corrupt transcript, no assistant usage,
# a zero measurement, no usable session_id, empty or malformed stdin - is a silent
# exit 0, and a block count that cannot be written degrades to the visible
# warning rather than to an unbounded block. When enforcement is on, blocking
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

# Pin the record location for the rest of this run. Canonicalizing once means a
# symlinked or relative state path cannot resolve to two different record
# locations across a session's invocations and split one session's records in
# two, which would silently re-arm a spent stand-down.
STATE=$(cd "$STATE" 2>/dev/null && pwd -P) || exit 0

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
# total. Nothing is slurped, so MEMORY is constant in the transcript's size; the
# time is still linear, and it is paid at every turn end including the common
# case far below the advisory.
#   fromjson? drops malformed or truncated lines instead of aborting, so a
#   partially written transcript degrades to "measure what parsed".
#   select(type == "object") drops a line that parses to a valid JSON SCALAR,
#   which would otherwise make the .isSidechain lookup a hard jq error and abort
#   the whole measurement.
#   select(. > 0) drops a synthetic zero-usage entry (rule 3 in the header): a
#   real long session never measures 0, so a 0 here is a missing measurement
#   masquerading as a reset, and taking the last POSITIVE total instead reports
#   the session's real size.
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
    | select(. > 0)
  ' "$TRANSCRIPT" 2>/dev/null | sed -n '$p'
}

TOTAL=$(measure_context) || exit 0
case "$TOTAL" in
  ''|*[!0-9]*) exit 0 ;;
esac
# A non-positive measurement is not evidence of anything: it means nothing
# countable was found, not that the context is empty. Stay completely inert on it
# rather than warning on a false number or treating it as proof of a drop.
[ "$TOTAL" -gt 0 ] || exit 0

# --- record identity ---------------------------------------------------------
# session_id is the identity of the context accumulation, so it names the
# records. A missing, empty, or unsafe id makes this turn inert: acting on a
# placeholder would merge two distinct sessions into one shared record, and an
# id that is not a plain filename token has no business in a path.
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
case "$SESSION_ID" in
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
[ "${#SESSION_ID}" -le 128 ] || exit 0

# The consecutive-block record doubles as the STICKY stand-down record: once the
# recorded standdown flag is set it stays set, and only a positive measurement
# back below the advisory removes the file.
BUDGET_FILE="$STATE/.context-budget-blocks-$SESSION_ID"
# Which visible notice stage this session has already been shown, so neither the
# advisory nor the warning-only ceiling notice repeats inside one episode.
NOTICE_FILE="$STATE/.context-budget-notice-$SESSION_ID"

# One session's records belong to that session and nothing else clears them, so
# prune only records old enough that no live session could own them. The sticky
# path refreshes its own record on every stood-down turn end, so pruning can
# never take a stand-down away from a session that is still running.
prune_dead_records() {
  find "$STATE" -maxdepth 1 -type f -name '.context-budget-*' -mtime +30 \
    -delete >/dev/null 2>&1 || true
}

# True when this session has already been shown the named notice stage.
notice_seen() {  # <stage>
  [ "$(sed -n '1s/^stage=//p' "$NOTICE_FILE" 2>/dev/null || true)" = "$1" ]
}

# A notice that cannot be recorded may repeat on a later turn end. That is the
# deliberate degrade: a repeated visible warning is harmless, while suppressing
# it would lose the only observable behavior the shipped default has.
notice_record() {  # <stage>
  [ -e "$NOTICE_FILE" ] || prune_dead_records
  printf 'stage=%s\nsession=%s\n' "$1" "$SESSION_ID" > "$NOTICE_FILE" 2>/dev/null || true
}

BUDGET_COUNT=0
BUDGET_STOOD_DOWN=0
# An unparseable count in an existing record is read as a spent stand-down, not
# as a fresh budget: re-arming on a record we cannot read is exactly the loss
# this record exists to prevent.
budget_read() {
  local raw_count raw_standdown
  [ -e "$BUDGET_FILE" ] || return 0
  raw_count=$(sed -n '1s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  raw_standdown=$(sed -n '2s/^standdown=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$raw_count" in
    ''|*[!0-9]*) BUDGET_STOOD_DOWN=1; return 0 ;;
  esac
  BUDGET_COUNT=$raw_count
  [ "$raw_standdown" = 1 ] && BUDGET_STOOD_DOWN=1
  return 0
}

# Returns non-zero when the record could not be persisted. The caller must then
# degrade toward NOT blocking: an unpersisted count cannot bound anything, so
# blocking on it would repeat every turn end with no bound at all.
budget_record() {  # <count> <standdown 0|1>
  [ -e "$BUDGET_FILE" ] || prune_dead_records
  printf 'count=%s\nstanddown=%s\nsession=%s\n' "$1" "$2" "$SESSION_ID" > "$BUDGET_FILE" 2>/dev/null
}

# A systemMessage object on stdout: the one channel a successful Stop hook has.
# jq builds it, compact and on one line, so a multi-line message is escaped
# correctly rather than by hand.
system_message() {  # <text>
  jq -n -c --arg msg "$1" '{systemMessage: $msg}'
}

valve_text() {
  printf 'Take the valve now, before any other work:\n'
  printf '  1. Run /stow to write durable knowledge, decisions, and unfinished work to disk.\n'
  printf '  2. Write a handoff note naming what you were doing and the exact next step.\n'
  printf '  3. Clear the context and resume from the stowed record.\n'
}

ceiling_text() {  # <closing line>
  printf 'CONTEXT BUDGET CEILING REACHED - HAND OFF AND CLEAR\n'
  printf 'This session measures %s tokens, over the %s ceiling.\n' "$TOTAL" "$CEILING"
  valve_text
  printf '%s\n' "$1"
  printf 'This is a cost and reasoning-quality policy, not an overflow warning.\n'
}

# One visible non-blocking notice per stage per episode, on stdout.
notice_once() {  # <stage> <text>
  notice_seen "$1" && return 0
  notice_record "$1"
  system_message "$2"
}

# --- below the advisory: silent, and re-arm the whole episode -----------------
# This is the ONLY place the sticky stand-down is cleared, and only a POSITIVE
# measurement reaches here, so a session that has already spent its block budget
# is never blocked again until it genuinely drops back under the advisory.
if [ "$TOTAL" -lt "$ADVISORY" ]; then
  rm -f "$BUDGET_FILE" "$NOTICE_FILE" 2>/dev/null || true
  exit 0
fi

# --- between advisory and ceiling: one non-blocking notice per episode ---------
if [ "$TOTAL" -lt "$CEILING" ]; then
  notice_once advisory "$(
    printf 'CONTEXT BUDGET ADVISORY - %s tokens, ceiling %s\n' "$TOTAL" "$CEILING"
    printf 'About %s tokens of headroom left before the ceiling.\n' "$((CEILING - TOTAL))"
    printf 'Prefer cheap actions now and avoid large reads.\n'
    printf 'Run /stow, write a handoff note, and clear before the ceiling is reached.\n'
  )"
  exit 0
fi

# --- at or above the ceiling, shipped default: warn once, never block ---------
if [ "$ENFORCE" -ne 1 ]; then
  notice_once ceiling "$(ceiling_text 'This is a warning: the ceiling does not block by default.')"
  exit 0
fi

# --- at or above the ceiling with enforcement on: block, bounded, then stand
# --- down stickily ------------------------------------------------------------
budget_read

if [ "$BUDGET_STOOD_DOWN" -eq 1 ]; then
  # Sticky and silent. The ceiling cannot clear without the captain, so once the
  # budget is spent this guard is out of the way for the rest of the session
  # rather than oscillating between blocking and allowing. Refreshing the record
  # keeps a long-running session's stand-down out of reach of the prune.
  touch "$BUDGET_FILE" 2>/dev/null || true
  exit 0
fi

COUNT=$((BUDGET_COUNT + 1))

if [ "$COUNT" -gt "$BLOCK_BUDGET" ]; then
  # Enter the stand-down as a recorded FLAG rather than a clamped count, so
  # raising FM_CONTEXT_BUDGET_BLOCK_BUDGET mid-session cannot re-arm a budget
  # that was already spent. Say so exactly once, visibly.
  budget_record "$COUNT" 1
  system_message "$(printf 'firstmate context budget: this session measures %s tokens, over the %s ceiling, and the block budget is exhausted so this guard now stands down for the rest of the session. Run /stow, write a handoff note, and clear before continuing.' \
    "$TOTAL" "$CEILING")"
  exit 0
fi

if ! budget_record "$COUNT" 0; then
  # The count could not be persisted, so blocking could not be bounded by it.
  # Degrade to the visible warning instead of blocking on a count that does not
  # survive the turn.
  notice_once ceiling "$(ceiling_text 'This turn is allowed rather than blocked because the block count could not be recorded.')"
  exit 0
fi

{
  printf '●%s\n' "$RULE"
  ceiling_text 'Blocking is bounded, then this guard stands down for the session.' \
    | sed 's/^/●  /'
  printf '●%s\n' "$RULE"
} >&2
exit 2
