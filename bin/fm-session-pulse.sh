#!/usr/bin/env bash
# Turn-end pulse for a firstmate PRIMARY session: the main home OR a secondmate's
# own home. Crew subagent turns are inert (shared primary scope, plus the
# sidechain filter inside the measurement).
#
# TWO duties on one Stop event, because both need the same payload and the same
# scope check:
#   1. STAMP the helm activity marker, so "this session is alive" and "this
#      session is working" stop being the same claim. bin/fm-helm-lib.sh owns
#      what the marker means and how a fresh session reads it.
#   2. REPORT that a handover is due once the session's context crosses the
#      threshold. bin/fm-context-measure-lib.sh owns the measurement.
#
# IT NEVER BLOCKS. The threshold is a thinking-quality line, not a capacity one:
# past it the session reasons worse, but a stalled fleet is worse still, so the
# session reports once and carries on. The notice therefore travels as a
# non-blocking systemMessage and this script always exits 0. Blocking a turn end
# is bin/fm-turnend-guard.sh's job and stays there.
#
# WHY 250,000 TOKENS FLAT, never a percentage: a percentage of a 1M-token window
# would park a session at 700,000, deep inside the degradation the threshold
# exists to avoid. The number must not scale with the context window.
#
# ONE NOTICE PER EPISODE: the session id is recorded when the notice fires, so a
# session that keeps working past the threshold is not nagged every turn. Falling
# back below the threshold - after a real handover, or after the harness compacts -
# re-arms it, so a later episode is reported again.
#
# NEVER WEDGE A SESSION: every failure - absent jq, missing or unreadable
# transcript, corrupt transcript, no assistant usage, unwritable state, empty or
# malformed stdin - is a silent exit 0.
#
# Ships as a TRACKED Stop hook, so this file is checked out into every worktree of
# this repo including crewmate and scout task worktrees. It scopes itself at
# runtime through the shared primary predicate and stays a silent, fast no-op
# inside child task worktrees.
#
# Per-harness support is claude only in this slice: no other verified adapter's
# turn-end payload carries a transcript pointer this can measure. The marker half
# would work anywhere, but a half-armed pulse on a second harness would be a
# second contract to keep in sync, so the fan-out lands with its measurement.
# docs/session-handover.md owns the per-harness table.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CLAUDE_MODE=0

# The one policy number (see the header). Overridable for tests and live proof.
THRESHOLD=${FM_HANDOVER_THRESHOLD:-250000}
case "$THRESHOLD" in ''|*[!0-9]*|0) THRESHOLD=250000 ;; esac

for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    -h|--help) sed -n '2,${/^set -u/q;p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: $(basename "$0") --claude" >&2; exit 0 ;;
  esac
done

# --claude is required rather than defaulted, because it is the only mode whose
# payload this can measure. A bare or misconfigured invocation is inert rather
# than a usage error: this runs as a Stop hook and must never wedge a session.
if [ "$CLAUDE_MODE" -ne 1 ]; then
  echo "usage: $(basename "$0") --claude" >&2
  exit 0
fi

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Scope before any JSON work, so the common case in a busy fleet - a crewmate
# turn end - costs a couple of git calls and no jq spawn at all.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-helm-lib.sh
. "$SCRIPT_DIR/fm-helm-lib.sh"
# shellcheck source=bin/fm-context-measure-lib.sh
. "$SCRIPT_DIR/fm-context-measure-lib.sh"

TRANSCRIPT=$(fm_context_payload_transcript "$PAYLOAD" 2>/dev/null || printf '')

# --- duty 1: stamp the helm activity marker ----------------------------------
# Only the session that actually holds the helm may stamp it. A read-only session
# ending a turn says nothing about whether the holder is working.
if fm_session_lock_owned_by_self "$STATE"; then
  HOLDER=$(fm_harness_ancestry_pid 2>/dev/null || printf '')
  [ -n "$HOLDER" ] && fm_helm_stamp "$STATE" "$HOLDER" "$TRANSCRIPT" 2>/dev/null
fi

# --- duty 2: report a due handover, once -------------------------------------
[ -n "$TRANSCRIPT" ] || exit 0
TOTAL=$(fm_context_measure_transcript "$TRANSCRIPT" 2>/dev/null) || exit 0

command -v jq >/dev/null 2>&1 || exit 0
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
DUE_FILE="$STATE/.handover-due"

if [ "$TOTAL" -lt "$THRESHOLD" ]; then
  # Re-arm for a later episode.
  rm -f "$DUE_FILE" 2>/dev/null || true
  exit 0
fi

SEEN=$(cat "$DUE_FILE" 2>/dev/null || true)
[ "$SEEN" = "$SESSION_ID" ] && exit 0
printf '%s\n' "$SESSION_ID" > "$DUE_FILE" 2>/dev/null || true

# jq -n builds the JSON so the message can never break the envelope.
jq -n --arg total "$TOTAL" --arg threshold "$THRESHOLD" '{
  systemMessage: ("firstmate handover due: this session measures " + $total
    + " tokens, over the " + $threshold
    + " threshold, so it is past the point where it reasons well. Keep working - nothing is blocked - and tell the captain a handover is due. Load the handover skill to prepare and verify one; the captain runs the one command it prints.")
}' 2>/dev/null || true
exit 0
