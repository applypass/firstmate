#!/usr/bin/env bash
# Behavior tests for bin/fm-decide.sh (applypass fork): the only writer of
# data/decided.md, which posts every decision to a Shortcut story. Shortcut is
# stubbed with a fake curl on PATH; no test reaches the real API, 1Password, or
# any real home's decided.md.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-decide)
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE \
  FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
TOKEN=tok-secret-123
OWNER=11111111-2222-4333-8444-555555555555

make_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/defaults" "$dir/home/data" "$dir/home/state" "$dir/home/config" "$dir/home/.claude"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
  cp "$ROOT/defaults/shortcut-tickets" "$dir/code/defaults/shortcut-tickets"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
  printf 'owner_id=%s\ntoken_ref=op://v/i/f\n' "$OWNER" > "$dir/home/config/shortcut-tickets"
  fm_fake_shortcut_curl "$dir/fakebin"
  fm_fake_exit0 "$dir/fakebin" tmux treehouse no-mistakes gh gh-axi
  : > "$dir/curl.log"
  printf '%s\n' "$dir"
}

decide() {  # <case-dir> <args...>
  local dir=$1
  shift
  (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    SHORTCUT_API_TOKEN="$TOKEN" FAKE_CURL_LOG="$dir/curl.log" FM_DECIDE_DATE=2026-10-09 \
    PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-decide.sh" "$@" 2>&1)
}

install_guard() {  # <case-dir>
  (cd "$1/code" && FM_HOME="$1/home" FM_ROOT_OVERRIDE="$1/code" "$ROOT/bin/fm-decide.sh" guard-line) > "$1/home/.claude/settings.local.json"
}

test_record_with_story_posts_then_stamps() {
  local dir out
  dir=$(make_case story)
  install_guard "$dir"
  out=$(decide "$dir" record dd-1 "Ship option B." --story sc-6523) || fail "record failed: $out"
  assert_grep 'POST https://api.app.shortcut.com/api/v3/stories/6523/comments' "$dir/curl.log" "the decision was not commented on the story"
  assert_grep 'Captain decision [dd-1]: Ship option B.' "$dir/curl.log" "the comment text is missing the key and words"
  assert_no_grep 'POST https://api.app.shortcut.com/api/v3/stories ' "$dir/curl.log" "a story was created although --story was given"
  assert_no_grep 'PUT ' "$dir/curl.log" "a named story was edited"
  assert_equals "- [dd-1] 2026-10-09 Ship option B. (shortcut: sc-6523 https://app.shortcut.com/applypass/story/6523)" \
    "$(cat "$dir/home/data/decided.md")" "the entry is not in the decided.md format with a stamp"
  assert_not_contains "$out" "warning" "a home with the guard installed still warned"
  pass "record posts to the named story, then appends a stamped entry without touching the story"
}

test_post_failure_records_nothing() {
  local dir out
  dir=$(make_case postfail)
  mkdir -p "$dir/failbin"
  cat > "$dir/failbin/curl" <<'SH'
#!/usr/bin/env bash
out=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = -o ] && out=${args[$((i + 1))]}; done
cat >/dev/null
printf '{}' > "$out"
printf 500
SH
  chmod +x "$dir/failbin/curl"
  out=$( (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    SHORTCUT_API_TOKEN="$TOKEN" PATH="$dir/failbin:$PATH" "$ROOT/bin/fm-decide.sh" record dd-2 "Words." --story sc-6523 2>&1)) \
    && fail "record succeeded although the post failed: $out"
  assert_contains "$out" "nothing was recorded" "the refusal does not say nothing was recorded"
  assert_absent "$dir/home/data/decided.md" "a failed post left an entry behind"
  pass "a failed post stops and records nothing"
}

