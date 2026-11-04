#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for the meeting-to-ticket gate (bin/fm-meeting-ticket-gate.sh).
#
# Hermetic: a scratch primary home (plain git checkout) holds state/ and data/; payloads are
# written by hand, so no real Krisp, Granola, or agent session is involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-meeting-ticket-gate)
GATE="$ROOT/bin/fm-meeting-ticket-gate.sh"
fm_git_identity fmtest fmtest@example.invalid

MID=01a18b1ae757732f8c48b2ef9dfdbf54
DATE=2026-11-03

new_home() {  # <name> -> prints the home path
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/bin" "$h/state" "$h/data" "$h/config"
  : > "$h/AGENTS.md"
  git -C "$h" init -q >/dev/null 2>&1
  printf '%s\n' "$h"
}

write_sample() {  # <file>
  cat > "$1" <<EOF
# Engineering standup $DATE - every agreed task, mapped
Source: Krisp meeting $MID (action items + full transcript re-read).

| # | Task | Owner | Due | Where |
|---|---|---|---|---|
| 1 | Release next iteration incl. upgrade card | release-eng | 2026-11-05 | FE PR 444, BE PR 826 (captain merge + prod SQL) |
| 2 | Job card counts of notes/files/tasks | core-backend + web-frontend | 2026-11-05 | BE 825 (dev), FE 445 |
| 3 | Notes/tasks fail on Job applied (403) | core-backend + web-frontend | 2026-11-06 | BE 824 (dev), FE 446 |
| 4 | File names should wrap | web-frontend | 2026-11-05 | in FE 444 (commit 9d90f4be) |
| 5 | Secondary language = dropdown | web-frontend | 2026-11-07 | captain re-confirmed 3 Nov (sc-8740) |
| 6 | Recording stage: no default, required | interview-recordings | 2026-11-07 | sc-9109 |
| 11 | Commit inactive-jobs script | apply-delivery | no deadline - ask at standup | sc-9113, PR auto_applier_py 127 |
| 15 | Oracle classifier input fixed? | done | 2026-11-03 | comment 3 Nov |
| - | Education reports, BambooHR applier | Tomasz |  | not ours |
EOF
}

transcript_text() {
  local i out=''
  for i in 1 2 3 4 5 6 7 8; do out="$out"$'\n'"Speaker $i: this is a long enough spoken line about the release and the tickets we agreed on today."; done
  printf '%s' "$out"
}

# payload <tool> <response-json>  (tool_input carries the meeting id)
payload() {
  jq -cn --arg t "$1" --arg id "$MID" --argjson r "$2" \
    '{hook_event_name:"PostToolUse",tool_name:$t,tool_use_id:"toolu_1",tool_input:{document_ids:[$id]},tool_response:$r}'
}

transcript_response() {
  jq -cn --arg id "$MID" --arg tr "$(transcript_text)" \
    '[{type:"text",text:({documents:[{id:$id,date:"2026-11-03T09:30:00Z",title:"Standup",transcript:$tr}]}|tostring)}]'
}

listing_response() {
  jq -cn --arg id "$MID" '[{type:"text",text:({meetings:[{id:$id,date:"2026-11-03",title:"Standup"}]}|tostring)}]'
}

run_mark() {  # <home> <payload>
  printf '%s' "$2" | FM_HOME="$1" FM_ROOT_OVERRIDE="$1" "$GATE" mark
}

run_check() {  # <home>; sets CHECK_ERR, CHECK_RC
  CHECK_ERR=$(FM_HOME="$1" FM_ROOT_OVERRIDE="$1" "$GATE" check 2>&1 >/dev/null </dev/null)
  CHECK_RC=$?
}

marker_of() { printf '%s/state/meeting-pending/%s\n' "$1" "$MID"; }

test_listed_transcript_writes_marker() {
  local h; h=$(new_home mark)
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  [ -f "$(marker_of "$h")" ] || fail "no marker for a listed tool returning a transcript"
  assert_contains "$(cat "$(marker_of "$h")")" "id=$MID" "marker names the meeting id"
  assert_contains "$(cat "$(marker_of "$h")")" "date=$DATE" "marker names the meeting date"
  pass "listed tool with a transcript writes a marker (id and date)"
}

