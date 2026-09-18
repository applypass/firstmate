#!/usr/bin/env bash
# Behavior tests for bin/fm-context-measure-lib.sh's fm_context_measure_transcript,
# the single owner of "how many context tokens is this transcript carrying, and
# how many compaction boundaries has it crossed" (docs/session-handover.md
# "Measuring the context", docs/context-budget.md).
#
# fm_context_measure_transcript prints "TOTAL COMPACTS" on success: the context
# total bin/fm-session-pulse.sh reports against, and the compaction tally
# bin/fm-context-budget.sh needs for its genuine-reset detection. Both fields
# come from ONE streaming pass so a caller that only wants the total never pays
# for a second read of the transcript.
#
# Correctness rules pinned here: take the LAST usage entry rather than the max
# (compaction resets the running total) - and a same- or different-requestId
# multi-block turn is handled identically, because every line of one turn
# already carries that turn's own cumulative usage, so no requestId grouping is
# needed; exclude isSidechain entries; ignore a trailing synthetic all-zero-usage
# entry so an abnormally-ended turn is never reported as a real, valid 0; and
# tally compact_boundary markers without letting a sidechain's own boundary
# count.
#
# All hermetic: no real agent session, no network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-context-measure-lib.sh
. "$ROOT/bin/fm-context-measure-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-measure-lib)

# --- fixtures ----------------------------------------------------------------

# One assistant transcript line whose four usage fields sum to $1.
assistant_line() {
  local total=$1 rid=${2:-req-1} sidechain=${3:-false}
  printf '{"type":"assistant","isSidechain":%s,"requestId":"%s","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":8,"cache_read_input_tokens":%s,"output_tokens":10}}}\n' \
    "$sidechain" "$rid" "$((total - 20))"
}

# A trailing synthetic entry, the shape Claude Code writes when a turn ends
# abnormally: assistant, main chain, model "<synthetic>", all four usage fields 0.
synthetic_zero_line() {
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n'
}

# The marker Claude Code writes across a compaction.
compact_boundary_line() {
  printf '{"type":"system","subtype":"compact_boundary","isSidechain":%s,"compactMetadata":{"preTokens":%s,"postTokens":%s}}\n' \
    "${3:-false}" "${1:-318961}" "${2:-18947}"
}

# $TMP_ROOT's own directory does not survive fm_test_tmproot's command
# substitution (its EXIT trap fires when that subshell exits), so mkdir -p
# recreates it on demand rather than assuming a bare mktemp against it works.
NEW_TRANSCRIPT_N=0
new_transcript() {
  NEW_TRANSCRIPT_N=$((NEW_TRANSCRIPT_N + 1))
  local dir="$TMP_ROOT/t$NEW_TRANSCRIPT_N"
  mkdir -p "$dir"
  printf '%s\n' "$dir/transcript.jsonl"
}

# Split helpers: every caller reads one field or the other, never the raw
# "TOTAL COMPACTS" line, so a field can be added without touching every test.
measure_total() {
  local out
  out=$(fm_context_measure_transcript "$1") || return 1
  printf '%s\n' "${out%% *}"
}

measure_compacts() {
  local out
  out=$(fm_context_measure_transcript "$1") || return 1
  printf '%s\n' "${out##* }"
}

# --- rule 3: synthetic zero-usage entries -------------------------------------

# The exact fixture the bug report reproduces with: one real 300,010-token
# turn, then the trailing zero-usage entry Claude Code writes on an abnormal
# turn end. Before the fix this returned "0" with exit 0, a false measurement
# indistinguishable from a genuinely empty session.
test_trailing_synthetic_zero_does_not_report_a_false_zero() {
  local t out status
  t=$(new_transcript)
  {
    assistant_line 300010 req-real
    synthetic_zero_line
  } > "$t"
  out=$(measure_total "$t"); status=$?
  if [ "$status" -eq 0 ] && [ "$out" = "0" ]; then
    fail "a trailing synthetic zero-usage entry reported a false 0: $out"
  fi
  # The narrow fix recovers the real total; a wider rewrite could instead
  # legitimately fail to measure, but must never report a false 0 (see brief).
  if [ "$status" -eq 0 ]; then
    [ "$out" = "300010" ] || fail "measured '$out' instead of the real total 300010"
  fi
  pass "fm-context-measure-lib: a trailing synthetic zero-usage entry never reports a false 0"
}

test_trailing_synthetic_zero_recovers_the_real_total() {
  local t out status
  t=$(new_transcript)
  {
    assistant_line 300010 req-real
    synthetic_zero_line
  } > "$t"
  out=$(measure_total "$t"); status=$?
  expect_code 0 "$status" "the real prior total must still be measurable"
  [ "$out" = "300010" ] || fail "expected 300010, got '$out'"
  pass "fm-context-measure-lib: a trailing synthetic zero-usage entry recovers the last real total"
}

