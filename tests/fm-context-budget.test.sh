#!/usr/bin/env bash
# Behavior tests for the primary context-budget guardrail (docs/context-budget.md).
#
# Subject: bin/fm-context-budget.sh, the Stop-boundary hook that measures the
# live session's context from the transcript the payload points at and blocks
# the turn end once the measurement crosses the absolute ceiling.
#
# Four layers:
#   MEASUREMENT  - the three correctness rules: requestId dedupe, last-not-max,
#                  sidechain exclusion.
#   STAGES       - the derived advisory notice and the enforcing ceiling.
#   DEGRADATION  - every measurement failure is a silent exit 0.
#   SCOPE        - inert in a crewmate worktree, active in a secondmate home.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-budget)
fm_git_identity fmtest fmtest@example.invalid

# --- fixtures ----------------------------------------------------------------

install_budget_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-context-budget.sh" "$dir/bin/fm-context-budget.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  chmod +x "$dir/bin/fm-context-budget.sh"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - everything the shared primary scope requires.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_budget_scripts "$dir"
  printf '%s\n' "$dir"
}

# Same shape plus the .fm-secondmate-home marker bin/fm-home-seed.sh writes. A
# secondmate runs its OWN primary session, so the guard must bind it.
make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-test-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked `git worktree`, the shape bin/fm-spawn.sh hands every
# crewmate and scout task. git-dir != git-common-dir here, and a child worktree
# never carries the gitignored secondmate marker.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/context-budget-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_budget_scripts "$dir"
  printf '%s\n' "$dir"
}

# One assistant transcript line whose four usage fields sum to $1. The bulk sits
# in cache_read_input_tokens, the field that dominates a real long session.
assistant_line() {
  local total=$1 rid=${2:-req-1} sidechain=${3:-false}
  printf '{"type":"assistant","isSidechain":%s,"requestId":"%s","message":{"model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":8,"cache_read_input_tokens":%s,"output_tokens":10}}}\n' \
    "$sidechain" "$rid" "$((total - 20))"
}

# A transcript of one assistant turn per argument, each with its own requestId.
write_transcript() {
  local path=$1
  shift
  : > "$path"
  local total
  for total in "$@"; do
    assistant_line "$total" "req-$total" >> "$path"
  done
}

stop_payload() {
  printf '{"session_id":"%s","stop_hook_active":false,"transcript_path":"%s"}' "${2:-sess-1}" "$1"
}

# Run the hook as the registered Claude Stop hook, with stdout and stderr merged
# so a test can assert on either channel.
run_budget() {
  local dir=$1 payload=$2
  shift 2
  local home
  home=$(cd "$dir" && pwd)
  printf '%s' "$payload" | env "$@" CLAUDECODE=1 FM_HOME="$home" \
    bash "$dir/bin/fm-context-budget.sh" --claude 2>&1
}

# --- MEASUREMENT: the ceiling blocks and names the valve ---------------------

test_blocks_over_ceiling_and_names_the_valve() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/over-ceiling")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "hook must block the turn end above the ceiling"
  assert_contains "$out" "CONTEXT BUDGET CEILING" "block banner must read as a ceiling alarm"
  assert_contains "$out" "210000" "block banner must report the measured total"
  assert_contains "$out" "180000" "block banner must report the ceiling it enforced"
  assert_contains "$out" "/stow" "the valve must name /stow"
  assert_contains "$out" "handoff note" "the valve must require a handoff note"
  assert_contains "$out" "Clear the context" "the valve must require clearing the session"
  pass "fm-context-budget: blocks above the ceiling and names the handoff-and-clear valve"
}

test_default_ceiling_is_180000() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/default-ceiling")
  transcript="$dir/transcript.jsonl"
  # One token under the shipped default must not block; one over must.
  write_transcript "$transcript" 179999
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 0 "$status" "179,999 tokens must not block under the shipped default ceiling"
  write_transcript "$transcript" 180000
  out=$(run_budget "$dir" "$(stop_payload "$transcript" sess-2)" FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 2 "$status" "180,000 tokens must block under the shipped default ceiling"
  assert_contains "$out" "180000" "the shipped default ceiling must be 180000"
  pass "fm-context-budget: the shipped default ceiling is an absolute 180,000 tokens"
}