test_granola_style_names_match_list() {
  local h; h=$(new_home granola
  ); run_mark "$h" "$(payload mcp__claude_ai_Granola__get_meeting_transcript "$(transcript_response)")"
  [ -f "$(marker_of "$h")" ] || fail "Granola-style tool name was not matched by the list"
  pass "Granola tool names match through the configured list"
}

test_unlisted_tool_writes_nothing() {
  local h; h=$(new_home unlisted)
  run_mark "$h" "$(payload mcp__other__read_document "$(transcript_response)")"
  [ ! -e "$h/state/meeting-pending" ] || fail "unlisted tool wrote a marker"
  pass "a non-listed tool writes no marker"
}

test_custom_list_overrides_default() {
  local h; h=$(new_home custom)
  printf '# mine\nmcp__acme__read_*\n' > "$h/config/meeting-transcript-tools"
  run_mark "$h" "$(payload mcp__acme__read_call "$(transcript_response)")"
  [ -f "$(marker_of "$h")" ] || fail "custom glob entry did not fire"
  rm -rf "$h/state/meeting-pending"
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  [ ! -e "$h/state/meeting-pending" ] || fail "default list still applied over the config list"
  pass "config/meeting-transcript-tools replaces the tracked default"
}

test_listing_without_transcript_writes_nothing() {
  local h; h=$(new_home listing)
  run_mark "$h" "$(payload mcp__krisp__search_meeting_content "$(listing_response)")"
  [ ! -e "$h/state/meeting-pending" ] || fail "bare listing wrote a marker"
  pass "a listed tool with no transcript writes no marker"
}

test_noop_outside_primary_home() {
  local h; h=$(new_home sm)
  echo secondmate1 > "$h/.fm-secondmate-home"
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  [ ! -e "$h/state/meeting-pending" ] || fail "secondmate home wrote a marker"
  local wt="$TMP_ROOT/wt-main" child="$TMP_ROOT/wt-child"
  mkdir -p "$wt/bin" "$wt/state"; : > "$wt/AGENTS.md"; : > "$wt/bin/.keep"
  git -C "$wt" init -q || fail "git init failed"
  git -C "$wt" add AGENTS.md bin/.keep || fail "parent add failed"
  git -C "$wt" commit -q -m i || fail "parent commit failed"
  git -C "$wt" worktree add -q "$child" -b child || fail "git worktree add failed"
  [ -f "$child/AGENTS.md" ] || fail "child worktree lacks AGENTS.md"
  [ -d "$child/bin" ] || fail "child worktree lacks bin/"
  [ "$(git -C "$child" rev-parse --git-dir)" != "$(git -C "$child" rev-parse --git-common-dir)" ] || fail "child is not a linked worktree"
  mkdir -p "$wt/data" "$child/state"
  run_mark "$wt" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  [ -f "$wt/state/meeting-pending/$MID" ] || fail "parent home did not write a marker, so the child check proves nothing"
  run_mark "$child" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  [ ! -e "$child/state/meeting-pending" ] || fail "child task worktree wrote a marker"
  pass "no-op in a secondmate home and in a child task worktree"
}

test_sample_passes_and_clears_marker() {
  local h; h=$(new_home pass)
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  write_sample "$h/data/standup-$DATE.md"
  run_check "$h"
  expect_code 0 "$CHECK_RC" "sample file passes: $CHECK_ERR"
  [ ! -e "$(marker_of "$h")" ] || fail "marker not cleared after pass"
  pass "the 3 Nov sample passes and the marker clears"
}

test_id_pending_row_fails_naming_row() {
  local h; h=$(new_home pending)
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  write_sample "$h/data/standup-$DATE.md"
  sed -i.bak 's#| sc-9109 |#| id pending |#' "$h/data/standup-$DATE.md"
  run_check "$h"
  expect_code 2 "$CHECK_RC" "id pending row blocks"
  assert_contains "$CHECK_ERR" "row 6: Recording stage: no default, required" "names the failing row and task"
  assert_contains "$CHECK_ERR" "standup-$DATE.md" "names the file checked"
  case "$CHECK_ERR" in *"row 1:"*|*"row 15:"*) fail "passing rows listed as failing: $CHECK_ERR" ;; esac
  [ -f "$(marker_of "$h")" ] || fail "marker cleared despite failure"
  pass "an 'id pending' row blocks and the message names that row"
}

