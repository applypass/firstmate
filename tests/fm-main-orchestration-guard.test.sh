#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for the main orchestration guard (bin/fm-main-orchestration-guard.sh).
#
# The guard is default deny: only the allowlist runs, everything else is refused
# and logged. It is driven with real PreToolUse payloads and real transcript
# files; no harness runs. The two 9 Nov cases (a grep over a labelling-page HTML
# file, a read of a quota script under bin/) are replayed as fixtures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-main-orch)
G="$ROOT/bin/fm-main-orchestration-guard.sh"
RF="$ROOT/bin/fm-reply-first.sh"

# make_home <name> <main|mate>
make_home() {
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state" "$H/config" "$H/data/label-audit" "$H/bin"
  if [ "$2" = mate ]; then
    printf 'mate-a\n' > "$H/.fm-secondmate-home"
  fi
  : > "$H/AGENTS.md"
  git -C "$H" init -q
  printf '<html>labelling page</html>\n' > "$H/data/label-audit/labelling-page.html"
  printf 'backlog\n' > "$H/data/backlog.md"
  TRANSCRIPT="$H/transcript.jsonl"
  : > "$TRANSCRIPT"
}

# gcall <tool> <input json>: one PreToolUse; exit code in RC, stderr in ERR.
gcall() {
  ERR=$(jq -cn --arg n "$1" --argjson i "$2" --arg t "$TRANSCRIPT" --arg c "$H" --arg s "${SESSION:-sess-1}" '{tool_name:$n,tool_input:$i,transcript_path:$t,cwd:$c,session_id:$s}' \
    | FM_HOME="$H" "$G" --claude 2>&1 >/dev/null)
  RC=$?
}
bash_call() { gcall Bash "$(jq -cn --arg c "$1" '{command:$c}')"; }

prompt() {  # <text>: a message the captain typed (the main prompt hook opens the window)
  jq -cn --arg p "$1" --arg t "$TRANSCRIPT" '{hook_event_name:"UserPromptSubmit",prompt:$p,transcript_path:$t}' \
    | FM_HOME="$H" "$RF" prompt --claude
}
midturn() {  # <text>: a message the captain sent inside a running turn
  jq -cn --arg p "$1" '{type:"attachment",attachment:{type:"queued_command",prompt:$p,origin:{kind:"human"},humanTurn:true,commandMode:"prompt"}}' >> "$TRANSCRIPT"
}
enc_home() { printf '%s' "$H" | sed 's/[^A-Za-z0-9]/-/g'; }
log_text() { cat "$H/state/main-orchestration-refusals.log" 2>/dev/null || true; }

test_9_nov_labelling_page_grep_is_refused() {
  make_home nov9a main
  prompt 'is the labelling page showing the new column?'
  bash_call 'bin/fm-crew-state.sh label-audit'; expect_code 0 "$RC" "call 1 (crew state)"
  bash_call 'cat data/backlog.md'; expect_code 0 "$RC" "call 2 (backlog)"
  bash_call 'bin/fm-wake-drain.sh'; expect_code 0 "$RC" "call 3 (wake drain)"
  bash_call 'grep -n "label" data/label-audit/labelling-page.html'; expect_code 2 "$RC" "call 4 (HTML grep) is refused"
  assert_contains "$ERR" '"permissionDecision":"deny"' "deny object"
  assert_contains "$ERR" "fm-send" "reason names fm-send"
  assert_contains "$ERR" "tell the captain who has it" "reason says tell the captain"
  assert_contains "$(log_text)" "group=artifact-read" "the refusal is logged with its group"
  bash_call 'grep -n "label" data/label-audit/labelling-page.html'; expect_code 2 "$RC" "digging is refused every time, not once"
  pass "9 Nov: the labelling-page HTML grep is refused (4th call) and logged"
}

test_9_nov_quota_script_read_is_refused() {
  make_home nov9b main
  prompt 'why did the quota stop fire?'
  bash_call 'sed -n 1,120p bin/fm-daily-quota-stop.sh'; expect_code 2 "$RC" "the first call, a read of a quota script, is refused"
  assert_contains "$(log_text)" "group=script-read" "logged as a script read"
  gcall Read '{"file_path":"'"$H"'/bin/fm-daily-quota-stop.sh"}'; expect_code 2 "$RC" "the Read tool on the same script is refused"
  pass "9 Nov: a read of the quota script under bin/ is refused"
}

