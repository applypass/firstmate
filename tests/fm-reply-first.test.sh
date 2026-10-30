#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for reply-first (bin/fm-reply-first.sh).
#
# The hook counts tool calls after a message that expects an answer and refuses
# the call after the limit, once. It is driven with real PreToolUse payloads and
# real transcript files; no harness runs. A second mate home and the primary
# home have it; a linked task worktree does not.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-reply-first)
RF="$ROOT/bin/fm-reply-first.sh"

# make_home <name> <mate|main>
make_home() {
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state" "$H/config"
  if [ "$2" = mate ]; then
    printf 'mate-a\n' > "$H/.fm-secondmate-home"
  elif [ "$2" = main ]; then
    mkdir -p "$H/bin"; : > "$H/AGENTS.md"
    git -C "$H" init -q
  fi
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

# expect_captain_reply <text> <want_code>: the call after the third, once <text> is said.
expect_captain_reply() {
  make_home "addr$((++ADDR_N))" mate
  arm
  call 'ls'
  say "$1"
  call 'ls'; call 'ls'
  call 'ls'; expect_code "$2" "$RC" "after '$1', call 4"
}

test_only_text_addressed_to_the_captain_counts() {
  ADDR_N=0
  expect_captain_reply 'Captain, shipshape.' 0
  expect_captain_reply 'Aye, captain - done.' 0
  expect_captain_reply 'Done, captain.' 0
  expect_captain_reply 'Let me see what the captain asked' 2
  expect_captain_reply 'Checking bin/fm-captain-hold.sh for X.' 2
  pass "text addressed to the captain closes the window, narration naming the captain or a captain script does not"
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

test_scope_is_mates_and_the_primary_home() {
  make_home main main
  FM_HOME="$H" "$RF" enabled || fail "the primary home is not on by default"
  make_home mate2 mate
  FM_HOME="$H" "$RF" enabled || fail "a mate home is not on"
  make_home off main
  printf 'off\n' > "$H/config/reply-first"
  FM_HOME="$H" "$RF" enabled && fail "config/reply-first off did not turn it off"
  arm
  call 'ls'; call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "a home that is off never refuses"
  [ ! -e "$H/state/.reply-first" ] || fail "a home that is off wrote a window"
  make_home wt main
  git -C "$H" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$H" worktree add -q "$TMP_ROOT/wt-linked" 2>/dev/null
  mkdir -p "$TMP_ROOT/wt-linked/state" "$TMP_ROOT/wt-linked/bin"; : > "$TMP_ROOT/wt-linked/AGENTS.md"
  FM_HOME="$TMP_ROOT/wt-linked" "$RF" enabled && fail "a linked task worktree is not a primary home"
  pass "it runs in a mate home and the primary home, honours config/reply-first off, and skips task worktrees"
}

# prompt <text>: one UserPromptSubmit through the main prompt hook.
prompt() {
  jq -cn --arg p "$1" --arg t "$TRANSCRIPT" '{hook_event_name:"UserPromptSubmit",prompt:$p,transcript_path:$t}' \
    | FM_HOME="$H" "$RF" prompt --claude
}

test_main_captain_prompt_opens_a_window() {
  make_home mcap main
  prompt 'how are the reply-first tests going?'
  call 'ls'; call 'ls'; call 'ls'
  call 'ls'; expect_code 2 "$RC" "the fourth call after a captain message is refused"
  assert_contains "$ERR" "Answer now" "answer-now reason"
  assert_contains "$ERR" "worker or second mate" "main hand-off wording"
  call 'ls'; expect_code 0 "$RC" "the refusal fires once"
  pass "a captain prompt in the main home gets the fourth call refused once"
}

test_main_slash_command_never_arms() {
  make_home mslash main
  prompt '  /afk'
  call 'ls'; call 'ls'; call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "no refusal after a slash command"
  [ ! -e "$H/state/.reply-first" ] || fail "a slash command opened a window"
  prompt 'what is the status?'
  [ -e "$H/state/.reply-first" ] || fail "a plain question did not open a window"
  call 'ls'; call 'ls'; call 'ls'
  call 'ls'; expect_code 2 "$RC" "a plain question still gets the fourth call refused"
  pass "a slash command never opens a window and a plain question still does"
}

test_main_machine_prompts_never_arm() {
  local text
  while IFS= read -r text; do
    make_home mwake main
    prompt "$text"
    call 'ls'; call 'ls'; call 'ls'; call 'ls'; call 'ls'
    expect_code 0 "$RC" "no refusal after: $text"
    [ ! -e "$H/state/.reply-first" ] || fail "armed by: $text"
  done <<'EOF2'
Stop hook feedback: firstmate watcher wake - one supervision event needs a handling turn now.
firstmate watcher wake - one supervision event needs a handling turn now.
<task-notification><task-id>abc</task-id></task-notification>
: Firstmate instruction waiting: read the inbox
[fm-from-firstmate] steer text
EOF2
  make_home mdoor main
  local bell
  bell=$(printf 'wake now' | FM_HOME="$H" "$ROOT/bin/fm-operational-input.sh" record watcher) || fail "could not write a doorbell record"
  prompt "$bell"
  call 'ls'; call 'ls'; call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "no refusal after an operational doorbell"
  make_home menc main
  prompt "$(printf 'wake now' | "$ROOT/bin/fm-operational-input.sh" encode away-supervisor)"
  call 'ls'; call 'ls'; call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "no refusal after encoded operational input"
  pass "wakes, task notifications, and firstmate doorbells never open a window"
}

test_main_machine_prompt_closes_an_open_window() {
  make_home mclose main
  prompt 'what is the status?'
  call 'ls'; call 'ls'; call 'ls'
  prompt 'Stop hook feedback: firstmate watcher wake'
  call 'ls'; expect_code 0 "$RC" "a wake prompt closes the captain window"
  make_home mstop main
  prompt 'what is the status?'
  call 'ls'; call 'ls'; call 'ls'
  FM_HOME="$H" "$RF" clear
  call 'ls'; expect_code 0 "$RC" "the Stop hook closes the window"
  pass "a machine prompt or the Stop hook closes a captain window"
}

test_main_reply_closes_and_handoffs_are_free() {
  make_home mreply main
  prompt 'what is the status?'
  call 'ls'
  say "$(printf 'Two workers are running: the hook change is in review and the measure is done. Nothing needs you yet. %.0s' 1 2)"
  call 'ls'; call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "a written answer closes the window"
  make_home mhand main
  prompt 'dig into the logs'
  call 'bin/fm-spawn.sh ship foo'; call 'bin/fm-send.sh task-a "go"'
  call 'bin/fm-dispatch-resolve.sh brief.md'; call 'bin/fm-brief.sh --help'
  call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "hand-off commands are not counted"
  call 'ls'; expect_code 2 "$RC" "the fourth counted call is refused"
  make_home mchain main
  prompt 'dig into the logs'
  call 'cd /tmp && FM_X=1 bin/fm-send.sh task-a "go"'; call 'true; bin/fm-spawn.sh ship foo'
  call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "a hand-off after && or ; is not counted"
  make_home mwrap main
  prompt 'dig into the logs'
  call '"$FM_HOME/bin/fm-send.sh" task-a go'; call 'bash bin/fm-spawn.sh ship foo'
  call 'timeout 30 bin/fm-send.sh task-a go'; call 'env X=1 bin/fm-spawn.sh ship foo'
  call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "quoted or wrapped hand-offs are not counted"
  make_home mqrep mate
  arm
  call "'bin/fm-secondmate-report.sh' working abc \"on it\""
  call 'ls'; call 'ls'; call 'ls'; call 'ls'
  expect_code 0 "$RC" "a quoted parent report is a reply"
  make_home mread main
  prompt 'dig into the logs'
  call 'sed -n 1,80p bin/fm-spawn.sh'; call 'grep -n arm bin/fm-send.sh'; call 'cat bin/fm-brief.sh'
  call 'cat bin/fm-secondmate-report.sh'; expect_code 2 "$RC" "reading hand-off or report scripts counts as digging"
  make_home mread2 main
  prompt 'dig into the logs'
  call 'timeout 5 cat bin/fm-spawn.sh'; call 'env X=1 sed -n 1p bin/fm-send.sh'; call 'bash -n bin/fm-brief.sh'
  call 'ls'; expect_code 2 "$RC" "wrapped reads of hand-off scripts still count"
  pass "a reply closes the window and hand-off commands are never counted or refused"
}

test_installer_registers_main_hooks_once() {
  make_home minst main
  "$ROOT/bin/fm-mate-hooks-install.sh" --main "$H" || fail "main install failed"
  "$ROOT/bin/fm-mate-hooks-install.sh" --main "$H" || fail "second main install failed"
  local f="$H/.claude/settings.local.json"
  [ "$(jq '[.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("fm-reply-first.sh") and contains("prompt"))] | length' "$f")" = 1 ] || fail "prompt hook not registered once"
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | contains("fm-reply-first.sh"))] | length' "$f")" = 1 ] || fail "pretool hook not registered once"
  [ "$(jq '[.hooks.Stop[].hooks[] | select(.command | contains("fm-reply-first.sh"))] | length' "$f")" = 1 ] || fail "stop hook not registered once"
  make_home minst2 mate
  "$ROOT/bin/fm-mate-hooks-install.sh" --main "$H" || fail "main install in a mate home failed"
  [ ! -e "$H/.claude/settings.local.json" ] || fail "--main wrote into a second mate home"
  pass "the main installer registers prompt, pretool, and Stop once and skips a mate home"
}

test_text_flushed_a_moment_late_still_counts() {
  make_home late main
  prompt 'what is the status?'
  call 'ls'; call 'ls'; call 'ls'
  ( sleep 0.5; say "$(printf 'The harness writes this answer to the transcript just after the tool call starts, so the hook must look again before it refuses. %.0s' 1 2)" ) &
  call 'ls'; expect_code 0 "$RC" "an answer flushed during the recheck closes the window"
  wait
  pass "an answer the harness flushes a moment late is not refused"
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
test_only_text_addressed_to_the_captain_counts
test_text_from_before_the_message_does_not_count
test_new_message_resets_the_count
test_clear_closes_the_window
test_no_window_no_refusal
test_scope_is_mates_and_the_primary_home
test_main_captain_prompt_opens_a_window
test_main_slash_command_never_arms
test_main_machine_prompts_never_arm
test_main_machine_prompt_closes_an_open_window
test_main_reply_closes_and_handoffs_are_free
test_installer_registers_main_hooks_once
test_text_flushed_a_moment_late_still_counts
test_limit_is_tunable_and_broken_input_fails_open
test_scripts_are_shellcheck_clean