test_tbd_and_blank_rows_fail() {
  local h; h=$(new_home tbd)
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  write_sample "$h/data/standup-$DATE.md"
  sed -i.bak 's#| FE PR 444, BE PR 826 (captain merge + prod SQL) |#| TBD |#; s#| sc-9113, PR auto_applier_py 127 |#| |#' "$h/data/standup-$DATE.md"
  run_check "$h"
  expect_code 2 "$CHECK_RC" "TBD and blank rows block"
  assert_contains "$CHECK_ERR" "row 1:" "TBD row named"
  assert_contains "$CHECK_ERR" "row 11:" "blank row named"
  pass "TBD and empty rows fail"
}

test_missing_file_blocks() {
  local h; h=$(new_home missing)
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  run_check "$h"
  expect_code 2 "$CHECK_RC" "missing file blocks"
  assert_contains "$CHECK_ERR" "data/standup-$DATE.md" "names the expected file"
  assert_contains "$CHECK_ERR" "$MID" "names the meeting"
  pass "a missing mapping file blocks"
}

test_other_meeting_id_blocks() {
  local h; h=$(new_home otherid)
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  write_sample "$h/data/standup-$DATE.md"
  sed -i.bak "s#$MID#ffffffffffffffffffffffffffffffff#" "$h/data/standup-$DATE.md"
  run_check "$h"
  expect_code 2 "$CHECK_RC" "file naming a different meeting blocks"
  assert_contains "$CHECK_ERR" "does not name meeting id" "explains the id mismatch"
  pass "a file naming a different meeting id blocks"
}

test_file_without_rows_blocks() {
  local h; h=$(new_home norows)
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  printf 'Source: Krisp meeting %s\nno table here\n' "$MID" > "$h/data/standup-$DATE.md"
  run_check "$h"
  expect_code 2 "$CHECK_RC" "file with no task rows blocks"
  assert_contains "$CHECK_ERR" "no task rows" "explains the empty table"
  pass "a file with no task rows blocks"
}

test_meeting_named_file_passes() {
  local h; h=$(new_home meetingfile)
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  write_sample "$h/data/meeting-$DATE-$MID.md"
  run_check "$h"
  expect_code 0 "$CHECK_RC" "data/meeting-<date>-<id>.md passes: $CHECK_ERR"
  pass "data/meeting-<date>-<id>.md is accepted"
}