test_orchestration_is_never_refused() {
  make_home orch main
  prompt 'what is going on?'
  local c
  while IFS= read -r c; do
    bash_call "$c"; expect_code 0 "$RC" "allowed: $c"
  done <<'EOF2'
bin/fm-wake-drain.sh
"$FM_HOME/bin/fm-send.sh" task-a "go on"
timeout 30 bin/fm-spawn.sh ship foo
FM_HOME=/x bin/fm-tasks-axi.sh list --state in_flight
bin/fm-crew-state.sh a | head -20
bin/fm-captain-hold.sh hold x --reason "waiting"
bin/fm-pr-merge.sh https://github.com/o/r/pull/3
bin/fm-peek.sh task-a
bin/fm-control.sh task-a interrupt
bin/fm-decide.sh record k "text"
(cd "$FM_HOME" && bin/fm-send.sh a "b c") 2>&1
for t in a b; do bin/fm-crew-state.sh $t; done
x=$(bin/fm-crew-state.sh a); echo "$x" > state/note.txt
cat data/backlog.md | grep -n back | head -3
ls data/label-audit
tail -n 5 state/a.status
jq -r .x data/a.json
echo hi >> data/notes.md
tasks-axi list
bin/fm-merge-local.sh task-a
bin/fm-capacity.sh
EOF2
  gcall Skill '{"skill":"stow"}'; expect_code 0 "$RC" "Skill"
  gcall Read '{"file_path":"'"$H"'/data/backlog.md"}'; expect_code 0 "$RC" "Read of a fleet record"
  gcall Read '{"file_path":"/tmp/worker/frame-3.png"}'; expect_code 0 "$RC" "Read of a PNG frame"
  gcall Read '{"file_path":"/tmp/worker/check.mp4"}'; expect_code 0 "$RC" "Read of an MP4"
  gcall Write '{"file_path":"'"$H"'/data/notes.md","content":"x"}'; expect_code 0 "$RC" "Write to a fleet record"
  gcall Edit '{"file_path":"/Users/x/.claude-work/projects/'"$(enc_home)"'/memory/a.md","old_string":"a","new_string":"b"}'; expect_code 0 "$RC" "Edit of the main home's memory dir"
  [ ! -s "$H/state/main-orchestration-refusals.log" ] || fail "an allowed call was logged"
  pass "orchestration scripts, fleet records, the memory dir, and worker frames are never refused"
}

