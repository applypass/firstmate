#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for the meeting to-do record parser (bin/fm-meeting-todos-lib.sh).
#
# Hermetic: every record file is written by hand into a scratch directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-meeting-todos-lib.sh
. "$ROOT/bin/fm-meeting-todos-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-meeting-todos-lib)
US=$'\x1f'

HEAD='| # | Task | Owner | Story | Scope | Deadline | Status | Quote |
|---|---|---|---|---|---|---|---|'

# record <file-name> <heading-suffix> <summary-lines> <rows>; prints the path
record() {
  local f="$TMP_ROOT/$1"
  mkdir -p "$(dirname "$f")"
  {
    printf '## Team standup - Krisp aa11bb22 https://app.krisp.example/m/aa11bb22%s\n' "$2"
    [ -z "$3" ] || printf '%s\n' "$3"
    printf '\n%s\n' "$HEAD"
    printf '%s\n' "$4"
  } > "$f"
  printf '%s\n' "$f"
}

ROW1='| 1 | Ship the widget fix | Alex | | today | 2026-11-05 | open | "we ship the widget fix tomorrow" @12:03 |'
ROW2='| 2 | Write the runbook [agentic] | Sam | sc-123 | week | 2026-11-06 | open | "runbook by Friday" @31:40 |'
SUMMARY='> Release scope agreed.
> Two follow-ups for the backend.'

expect_error() {  # <label> <file> <message-fragment>
  local out
  out=$(fm_mt_validate "$2" 2>&1) && fail "$1: a malformed record passed"
  case "$out" in *"$3"*) ;; *) fail "$1: error did not say '$3'; got: $out" ;; esac
}

