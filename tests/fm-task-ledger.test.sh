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

test_captain_wait_clock_includes_away_time() {
  local out
  "$LEDGER" record w1 intake-start --at 1000
  "$LEDGER" wait-start w1 --at 1100 --note "design pick"
  # A second ask before the first answer does not restart the clock.
  "$LEDGER" wait-start w1 --at 1200
  : > "$FM/state/.afk"
  "$LEDGER" wait-end w1 --at 5000
  rm -f "$FM/state/.afk"
  out=$("$LEDGER" summary w1 --now 9000)
  assert_contains "$out" "captain_wait_seconds=3900" "the clock runs from the first ask to the answer, away time included"
  assert_contains "$out" "open_captain_wait=0" "answered wait is closed"
  "$LEDGER" wait-start w1 --at 6000
  out=$("$LEDGER" summary w1 --now 7000)
  assert_contains "$out" "captain_wait_seconds=4900" "an open ask counts up to now"
  assert_contains "$out" "open_captain_wait=1" "open ask is reported"
  pass "captain wait clock runs from recorded ask to recorded answer"
}

test_wait_end_after_pr_ready_records_approval() {
  "$LEDGER" record w2 pr-ready --at 100
  "$LEDGER" wait-start w2 --at 200
  "$LEDGER" wait-end w2 --at 300
  "$LEDGER" has w2 captain-approval || fail "answer to the post-ready ask is the approval"
  assert_equals "300" "$(jq -r 'select(.event == "captain-approval") | .at' "$(ledger_file w2)")" "approval time is the answer time"
  "$LEDGER" record w3 intake-start --at 1
  "$LEDGER" wait-start w3 --at 2
  "$LEDGER" wait-end w3 --at 3
  "$LEDGER" has w3 captain-approval && fail "a pre-ready answer is not a merge approval"
  pass "an answer to an ask opened after pr-ready records captain-approval"
}

test_captain_hold_records_the_wait() {
  local fm="$TMP_ROOT/holdhome"
  mkdir -p "$fm/data" "$fm/state"
  # Drive the real hold and answer commands against a fixture backlog.
  command -v tasks-axi >/dev/null 2>&1 || { pass "fm-captain-hold records the wait around hold and answer (skipped: tasks-axi absent)"; return 0; }
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$fm/data/backlog.md"
  FM_HOME=$fm "$ROOT/bin/fm-tasks-axi.sh" add hold-t "Hold test" --kind ship >/dev/null 2>&1
  FM_HOME=$fm "$ROOT/bin/fm-captain-hold.sh" hold hold-t --reason "pick one" >/dev/null 2>&1
  printf 'option a\n' > "$fm/decision.txt"
  FM_HOME=$fm "$ROOT/bin/fm-captain-hold.sh" answer hold-t --decision-file "$fm/decision.txt" --release >/dev/null 2>&1
  local f="$fm/data/ticket-ledger/hold-t.jsonl"
  assert_contains "$(jq -r .event "$f" | tr '\n' ' ')" "captain-wait-start" "hold recorded the ask"
  assert_contains "$(jq -r .event "$f" | tr '\n' ' ')" "captain-wait-end" "answer recorded the answer"
  pass "fm-captain-hold records the wait around hold and answer"
}

# A two-line Claude transcript fragment: one user prompt and one assistant reply
# whose usage repeats across content blocks (same message id).
write_transcript() {  # <file> <t0 ISO> <t1 ISO> <msg-id> <in> <out>
  local reply
  reply=$(jq -nc --arg t "$3" --arg id "$4" --argjson i "$5" --argjson o "$6" \
    '{type: "assistant", timestamp: $t, message: {id: $id, role: "assistant", usage: {input_tokens: $i, output_tokens: $o, cache_read_input_tokens: 7, cache_creation_input_tokens: 3}}}')
  {
    jq -nc --arg t "$2" '{type: "user", timestamp: $t, message: {role: "user", content: "go"}}'
    printf '%s\n%s\n' "$reply" "$reply"
  } >> "$1"
}

charge() {  # <home> <session> <transcript>
  FM_HOME=$1 "$LEDGER" charge --payload "$(jq -nc --arg s "$2" --arg t "$3" '{session_id: $s, transcript_path: $t}')"
}