test_allowlist_is_narrow_and_documented() {
  make_home narrow main
  local c
  for c in 'bin/fm-branch-report.sh x' 'bin/fm-task-ledger.sh list' 'bin/fm-lint.sh' 'bin/fm-fork-footprint.sh' 'bin/fm-doc-audience-check.sh'; do
    bash_call "$c"; expect_code 2 "$RC" "refused: $c"
  done
  gcall Read '{"file_path":"/tmp/worker/frame.jpg"}'; expect_code 2 "$RC" "only .png and .mp4 media are read"
  gcall Read '{"file_path":"/tmp/worker/frame.webp"}'; expect_code 2 "$RC" "webp is not allowed"
  gcall Read '{"file_path":"/Users/x/.claude-work/projects/-some-other-project/memory/a.md"}'; expect_code 2 "$RC" "another project's memory dir is refused"
  gcall Edit '{"file_path":"/Users/x/.claude-work/projects/-some-other-project/memory/a.md","old_string":"a","new_string":"b"}'; expect_code 2 "$RC" "editing another project's memory dir is refused"
  gcall Read '{"file_path":"/Users/x/.claude-work/projects/'"$(enc_home)"'/memory/MEMORY.md"}'; expect_code 0 "$RC" "the main home's memory dir is read"
  SESSION=abc-123
  gcall Read '{"file_path":"/private/tmp/claude-501/-proj/abc-123/tasks/b1.output"}'; expect_code 0 "$RC" "this session's task output is read"
  gcall Read '{"file_path":"/Users/x/.claude-work/projects/-proj/abc-123/tool-results/t.txt"}'; expect_code 0 "$RC" "this session's tool result is read"
  gcall Read '{"file_path":"/private/tmp/claude-501/-proj/zzz-999/tasks/b1.output"}'; expect_code 2 "$RC" "another session's task output is refused"
  gcall Read '{"file_path":"/Users/x/.claude-work/projects/-proj/zzz-999/tool-results/t.txt"}'; expect_code 2 "$RC" "another session's tool result is refused"
  bash_call 'cat /private/tmp/claude-501/-proj/abc-123/tasks/b1.output'; expect_code 0 "$RC" "cat of this session's output"
  bash_call 'cat /private/tmp/claude-501/-proj/zzz-999/tasks/b1.output'; expect_code 2 "$RC" "cat of another session's output is refused"
  SESSION=
  # The header names a reason for every allowlisted script, and only those.
  local listed header
  listed=$(P="$ROOT/bin/fm-main-orchestration-policy.mjs" node --input-type=module -e 'const m = await import(process.env.P); console.log([...m.ALLOWED_SCRIPTS].sort().join("\n"))' < /dev/null)
  header=$(grep -E '^#       fm-[a-z-]+\.sh - ' "$G" | sed -E 's/^#       (fm-[a-z-]+\.sh) - .*/\1/' | sort -u)
  local n
  for n in $header; do
    printf '%s\n' "$listed" | grep -qx "$n" || fail "header names $n but the policy does not allow it"
  done
  [ "$(printf '%s\n' "$header" | wc -l | tr -d ' ')" = "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] || fail "the header and the policy list different numbers of scripts"
  pass "the allowlist is narrow, every script has a header reason, and media, memory, and harness output are scoped"
}

test_artifact_html_is_refused_on_every_path() {
  make_home htmlpaths main
  gcall Grep '{"pattern":"label","path":"'"$H"'/data/label-audit"}'; expect_code 2 "$RC" "the labelling-page case through the Grep tool (a directory under data/) is refused"
  assert_contains "$(log_text)" "group=artifact-read" "logged as an artifact read"
  gcall Grep '{"pattern":"label","path":"'"$H"'/data/label-audit/labelling-page.html"}'; expect_code 2 "$RC" "Grep on the HTML file is refused"
  gcall Grep '{"pattern":"label","path":"'"$H"'/data/label-audit","glob":"*.md"}'; expect_code 0 "$RC" "Grep with a glob that excludes html is allowed"
  gcall Grep '{"pattern":"label","path":"'"$H"'/data/label-audit","glob":"*.{md,html}"}'; expect_code 2 "$RC" "a brace glob that includes html is refused"
  gcall Grep '{"pattern":"label","path":"'"$H"'/data/label-audit","type":"md"}'; expect_code 0 "$RC" "a non-html type is allowed"
  gcall Grep '{"pattern":"label","path":"'"$H"'/data/label-audit","type":"html"}'; expect_code 2 "$RC" "the html type is refused"
  gcall Grep '{"pattern":"x","path":"'"$H"'/state"}'; expect_code 0 "$RC" "Grep over state/ is allowed"
  gcall Glob '{"pattern":"**/*.html","path":"'"$H"'/data"}'; expect_code 2 "$RC" "Glob for html under data/ is refused"
  gcall Glob '{"pattern":"**/*.md","path":"'"$H"'/data"}'; expect_code 0 "$RC" "Glob for md files is allowed"
  gcall Write '{"file_path":"'"$H"'/data/label-audit/page.html","content":"<html></html>"}'; expect_code 2 "$RC" "Write of data/**/*.html is refused"
  gcall Edit '{"file_path":"'"$H"'/data/label-audit/labelling-page.html","old_string":"a","new_string":"b"}'; expect_code 2 "$RC" "Edit of data/**/*.html is refused"
  bash_call 'grep -rn label data/label-audit'; expect_code 2 "$RC" "a recursive grep over the directory is refused"
  bash_call 'rg label data/label-audit'; expect_code 2 "$RC" "rg over the directory is refused"
  bash_call 'grep -rn --include=*.md label data/label-audit'; expect_code 0 "$RC" "a recursive grep limited to md files is allowed"
  bash_call 'rg -g "!*.html" label data/label-audit'; expect_code 0 "$RC" "rg that excludes html is allowed"
  bash_call 'grep -n backlog data/backlog.md'; expect_code 0 "$RC" "a plain fleet record is still read"
  pass "artifact HTML under data/ is refused through Read, Bash readers, Grep, Glob, Edit, and Write"
}

test_default_deny_refuses_and_logs_unknown_work() {
  make_home deny main
  local c group
  while IFS='|' read -r group c; do
    bash_call "$c"; expect_code 2 "$RC" "refused: $c"
    assert_contains "$(log_text)" "group=$group" "logged group $group for: $c"
  done <<'EOF2'
run-script|python3 scripts/x.py
poll-loop|sleep 20
project-read|git status
project-read|git -C projects/app log
prod-db|psql-17 -c "select 1"
prod-ops|doctl apps list
outside-records|cat /etc/hosts
project-edit|echo x > /tmp/out.txt
project-edit|rm -rf projects/app/dist
other|some-new-tool --flag
other-script|bin/fm-new-unlisted-thing.sh
run-script|bin/fm-test-run.sh
run-script|bash -c 'python3 x.py'
poll-loop|until [ -f state/x ]; do sleep 2; done
other|eval "$CMD"
other|cat data/a | $FILTER
EOF2
  gcall Agent '{"prompt":"look into it"}'; expect_code 2 "$RC" "Agent refused"
  assert_contains "$(log_text)" "group=subagent" "subagent group"
  gcall mcp__SigNoz__signoz_search_logs '{"q":"x"}'; expect_code 2 "$RC" "an MCP tool for an outside system is refused"
  assert_contains "$(log_text)" "group=mcp" "mcp group"
  gcall mcp__shortcut__stories-get-by-id '{"id":1}'; expect_code 2 "$RC" "Shortcut reads are refused"
  gcall WebSearch '{"query":"x"}'; expect_code 2 "$RC" "WebSearch refused"
  gcall WebFetch '{"url":"https://x"}'; expect_code 2 "$RC" "WebFetch refused"
  gcall SomeNewTool '{}'; expect_code 2 "$RC" "an unknown tool is refused"
  gcall Edit '{"file_path":"'"$H"'/bin/fm-send.sh","old_string":"a","new_string":"b"}'; expect_code 2 "$RC" "Edit outside the records is refused"
  gcall Write '{"file_path":"'"$H"'/.claude/settings.local.json","content":"{}"}'; expect_code 2 "$RC" "a settings edit is refused"
  assert_contains "$(log_text)" "group=config-edit" "config edit group"
  gcall Read '{"file_path":"'"$H"'/projects/app/src/index.ts"}'; expect_code 2 "$RC" "a project read is refused"
  gcall Read '{"file_path":"'"$H"'/data/label-audit/labelling-page.html"}'; expect_code 2 "$RC" "an artifact HTML dump is refused even under data/"
  pass "every call off the allowlist is refused and logged with its group"
}

test_quick_lookups_are_limited_per_captain_message() {
  make_home quick main
  prompt 'what is the state of PR 77?'
  bash_call 'gh-axi pr view 77'; expect_code 0 "$RC" "quick lookup 1"
  bash_call 'gh pr view 78 --json state'; expect_code 0 "$RC" "quick lookup 2"
  bash_call 'gh-axi pr status'; expect_code 2 "$RC" "the third quick lookup is refused"
  assert_contains "$ERR" "quick lookups are used" "limit reason"
  assert_contains "$(log_text)" "group=quick-lookup-limit" "logged as the limit"
  bash_call 'gh-axi pr diff 77'; expect_code 2 "$RC" "a PR diff is not a quick lookup"
  gcall Artifact '{"action":"list","limit":5}'; expect_code 2 "$RC" "Artifact list is counted too"
  make_home quick2 main
  prompt 'status?'
  gcall Artifact '{"action":"list","limit":5}'; expect_code 0 "$RC" "Artifact list is a quick lookup"
  bash_call 'gh-axi pr view 1'; expect_code 0 "$RC" "second"
  gcall Artifact '{"action":"read","url":"https://x"}'; expect_code 2 "$RC" "Artifact read is digging"
  make_home quick3 main
  bash_call 'gh-axi pr view 1'; expect_code 0 "$RC" "no transcript turn to count from: allowed silently"
  pass "two quick lookups per captain message, the third is refused, other PR reads are refused"
}

test_captain_messages_reset_the_lookup_count() {
  make_home reset main
  prompt 'first question?'
  bash_call 'gh-axi pr view 1'; bash_call 'gh-axi pr view 2'
  bash_call 'gh-axi pr view 3'; expect_code 2 "$RC" "third refused"
  midturn 'and what about the other one?'
  bash_call 'gh-axi pr view 4'; expect_code 0 "$RC" "a mid-turn captain message resets the count (1)"
  bash_call 'gh-axi pr view 5'; expect_code 0 "$RC" "(2)"
  bash_call 'gh-axi pr view 6'; expect_code 2 "$RC" "third after the mid-turn message refused"
  prompt 'a typed follow-up'
  bash_call 'gh-axi pr view 7'; expect_code 0 "$RC" "a typed message resets the count too"
  midturn ': Firstmate instruction waiting: list the inbox'
  bash_call 'gh-axi pr view 8'; expect_code 0 "$RC" "(2)"
  bash_call 'gh-axi pr view 9'; expect_code 2 "$RC" "a doorbell does not reset the count"
  pass "a typed or mid-turn captain message resets the quick-lookup count; a doorbell does not"
}

turn_start() {  # <kind: wake|doorbell> : the start of a turn that has no captain message
  case "$1" in
    wake) jq -cn --arg u "$2" '{type:"user",uuid:$u,origin:{kind:"task-notification"},message:{role:"user",content:"<task-notification>done</task-notification>"}}' >> "$TRANSCRIPT" ;;
    doorbell) jq -cn --arg u "$2" '{type:"attachment",uuid:$u,attachment:{type:"queued_command",prompt:": Firstmate instruction waiting: list the inbox",origin:{kind:"human"},source_uuid:$u}}' >> "$TRANSCRIPT" ;;
  esac
}