test_valid_record_passes() {
  local f
  f=$(record 2026-11-04.md '' "$SUMMARY" "$ROW1
$ROW2")
  fm_mt_validate "$f" || fail "a valid record was refused: $(fm_mt_validate "$f" 2>&1)"
  pass "a valid record passes validation"
}

test_records_expose_every_field() {
  local f out
  f=$(record 2026-11-04.md ' | doc 77 abc1234567' "$SUMMARY" "$ROW1
$ROW2")
  out=$(fm_mt_records "$f")
  assert_contains "$out" "S${US}1${US}Team standup${US}aa11bb22${US}https://app.krisp.example/m/aa11bb22${US}77${US}abc1234567${US}Release scope agreed.${US}Two follow-ups for the backend." "section record wrong: $out"
  assert_contains "$out" "R${US}1${US}" "row records missing"
  assert_contains "$out" "${US}1${US}Ship the widget fix${US}Alex${US}${US}today${US}2026-11-05${US}${US}open${US}\"we ship the widget fix tomorrow\" @12:03" "row 1 fields wrong: $out"
  assert_contains "$out" "${US}2${US}Write the runbook [agentic]${US}Sam${US}sc-123${US}week${US}2026-11-06${US}${US}open${US}" "row 2 fields wrong: $out"
  pass "records expose section, doc id, summary, and every row field"
}

test_moved_reason_is_split_from_the_date() {
  local f out
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | Ship the widget fix | Alex | sc-9 | today | 2026-11-10 (moved: design slipped) | moved | "tomorrow" @01:02 |')
  fm_mt_validate "$f" || fail "a moved row with a reason was refused"
  out=$(fm_mt_records "$f")
  assert_contains "$out" "${US}sc-9${US}today${US}2026-11-10${US}design slipped${US}moved${US}" "moved reason not split: $out"
  pass "a moved reason is split from the deadline date"
}

test_malformed_cases_each_name_the_problem() {
  local f
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | soon | 2026-11-05 | open | "q" @1:02 |')
  expect_error scope "$f" "Scope must be today, week or later"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | today | 2026-11-05 | later | "q" @1:02 |')
  expect_error status "$f" "Status must be open, done, dropped or moved"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | 123 | today | 2026-11-05 | open | "q" @1:02 |')
  expect_error story "$f" "Story must be empty or sc-NNNN"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | today | 5 Nov | open | "q" @1:02 |')
  expect_error date-format "$f" "Deadline must start with YYYY-MM-DD"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | week | 2026-02-30 | open | "q" @1:02 |')
  expect_error impossible-date "$f" "not a real date"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | today | 2026-11-06 | open | "q" @1:02 |')
  expect_error today-date "$f" "a today item is due the next standup date 2026-11-05"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | week | 2026-11-05 | open | "q" @1:02 |')
  expect_error week-date "$f" "a week item is due Friday 2026-11-06"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | week | 2026-11-13 (moved: ) | moved | "q" @1:02 |')
  expect_error empty-reason "$f" "moved reason is empty"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | today | 2026-11-05 | open |')
  expect_error cell-count "$f" "expected 8 cells"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | today | 2026-11-05 | open | "no timestamp" |')
  expect_error quote "$f" "Quote must end with the transcript time @mm:ss"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | | A | | today | 2026-11-05 | open | "q" @1:02 |')
  expect_error empty-task "$f" "Task is empty"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | | | today | 2026-11-05 | open | "q" @1:02 |')
  expect_error empty-owner "$f" "Owner is empty"
  f=$(record 2026-11-04.md '' "$SUMMARY" "$ROW1
| 1 | Other | A | | today | 2026-11-05 | open | \"q\" @1:02 |")
  expect_error duplicate-number "$f" "duplicate row number 1"
  pass "each malformed row is refused with a message naming the problem and the line"
}

test_moved_rows_may_use_any_date() {
  local f
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | sc-5 | today | 2026-11-12 (moved: waiting on design) | moved | "q" @1:02 |')
  fm_mt_validate "$f" || fail "a moved date outside the standup rule was refused"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | sc-5 | week | 2026-11-12 (moved: waiting on design) | open | "q" @1:02 |')
  fm_mt_validate "$f" || fail "a row with a moved reason was refused"
  pass "a row that moved may carry a date outside the standup rule"
}

test_later_rows_carry_the_two_week_placeholder() {
  local f
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | later | 2026-11-18 | open | "maybe someday" @1:02 |')
  fm_mt_validate "$f" || fail "a later row with the placeholder deadline was refused: $(fm_mt_validate "$f" 2>&1)"
  f=$(record 2026-10-30.md '' "$SUMMARY" '| 1 | T | A | | later | 2026-11-13 | open | "maybe someday" @1:02 |')
  fm_mt_validate "$f" || fail "30 Oct later row due 13 Nov was refused"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | | later | 2026-11-11 | open | "q" @1:02 |')
  expect_error later-date "$f" "a later item has the placeholder deadline 2026-11-18"
  f=$(record 2026-11-04.md '' "$SUMMARY" '| 1 | T | A | sc-5 | later | 2026-11-09 (moved: Sam said Monday) | moved | "q" @1:02 |')
  fm_mt_validate "$f" || fail "a later row with a stated timing was refused"
  pass "a later row is due two weeks after the meeting unless a transcript stated a timing"
}

test_friday_meetings_are_due_monday() {
  local f
  f=$(record 2026-11-06.md '' "$SUMMARY" '| 1 | T | A | | today | 2026-11-09 | open | "q" @1:02 |
| 2 | U | A | | week | 2026-11-06 | open | "q" @2:02 |')
  fm_mt_validate "$f" || fail "a Friday meeting was refused: $(fm_mt_validate "$f" 2>&1)"
  f=$(record 2026-11-06.md '' "$SUMMARY" '| 1 | T | A | | today | 2026-11-07 | open | "q" @1:02 |')
  expect_error saturday "$f" "next standup date 2026-11-09"
  pass "a Friday meeting's today items are due Monday"
}

test_structure_errors() {
  local f
  f=$(record 2026-11-04.md '' "$SUMMARY" "$ROW1")
  sed -i.bak 's/| # | Task | Owner | Story | Scope | Deadline | Status | Quote |/| # | Task | Who | Story | Scope | Deadline | Status | Quote |/' "$f"
  expect_error header "$f" "table header must be"
  f=$TMP_ROOT/2026-11-04.md
  printf 'nothing here\n' > "$f"
  expect_error no-sections "$f" "no meeting section"
  printf '## Standup\n> s\n\n%s\n%s\n' "$HEAD" "$ROW1" > "$f"
  expect_error bad-heading "$f" "section heading must be"
  printf '## Team standup - Krisp aa11 https://k.example/m/aa11\n\n%s\n%s\n' "$HEAD" "$ROW1" > "$f"
  expect_error no-summary "$f" "needs a '> summary' line"
  printf '## Team standup - Krisp aa11 https://k.example/m/aa11\n> a\n> b\n> c\n\n%s\n%s\n' "$HEAD" "$ROW1" > "$f"
  expect_error long-summary "$f" "at most 2 '> summary' lines"
  printf '## Team standup - Krisp aa11 https://k.example/m/aa11\n> a\n\n%s\n' "$HEAD" > "$f"
  expect_error no-rows "$f" "has no task rows"
  printf '## Team standup - Krisp aa11 not-a-link\n> a\n\n%s\n%s\n' "$HEAD" "$ROW1" > "$f"
  expect_error bad-link "$f" "section heading must be"
  f=$(record 2026-11-04.md ' | doc 77' "$SUMMARY" "$ROW1")
  expect_error bad-doc "$f" "doc suffix must be"
  f=$(record notes.md '' "$SUMMARY" "$ROW1")
  expect_error file-name "$f" "file name must be YYYY-MM-DD.md"
  expect_error missing-file "$TMP_ROOT/absent.md" "cannot read"
  pass "structure errors (header, sections, summary, rows, link, doc suffix, file name) are refused"
}

test_write_back_story_and_doc() {
  local f
  f=$(record 2026-11-04.md '' "$SUMMARY" "$ROW1
$ROW2")
  fm_mt_set_story "$f" 7 sc-456 || fail "set_story failed"
  grep -qF '| 1 | Ship the widget fix | Alex | sc-456 | today | 2026-11-05 | open | "we ship the widget fix tomorrow" @12:03 |' "$f" || fail "story id not written into row 1: $(cat "$f")"
  grep -qF "$ROW2" "$f" || fail "row 2 changed"
  fm_mt_validate "$f" || fail "the record no longer validates after write-back"
  fm_mt_set_doc "$f" 1 99 deadbeef01 || fail "set_doc failed"
  head -1 "$f" | grep -qF 'https://app.krisp.example/m/aa11bb22 | doc 99 deadbeef01' || fail "doc suffix not written: $(head -1 "$f")"
  fm_mt_set_doc "$f" 1 99 cafe000002 || fail "set_doc rewrite failed"
  [ "$(head -1 "$f" | grep -o '| doc' | wc -l | tr -d ' ')" = 1 ] || fail "doc suffix duplicated: $(head -1 "$f")"
  head -1 "$f" | grep -qF '| doc 99 cafe000002' || fail "doc suffix not replaced"
  fm_mt_validate "$f" || fail "the record no longer validates after the doc write-back"
  pass "write-back sets the story id in its row and replaces the doc suffix in the heading"
}

test_doc_title_uses_the_meeting_day() {
  assert_equals "Standup Wed 4 Nov - agreed to-dos" "$(fm_mt_doc_title 2026-11-04)" "doc title wrong"
  assert_equals "Standup Fri 6 Nov - agreed to-dos" "$(fm_mt_doc_title 2026-11-06)" "doc title wrong"
  assert_equals "Standup Mon 12 Oct - agreed to-dos" "$(fm_mt_doc_title 2026-10-12)" "doc title wrong"
  pass "the doc title names the meeting day, date and month"
}

fm_test_run \
  test_valid_record_passes \
  test_records_expose_every_field \
  test_moved_reason_is_split_from_the_date \
  test_malformed_cases_each_name_the_problem \
  test_moved_rows_may_use_any_date \
  test_later_rows_carry_the_two_week_placeholder \
  test_friday_meetings_are_due_monday \
  test_structure_errors \
  test_write_back_story_and_doc \
  test_doc_title_uses_the_meeting_day
