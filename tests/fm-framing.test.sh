#!/usr/bin/env bash
# Fork-only: behavior tests for bin/fm-framing.sh and the framing block in bin/fm-brief.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-framing)
FRAMING="$ROOT/bin/fm-framing.sh"
LABELS=("Five whys" "Need" "Who and how many" "How often" "Manual vs automated ROI" "Product change" "Non-code way" "Metric owner")

# write_report <name> <line...> - a report fixture; prints its path.
write_report() {
  local f="$TMP_ROOT/$1.md"
  shift
  printf '%s\n' "$@" > "$f"
  printf '%s\n' "$f"
}

full_list() {
  printf '%s\n' '# Report' '' '## Framing' \
    '- **Five whys:** 1. a 2. b 3. c' \
    'Need: yes, root fix' \
    'Who and how many: every scout worker, about 6 a day' \
    'How often: 5 of 39 briefs carried it' \
    'Manual vs automated ROI: 3-5 hours once, then zero' \
    'Product change: not applicable, internal tooling' \
    'Non-code way: a memory line already exists and fails' \
    'Metric owner: firstmate, share of reports passing the check' \
    '' '## Findings' 'text'
}

GOOD="$TMP_ROOT/good.md"
full_list > "$GOOD"

run_check() {
  "$FRAMING" check "$1" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
}

test_check_passes_list_form() {
  local rc
  run_check "$GOOD"; rc=$?
  expect_code 0 "$rc" "list form must pass: $(cat "$TMP_ROOT/err")"
  [ -s "$TMP_ROOT/err" ] && fail "a passing check must print nothing"
  [ -s "$TMP_ROOT/out" ] && fail "a passing check must print nothing"
  pass "fm-framing.sh check: passes a report with all eight labelled answers"
}

