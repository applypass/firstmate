#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for the per-task event ledger (bin/fm-task-ledger.sh)
# and the gates built on it: the launch gate in bin/fm-spawn.sh, the merge gates in
# bin/fm-pr-merge.sh and bin/fm-merge-local.sh, the captain wait clock, the turn-end
# charge, and the never-wait checks. No network, no real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# tests/lib.sh turns the ledger gates off for fixtures; this suite tests them.
unset FM_TASK_LEDGER
export TZ=UTC

TMP_ROOT=$(fm_test_tmproot fm-task-ledger)
LEDGER="$ROOT/bin/fm-task-ledger.sh"
FM="$TMP_ROOT/home"
mkdir -p "$FM/data" "$FM/state"
export FM_HOME="$FM"

ledger_file() { printf '%s/data/ticket-ledger/%s.jsonl' "$FM" "$1"; }

test_record_appends_json_lines() {
  local f
  f=$(ledger_file t1)
  "$LEDGER" record t1 intake-start --at 1000 --session s-main --note "filed" || fail "record failed"
  "$LEDGER" record t1 grill-start --at 1060 --session s-main || fail "record failed"
  [ "$(wc -l < "$f")" -eq 2 ] || fail "expected two lines, got: $(cat "$f")"
  assert_equals "intake-start" "$(sed -n 1p "$f" | jq -r .event)" "first event"
  assert_equals "1000" "$(sed -n 1p "$f" | jq -r .at)" "first timestamp"
  assert_equals "s-main" "$(sed -n 1p "$f" | jq -r .session)" "session id kept"
  assert_equals "filed" "$(sed -n 1p "$f" | jq -r .note)" "note kept"
  assert_equals "grill-start" "$(sed -n 2p "$f" | jq -r .event)" "second event appended, not rewritten"
  pass "record appends one JSON line per event"
}

test_record_rejects_unknown_event() {
  local out rc
  out=$("$LEDGER" record t1 coffee-break 2>&1); rc=$?
  expect_code 2 "$rc" "unknown event is a usage error"
  assert_contains "$out" "intake-start" "the error lists the legal events"
  pass "record rejects an event outside the vocabulary"
}

test_record_defaults_time_to_now() {
  local before after at
  before=$(date +%s)
  "$LEDGER" record t2 intake-start || fail "record failed"
  after=$(date +%s)
  at=$(jq -r .at "$(ledger_file t2)")
  [ "$at" -ge "$before" ] && [ "$at" -le "$after" ] || fail "timestamp $at outside $before..$after"
  pass "record stamps the current time by default"
}

test_ledger_survives_task_state_cleanup() {
  "$LEDGER" record t3 intake-start --at 5 || fail "record failed"
  mkdir -p "$FM/state"
  : > "$FM/state/t3.meta"
  rm -rf "$FM/state/t3.meta"
  [ -s "$(ledger_file t3)" ] || fail "ledger lost with the task state"
  assert_contains "$("$LEDGER" show t3)" "intake-start" "show reads the kept ledger"
  pass "ledger lives in data/ and outlives the task state"
}

test_require_spawn_names_missing_event_and_command() {
  local out rc
  out=$("$LEDGER" require spawn fresh1 2>&1); rc=$?
  expect_code 1 "$rc" "a task with no events is refused"
  assert_contains "$out" "intake-start" "names the missing intake event"
  assert_contains "$out" "bin/fm-task-ledger.sh record fresh1 intake-start" "names the command that records it"
  "$LEDGER" record fresh1 intake-start --at 10
  out=$("$LEDGER" require spawn fresh1 2>&1); rc=$?
  expect_code 1 "$rc" "intake alone is not enough"
  assert_contains "$out" "planning-done" "names the missing planning event"
  assert_contains "$out" "bin/fm-task-ledger.sh record fresh1 planning-done" "names the command that records it"
  "$LEDGER" record fresh1 planning-done --at 20
  out=$("$LEDGER" require spawn fresh1 2>&1); rc=$?
  expect_code 0 "$rc" "intake and planning satisfy the gate: $out"
  pass "require spawn needs intake-start and planning-done"
}