# Correctness rule 1. A multi-block assistant turn writes several JSONL lines
# sharing one requestId and one usage object. Summing them would report 3x the
# real total and fire the guard far too early.
test_dedupes_multi_block_turn_by_request_id() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/dedupe")
  transcript="$dir/transcript.jsonl"
  {
    assistant_line 100000 req-multi
    assistant_line 100000 req-multi
    assistant_line 100000 req-multi
  } > "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 0 "$status" "three blocks of one 100,000-token turn must measure 100,000, not 300,000"
  [ -z "$out" ] || fail "hook produced output for a turn below the ceiling: $out"
  pass "fm-context-budget: dedupes a multi-block turn by requestId instead of summing its blocks"
}

# Correctness rule 2. Compaction RESETS the running total. A max implementation
# would latch the pre-compaction peak and suppress the guard forever after.
test_takes_last_never_max_across_compaction() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/last-not-max")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 240000 30000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 0 "$status" "a post-compaction 30,000 must be measured, not the stale 240,000 peak"
  [ -z "$out" ] || fail "hook fired on a stale pre-compaction peak: $out"
  pass "fm-context-budget: takes the last total, never the max, so compaction cannot disable the guard"
}

# Correctness rule 3. isSidechain==true marks subagent turns. A single inflated
# sidechain entry must never drag the primary over the ceiling.
test_excludes_sidechain_entries() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/sidechain")
  transcript="$dir/transcript.jsonl"
  : > "$transcript"
  assistant_line 20000 req-main >> "$transcript"
  assistant_line 999999 req-sub true >> "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 0 "$status" "a 999,999-token sidechain entry must not count toward the primary total"
  [ -z "$out" ] || fail "hook counted a sidechain entry: $out"
  pass "fm-context-budget: excludes isSidechain entries so subagent turns never inflate the primary"
}

test_measures_only_assistant_entries() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/assistant-only")
  transcript="$dir/transcript.jsonl"
  : > "$transcript"
  assistant_line 210000 req-a >> "$transcript"
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' >> "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "a trailing user entry must not hide the last assistant measurement"
  assert_contains "$out" "210000" "the last assistant usage must still be measured"
  pass "fm-context-budget: measures the last assistant usage past trailing non-assistant entries"
}

test_sums_all_four_usage_fields() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/four-fields")
  transcript="$dir/transcript.jsonl"
  printf '{"type":"assistant","requestId":"req-1","message":{"usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":4000,"output_tokens":8000}}}\n' \
    > "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=15000 FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 2 "$status" "1000+2000+4000+8000 must measure 15000 and reach a 15000 ceiling"
  assert_contains "$out" "15000 tokens" "all four usage fields must be summed"
  pass "fm-context-budget: sums input, cache creation, cache read, and output tokens"
}

# --- STAGES: one policy number, one derived advisory -------------------------

test_advisory_warns_without_blocking() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/advisory")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 160000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000); status=$?
  expect_code 0 "$status" "the advisory stage must never block the turn end"
  assert_contains "$out" "CONTEXT BUDGET ADVISORY" "advisory must print the banner"
  assert_contains "$out" "20000 tokens of headroom" "advisory must report remaining headroom"
  assert_contains "$out" "/stow" "advisory must still name the valve"
  pass "fm-context-budget: warns without blocking between the derived advisory and the ceiling"
}

test_advisory_is_derived_from_ceiling_minus_headroom() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/derived")
  transcript="$dir/transcript.jsonl"
  # 149,999 is below 180000-30000 and must stay silent; 150,000 is exactly the
  # derived advisory and must warn. No second policy number is configurable.
  write_transcript "$transcript" 149999
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000); status=$?
  expect_code 0 "$status" "below the derived advisory must exit 0"
  [ -z "$out" ] || fail "hook warned below the derived advisory: $out"
  write_transcript "$transcript" 150000
  out=$(run_budget "$dir" "$(stop_payload "$transcript" sess-derived)" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000); status=$?
  expect_code 0 "$status" "at the derived advisory must still exit 0"
  assert_contains "$out" "CONTEXT BUDGET ADVISORY" "the advisory point must be ceiling minus headroom"
  pass "fm-context-budget: the advisory is derived as ceiling minus headroom, not a second threshold"
}