test_no_story_files_a_chore_then_posts() {
  local dir out
  dir=$(make_case chore)
  out=$(decide "$dir" record dd-3 "Operational call: rotate the key.") || fail "record failed: $out"
  assert_grep 'POST https://api.app.shortcut.com/api/v3/stories' "$dir/curl.log" "no chore story was filed"
  assert_grep '"story_type":"chore"' "$dir/curl.log" "the story is not a chore"
  assert_grep '"group_id":"649562cb-7f18-471f-835f-7ed28a5abf0a"' "$dir/curl.log" "the chore is not on the Engineering team"
  assert_grep '"workflow_state_id":500000006' "$dir/curl.log" "the chore is not in Backlog"
  assert_grep 'POST https://api.app.shortcut.com/api/v3/stories/7777/comments' "$dir/curl.log" "the decision was not posted on the new chore"
  assert_grep '(shortcut: sc-7777 https://app.shortcut.com/applypass/story/7777)' "$dir/home/data/decided.md" "the entry is not stamped with the chore"
  pass "a decision with no story files an Engineering/Backlog chore and posts there"
}

test_same_decision_twice_is_a_noop_and_changed_text_refuses() {
  local dir out
  dir=$(make_case idem)
  decide "$dir" record dd-4 "Same." --story sc-6523 >/dev/null || fail "first record failed"
  : > "$dir/curl.log"
  out=$(decide "$dir" record dd-4 "Same." --story sc-6523) || fail "replay failed: $out"
  [ ! -s "$dir/curl.log" ] || fail "a replay called Shortcut again"
  assert_equals 1 "$(grep -c '^- \[dd-4\]' "$dir/home/data/decided.md")" "a replay appended a second entry"
  out=$(decide "$dir" record dd-4 "Different." --story sc-6523) && fail "a changed decision under the same key was accepted"
  assert_contains "$out" "different text" "the refusal does not name the changed text"
  out=$(decide "$dir" record dd-4 "Sam" --story sc-6523) && fail "a prefix of the recorded text counted as the same decision"
  assert_contains "$out" "different text" "a prefix of the recorded text was not refused"
  decide "$dir" record dd-4b "Ship option B." --story sc-6523 >/dev/null || fail "record dd-4b failed"
  : > "$dir/curl.log"
  out=$(decide "$dir" record dd-4b "option B." --story sc-6523) && fail "a suffix of the recorded text counted as the same decision"
  assert_contains "$out" "different text" "a suffix of the recorded text was not refused"
  assert_equals 1 "$(grep -c '^- \[dd-4b\]' "$dir/home/data/decided.md")" "a suffix of the recorded text appended an entry"
  pass "replaying a key is a no-op and a changed text under it is refused"
}

test_audit_lists_unstamped_entries() {
  local dir out
  dir=$(make_case audit)
  printf '%s\n' '- [old-1] 2026-10-01 No story here.' > "$dir/home/data/decided.md"
  decide "$dir" record dd-5 "Stamped." --story sc-6523 >/dev/null || fail "record failed"
  out=$(decide "$dir" audit) && fail "audit exited 0 with an unstamped entry"
  assert_contains "$out" "old-1" "audit missed the unstamped entry"
  assert_not_contains "$out" "dd-5" "audit listed a stamped entry"
  printf '%s\n' "$(grep -v old-1 "$dir/home/data/decided.md")" > "$dir/home/data/decided.md"
  decide "$dir" audit >/dev/null || fail "audit failed on a fully stamped file"
  pass "audit lists entries with no story stamp"
}

test_missing_guard_warns_with_the_line_to_add() {
  local dir out
  dir=$(make_case noguard)
  out=$(decide "$dir" record dd-6 "Words." --story sc-6523) || fail "record failed: $out"
  assert_contains "$out" "settings.local.json" "no warning named the home's untracked settings file"
  assert_contains "$out" "fm-decide.sh' guard-hook" "the warning does not print the hook line"
  pass "a missing guard warns with the line to add"
}

