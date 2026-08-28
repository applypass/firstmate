#!/usr/bin/env bash
# ONE owner of "how many context tokens is this primary session carrying, and
# how many compaction boundaries has it crossed?".
#
# No turn-end hook payload on any harness carries a token count, so the number
# comes from the transcript the payload points at. Two rules bind every caller:
# read transcript_path from the PAYLOAD and never derive it from $HOME (a
# non-default Claude config dir puts the transcript where $HOME cannot predict),
# and measure with fm_context_measure_transcript rather than a private formula.
#
# THE FORMULA: the total is input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens + output_tokens on the LAST non-sidechain
# type=="assistant" entry. That reproduces Claude Code's own accounting;
# docs/verification/session-handover.md records the cross-check.
#
# Three correctness rules the measurement must keep:
#   1. Take LAST, never max and never a sum. Compaction RESETS the running
#      total, so a max implementation would latch the pre-compaction peak and
#      never fall back below a threshold again. Taking the last entry also
#      subsumes multi-block dedupe for free: every JSONL line of one
#      multi-block turn carries that turn's own cumulative usage, so the last
#      line IS the turn's total and no requestId grouping is needed.
#   2. Exclude sidechains. isSidechain==true marks subagent turns, which must
#      never inflate the primary's measurement or its compaction tally.
#   3. Ignore zero-total entries. Claude Code writes a synthetic all-zero-usage
#      assistant entry whenever a turn ends abnormally; counting one would read
#      a long session as empty and look like proof the context had reset.
#
# ONE STREAMING PASS, CONSTANT MEMORY: jq -R reads a line at a time and emits a
# tagged token for each line worth counting; awk then reduces the stream to the
# LAST total and the COUNT of compaction boundaries. Nothing is slurped at
# either stage, so memory is constant in the transcript's size regardless of
# whether a caller wants the total, the compaction tally, or both - both ride
# along in the same pass, so a caller that needs only the total never causes a
# second read of the transcript for the tally, and vice versa.
#
# HISTORY: this formula was lifted verbatim from bin/fm-context-budget.sh's own
# inline measure_context(), the only place it was previously correct end to end
# (streaming, compaction-aware). bin/fm-context-budget.sh and
# bin/fm-session-pulse.sh both source this file rather than keeping their own
# copy; see the "fm-context-measure-lib-adoption" entry in
# docs/verification/context-budget.md for the completed convergence.
#
# This file is sourced by scripts and has no side effects on source.

# fm_context_payload_transcript <payload>: print the transcript path a turn-end
# payload points at. Non-zero when the payload carries none, is unparseable, or
# the path is not a readable regular file. jq is the repo's established JSON
# dependency; its absence is an ordinary unmeasurable, never an error.
fm_context_payload_transcript() {
  local payload=$1 path
  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null) || return 1
  [ -n "$path" ] || return 1
  [ -f "$path" ] && [ -r "$path" ] || return 1
  printf '%s\n' "$path"
}

# fm_context_measure_transcript <transcript>: print "TOTAL COMPACTS" - the
# session's context total in tokens, and the count of compaction boundaries it
# has crossed. Non-zero when the total cannot be established at all - absent
# jq, missing or unreadable file, no assistant usage, or a total that is not a
# plain integer - so every caller has exactly one unmeasurable case to degrade
# on. A caller that only wants the total reads the field before the first
# space; the compaction tally is the field after the last space and defaults to
# 0 when nothing was countable in that dimension.
#
# fromjson? drops malformed or truncated lines instead of aborting, so a
# partially written transcript degrades to "measure what parsed" rather than to
# an error. select(type == "object") skips a line that parsed to a JSON scalar
# or array. select(.isSidechain != true) sits above the branch so rule 2
# governs the whole pass, not only the token total: a subagent's own compaction
# is no evidence at all that the primary's context reset.
fm_context_measure_transcript() {
  local transcript=$1 measured total compacts
  [ -n "$transcript" ] || return 1
  [ -f "$transcript" ] && [ -r "$transcript" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  measured=$(jq -R -r '
    def usage_total:
      (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
      + (.cache_read_input_tokens // 0) + (.output_tokens // 0);
    (fromjson? // empty)
    | select(type == "object")
    | select(.isSidechain != true)
    | if (.type == "system" and .subtype == "compact_boundary") then "c"
      else
        select((.type == "assistant")
          and ((.message.usage | type) == "object"))
        | .message.usage
        | usage_total
        | floor
        | select(. > 0)
        | "t \(.)"
      end
  ' "$transcript" 2>/dev/null | awk '
    $1 == "c" { compacts += 1; next }
    $1 == "t" { total = $2 }
    END { printf "%s %s\n", total, compacts + 0 }
  ') || return 1
  total=${measured%% *}
  compacts=${measured##* }
  case "$total" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$compacts" in
    ''|*[!0-9]*) compacts=0 ;;
  esac
  printf '%s %s\n' "$total" "$compacts"
}