# A transcript whose ONLY assistant entry is a synthetic zero, and one with no
# assistant usage at all, must both stay unmeasurable exactly as before the fix.
test_genuinely_empty_transcript_stays_unmeasurable() {
  local t status
  t=$(new_transcript)
  : > "$t"
  fm_context_measure_transcript "$t" >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "an empty transcript must stay unmeasurable"

  t=$(new_transcript)
  synthetic_zero_line > "$t"
  fm_context_measure_transcript "$t" >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "a transcript with only a synthetic zero entry must stay unmeasurable"

  t=$(new_transcript)
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$t"
  fm_context_measure_transcript "$t" >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "a transcript with no assistant usage at all must stay unmeasurable"
  pass "fm-context-measure-lib: a genuinely empty or all-zero transcript stays unmeasurable"
}

# --- ordinary measurement -----------------------------------------------------

test_ordinary_nonzero_measurement_is_unchanged() {
  local t out
  t=$(new_transcript)
  assistant_line 75782 req-a > "$t"
  out=$(measure_total "$t")
  [ "$out" = "75782" ] || fail "expected 75782, got '$out'"
  pass "fm-context-measure-lib: an ordinary non-zero measurement is unchanged"
}

# A multi-block turn writes several JSONL lines carrying the SAME requestId,
# each line already holding that turn's own cumulative usage. Taking the final
# line must report the final block, not the sum or an earlier block.
test_multi_block_turn_same_request_id_takes_the_final_block() {
  local t out
  t=$(new_transcript)
  {
    assistant_line 100000 req-multi
    assistant_line 100000 req-multi
    assistant_line 120000 req-multi
  } > "$t"
  out=$(measure_total "$t")
  [ "$out" = "120000" ] || fail "expected the final block of one requestId (120000), got '$out'"
  pass "fm-context-measure-lib: a multi-block turn measures its final block, not the sum"
}

# THE AGREED CONTRACT (fm-context-measure-lib-adoption): the guard's own
# implementation takes the last usage entry in file order with NO requestId
# grouping at all, on the grounds that every line of one turn already carries
# that turn's cumulative usage, so the file's last line IS the session's last
# turn regardless of which requestId produced it. This is the regression test
# that pins that contract: a later, DIFFERENT requestId with a smaller total
# must win over an earlier requestId's larger total, exactly as it would if the
# earlier requestId were re-visited by a grouping implementation - because in
# real transcripts requestIds never interleave out of chronological order.
test_last_line_wins_regardless_of_request_id() {
  local t out
  t=$(new_transcript)
  {
    assistant_line 240000 req-pre
    assistant_line 30000 req-post
  } > "$t"
  out=$(measure_total "$t")
  [ "$out" = "30000" ] || fail "expected the last line's total (30000) regardless of requestId, got '$out'"
  pass "fm-context-measure-lib: the last line wins regardless of requestId"
}

test_takes_last_never_max_across_compaction() {
  local t out
  t=$(new_transcript)
  {
    assistant_line 240000 req-pre
    assistant_line 30000 req-post
  } > "$t"
  out=$(measure_total "$t")
  [ "$out" = "30000" ] || fail "expected the last total 30000, not the pre-compaction peak, got '$out'"
  pass "fm-context-measure-lib: takes the last total, never the max, across a compaction"
}

test_excludes_sidechain_entries() {
  local t out
  t=$(new_transcript)
  {
    assistant_line 20000 req-main false
    assistant_line 999999 req-sub true
  } > "$t"
  out=$(measure_total "$t")
  [ "$out" = "20000" ] || fail "a sidechain entry must not count toward the total, got '$out'"
  pass "fm-context-measure-lib: excludes isSidechain entries"
}

# --- the compaction tally -----------------------------------------------------

test_compaction_tally_is_returned_alongside_the_total() {
  local t out
  t=$(new_transcript)
  {
    assistant_line 240000 req-pre
    compact_boundary_line 240000 18947
    assistant_line 30000 req-post
  } > "$t"
  out=$(measure_compacts "$t")
  [ "$out" = "1" ] || fail "expected a compaction tally of 1, got '$out'"
  out=$(measure_total "$t")
  [ "$out" = "30000" ] || fail "the total must still be the last usage entry, got '$out'"
  pass "fm-context-measure-lib: returns the compaction tally alongside the total, from one pass"
}

test_compaction_tally_counts_every_boundary() {
  local t out
  t=$(new_transcript)
  {
    assistant_line 240000 req-1
    compact_boundary_line 240000 18000
    assistant_line 230000 req-2
    compact_boundary_line 230000 19000
    assistant_line 40000 req-3
  } > "$t"
  out=$(measure_compacts "$t")
  [ "$out" = "2" ] || fail "expected a compaction tally of 2, got '$out'"
  pass "fm-context-measure-lib: counts every compaction boundary, not just the first"
}