test_record_once_skips_a_repeat() {
  "$LEDGER" record once1 intake-start --at 1 --once
  "$LEDGER" record once1 intake-start --at 2 --once
  [ "$(wc -l < "$(ledger_file once1)")" -eq 1 ] || fail "--once appended a duplicate"
  assert_equals "1" "$(jq -r .at "$(ledger_file once1)")" "the first record stays"
  pass "record --once leaves an existing event alone"
}

test_require_off_switch() {
  FM_TASK_LEDGER=off "$LEDGER" require spawn never-recorded >/dev/null 2>&1 || fail "FM_TASK_LEDGER=off must disable the gate"
  pass "the fixture switch disables the gate"
}

test_spawn_refuses_without_intake_and_planning() {
  local out rc fm="$TMP_ROOT/spawnhome"
  mkdir -p "$fm/data" "$fm/state"
  out=$(FM_HOME=$fm "$ROOT/bin/fm-spawn.sh" gated-task "$TMP_ROOT/no-such-project" --scout 2>&1); rc=$?
  expect_code 1 "$rc" "spawn is refused without ledger events"
  assert_contains "$out" "bin/fm-task-ledger.sh record gated-task intake-start" "refusal names the record command"
  [ ! -e "$fm/state/gated-task.meta" ] || fail "refused launch left task state"
  FM_HOME=$fm "$LEDGER" record gated-task intake-start --at 1
  FM_HOME=$fm "$LEDGER" record gated-task planning-done --at 2
  out=$(FM_HOME=$fm "$ROOT/bin/fm-spawn.sh" gated-task "$TMP_ROOT/no-such-project" --scout 2>&1)
  assert_not_contains "$out" "task ledger" "recorded events pass the gate"
  out=$(FM_HOME=$fm "$ROOT/bin/fm-spawn.sh" other-task --relaunch 2>&1)
  assert_not_contains "$out" "task ledger" "relaunch is running work and is never gated"
  pass "spawn refuses a fresh launch without intake and planning events"
}

test_merge_refusals() {
  local out rc fm="$TMP_ROOT/mergehome" url=https://github.com/o/r/pull/1
  mkdir -p "$fm/data" "$fm/state"
  out=$(FM_HOME=$fm "$ROOT/bin/fm-pr-merge.sh" merge-task "$url" 2>&1); rc=$?
  expect_code 1 "$rc" "merge is refused without ready and approval times"
  assert_contains "$out" "bin/fm-task-ledger.sh record merge-task pr-ready" "names the pr-ready command"
  assert_contains "$out" "bin/fm-task-ledger.sh record merge-task captain-approval" "names the approval command"
  FM_HOME=$fm "$LEDGER" record merge-task pr-ready --at 1
  out=$(FM_HOME=$fm "$ROOT/bin/fm-pr-merge.sh" merge-task "$url" 2>&1); rc=$?
  expect_code 1 "$rc" "ready alone is not enough"
  assert_not_contains "$out" "record merge-task pr-ready" "pr-ready no longer missing"
  assert_contains "$out" "record merge-task captain-approval" "approval still missing"
  FM_HOME=$fm "$LEDGER" record merge-task captain-approval --at 2
  out=$(FM_HOME=$fm "$ROOT/bin/fm-pr-merge.sh" merge-task "$url" 2>&1)
  assert_not_contains "$out" "task ledger" "both recorded: the ledger gate passes"
  out=$(FM_HOME=$fm "$ROOT/bin/fm-merge-local.sh" local-task 2>&1); rc=$?
  expect_code 1 "$rc" "local landing is refused without ready and approval times"
  assert_contains "$out" "bin/fm-task-ledger.sh record local-task pr-ready" "local landing names the command"
  pass "merge and local landing are refused without pr-ready and captain-approval"
}

fm_test_run \
  test_record_appends_json_lines \
  test_record_rejects_unknown_event \
  test_record_defaults_time_to_now \
  test_ledger_survives_task_state_cleanup \
  test_require_spawn_names_missing_event_and_command \
  test_record_once_skips_a_repeat \
  test_require_off_switch \
  test_spawn_refuses_without_intake_and_planning \
  test_merge_refusals