test_advisory_prints_once_per_episode() {
  local dir transcript first second status
  dir=$(make_primary_dir "$TMP_ROOT/advisory-dedup")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 160000
  first=$(run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000)
  assert_contains "$first" "CONTEXT BUDGET ADVISORY" "the first advisory turn must print the banner"
  second=$(run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000); status=$?
  expect_code 0 "$status" "a repeat advisory turn must still exit 0"
  [ -z "$second" ] || fail "advisory banner repeated inside one episode: $second"
  pass "fm-context-budget: the advisory banner prints once per episode, like bin/fm-guard.sh"
}

test_advisory_rearms_after_dropping_below() {
  local dir transcript out
  dir=$(make_primary_dir "$TMP_ROOT/advisory-rearm")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 160000
  run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000 >/dev/null
  # A clear or compaction drops the measurement back under the advisory.
  write_transcript "$transcript" 30000
  run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000 >/dev/null
  write_transcript "$transcript" 160000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000)
  assert_contains "$out" "CONTEXT BUDGET ADVISORY" "a later episode must re-arm the advisory banner"
  pass "fm-context-budget: the advisory re-arms once the session drops back below it"
}

test_silent_well_below_advisory() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/below")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 31710
  out=$(run_budget "$dir" "$(stop_payload "$transcript")"); status=$?
  expect_code 0 "$status" "an ordinary session must exit 0"
  [ -z "$out" ] || fail "hook produced output for an ordinary session: $out"
  pass "fm-context-budget: completely silent for a session well below the advisory"
}

# --- Block-budget safety: bounded blocking can never wedge a session ---------

test_block_budget_degrades_to_visible_warning() {
  local dir transcript payload out status i
  dir=$(make_primary_dir "$TMP_ROOT/block-budget")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-budget)
  for i in 1 2; do
    out=$(run_budget "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2); status=$?
    expect_code 2 "$status" "block $i must still block within the budget"
  done
  out=$(run_budget "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2); status=$?
  expect_code 0 "$status" "past the block budget the turn end must be allowed, never wedged"
  assert_contains "$out" "systemMessage" "the degraded allow must stay visible to the session"
  assert_contains "$out" "block budget is exhausted" "the degraded allow must say why it stopped blocking"
  assert_contains "$out" "/stow" "the degraded allow must still name the valve"
  pass "fm-context-budget: bounded blocking degrades to a visible warning instead of wedging"
}

test_block_budget_is_per_session() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/block-budget-session")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  run_budget "$dir" "$(stop_payload "$transcript" sess-a)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null
  out=$(run_budget "$dir" "$(stop_payload "$transcript" sess-a)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "the same session must exhaust its budget"
  out=$(run_budget "$dir" "$(stop_payload "$transcript" sess-b)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 2 "$status" "a different session must start with a fresh block budget"
  pass "fm-context-budget: the block budget is keyed to the session, not the home"
}

test_block_budget_resets_after_the_valve() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/block-reset")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  run_budget "$dir" "$(stop_payload "$transcript" sess-r)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=2 >/dev/null
  # The session takes the valve: the measurement drops back to baseline.
  write_transcript "$transcript" 30000
  run_budget "$dir" "$(stop_payload "$transcript" sess-r)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=2 >/dev/null
  # A later balloon in the same session must get the full budget again.
  write_transcript "$transcript" 210000
  run_budget "$dir" "$(stop_payload "$transcript" sess-r)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=2 >/dev/null
  out=$(run_budget "$dir" "$(stop_payload "$transcript" sess-r)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=2); status=$?
  expect_code 2 "$status" "an allow must reset the consecutive-block budget"
  pass "fm-context-budget: any allow resets the consecutive-block budget"
}

# --- DEGRADATION: the eight rows, every one a silent exit 0 ------------------

expect_silent_exit_zero() {
  local label=$1 out=$2 status=$3
  expect_code 0 "$status" "$label must exit 0"
  [ -z "$out" ] || fail "$label produced output: $out"
}

test_degrades_on_empty_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-empty")
  out=$(run_budget "$dir" ""); status=$?
  expect_silent_exit_zero "empty stdin" "$out" "$status"
  pass "fm-context-budget degradation: empty stdin is a silent exit 0"
}

test_degrades_on_malformed_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-malformed")
  out=$(run_budget "$dir" 'not json at all {{{'); status=$?
  expect_silent_exit_zero "malformed stdin" "$out" "$status"
  pass "fm-context-budget degradation: malformed stdin is a silent exit 0"
}