test_compaction_tally_is_zero_when_no_boundary_crossed() {
  local t out
  t=$(new_transcript)
  assistant_line 75782 req-a > "$t"
  out=$(measure_compacts "$t")
  [ "$out" = "0" ] || fail "expected a compaction tally of 0, got '$out'"
  pass "fm-context-measure-lib: the compaction tally is 0 when no boundary was crossed"
}

# A subagent's own compaction is no evidence at all that the primary's context
# reset, matching the sidechain exclusion applied to the total.
test_compaction_tally_excludes_sidechain_boundaries() {
  local t out
  t=$(new_transcript)
  {
    assistant_line 240000 req-1
    compact_boundary_line 240000 18000 true
    assistant_line 230000 req-2
  } > "$t"
  out=$(measure_compacts "$t")
  [ "$out" = "0" ] || fail "a sidechain compaction boundary must not count, got '$out'"
  pass "fm-context-measure-lib: excludes a sidechain's own compaction boundary from the tally"
}

# --- malformed input -----------------------------------------------------------

test_malformed_lines_are_skipped_not_fatal() {
  local t out
  t=$(new_transcript)
  {
    printf 'not json at all\n'
    printf '{"truncated": \n'
    assistant_line 50000 req-ok
    printf '{"type":"assistant","isSidechain":false,"requestId":"req-bad","message":{"usage":"not-an-object"}}\n'
  } > "$t"
  out=$(measure_total "$t")
  [ "$out" = "50000" ] || fail "a malformed line must be skipped, not abort the pass, got '$out'"
  pass "fm-context-measure-lib: malformed or truncated lines degrade to 'measure what parsed'"
}

# --- streaming, constant-memory behavior over a large transcript --------------

# A wall-clock bound over a hermetic fixture cannot prove constant memory by
# itself; the structural assertion in tests/fm-lint.test.sh-adjacent style below
# (no jq -s / --slurp, exactly one jq -R pass) is the real regression guard.
# This test is the correctness half: a transcript far larger than any prior
# fixture in this suite must still measure correctly and finish quickly, which a
# slurp-based implementation would also do at this size - the point is that the
# streaming rewrite has not broken correctness at scale.
test_large_transcript_measures_correctly_and_streams() {
  local t started elapsed out
  t=$(new_transcript)
  : > "$t"
  local i
  {
    for i in $(seq 1 20000); do
      assistant_line $((30000 + i)) "req-$i"
    done
    compact_boundary_line 300000 18000
    assistant_line 12345 req-final
  } >> "$t"
  started=$(date +%s)
  out=$(measure_total "$t")
  elapsed=$(( $(date +%s) - started ))
  [ "$out" = "12345" ] || fail "expected the final block's total 12345 over a large transcript, got '$out'"
  [ "$elapsed" -le 15 ] || fail "measuring a 20,000-line transcript took ${elapsed}s"
  out=$(measure_compacts "$t")
  [ "$out" = "1" ] || fail "expected a compaction tally of 1 over the large transcript, got '$out'"
  pass "fm-context-measure-lib: measures a large transcript correctly with a bounded, cheap pass"

  assert_no_grep 'jq -s' "$ROOT/bin/fm-context-measure-lib.sh" \
    "the reader must stream the transcript, never slurp it into one array"
  assert_no_grep 'jq --slurp' "$ROOT/bin/fm-context-measure-lib.sh" \
    "the reader must stream the transcript, never slurp it into one array"
  local passes
  passes=$(grep -c '^[^#]*jq -R' "$ROOT/bin/fm-context-measure-lib.sh" || true)
  [ "$passes" -eq 1 ] || fail "the transcript must be parsed by exactly one jq -R pass, not $passes"
  pass "fm-context-measure-lib: the measurement is one streaming pass, never a slurp"
}

# --- degradation ---------------------------------------------------------------

test_missing_file_is_unmeasurable() {
  local status
  fm_context_measure_transcript "$TMP_ROOT/nope-does-not-exist.jsonl" >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "a missing transcript must be unmeasurable"
  pass "fm-context-measure-lib: a missing transcript is unmeasurable"
}

run_all() {
  test_trailing_synthetic_zero_does_not_report_a_false_zero
  test_trailing_synthetic_zero_recovers_the_real_total
  test_genuinely_empty_transcript_stays_unmeasurable
  test_ordinary_nonzero_measurement_is_unchanged
  test_multi_block_turn_same_request_id_takes_the_final_block
  test_last_line_wins_regardless_of_request_id
  test_takes_last_never_max_across_compaction
  test_excludes_sidechain_entries
  test_compaction_tally_is_returned_alongside_the_total
  test_compaction_tally_counts_every_boundary
  test_compaction_tally_is_zero_when_no_boundary_crossed
  test_compaction_tally_excludes_sidechain_boundaries
  test_malformed_lines_are_skipped_not_fatal
  test_large_transcript_measures_correctly_and_streams
  test_missing_file_is_unmeasurable
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'skip: jq not found - the context measurement needs it\n'
  exit 0
fi

run_all
