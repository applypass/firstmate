#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for the second mate captain-direct hook (bin/fm-captain-direct.sh)
# and its installer (bin/fm-mate-hooks-install.sh).
#
# A human typing into a second mate's pane must reach the parent as one
# `captain-direct` status line the classifier surfaces, while Firstmate's own
# traffic (doorbell, from-firstmate, operational input, harness notifications)
# never does, and a main home or a read-only side session stays untouched.
# The hook is driven with real UserPromptSubmit payloads and real scripts; no
# harness runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-direct)
HOOK="$ROOT/bin/fm-captain-direct.sh"

# make_world <name>: a parent home plus a seeded local mate home "mate-a".
make_world() {
  local dir="$TMP_ROOT/$1"
  PARENT="$dir/parent"
  MATE="$dir/mate"
  mkdir -p "$PARENT/state" "$PARENT/data" "$MATE/state" "$MATE/config" "$MATE/bin"
  printf 'mate-a\n' > "$MATE/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$MATE/.fm-secondmate-parent"
  STATUS="$PARENT/state/mate-a.status"
}

# hook <prompt> [env assignments...]: runs the hook as a mate; output in HOOK_OUT.
hook() {
  local prompt=$1
  shift
  HOOK_OUT=$(jq -cn --arg p "$prompt" '{hook_event_name:"UserPromptSubmit",prompt:$p,transcript_path:""}' \
    | env FM_HOME="$MATE" "$@" "$HOOK" --claude 2>&1)
  HOOK_RC=$?
}

test_captain_words_reach_the_parent() {
  make_world typed
  hook 'please drop the audit and look at the invoice bug first'
  expect_code 0 "$HOOK_RC" "hook exits 0"
  [ -f "$STATUS" ] || fail "no parent status line was written"
  assert_equals "1" "$(wc -l < "$STATUS" | tr -d ' ')" "exactly one line"
  grep -Eq '^captain-direct \[at=[0-9]+\]: please drop the audit and look at the invoice bug first$' "$STATUS" \
    || fail "line shape wrong: $(cat "$STATUS")"
  assert_equals "captain-direct" "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$HOOK_OUT" | sed -n 's/^\[\(captain-direct\)\].*/\1/p')" "reminder injected"
  assert_contains "$HOOK_OUT" "fm-secondmate-report.sh" "reminder keeps outcomes on the parent channel"
  assert_equals "UserPromptSubmit" "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$HOOK_OUT")" "hook event name"
  pass "captain words become one parent line and a reminder to answer in the pane"
}

test_line_is_surfaced_not_a_decision() {
  make_world classify
  hook 'status of the audit?'
  local line out
  line=$(tail -n 1 "$STATUS")
  out=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_is_captain_relevant "$2" && echo relevant; status_open_decisions "$3"' _ "$ROOT" "$line" "$STATUS" 2>&1)
  assert_contains "$out" "relevant" "classifier surfaces the captain-direct line as an event"
  assert_not_contains "$out" "captain-direct" "the line is not an open decision"
  pass "the classifier surfaces the line and does not open a decision"
}

test_long_and_multiline_words_are_bounded() {
  make_world long
  local long
  long=$(printf 'word%.0s ' $(seq 1 120))
  hook "$(printf 'first line\nsecond\tline %s' "$long")"
  [ "$(wc -l < "$STATUS" | tr -d ' ')" = 1 ] || fail "multi-line prompt broke the line framing"
  local body
  body=$(sed 's/^[^:]*: //' "$STATUS")
  [ "${#body}" -le 200 ] || fail "line body is ${#body} characters, over 200"
  assert_contains "$body" "first line second line" "newlines and tabs fold to spaces"
  assert_contains "$body" "..." "a cut line says so"
  pass "a long or multi-line prompt is folded to one bounded line"
}

test_firstmate_traffic_is_not_the_captain() {
  make_world traffic
  local doorbell op
  doorbell=': Firstmate instruction waiting: list "$FM_TASK_INBOX"/*.msg in your '"'mate-a.inbox'"' steering inbox, read and act on each in numeric order, then mv each into its handled/.'
  hook "$doorbell"
  hook '[fm-from-firstmate] audit the invoice queue'
  hook "$(printf '[fm-from-firstmate]\xE2\x81\xA3 audit the invoice queue')"
  op=$(printf 'wake now' | "$ROOT/bin/fm-operational-input.sh" encode watcher)
  hook "$op"
  hook '<task-notification><task-id>x</task-id></task-notification>'
  hook '   '
  [ ! -s "$STATUS" ] || fail "firstmate traffic wrote a captain-direct line: $(cat "$STATUS")"
  pass "doorbell, from-firstmate, operational input, notifications, and blanks write nothing"
}

