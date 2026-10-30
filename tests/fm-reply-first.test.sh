#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for reply-first (bin/fm-reply-first.sh).
#
# The hook counts tool calls after a message that expects an answer and refuses
# the call after the limit, once. It is driven with real PreToolUse payloads and
# real transcript files; no harness runs. Only a second mate home has it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-reply-first)
RF="$ROOT/bin/fm-reply-first.sh"

# make_home <name> <mate|main>
make_home() {
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state" "$H/config"
  [ "$2" != mate ] || printf 'mate-a\n' > "$H/.fm-secondmate-home"
  TRANSCRIPT="$H/transcript.jsonl"
  : > "$TRANSCRIPT"
}

arm() { FM_HOME="$H" "$RF" arm --transcript "$TRANSCRIPT"; }

# call <command>: one Bash PreToolUse; exit code in RC, stderr in ERR.
call() {
  ERR=$(jq -cn --arg c "$1" --arg t "$TRANSCRIPT" '{tool_name:"Bash",tool_input:{command:$c},transcript_path:$t}' \
    | FM_HOME="$H" "$RF" pretool --claude 2>&1 >/dev/null)
  RC=$?
}

say() {  # <text>: the assistant writes text into the transcript
  jq -cn --arg t "$1" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' >> "$TRANSCRIPT"
}

test_refuses_the_fourth_call_once() {
  make_home four mate
  arm
  call 'ls'; expect_code 0 "$RC" "call 1"
  call 'cat a'; expect_code 0 "$RC" "call 2"
  call 'cat b'; expect_code 0 "$RC" "call 3"
  call 'cat c'; expect_code 2 "$RC" "call 4 is refused"
  assert_contains "$ERR" '"permissionDecision":"deny"' "deny object"
  assert_contains "$ERR" "Answer now" "reason says answer now"
  assert_contains "$ERR" "hand the rest off" "reason says hand the rest off"
  call 'cat c'; expect_code 0 "$RC" "the refusal fires once, the retry runs"
  call 'cat d'; expect_code 0 "$RC" "later calls run"
  pass "the call after the third command is refused once, then work resumes"
}

test_a_parent_report_is_a_reply() {
  make_home report mate
  arm
  call 'ls'; call 'ls'
  call 'bin/fm-secondmate-report.sh working abcdef0123456789 "on it, audit half done"'
  expect_code 0 "$RC" "the report call itself runs"
  call 'ls'; call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "no refusal after a report"
  pass "a status append to the parent counts as the reply"
}

test_substantial_text_is_a_reply_and_narration_is_not() {
  make_home text mate
  arm
  say 'Let me check that.'
  call 'ls'; call 'ls'; call 'ls'
  call 'ls'; expect_code 2 "$RC" "a line of narration is not an answer"
  make_home text2 mate
  arm
  call 'ls'
  say "$(printf 'The audit is half done: 40 of 80 invoices are checked, 3 need a fix, and I will report the rest when it finishes. %.0s' 1 2)"
  call 'ls'; call 'ls'; call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "a real answer in the pane closes the window"
  pass "an answer of a paragraph closes the window, a line of narration does not"
}

test_short_captain_reply_closes_the_window() {
  make_home short mate
  arm
  call 'ls'; call 'ls'
  say 'Captain, shipshape.'
  call 'ls'; expect_code 0 "$RC" "call 3"
  call 'ls'; expect_code 0 "$RC" "a short reply to the captain closes the window, call 4 runs"
  make_home short2 mate
  arm
  say 'let me check'
  call 'ls'; call 'ls'; call 'ls'
  call 'ls'; expect_code 2 "$RC" "short narration does not close the window"
  call 'ls'; expect_code 0 "$RC" "refused once"
  pass "a short reply addressing the captain closes the window, short narration does not"
}

test_text_from_before_the_message_does_not_count() {
  make_home old mate
  say "$(printf 'An earlier reply to a different message, long enough to count as an answer on its own. %.0s' 1 2 3)"
  arm
  call 'ls'; call 'ls'; call 'ls'
  call 'ls'; expect_code 2 "$RC" "text written before the message is ignored"
  pass "only text after the message opens the window counts"
}

test_new_message_resets_the_count() {
  make_home reset mate
  arm
  call 'ls'; call 'ls'; call 'ls'
  arm
  call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "three calls after the new message"
  call 'ls'; expect_code 2 "$RC" "the fourth after the new message is refused"
  pass "a new message opens a fresh window"
}

test_clear_closes_the_window() {
  make_home clear mate
  arm
  call 'ls'; call 'ls'; call 'ls'
  FM_HOME="$H" "$RF" clear
  call 'ls'; expect_code 0 "$RC" "a closed window refuses nothing"
  pass "clear closes the window, so routed work is never refused"
}

test_no_window_no_refusal() {
  make_home idle mate
  local i
  for i in 1 2 3 4 5 6; do call 'ls'; expect_code 0 "$RC" "call $i with no message"; done
  pass "calls with no open window are never refused"
}

test_only_a_mate_home_has_it() {
  make_home main main
  printf 'on\n' > "$H/config/reply-first"
  arm
  call 'ls'; call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "a main home never refuses"
  [ ! -e "$H/state/.reply-first" ] || fail "a main home wrote a window"
  FM_HOME="$H" "$RF" enabled && fail "enabled reported on for a main home"
  make_home mate2 mate
  FM_HOME="$H" "$RF" enabled || fail "a mate home is not on"
  pass "reply-first runs in a second mate home only"
}

test_limit_is_tunable_and_broken_input_fails_open() {
  make_home limit mate
  arm
  FM_REPLY_FIRST_LIMIT=1 call 'ls'
  FM_REPLY_FIRST_LIMIT=1 call 'ls'
  expect_code 2 "$RC" "limit 1 refuses the second call"
  make_home broken mate
  arm
  printf 'epoch=x\ncount=zzz\n' > "$H/state/.reply-first"
  call 'ls'; expect_code 0 "$RC" "an unreadable window allows the call"
  printf 'not json' | FM_HOME="$H" "$RF" pretool --claude; expect_code 0 $? "malformed payload allows"
  printf '' | FM_HOME="$H" "$RF" pretool --claude; expect_code 0 $? "empty payload allows"
  pass "the limit is tunable and broken input never blocks work"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  "$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-reply-first.sh" >/dev/null 2>&1 || fail "bin/fm-reply-first.sh is not lint-clean"
  pass "reply-first is clean under bin/fm-lint.sh"
}

test_refuses_the_fourth_call_once
test_a_parent_report_is_a_reply
test_substantial_text_is_a_reply_and_narration_is_not
test_short_captain_reply_closes_the_window
test_text_from_before_the_message_does_not_count
test_new_message_resets_the_count
test_clear_closes_the_window
test_no_window_no_refusal
test_only_a_mate_home_has_it
test_limit_is_tunable_and_broken_input_fails_open
test_scripts_are_shellcheck_clean