test_a_turn_without_a_captain_message_gets_two_lookups() {
  make_home wake main
  turn_start wake u-wake-1
  bash_call 'gh-axi pr view 1'; expect_code 0 "$RC" "wake turn lookup 1"
  bash_call 'gh-axi pr view 2'; expect_code 0 "$RC" "wake turn lookup 2"
  bash_call 'gh-axi pr view 3'; expect_code 2 "$RC" "wake turn lookup 3 is refused"
  assert_contains "$ERR" "quick lookups are used" "limit reason"
  assert_contains "$(log_text)" "group=quick-lookup-limit" "logged as the limit"
  assert_contains "$(log_text)" "msg=u-wake-1" "the log names the turn's own message id"
  bash_call 'gh-axi pr status'; expect_code 2 "$RC" "still refused later in the same turn"
  turn_start wake u-wake-2
  bash_call 'gh-axi pr view 4'; expect_code 0 "$RC" "a new wake turn starts a fresh count"
  bash_call 'gh-axi pr view 5'; expect_code 0 "$RC" "(2)"
  bash_call 'gh-axi pr view 6'; expect_code 2 "$RC" "third in the new turn refused"
  turn_start doorbell u-bell-1
  bash_call 'gh-axi pr view 7'; expect_code 0 "$RC" "a doorbell starts a new turn too: count (1)"
  prompt 'a captain question'
  jq -cn '{type:"user",uuid:"u-typed-1",origin:{kind:"human"},message:{role:"user",content:"a captain question"}}' >> "$TRANSCRIPT"
  bash_call 'gh-axi pr view 8'; expect_code 0 "$RC" "a captain message resets to 2 (1)"
  bash_call 'gh-axi pr view 9'; expect_code 0 "$RC" "(2)"
  bash_call 'gh-axi pr view 10'; expect_code 2 "$RC" "third refused in the captain window"
  assert_contains "$(log_text)" "msg=u-typed-1" "a typed message logs the prompt entry's uuid"
  # The reply-first 3-call window stays captain-only: a wake turn opens none.
  make_home wake2 main
  turn_start wake u-wake-3
  [ ! -f "$H/state/.reply-first" ] || fail "a wake turn opened a reply-first window"
  pass "a turn without a captain message gets 2 quick lookups per turn; a new turn or a captain message resets it"
}

