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

| # | Task | Owner | Where |
|---|---|---|---|
| 1 | Release next iteration incl. upgrade card | release-eng | FE PR 444, BE PR 826 (captain merge + prod SQL) |
| 2 | Job card counts of notes/files/tasks | core-backend + web-frontend | BE 825 (dev), FE 445 |
| 3 | Notes/tasks fail on Job applied (403) | core-backend + web-frontend | BE 824 (dev), FE 446 |
| 4 | File names should wrap | web-frontend | in FE 444 (commit 9d90f4be) |
| 5 | Secondary language = dropdown | web-frontend | captain re-confirmed 3 Nov (sc-8740) |
| 6 | Recording stage: no default, required | interview-recordings | sc-9109 |
| 11 | Commit inactive-jobs script | apply-delivery | sc-9113, PR auto_applier_py 127 |
| 15 | Oracle classifier input fixed? | done | comment 3 Nov |
| - | Education reports, BambooHR applier | Tomasz | not ours |
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
  local wt="$TMP_ROOT/wt-main" ; mkdir -p "$wt/bin" "$wt/state"; : > "$wt/AGENTS.md"
  git -C "$wt" init -q >/dev/null 2>&1; git -C "$wt" commit -q --allow-empty -m i >/dev/null 2>&1
  git -C "$wt" worktree add -q "$TMP_ROOT/wt-child" -b child >/dev/null 2>&1 || true
  mkdir -p "$TMP_ROOT/wt-child/state"
  run_mark "$TMP_ROOT/wt-child" "$(payload mcp__krisp__get_multiple_documents "$(transcript_response)")"
  [ ! -e "$TMP_ROOT/wt-child/state/meeting-pending" ] || fail "child task worktree wrote a marker"
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
test_installer_is_idempotent