test_guard_hook_blocks_direct_writes() {
  local dir
  dir=$(make_case guard)
  guard() { printf '%s' "$1" | "$ROOT/bin/fm-decide.sh" guard-hook 2>/dev/null; }
  guard '{"tool_name":"Write","tool_input":{"file_path":"/h/data/decided.md"}}' && fail "a Write to decided.md was allowed"
  guard '{"tool_name":"Edit","tool_input":{"file_path":"/h/data/decided.md"}}' && fail "an Edit of decided.md was allowed"
  guard '{"tool_name":"Bash","tool_input":{"command":"echo x >> data/decided.md"}}' && fail "a shell append to decided.md was allowed"
  guard '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ data/decided.md"}}' && fail "sed -i on decided.md was allowed"
  guard '{"tool_name":"Write","tool_input":{"file_path":"/h/data/other.md"}}' >/dev/null || fail "an unrelated write was blocked"
  guard '{"tool_name":"Bash","tool_input":{"command":"cat data/decided.md"}}' >/dev/null || fail "reading decided.md was blocked"
  guard '{"tool_name":"Bash","tool_input":{"command":"bin/fm-decide.sh record k t >> /dev/null; grep k data/decided.md"}}' >/dev/null || fail "the sanctioned writer was blocked"
  guard '{"tool_name":"Bash","tool_input":{"command":"cat a > ./data/decided.md"}}' && fail "a shell overwrite of decided.md was allowed"
  guard '{"tool_name":"Bash","tool_input":{"command":"sed -i.bak s/a/b/ data/decided.md"}}' && fail "sed -i.bak on decided.md was allowed"
  guard '{"tool_name":"Bash","tool_input":{"command":"rm data/decided.md"}}' && fail "rm of decided.md was allowed"
  guard '{"tool_name":"Bash","tool_input":{"command":"git log --format=%h -- data/decided.md"}}' >/dev/null || fail "git log --format on decided.md was blocked"
  guard '{"tool_name":"Bash","tool_input":{"command":"grep -c x 2>/dev/null data/decided.md"}}' >/dev/null || fail "a read with a stderr redirect was blocked"
  guard '{"tool_name":"Bash","tool_input":{"command":"bin/fm-decide.sh audit; echo x >> data/decided.md"}}' && fail "an append chained after fm-decide.sh was allowed"
  guard '{"tool_name":"Bash","tool_input":{"command":"cat bin/fm-decide.sh && sed -i s/a/b/ data/decided.md"}}' && fail "sed -i chained after a mention of fm-decide.sh was allowed"
  guard '{"tool_name":"Bash","tool_input":{"command":"bin/fm-decide.sh audit > data/decided.md"}}' && fail "a redirect of fm-decide.sh output into decided.md was allowed"
  guard '{"tool_name":"Bash","tool_input":{"command":"bin/fm-decide.sh audit > \"data/decided.md\""}}' && fail "a double-quoted redirect target of fm-decide.sh output was allowed"
  guard '{"tool_name":"Bash","tool_input":{"command":"bin/fm-decide.sh audit >> '"'"'data/decided.md'"'"'"}}' && fail "a single-quoted redirect target of fm-decide.sh output was allowed"
  guard '{"tool_name":"Bash","tool_input":{"command":"FM_HOME=/h bin/fm-decide.sh record k \"never rm data/decided.md; use > decided.md\""}}' >/dev/null \
    || fail "a record whose text mentions writes to decided.md was blocked"
  jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("fm-decide.sh")' <<<"$("$ROOT/bin/fm-decide.sh" guard-line)" >/dev/null \
    || fail "guard-line does not print a PreToolUse hook for fm-decide.sh"
  pass "the guard blocks direct writes to decided.md and allows reads and the sanctioned writer"
}

test_record_waits_for_a_slow_concurrent_record() {
  local dir out
  dir=$(make_case lockwait)
  mkdir "$dir/home/data/.decided.lock"
  (sleep 6; rmdir "$dir/home/data/.decided.lock") &
  out=$(decide "$dir" record dd-9 "Wait your turn." --story sc-6523) || fail "record gave up on a lock held for 6s: $out"
  wait
  assert_grep '- [dd-9] 2026-10-09 Wait your turn. (shortcut: sc-6523 ' "$dir/home/data/decided.md" "the waiting record was not written"
  pass "record waits out a concurrent record that holds the lock across slow Shortcut calls"
}