test_degrades_without_transcript_path() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-nopath")
  out=$(run_budget "$dir" '{"session_id":"s","stop_hook_active":false}'); status=$?
  expect_silent_exit_zero "a payload with no transcript_path" "$out" "$status"
  pass "fm-context-budget degradation: a payload with no transcript_path is a silent exit 0"
}

test_degrades_on_missing_transcript_file() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-missing")
  out=$(run_budget "$dir" "$(stop_payload "$dir/not-there.jsonl")"); status=$?
  expect_silent_exit_zero "a missing transcript file" "$out" "$status"
  pass "fm-context-budget degradation: a missing transcript file is a silent exit 0"
}

test_degrades_on_unreadable_transcript() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-unreadable")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  chmod 000 "$transcript"
  if [ -r "$transcript" ]; then
    chmod 644 "$transcript"
    pass "fm-context-budget degradation: skipped unreadable-transcript row (test host ignores mode 000)"
    return 0
  fi
  out=$(run_budget "$dir" "$(stop_payload "$transcript")"); status=$?
  chmod 644 "$transcript"
  expect_silent_exit_zero "an unreadable transcript" "$out" "$status"
  pass "fm-context-budget degradation: an unreadable transcript is a silent exit 0"
}

test_degrades_on_transcript_without_assistant_usage() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-nousage")
  transcript="$dir/transcript.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$transcript"
  printf '{"type":"summary","summary":"a compaction summary"}\n' >> "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")"); status=$?
  expect_silent_exit_zero "a transcript with no assistant usage" "$out" "$status"
  pass "fm-context-budget degradation: a transcript with no assistant usage is a silent exit 0"
}

test_degrades_on_corrupt_transcript() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-corrupt")
  transcript="$dir/transcript.jsonl"
  printf 'this is not json\n{"type":"assist\n\0\0binary\n' > "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")"); status=$?
  expect_silent_exit_zero "a corrupt transcript" "$out" "$status"
  pass "fm-context-budget degradation: a corrupt transcript is a silent exit 0"
}

test_degrades_on_empty_transcript() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-emptyfile")
  transcript="$dir/transcript.jsonl"
  : > "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")"); status=$?
  expect_silent_exit_zero "an empty transcript" "$out" "$status"
  pass "fm-context-budget degradation: an empty transcript file is a silent exit 0"
}

test_degrades_without_jq() {
  local dir transcript fakebin tool tool_path out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-nojq")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  fakebin=$(fm_fakebin "$TMP_ROOT/deg-nojq-fake")
  for tool in bash sh git cat printf date uname stat mkdir dirname sed rm; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -sf "$tool_path" "$fakebin/$tool"
  done
  out=$(printf '%s' "$(stop_payload "$transcript")" | PATH="$fakebin" \
    bash "$dir/bin/fm-context-budget.sh" --claude 2>&1); status=$?
  expect_silent_exit_zero "a host without jq" "$out" "$status"
  pass "fm-context-budget degradation: a host without jq is a silent exit 0"
}

# A truncated final line is the realistic corruption: the transcript is written
# as the session runs. The measurement must fall back to the last line that
# parsed rather than aborting or reporting a wrong number.
test_truncated_last_line_measures_last_valid_entry() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-truncated")
  transcript="$dir/transcript.jsonl"
  assistant_line 210000 req-good > "$transcript"
  printf '{"type":"assistant","requestId":"req-half","message":{"usa' >> "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "a half-written final line must not hide the last complete measurement"
  assert_contains "$out" "210000" "the last parseable assistant entry must be measured"
  pass "fm-context-budget: a truncated final line falls back to the last entry that parsed"
}