test_the_log_names_the_midturn_message_id() {
  make_home logid main
  prompt 'first question?'
  jq -cn '{type:"attachment",uuid:"att-uuid-9",attachment:{type:"queued_command",prompt:"and what about the other one?",origin:{kind:"human"},humanTurn:true,source_uuid:"src-uuid-7"}}' >> "$TRANSCRIPT"
  bash_call 'gh-axi pr view 1'; bash_call 'gh-axi pr view 2'
  bash_call 'gh-axi pr view 3'; expect_code 2 "$RC" "third refused"
  assert_contains "$(log_text)" "msg=src-uuid-7" "a mid-turn message logs the attachment's source_uuid"
  make_home logid2 main
  prompt 'second?'
  jq -cn '{type:"attachment",uuid:"att-uuid-10",attachment:{type:"queued_command",prompt:"one more thing",origin:{kind:"human"},humanTurn:true}}' >> "$TRANSCRIPT"
  bash_call 'python3 x.py'; expect_code 2 "$RC" "refused"
  assert_contains "$(log_text)" "msg=att-uuid-10" "without a source_uuid it logs the entry's uuid"
  make_home logid3 main
  jq -cn '{type:"user",uuid:"typed-uuid-3",origin:{kind:"human"},message:{role:"user",content:"dig into this"}}' >> "$TRANSCRIPT"
  prompt 'dig into this'
  bash_call 'python3 x.py'; expect_code 2 "$RC" "refused"
  assert_contains "$(log_text)" "msg=typed-uuid-3" "a typed message logs the prompt entry's uuid"
  make_home logid4 main
  prompt 'no transcript line for this'
  bash_call 'python3 x.py'; expect_code 2 "$RC" "refused"
  assert_contains "$(log_text)" "msg=- " "a message with no transcript entry logs -"
  pass "the refusal log holds the real message id from the transcript, and - only when none exists"
}

test_the_guard_cannot_switch_itself_off() {
  make_home selfoff main
  local c
  while IFS= read -r c; do
    bash_call "$c"; expect_code 2 "$RC" "refused: $c"
  done <<'EOF2'
echo off > config/main-orchestration-guard
echo off > config/reply-first
rm state/.reply-first
sed -i 's/override=0/override=1/' state/.reply-first
rm state/main-orchestration-refusals.log
tee state/.reply-first-wake < /dev/null
cp data/backlog.md state/.reply-first
EOF2
  gcall Write '{"file_path":"'"$H"'/config/reply-first","content":"off"}'; expect_code 2 "$RC" "Write of a guard switch is refused"
  gcall Edit '{"file_path":"'"$H"'/state/.reply-first","old_string":"a","new_string":"b"}'; expect_code 2 "$RC" "Edit of the window state is refused"
  bash_call 'cat state/.reply-first'; expect_code 0 "$RC" "the window state can be read"
  bash_call 'echo x > state/note.txt'; expect_code 0 "$RC" "other state files are still writable"
  bash_call 'echo x > config/other-setting'; expect_code 0 "$RC" "other config files are still writable"
  pass "the guard's own switches, window state, and refusal log are readable but never writable"
}