test_captain_hold_answer_calls_fm_decide() {
  local dir out
  dir=$(make_case hold)
  install_guard "$dir"
  (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" SHORTCUT_API_TOKEN="$TOKEN" \
    FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-tasks-axi.sh" add dh-1 "Pick one" --kind captain >/dev/null 2>&1) \
    || fail "setup add failed"
  printf 'Go with B.\n' > "$dir/decision.txt"
  hold() {
    (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" FM_DECIDE_DATE=2026-10-09 \
      SHORTCUT_API_TOKEN="$TOKEN" FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$PATH" \
      "$ROOT/bin/fm-captain-hold.sh" "$@" 2>&1)
  }
  out=$(hold hold dh-1 --reason "captain must choose") || fail "hold failed: $out"
  out=$(hold answer dh-1 --decision-file "$dir/decision.txt") || fail "answer failed: $out"
  assert_grep '- [dh-1-1] 2026-10-09 Go with B.' "$dir/home/data/decided.md" "answer did not record the decision through fm-decide"
  assert_grep 'POST https://api.app.shortcut.com/api/v3/stories' "$dir/curl.log" "a decision-only item got no story"
  : > "$dir/curl.log"
  out=$(hold answer dh-1 --decision-file "$dir/decision.txt") || fail "answer replay failed: $out"
  [ ! -s "$dir/curl.log" ] || fail "an answer replay called Shortcut again"
  assert_equals 1 "$(grep -c '^- \[dh-1-' "$dir/home/data/decided.md")" "an answer replay appended a second entry"
  pass "the captain-hold answer hook records through fm-decide and files a chore for a decision-only item"
}

test_captain_hold_reanswer_records_each_occurrence() {
  local dir out
  dir=$(make_case rehold)
  install_guard "$dir"
  (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" SHORTCUT_API_TOKEN="$TOKEN" \
    FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-tasks-axi.sh" add rh-1 "Pick one" --kind captain >/dev/null 2>&1) \
    || fail "setup add failed"
  printf 'Use A.\n' > "$dir/a.txt"
  printf 'Use B.\n' > "$dir/b.txt"
  hold() {
    (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" FM_DECIDE_DATE=2026-10-09 \
      SHORTCUT_API_TOKEN="$TOKEN" FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$PATH" \
      "$ROOT/bin/fm-captain-hold.sh" "$@" 2>&1)
  }
  out=$(hold hold rh-1 --reason "captain must choose") || fail "hold failed: $out"
  out=$(hold answer rh-1 --decision-file "$dir/a.txt" --release) || fail "first answer failed: $out"
  out=$(hold hold rh-1 --reason "captain must choose again") || fail "second hold failed: $out"
  : > "$dir/curl.log"
  out=$(hold answer rh-1 --decision-file "$dir/b.txt") || fail "second answer failed: $out"
  assert_not_contains "$out" "warning: a decision" "the second answer was refused as a key collision"
  assert_grep '- [rh-1-1] 2026-10-09 Use A.' "$dir/home/data/decided.md" "the first answer was not recorded"
  assert_grep '- [rh-1-2] 2026-10-09 Use B.' "$dir/home/data/decided.md" "the second answer was not recorded under its own key"
  assert_grep 'Captain decision [rh-1-2]: Use B.' "$dir/curl.log" "the second answer was not posted to Shortcut"
  pass "each answer to a task held more than once is recorded and posted under its own key"
}

test_record_with_story_posts_then_stamps
test_post_failure_records_nothing
test_no_story_files_a_chore_then_posts
test_same_decision_twice_is_a_noop_and_changed_text_refuses
test_audit_lists_unstamped_entries
test_missing_guard_warns_with_the_line_to_add
test_guard_hook_blocks_direct_writes
test_record_waits_for_a_slow_concurrent_record
test_captain_hold_answer_calls_fm_decide
test_captain_hold_reanswer_records_each_occurrence