# --- SCOPE: primary and secondmate bind, crew subagent worktrees stay inert ---

test_active_in_main_primary() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/scope-primary")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "the main primary home must be guarded"
  pass "fm-context-budget scope: active in the main primary home"
}

test_active_in_secondmate_home() {
  local dir transcript out status
  dir=$(make_secondmate_dir "$TMP_ROOT/scope-secondmate")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "a secondmate runs its own primary session and must be guarded"
  assert_contains "$out" "CONTEXT BUDGET CEILING" "the secondmate block must carry the same banner"
  pass "fm-context-budget scope: active in a marked secondmate home"
}

test_active_in_treehouse_leased_secondmate_home() {
  local base dir transcript out status
  base="$TMP_ROOT/scope-sm-linked-base"
  dir="$TMP_ROOT/scope-sm-linked"
  fm_git_worktree "$base" "$dir" fm/context-budget-secondmate-home
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_budget_scripts "$dir"
  printf 'sm-linked-1\n' > "$dir/.fm-secondmate-home"
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "a treehouse-leased secondmate home is a linked worktree but still a primary"
  pass "fm-context-budget scope: active in a treehouse-leased secondmate home"
}

test_inert_in_crewmate_worktree() {
  local base dir transcript out status
  base="$TMP_ROOT/scope-crew-base"
  dir=$(make_crewmate_worktree_dir "$base" "$TMP_ROOT/scope-crew")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 999999
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_silent_exit_zero "a crewmate task worktree" "$out" "$status"
  pass "fm-context-budget scope: inert in a linked crewmate worktree, whatever its context size"
}

test_inert_in_secondmate_child_worktree() {
  local home dir transcript out status
  home=$(make_secondmate_dir "$TMP_ROOT/scope-sm-parent")
  dir="$TMP_ROOT/scope-sm-child"
  git -C "$home" worktree add --quiet -b fm/context-budget-secondmate-child "$dir"
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_budget_scripts "$dir"
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 999999
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_silent_exit_zero "a secondmate's own child task worktree" "$out" "$status"
  pass "fm-context-budget scope: inert in a secondmate's own child task worktree"
}

test_inert_without_state_dir() {
  local dir transcript out status
  dir="$TMP_ROOT/scope-nostate"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_budget_scripts "$dir"
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_silent_exit_zero "a checkout with no state directory" "$out" "$status"
  pass "fm-context-budget scope: inert without an effective state directory"
}

# --- Registration and cost ---------------------------------------------------

test_settings_registers_the_stop_hook() {
  local settings count command
  settings="$ROOT/.claude/settings.json"
  [ -f "$settings" ] || fail "tracked .claude/settings.json is missing"
  count=$(jq -r '[.hooks.Stop[].hooks[] | select(.command | test("fm-context-budget\\.sh"))] | length' "$settings")
  [ "$count" -eq 1 ] || fail "expected exactly one context-budget Stop hook, found $count"
  command=$(jq -r '.hooks.Stop[].hooks[] | select(.command | test("fm-context-budget\\.sh")) | .command' "$settings")
  assert_contains "$command" 'CLAUDE_PROJECT_DIR' "the Stop hook must anchor through CLAUDE_PROJECT_DIR"
  assert_contains "$command" '--claude' "the Stop hook must run in Claude mode"
  jq -e '[.hooks.Stop[].hooks[]] | length == 3' "$settings" >/dev/null \
    || fail "Stop must stack exactly three hooks: turn-end guard, context budget, auto-arm"
  pass ".claude/settings.json: registers the context-budget guard as a sibling Stop hook"
}

test_hook_does_not_fold_into_the_turnend_guard() {
  assert_no_grep 'fm-context-budget' "$ROOT/bin/fm-turnend-guard.sh" \
    "the turn-end guard must keep owning exactly one predicate"
  assert_no_grep 'transcript_path' "$ROOT/bin/fm-turnend-guard.sh" \
    "context measurement must not leak into the turn-end guard"
  pass "one-owner rule: the context budget is a separate owner from the turn-end guard"
}