test_check_passes_table_form() {
  local r rc
  r=$(write_report table '## Framing' \
    '| Item | Five whys | Need | Who and how many | How often | Manual vs automated ROI | Product change | Non-code way | Metric owner |' \
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- |' \
    '| gate 1 | a | yes | all | daily | cheap | none | none | firstmate |')
  run_check "$r"; rc=$?
  expect_code 0 "$rc" "table form must pass: $(cat "$TMP_ROOT/err")"
  pass "fm-framing.sh check: passes a per-item table naming all eight labels"
}

test_check_fails_table_with_only_empty_cell_row() {
  local r rc
  r=$(write_report table-empty '## Framing' \
    '| Item | Five whys | Need | Who and how many | How often | Manual vs automated ROI | Product change | Non-code way | Metric owner |' \
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- |' \
    '| gate 1 | a | yes | all | daily | cheap | none | none |  |')
  run_check "$r"; rc=$?
  expect_code 1 "$rc" "a table whose only row has an empty cell must fail"
  pass "fm-framing.sh check: fails a table with no complete row"
}

test_check_passes_opt_out() {
  local r rc
  r=$(write_report na '## Framing' 'Not applicable: pure data pull, no decision')
  run_check "$r"; rc=$?
  expect_code 0 "$rc" "opt-out with a reason must pass"
  pass "fm-framing.sh check: passes Not applicable with a reason"
}

test_check_fails_short_opt_out() {
  local r rc
  r=$(write_report na-short '## Framing' 'Not applicable: n/a')
  run_check "$r"; rc=$?
  expect_code 1 "$rc" "opt-out with under 10 characters of reason must fail"
  pass "fm-framing.sh check: fails Not applicable with no real reason"
}

test_check_names_missing_labels() {
  local r rc
  r=$(write_report missing '## Framing' \
    '- Five whys: a' 'Need: yes' 'Who and how many: all' \
    'Manual vs automated ROI: cheap' 'Product change: none' 'Non-code way: none')
  run_check "$r"; rc=$?
  expect_code 1 "$rc" "missing labels must fail"
  assert_grep "$r is missing ## Framing answers: How often, Metric owner" "$TMP_ROOT/err" "message must name the missing labels"
  assert_grep 'unknown - ' "$TMP_ROOT/err" "message must offer the unknown form"
  pass "fm-framing.sh check: exits 1 and names How often, Metric owner"
}

test_check_fails_empty_answer() {
  local r rc
  r="$TMP_ROOT/empty.md"
  sed 's/^Metric owner:.*/Metric owner:/' "$GOOD" > "$r"
  run_check "$r"; rc=$?
  expect_code 1 "$rc" "an empty answer must fail"
  assert_grep "missing ## Framing answers: Metric owner" "$TMP_ROOT/err" "message must name only Metric owner"
  pass "fm-framing.sh check: fails an empty answer"
}

test_check_accepts_unknown_with_text() {
  local r rc
  r="$TMP_ROOT/unknown.md"
  sed 's/^How often:.*/How often: unknown - count the briefs under data/' "$GOOD" > "$r"
  run_check "$r"; rc=$?
  expect_code 0 "$rc" "unknown plus text is a valid answer"
  pass "fm-framing.sh check: accepts unknown followed by a next step"
}

test_check_fails_without_section() {
  local r rc
  r=$(write_report nosection '# Report' 'Need: yes')
  run_check "$r"; rc=$?
  expect_code 1 "$rc" "no section must fail"
  assert_grep "no ## Framing section" "$TMP_ROOT/err" "message must say the section is absent"
  pass "fm-framing.sh check: fails with no ## Framing section"
}

test_check_reads_only_the_framing_section() {
  local r rc
  r=$(write_report outside '## Framing' 'Need: yes' '## Findings' \
    'Five whys: a' 'Who and how many: all' 'How often: daily' 'Manual vs automated ROI: x' \
    'Product change: x' 'Non-code way: x' 'Metric owner: x')
  run_check "$r"; rc=$?
  expect_code 1 "$rc" "labels outside the Framing section must not count"
  pass "fm-framing.sh check: reads only the Framing section"
}

test_usage_errors_exit_2() {
  local rc
  "$FRAMING" check "$TMP_ROOT/does-not-exist.md" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "missing file is a usage error"
  "$FRAMING" bogus >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "unknown command is a usage error"
  pass "fm-framing.sh: usage errors exit 2"
}

test_brief_block_lists_labels_and_command() {
  local out label
  out=$("$FRAMING" brief-block /abs/root)
  for label in "${LABELS[@]}"; do
    assert_contains "$out" "$label" "brief block must name $label"
  done
  assert_contains "$out" "# Framing" "brief block heading"
  assert_contains "$out" "/abs/root/bin/fm-framing.sh check" "brief block must carry the absolute check command"
  assert_contains "$out" "Not applicable:" "brief block must explain the opt-out"
  assert_contains "$out" "one row per item" "brief block must explain the per-item form"
  pass "fm-framing.sh brief-block: names every label and the absolute check command"
}

test_gate_off_skips() {
  local rc
  FM_FRAMING_GATE=off "$FRAMING" gate "$TMP_ROOT/missing-framing.md" scout-x >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "off must skip even a missing report"
  pass "fm-framing.sh gate: off skips"
}

test_gate_warn_and_fail() {
  local r rc
  r=$(write_report gate-bad '## Framing' 'Need: yes')
  FM_FRAMING_GATE=warn "$FRAMING" gate "$r" scout-x > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; rc=$?
  expect_code 0 "$rc" "warn continues"
  grep -q "^WARNING: " "$TMP_ROOT/err" || fail "warn prints a WARNING line"
  env -u FM_FRAMING_GATE "$FRAMING" gate "$r" scout-x > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; rc=$?
  expect_code 0 "$rc" "default mode is warn"
  grep -q "^WARNING: " "$TMP_ROOT/err" || fail "default prints a WARNING line"
  FM_FRAMING_GATE=fail "$FRAMING" gate "$r" scout-x > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; rc=$?
  expect_code 1 "$rc" "fail refuses"
  assert_grep "REFUSED: scout task scout-x report lacks framing answers." "$TMP_ROOT/err" "fail names the task"
  assert_grep "missing ## Framing answers" "$TMP_ROOT/err" "fail carries the check message"
  pass "fm-framing.sh gate: warn continues, fail refuses"
}

test_gate_passes_good_report_silently() {
  local rc
  FM_FRAMING_GATE=fail "$FRAMING" gate "$GOOD" scout-x > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; rc=$?
  expect_code 0 "$rc" "good report passes under fail"
  [ -s "$TMP_ROOT/err" ] && fail "good report printed output"
  pass "fm-framing.sh gate: a good report is silent"
}

test_gate_rejects_unknown_mode() {
  local rc
  FM_FRAMING_GATE=banana "$FRAMING" gate "$GOOD" scout-x >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown mode is a usage error, not a silent skip"
  pass "fm-framing.sh gate: unknown FM_FRAMING_GATE value exits 2"
}

# --- brief scaffold -------------------------------------------------------

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

test_scout_brief_carries_block() {
  local home brief label
  home=$(make_home scout-home)
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fr-scout1 firstmate --scout >/dev/null 2>&1 || fail "scout scaffold failed"
  brief="$home/data/fr-scout1/brief.md"
  grep -q "^# Framing" "$brief" || fail "scout brief missing the framing section"
  for label in "${LABELS[@]}"; do
    assert_grep "$label" "$brief" "scout brief missing label $label"
  done
  assert_grep "fm-framing.sh check" "$brief" "scout brief missing the check command"
  pass "fm-brief.sh: scout brief carries the framing block"
}

test_ship_brief_short_form_without_plan() {
  local home brief
  home=$(make_home ship-noplan)
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fr-ship1 firstmate --mode local-only >/dev/null 2>&1 || fail "ship scaffold failed"
  brief="$home/data/fr-ship1/brief.md"
  grep -q "^# Framing" "$brief" || fail "ship brief without a plan must carry the short framing form"
  assert_grep "Five whys, Need, Who and how many, How often, Manual vs automated ROI, Product change, Non-code way, Metric owner" "$brief" "short form lists the eight labels on one line"
  grep -q "fm-framing.sh check" "$brief" && fail "the short form must not carry the report check command"
  pass "fm-brief.sh: ship brief with no approved plan gets the short framing form"
}

test_ship_brief_nothing_with_plan() {
  local home brief record
  home=$(make_home ship-plan)
  record="$home/data/decided.md"
  printf '%s\n' '- [plan-fr-ship2] 2026-11-23 approved: captain said yes' > "$record"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fr-ship2 firstmate --mode local-only >/dev/null 2>&1 || fail "ship scaffold failed"
  brief="$home/data/fr-ship2/brief.md"
  grep -q "^# Framing" "$brief" && fail "ship brief with an approved plan must not carry the framing block"
  pass "fm-brief.sh: ship brief with an approved plan gets no framing block"
}

test_ship_brief_other_task_plan_does_not_count() {
  local home brief record
  home=$(make_home ship-other-plan)
  record="$home/data/decided.md"
  printf '%s\n' '- [plan-fr-ship3-other] 2026-11-23 approved: someone else' > "$record"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fr-ship3 firstmate --mode local-only >/dev/null 2>&1 || fail "ship scaffold failed"
  brief="$home/data/fr-ship3/brief.md"
  grep -q "^# Framing" "$brief" || fail "a plan for a different task id must not suppress the block"
  pass "fm-brief.sh: only the exact plan key for this task suppresses the short form"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