test_readers_that_run_or_write_are_refused() {
  make_home readers main
  local c
  while IFS= read -r c; do
    bash_call "$c"; expect_code 2 "$RC" "refused: $c"
  done <<'EOF2'
find state -maxdepth 0 -exec python3 /tmp/x.py \;
find state -name '*.status' -delete
find state -fprint /tmp/out
awk 'BEGIN{system("ls")}' state/x
awk '{print > "/tmp/o"}' state/x
awk '{print | "sh"}' state/x
sed -n '1e ls' state/x
sed 'w /tmp/o' state/x
sed -i s/a/b/ state/x
sort -o /tmp/out state/x
f=$(echo ../../x); cat state/$f
cat state/$UNKNOWN_VAR
EOF2
  while IFS= read -r c; do
    bash_call "$c"; expect_code 0 "$RC" "allowed: $c"
  done <<'EOF2'
find state -maxdepth 1 -name '*.status'
awk '{print $1}' state/x
sed -n '1,5p' state/x
sed 's/a/b/g' state/x
sort -o state/sorted state/x
for t in a b; do cat state/$t.status; done
m=task-a; tail -n 2 state/$m.status
EOF2
  pass "find actions, awk and sed programs that run or write, sort -o outside the records, and unknown variables in paths are refused"
}

test_a_compound_command_counts_each_lookup() {
  make_home count main
  prompt 'status of three PRs?'
  bash_call 'gh pr view 1; gh pr view 2; gh pr view 3'; expect_code 2 "$RC" "three lookups in one call are three lookups"
  make_home count2 main
  prompt 'status of two PRs?'
  bash_call 'gh pr view 1 && gh pr view 2'; expect_code 0 "$RC" "two lookups in one call are allowed"
  bash_call 'gh pr view 3'; expect_code 2 "$RC" "the next lookup is the third"
  pass "a compound command counts each quick lookup it holds"
}

test_the_override_and_count_work_with_reply_first_off() {
  make_home rfoff main
  printf 'off\n' > "$H/config/reply-first"
  prompt 'look yourself at the page'
  bash_call 'cat bin/fm-send.sh'; expect_code 0 "$RC" "the override works with config/reply-first off"
  prompt 'plain question'
  bash_call 'gh pr view 1'; bash_call 'gh pr view 2'
  bash_call 'gh pr view 3'; expect_code 2 "$RC" "lookups are counted with config/reply-first off"
  midturn 'another question'
  bash_call 'gh pr view 4'; expect_code 0 "$RC" "a mid-turn message resets the count with config/reply-first off"
  for i in 1 2 3 4 5; do bash_call 'echo hi'; done
  expect_code 0 "$RC" "the 3-call cap itself stays off"
  pass "reply-first off turns off its 3-call cap only; the guard's window, count, and override keep working"
}

test_replay_closes_the_window_at_a_non_captain_prompt() {
  make_home replay2 main
  local t="$TMP_ROOT/recorded2.jsonl" out
  {
    jq -cn '{type:"user",origin:{kind:"human"},message:{content:"look yourself: what is in the page?"},cwd:"'"$H"'"}'
    jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:"cat bin/fm-send.sh"}}]}}'
    jq -cn '{type:"user",origin:{kind:"task-notification"},message:{content:"<task-notification>x</task-notification>"}}'
    jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:"cat bin/fm-send.sh"}},{type:"tool_use",name:"Bash",input:{command:"gh-axi pr view 1"}},{type:"tool_use",name:"Bash",input:{command:"gh-axi pr view 2"}},{type:"tool_use",name:"Bash",input:{command:"gh-axi pr view 3"}}]}}'
  } > "$t"
  out=$(FM_MAIN_LOOKUP_LIMIT=2 node "$ROOT/bin/fm-main-orchestration-replay.mjs" --home "$H" --json "$t") || fail "the replay failed"
  [ "$(printf '%s' "$out" | jq -r .counts.overridden)" = 1 ] || fail "only the call inside the override window is lifted: $out"
  [ "$(printf '%s' "$out" | jq -r .counts.quick)" = 2 ] || fail "the wake turn gets its own 2 lookups: $out"
  [ "$(printf '%s' "$out" | jq -r '.blockedByGroup["quick-lookup-limit"].total')" = 1 ] || fail "the third wake-turn lookup is the one limit block: $out"
  [ "$(printf '%s' "$out" | jq -r '.blockedByGroup["script-read"].total')" = 1 ] || fail "the script read in the wake turn is refused: $out"
  pass "the replay closes the captain window at a wake prompt, counts the wake turn on its own, and reads FM_MAIN_LOOKUP_LIMIT"
}

test_override_lifts_the_check_for_one_message() {
  make_home over main
  prompt 'look yourself at the labelling page and tell me what it shows'
  bash_call 'grep -n label data/label-audit/labelling-page.html'; expect_code 0 "$RC" "digging allowed under the override"
  bash_call 'python3 scripts/x.py'; expect_code 0 "$RC" "anything is allowed under the override"
  bash_call 'gh-axi pr view 1'; bash_call 'gh-axi pr view 2'; bash_call 'gh-axi pr view 3'
  expect_code 0 "$RC" "no lookup limit under the override"
  midturn 'thanks, now what is the status of the other project?'
  bash_call 'sed -n 1,5p bin/fm-send.sh'; expect_code 2 "$RC" "the next captain message ends the override"
  midturn 'Check it yourself please'
  bash_call 'sed -n 1,5p bin/fm-send.sh'; expect_code 0 "$RC" "a mid-turn message can grant the override too"
  prompt 'ok next topic'
  bash_call 'sed -n 1,5p bin/fm-send.sh'; expect_code 2 "$RC" "a typed message without the phrase ends it"
  local phrase
  for phrase in 'look it up yourself' 'DIG IN YOURSELF' 'check yourself' 'dig yourself' 'look at it yourself'; do
    make_home "ph$((++PH))" main
    prompt "$phrase"
    bash_call 'cat bin/fm-send.sh'; expect_code 0 "$RC" "phrase: $phrase"
  done
  make_home near main
  prompt 'look at this yourselves later'
  bash_call 'cat bin/fm-send.sh'; expect_code 2 "$RC" "a near miss is not an override"
  pass "the override phrases lift the check for one message's window only"
}
PH=0