test_hook_never_injects_a_command() {
  local script="$ROOT/bin/fm-context-budget.sh"
  assert_no_grep 'fm-send.sh' "$script" "the guard must never type into a pane"
  assert_no_grep 'tmux ' "$script" "the guard must never drive a terminal directly"
  assert_no_grep 'fm-spawn.sh' "$script" "the guard must never spawn a replacement agent"
  pass "settled decision: the guard only instructs, it never injects a command or spawns an agent"
}

test_requires_claude_mode_and_stays_inert_otherwise() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/mode")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(printf '%s' "$(stop_payload "$transcript")" | FM_HOME="$dir" \
    bash "$dir/bin/fm-context-budget.sh" 2>&1); status=$?
  expect_code 0 "$status" "a bare invocation must never block; only claude is wired in this slice"
  assert_contains "$out" "usage:" "a bare invocation must say which mode it needs"
  out=$(printf '%s' "$(stop_payload "$transcript")" | FM_HOME="$dir" \
    bash "$dir/bin/fm-context-budget.sh" --codex 2>&1); status=$?
  expect_code 0 "$status" "an unsupported harness mode must be inert, never a blocking usage error"
  pass "fm-context-budget: claude is the only wired mode, and every other invocation is inert"
}

test_help_prints_the_header_only() {
  local out
  out=$(bash "$ROOT/bin/fm-context-budget.sh" --help 2>&1)
  assert_contains "$out" "Context-budget guardrail" "--help must print the header contract"
  assert_contains "$out" "docs/context-budget.md" "--help must point at the owning doc"
  assert_not_contains "$out" "set -u" "--help must stop at the header and never leak script body"
  assert_not_contains "$out" "SCRIPT_DIR=" "--help must not leak implementation lines"
  pass "fm-context-budget: --help prints the header contract and no script body"
}

test_hook_runs_fast() {
  local dir transcript i started elapsed
  dir=$(make_primary_dir "$TMP_ROOT/fast")
  transcript="$dir/transcript.jsonl"
  : > "$transcript"
  for i in $(seq 1 400); do
    assistant_line $((30000 + i)) "req-$i" >> "$transcript"
  done
  started=$(date +%s)
  run_budget "$dir" "$(stop_payload "$transcript")" >/dev/null
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 5 ] || fail "hook took ${elapsed}s over a 400-turn transcript; it runs on every turn end"
  pass "fm-context-budget: one measurement pass stays cheap on a long transcript"
}

test_blocks_over_ceiling_and_names_the_valve
test_default_ceiling_is_180000
test_dedupes_multi_block_turn_by_request_id
test_takes_last_never_max_across_compaction
test_excludes_sidechain_entries
test_measures_only_assistant_entries
test_sums_all_four_usage_fields
test_advisory_warns_without_blocking
test_advisory_is_derived_from_ceiling_minus_headroom
test_advisory_prints_once_per_episode
test_advisory_rearms_after_dropping_below
test_silent_well_below_advisory
test_block_budget_degrades_to_visible_warning
test_block_budget_is_per_session
test_block_budget_resets_after_the_valve
test_degrades_on_empty_stdin
test_degrades_on_malformed_stdin
test_degrades_without_transcript_path
test_degrades_on_missing_transcript_file
test_degrades_on_unreadable_transcript
test_degrades_on_transcript_without_assistant_usage
test_degrades_on_corrupt_transcript
test_degrades_on_empty_transcript
test_degrades_without_jq
test_truncated_last_line_measures_last_valid_entry
test_active_in_main_primary
test_active_in_secondmate_home
test_active_in_treehouse_leased_secondmate_home
test_inert_in_crewmate_worktree
test_inert_in_secondmate_child_worktree
test_inert_without_state_dir
test_settings_registers_the_stop_hook
test_hook_does_not_fold_into_the_turnend_guard
test_hook_never_injects_a_command
test_requires_claude_mode_and_stays_inert_otherwise
test_help_prints_the_header_only
test_hook_runs_fast