test_charge_bills_the_open_task_then_fleet_overhead() {
  local fm="$TMP_ROOT/chargehome" tr="$TMP_ROOT/chargehome/transcript.jsonl" f out
  mkdir -p "$fm/data" "$fm/state"
  # No open task: the turn goes to fleet overhead.
  write_transcript "$tr" 2026-10-27T10:00:00.000Z 2026-10-27T10:01:30.000Z msg-a 100 40
  charge "$fm" sess-1 "$tr" || fail "charge failed"
  f="$fm/data/ticket-ledger/_fleet-overhead.jsonl"
  [ -s "$f" ] || fail "no overhead record: $(ls "$fm/data/ticket-ledger")"
  assert_equals "turn" "$(jq -r .event "$f")" "event kind"
  assert_equals "sess-1" "$(jq -r .session "$f")" "session id kept for the token join"
  assert_equals "90" "$(jq -r .turn_seconds "$f")" "turn length from the transcript timestamps"
  assert_equals "100" "$(jq -r .tokens.input "$f")" "duplicate message blocks count once"
  assert_equals "40" "$(jq -r .tokens.output "$f")" "output tokens"
  # Filing a task opens it: the next turn is charged to it, and only the new transcript lines count.
  FM_HOME=$fm "$LEDGER" record open-t intake-start --at 1
  write_transcript "$tr" 2026-10-27T11:00:00.000Z 2026-10-27T11:00:20.000Z msg-b 5 6
  charge "$fm" sess-1 "$tr" || fail "charge failed"
  f="$fm/data/ticket-ledger/open-t.jsonl"
  assert_equals "20" "$(jq -rs '[.[] | select(.event == "turn")][0].turn_seconds' "$f")" "second charge reads only the new region"
  assert_equals "5" "$(jq -rs '[.[] | select(.event == "turn")][0].tokens.input' "$f")" "second charge tokens"
  out=$(FM_HOME=$fm "$LEDGER" tokens open-t)
  assert_contains "$out" "input=5" "tokens sums the task's turns"
  assert_contains "$out" "output=6" "tokens sums output"
  assert_contains "$(FM_HOME=$fm "$LEDGER" sessions open-t)" "sess-1" "sessions lists the join keys"
  # The merge closes the task: later turns return to fleet overhead.
  FM_HOME=$fm "$LEDGER" record open-t merged --at 9
  write_transcript "$tr" 2026-10-27T12:00:00.000Z 2026-10-27T12:00:10.000Z msg-c 1 1
  charge "$fm" sess-1 "$tr"
  [ "$(jq -rs '[.[] | select(.event == "turn")] | length' "$fm/data/ticket-ledger/open-t.jsonl")" -eq 1 ] || fail "a merged task kept getting charged"
  [ "$(jq -rs 'length' "$fm/data/ticket-ledger/_fleet-overhead.jsonl")" -eq 2 ] || fail "the post-merge turn did not reach fleet overhead"
  pass "charge bills the open task, falls back to fleet overhead, and joins tokens by session id"
}

test_charge_is_a_noop_without_a_session() {
  local fm="$TMP_ROOT/nosessionhome"
  mkdir -p "$fm/data" "$fm/state"
  FM_HOME=$fm "$LEDGER" charge --payload '{}' || fail "charge must not fail the turn end"
  [ ! -e "$fm/data/ticket-ledger" ] || fail "a payload with no session wrote a record"
  FM_TASK_LEDGER=off FM_HOME=$fm "$LEDGER" charge --payload '{"session_id":"x","transcript_path":"/nope"}' || fail "off switch"
  pass "charge never blocks a turn end and respects the off switch"
}

test_turnend_guard_charges_a_primary_turn() {
  local dir="$TMP_ROOT/guardprimary" tr="$TMP_ROOT/guard-transcript.jsonl"
  mkdir -p "$dir/state"
  git init -q "$dir"
  fm_git_identity fmtest fmtest@example.invalid
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  write_transcript "$tr" 2026-10-27T10:00:00.000Z 2026-10-27T10:00:05.000Z msg-g 9 4
  jq -nc --arg t "$tr" '{session_id: "sess-guard", transcript_path: $t}' \
    | CLAUDECODE=1 FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" --claude >/dev/null 2>&1
  assert_equals "turn" "$(jq -r .event "$dir/data/ticket-ledger/_fleet-overhead.jsonl" 2>/dev/null)" "the guard charged the turn"
  assert_equals "9" "$(jq -r .tokens.input "$dir/data/ticket-ledger/_fleet-overhead.jsonl")" "with the transcript tokens"
  pass "the turn-end guard charges a primary session's turn"
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
  test_merge_refusals \
  test_captain_wait_clock_includes_away_time \
  test_wait_end_after_pr_ready_records_approval \
  test_captain_hold_records_the_wait \
  test_charge_bills_the_open_task_then_fleet_overhead \
  test_charge_is_a_noop_without_a_session \
  test_turnend_guard_charges_a_primary_turn