test_publishing_is_for_mate_produced_pages() {
  make_home pub main
  mkdir -p "$TMP_ROOT/mate-home/data/job-a"
  printf -- '- mate-a - (home: %s; scope: x; projects: y; added 2026-11-01)\n' "$TMP_ROOT/mate-home" > "$H/data/secondmates.md"
  gcall Artifact '{"file_path":"'"$TMP_ROOT"'/mate-home/data/job-a/page.html","label":"x"}'; expect_code 0 "$RC" "a page under a mate home data/ publishes"
  gcall Artifact '{"action":"publish","file_path":"'"$H"'/data/job-a/report.html"}'; expect_code 0 "$RC" "a worker report path publishes"
  gcall Artifact '{"action":"publish","file_path":"'"$H"'/data/notes.html"}'; expect_code 2 "$RC" "main's own page does not"
  assert_contains "$(log_text)" "group=artifact-publish" "publish group"
  gcall Artifact '{"action":"publish","file_path":"/tmp/random.html"}'; expect_code 2 "$RC" "a random file does not"
  pass "Artifact publish is allowed only for a mate-produced page or a worker report"
}

test_the_log_never_holds_secrets_or_contents() {
  make_home sec main
  bash_call 'curl -H "Authorization: Bearer abc123SECRET" https://api.example.com/x'
  expect_code 2 "$RC" "refused"
  bash_call 'PGPASSWORD=hunter2 psql-17 -h db -c "select secret_col from t"'
  expect_code 2 "$RC" "refused"
  bash_call 'cat > /tmp/x <<EOF
the body with TOKEN=abc999 inside
EOF'
  expect_code 2 "$RC" "refused"
  local text
  text=$(log_text)
  case "$text" in *abc123SECRET*|*hunter2*|*abc999*|*select\ secret_col*|*body\ with*) fail "the log holds a secret or content: $text" ;; esac
  assert_contains "$text" "tool=Bash" "the line names the tool"
  assert_contains "$text" "msg=" "the line names the captain message"
  pass "a refusal line holds the tool, group, message id, and a short summary, never quoted text or secrets"
}

test_inert_outside_the_primary_home() {
  make_home matehome mate
  prompt 'dig into the logs'
  bash_call 'cat bin/fm-send.sh'; expect_code 0 "$RC" "a second mate home is not guarded"
  [ ! -s "$H/state/main-orchestration-refusals.log" ] || fail "a mate home wrote a refusal"
  make_home wt main
  git -C "$H" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$H" worktree add -q "$TMP_ROOT/wt-linked" 2>/dev/null
  mkdir -p "$TMP_ROOT/wt-linked/state" "$TMP_ROOT/wt-linked/bin"; : > "$TMP_ROOT/wt-linked/AGENTS.md"
  H="$TMP_ROOT/wt-linked"
  bash_call 'cat bin/fm-send.sh'; expect_code 0 "$RC" "a linked task worktree is not guarded"
  FM_HOME="$H" "$G" enabled && fail "a worktree reports the guard enabled"
  make_home offhome main
  printf 'off\n' > "$H/config/main-orchestration-guard"
  bash_call 'cat bin/fm-send.sh'; expect_code 0 "$RC" "config/main-orchestration-guard off turns it off"
  make_home on main
  FM_HOME="$H" "$G" enabled || fail "the primary home is not on by default"
  pass "inert in a second mate home and a task worktree; off with config/main-orchestration-guard"
}

test_broken_input_allows_silently() {
  make_home broken main
  printf 'not json' | FM_HOME="$H" "$G" --claude; expect_code 0 $? "malformed payload allows"
  printf '' | FM_HOME="$H" "$G" --claude; expect_code 0 $? "empty payload allows"
  printf '{"tool_name":"Bash"}' | FM_HOME="$H" "$G" --claude; expect_code 0 $? "a Bash call with no command is allowed"
  printf '{"tool_input":{"command":"cat /etc/hosts"}}' | FM_HOME="$H" "$G" --claude; expect_code 0 $? "no tool name allows"
  bash_call 'cat <<EOF'; expect_code 2 "$RC" "an unparseable command is refused, not allowed"
  pass "an unreadable payload allows silently; an unparseable command is default deny"
}