test_inert_outside_a_mate_home() {
  make_world main
  rm -f "$MATE/.fm-secondmate-home"
  hook 'hello from the captain'
  [ ! -s "$STATUS" ] || fail "a home with no secondmate marker wrote a line"
  [ -z "$HOOK_OUT" ] || fail "a main home printed output: $HOOK_OUT"
  make_world ask
  hook 'hello from the captain' FM_ASK_READONLY=1
  [ ! -s "$STATUS" ] && [ -z "$HOOK_OUT" ] || fail "the read-only side session was not left alone"
  pass "a main home and the read-only side session are untouched"
}

test_unwritable_parent_channel_is_said() {
  make_world nochannel
  rm -f "$MATE/.fm-secondmate-parent"
  hook 'where are we?'
  expect_code 0 "$HOOK_RC" "hook never blocks the prompt"
  assert_contains "$HOOK_OUT" "could not be written" "the reminder tells the mate the parent note failed"
  pass "a missing parent binding is reported to the mate, not swallowed"
}

test_reply_window_is_armed() {
  make_world arm
  hook 'quick question'
  grep -q '^source=captain-direct$' "$MATE/state/.reply-first" || fail "captain-direct did not arm the reply window"
  hook ': Firstmate instruction waiting: list "$FM_TASK_INBOX"/*.msg in your '"'mate-a.inbox'"' steering inbox'
  [ ! -e "$MATE/state/.reply-first" ] || fail "the doorbell did not close the captain's reply window"
  hook 'quick question'
  hook "$(printf '[fm-from-firstmate]\xE2\x81\xA3 audit the invoice queue')"
  [ ! -e "$MATE/state/.reply-first" ] || fail "a from-firstmate message did not close the reply window"
  pass "a captain message opens the reply window; firstmate traffic closes it"
}

test_installer() {
  local target="$TMP_ROOT/install" f
  mkdir -p "$target/.claude"
  printf '{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"keep-me"}]}]}}\n' > "$target/.claude/settings.local.json"
  "$ROOT/bin/fm-mate-hooks-install.sh" "$target" || fail "installer failed"
  "$ROOT/bin/fm-mate-hooks-install.sh" "$target" || fail "second install failed"
  f="$target/.claude/settings.local.json"
  [ "$(jq '[.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("fm-captain-direct.sh"))] | length' "$f")" = 1 ] || fail "prompt hook not registered exactly once"
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | contains("fm-reply-first.sh"))] | length' "$f")" = 1 ] || fail "tool hook not registered exactly once"
  [ "$(jq -r '.permissions.allow[0]' "$f")" = 'Bash(ls:*)' ] || fail "installer dropped an existing permission"
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command == "keep-me")] | length' "$f")" = 1 ] || fail "installer dropped an existing hook"
  # The registered command runs from a path with a space and reaches the hook.
  local spaced="$TMP_ROOT/with space" cmd out
  mkdir -p "$spaced" "$TMP_ROOT/install2"
  cp "$ROOT"/bin/fm-mate-hooks-install.sh "$ROOT"/bin/fm-captain-direct.sh "$ROOT"/bin/fm-reply-first.sh "$spaced/"
  "$spaced/fm-mate-hooks-install.sh" "$TMP_ROOT/install2" || fail "spaced install failed"
  cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$TMP_ROOT/install2/.claude/settings.local.json")
  out=$(printf '{}' | bash -c "$cmd" 2>&1)
  expect_code 0 $? "registered prompt hook runs from a spaced path: $out"
  pass "installer merges, keeps other settings, is idempotent, and registers runnable commands"
}

test_scripts_are_shellcheck_clean() {
  local out f
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  for f in fm-captain-direct.sh fm-mate-hooks-install.sh fm-reply-first.sh; do
    out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/$f" 2>&1) || fail "bin/$f is not lint-clean: $out"
  done
  pass "captain-direct scripts are clean under bin/fm-lint.sh"
}

test_captain_words_reach_the_parent
test_line_is_surfaced_not_a_decision
test_long_and_multiline_words_are_bounded
test_firstmate_traffic_is_not_the_captain
test_inert_outside_a_mate_home
test_unwritable_parent_channel_is_said
test_reply_window_is_armed
test_installer
test_scripts_are_shellcheck_clean