test_turnend_guard_blocks_then_allows() {
  local h out rc; h=$(new_home guard)
  mkdir -p "$h/bin"
  cp "$ROOT"/bin/*.sh "$ROOT"/bin/*.default "$h/bin/" 2>/dev/null
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  out=$(printf '{"session_id":"s1"}' | FM_HOME="$h" FM_ROOT_OVERRIDE="$h" "$h/bin/fm-turnend-guard.sh" --claude 2>&1 >/dev/null); rc=$?
  expect_code 2 "$rc" "guard blocks with a pending marker: $out"
  assert_contains "$out" "TICKETS NOT FILED" "guard prints the gate message"
  write_sample "$h/data/standup-$DATE.md"
  out=$(printf '{"session_id":"s1"}' | FM_HOME="$h" FM_ROOT_OVERRIDE="$h" "$h/bin/fm-turnend-guard.sh" --claude 2>&1 >/dev/null); rc=$?
  expect_code 0 "$rc" "guard allows once the file passes: $out"
  [ ! -e "$(marker_of "$h")" ] || fail "guard left the marker after a pass"
  pass "the turn-end guard blocks on a pending marker and allows after a pass"
}

test_multi_document_read_marks_every_meeting() {
  local h resp p; h=$(new_home multidoc)
  resp=$(jq -cn --arg tr "$(transcript_text)" \
    '[{type:"text",text:({documents:[{id:"aaa",date:"2026-11-03T09:30:00Z",transcript:$tr},{id:"bbb",date:"2026-11-02",transcript:$tr}]}|tostring)}]')
  p=$(jq -cn --argjson r "$resp" '{tool_name:"mcp__krisp__get_multiple_documents",tool_use_id:"toolu_2",tool_input:{document_ids:["aaa","bbb"]},tool_response:$r}')
  run_mark "$h" "$p"
  assert_contains "$(cat "$h/state/meeting-pending/aaa" 2>/dev/null)" "date=2026-11-03" "first meeting marked with its date"
  assert_contains "$(cat "$h/state/meeting-pending/bbb" 2>/dev/null)" "date=2026-11-02" "second meeting marked with its date"
  pass "a multi-document read marks every meeting with its own date"
}

test_idless_transcripts_mark_every_input_id() {
  local h resp p; h=$(new_home idless)
  resp=$(jq -cn --arg tr "$(transcript_text)" '[{type:"text",text:({documents:[{transcript:$tr},{transcript:$tr}]}|tostring)}]')
  p=$(jq -cn --argjson r "$resp" '{tool_name:"mcp__krisp__get_multiple_documents",tool_use_id:"toolu_3",tool_input:{document_ids:["aaa","bbb"],date:"2026-11-03"},tool_response:$r}')
  run_mark "$h" "$p"
  [ -f "$h/state/meeting-pending/aaa" ] || fail "input id aaa not marked"
  [ -f "$h/state/meeting-pending/bbb" ] || fail "input id bbb not marked"
  pass "transcripts with no ids mark every input id"
}

test_idless_transcript_without_input_id_marks_unknown() {
  local h p; h=$(new_home unknownid)
  p=$(jq -cn --arg tr "$(transcript_text)" '{tool_name:"mcp__granola__get_meeting_transcript",tool_use_id:"toolu_4",tool_input:{},tool_response:{transcript:$tr}}')
  run_mark "$h" "$p"
  local m; set -- "$h"/state/meeting-pending/unknown-*; m=$1
  [ -f "$m" ] || fail "no unknown-id marker for an id-less transcript"
  pass "an id-less transcript with no input id still writes a marker"
}

# row_check <home-name> <sed-expr> -> sets CHECK_RC/CHECK_ERR for the sample with row 6 rewritten
row_check() {
  local h; h=$(new_home "$1")
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  write_sample "$h/data/standup-$DATE.md"
  sed -i.bak "$2" "$h/data/standup-$DATE.md"
  run_check "$h"
}

test_negated_done_and_not_ours_fail() {
  row_check notdone 's#| Recording stage: no default, required | interview-recordings | 2026-11-07 | sc-9109 |#| Recording stage required | interview-recordings | 2026-11-07 | not done |#'
  expect_code 2 "$CHECK_RC" "'not done' row blocks"
  assert_contains "$CHECK_ERR" "row 6: Recording stage required" "names the 'not done' row"
  row_check maybenot 's#| interview-recordings | 2026-11-07 | sc-9109 |#| interview-recordings | 2026-11-07 | maybe not ours |#'
  expect_code 2 "$CHECK_RC" "'maybe not ours' row blocks"
  assert_contains "$CHECK_ERR" "row 6:" "names the 'maybe not ours' row"
  pass "'not done' and 'maybe not ours' are not evidence"
}

test_story_id_in_task_cell_only_fails() {
  row_check taskcell 's#| Recording stage: no default, required | interview-recordings | 2026-11-07 | sc-9109 |#| Recording stage (see sc-9109) | interview-recordings | 2026-11-07 | later |#'
  expect_code 2 "$CHECK_RC" "sc id only in the Task cell blocks"
  assert_contains "$CHECK_ERR" "row 6:" "names the row whose id sits in the Task cell"
  pass "evidence in the Task cell does not count"
}

test_short_pr_numbers_fail() {
  row_check be2 's#| interview-recordings | 2026-11-07 | sc-9109 |#| interview-recordings | 2026-11-07 | BE 2 |#'
  expect_code 2 "$CHECK_RC" "'BE 2' blocks"
  row_check fe1 's#| interview-recordings | 2026-11-07 | sc-9109 |#| interview-recordings | 2026-11-07 | FE 1 |#'
  expect_code 2 "$CHECK_RC" "'FE 1' blocks"
  row_check pr12 's#| interview-recordings | 2026-11-07 | sc-9109 |#| interview-recordings | 2026-11-07 | PR 12 |#'
  expect_code 2 "$CHECK_RC" "'PR 12' blocks"
  row_check be825 's#| interview-recordings | 2026-11-07 | sc-9109 |#| interview-recordings | 2026-11-07 | BE 825 |#'
  expect_code 0 "$CHECK_RC" "'BE 825' passes: $CHECK_ERR"
  row_check pullurl 's#| interview-recordings | 2026-11-07 | sc-9109 |#| interview-recordings | 2026-11-07 | github.com/o/r/pull/9 |#'
  expect_code 0 "$CHECK_RC" "a /pull/N url passes: $CHECK_ERR"
  pass "PR shorthand needs 3+ digits; a /pull/N url passes"
}

test_due_date_and_flag_pass() {
  row_check duedate 's#| 2026-11-07 | sc-9109 |#| 2026-12-01 | sc-9109 |#'
  expect_code 0 "$CHECK_RC" "a YYYY-MM-DD Due passes: $CHECK_ERR"
  row_check dueflag 's#| 2026-11-07 | sc-9109 |#|  No Deadline - Ask At Standup  | sc-9109 |#'
  expect_code 0 "$CHECK_RC" "the no-deadline flag passes (case and spaces tolerated): $CHECK_ERR"
  pass "a date and the no-deadline flag both pass"
}

test_empty_due_fails_naming_row() {
  row_check dueempty 's#| 2026-11-07 | sc-9109 |#|  | sc-9109 |#'
  expect_code 2 "$CHECK_RC" "empty Due blocks"
  assert_contains "$CHECK_ERR" "row 6: Recording stage: no default, required" "names the row with no due date"
  assert_contains "$CHECK_ERR" "YYYY-MM-DD" "names the date form"
  assert_contains "$CHECK_ERR" "no deadline - ask at standup" "names the flag form"
  case "$CHECK_ERR" in *"row 1:"*) fail "passing rows listed as failing: $CHECK_ERR" ;; esac
  pass "an empty Due cell blocks and names the row and both forms"
}

test_tbd_due_fails() {
  row_check duetbd 's#| 2026-11-07 | sc-9109 |#| TBD | sc-9109 |#'
  expect_code 2 "$CHECK_RC" "'TBD' Due blocks"
  assert_contains "$CHECK_ERR" "row 6:" "names the TBD-due row"
  row_check duestyle 's#| 2026-11-07 | sc-9109 |#| 7 Nov | sc-9109 |#'
  expect_code 2 "$CHECK_RC" "other date styles block"
  pass "'TBD' and other date styles fail"
}

test_missing_due_column_fails() {
  local h; h=$(new_home nodue)
  run_mark "$h" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  printf 'Source: Krisp meeting %s\n\n| # | Task | Owner | Where |\n|---|---|---|---|\n| 1 | Ship it | eng | sc-9109 |\n' "$MID" > "$h/data/standup-$DATE.md"
  run_check "$h"
  expect_code 2 "$CHECK_RC" "a table with no Due column blocks"
  assert_contains "$CHECK_ERR" "standup-$DATE.md" "names the file"
  assert_contains "$CHECK_ERR" "| # | Task | Owner | Due | Where |" "names the expected header"
  pass "a table with no Due column blocks and names the expected header"
}

test_not_ours_row_needs_no_due() {
  row_check dueours 's#| 2026-11-07 | sc-9109 |#|  | not ours |#'
  expect_code 0 "$CHECK_RC" "a 'not ours' row with no Due passes: $CHECK_ERR"
  pass "a 'not ours' row needs no due date"
}

test_installer_is_idempotent() {
  local d="$TMP_ROOT/inst" file
  mkdir -p "$d/.claude"
  printf '{"env":{"A":"1"}}\n' > "$d/.claude/settings.local.json"
  "$GATE" install "$d" || fail "install failed"
  "$GATE" install "$d" || fail "second install failed"
  file="$d/.claude/settings.local.json"
  jq -e '.env.A == "1" and (.hooks.PostToolUse | length == 1)' "$file" >/dev/null || fail "installer not idempotent or dropped settings"
  pass "installer registers one PostToolUse hook and keeps other settings"
}

test_listed_transcript_writes_marker
test_granola_style_names_match_list
test_unlisted_tool_writes_nothing
test_custom_list_overrides_default
test_listing_without_transcript_writes_nothing
test_noop_outside_primary_home
test_sample_passes_and_clears_marker
test_id_pending_row_fails_naming_row
test_tbd_and_blank_rows_fail
test_missing_file_blocks
test_other_meeting_id_blocks
test_file_without_rows_blocks
test_meeting_named_file_passes
test_turnend_guard_blocks_then_allows
test_multi_document_read_marks_every_meeting
test_idless_transcripts_mark_every_input_id
test_idless_transcript_without_input_id_marks_unknown
test_negated_done_and_not_ours_fail
test_story_id_in_task_cell_only_fails
test_short_pr_numbers_fail
test_due_date_and_flag_pass
test_empty_due_fails_naming_row
test_tbd_due_fails
test_missing_due_column_fails
test_not_ours_row_needs_no_due
test_installer_is_idempotent