test_installer_registers_the_guard_once_in_the_main_home() {
  make_home inst main
  "$ROOT/bin/fm-mate-hooks-install.sh" --main "$H" || fail "main install failed"
  "$ROOT/bin/fm-mate-hooks-install.sh" --main "$H" || fail "second main install failed"
  local f="$H/.claude/settings.local.json"
  [ "$(jq '[.hooks.PreToolUse[] | select(.matcher == ".*") | .hooks[] | select(.command | contains("fm-main-orchestration-guard.sh"))] | length' "$f")" = 1 ] || fail "the guard is not registered once"
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | contains("fm-reply-first.sh"))] | length' "$f")" = 1 ] || fail "reply-first pretool is not registered once"
  make_home inst2 mate
  "$ROOT/bin/fm-mate-hooks-install.sh" "$H" || fail "mate install failed"
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | contains("fm-main-orchestration-guard.sh"))] | length' "$H/.claude/settings.local.json")" = 0 ] || fail "a mate got the main guard"
  pass "the main installer registers the guard once; a mate home does not get it"
}

test_replay_counts_a_recorded_session() {
  make_home replay main
  local t="$TMP_ROOT/recorded.jsonl" out
  {
    jq -cn '{type:"user",origin:{kind:"human"},message:{content:"what is going on with the PRs?"},cwd:"'"$H"'"}'
    jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:"bin/fm-wake-drain.sh"}},{type:"tool_use",name:"Bash",input:{command:"gh-axi pr view 1"}},{type:"tool_use",name:"Bash",input:{command:"gh-axi pr view 2"}},{type:"tool_use",name:"Bash",input:{command:"gh-axi pr view 3"}},{type:"tool_use",name:"Bash",input:{command:"python3 x.py"}},{type:"tool_use",name:"mcp__krisp__search_meetings",input:{}}]}}'
    jq -cn '{type:"attachment",attachment:{type:"queued_command",prompt:": Firstmate instruction waiting: read the inbox",origin:{kind:"human"}}}'
    jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:"gh-axi pr view 4"}}]}}'
    jq -cn '{type:"attachment",attachment:{type:"queued_command",prompt:"look yourself at it",origin:{kind:"human"}}}'
    jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:"cat bin/fm-send.sh"}}]}}'
  } > "$t"
  out=$(node "$ROOT/bin/fm-main-orchestration-replay.mjs" --home "$H" --json "$t") || fail "the replay failed"
  [ "$(printf '%s' "$out" | jq -r .calls)" = 8 ] || fail "wrong call count: $out"
  [ "$(printf '%s' "$out" | jq -r .captainMessages)" = 2 ] || fail "the doorbell opened a window or a message was missed: $out"
  [ "$(printf '%s' "$out" | jq -r .counts.allow)" = 1 ] || fail "allowed count: $out"
  [ "$(printf '%s' "$out" | jq -r .counts.quick)" = 2 ] || fail "quick count: $out"
  [ "$(printf '%s' "$out" | jq -r .counts.deny)" = 4 ] || fail "blocked count: $out"
  [ "$(printf '%s' "$out" | jq -r .counts.overridden)" = 1 ] || fail "overridden count: $out"
  [ "$(printf '%s' "$out" | jq -r '.blockedByGroup["quick-lookup-limit"].total')" = 2 ] || fail "the lookups after the second (a doorbell inside a captain window does not reset the count) are not in the limit group: $out"
  pass "the replay rebuilds windows from a transcript and counts allowed, quick, blocked, and overridden calls"
}

test_scripts_are_lint_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  "$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-main-orchestration-guard.sh" "$ROOT/bin/fm-reply-first.sh" "$ROOT/bin/fm-mate-hooks-install.sh" >/dev/null 2>&1 || fail "a guard script is not lint-clean"
  pass "the guard scripts are clean under bin/fm-lint.sh"
}

test_9_nov_labelling_page_grep_is_refused
test_9_nov_quota_script_read_is_refused
test_orchestration_is_never_refused
test_allowlist_is_narrow_and_documented
test_artifact_html_is_refused_on_every_path
test_default_deny_refuses_and_logs_unknown_work
test_quick_lookups_are_limited_per_captain_message
test_captain_messages_reset_the_lookup_count
test_a_turn_without_a_captain_message_gets_two_lookups
test_the_log_names_the_midturn_message_id
test_the_guard_cannot_switch_itself_off
test_readers_that_run_or_write_are_refused
test_a_compound_command_counts_each_lookup
test_the_override_and_count_work_with_reply_first_off
test_replay_closes_the_window_at_a_non_captain_prompt
test_override_lifts_the_check_for_one_message
test_publishing_is_for_mate_produced_pages
test_the_log_never_holds_secrets_or_contents
test_inert_outside_the_primary_home
test_broken_input_allows_silently
test_installer_registers_the_guard_once_in_the_main_home
test_replay_counts_a_recorded_session
test_scripts_are_lint_clean
