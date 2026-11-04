#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for bin/fm-meeting-todos-sync.sh.
#
# Shortcut is a fake ticket command (the same `api` and `setting` interface as
# bin/fm-shortcut-ticket.sh) that keeps stories, labels and docs in a scratch
# directory and logs every call. Nothing reaches the real API.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-meeting-todos-sync)
SYNC="$ROOT/bin/fm-meeting-todos-sync.sh"
TEAM=99999999-8888-4777-8666-555555555555

# The fake ticket command. State lives in $FAKE_SC_DIR; calls.log holds every call,
# writes.log only the POST, PUT and DELETE calls.
write_fake() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
D=$FAKE_SC_DIR
mkdir -p "$D/stories" "$D/docs"
[ -f "$D/labels.json" ] || echo '[]' > "$D/labels.json"
[ -f "$D/counter" ] || echo 1000 > "$D/counter"
case "${1:-}" in
  setting)
    case "${2:-}" in
      team_id) echo "$FAKE_TEAM" ;;
      story_type) echo feature ;;
      state_backlog) echo 500000006 ;;
      *) echo "${3:-}" ;;
    esac
    exit 0 ;;
  api) ;;
  *) echo "fake: unsupported op ${1:-}" >&2; exit 2 ;;
esac
method=$2 path=$3 body=${4:-}
echo "$method $path" >> "$D/calls.log"
case "$method" in GET) ;; *) echo "$method $path" >> "$D/writes.log"; [ -z "$body" ] || jq -c . "$body" >> "$D/bodies.log" ;; esac
fail() { echo "HTTP $1" >&2; exit 1; }
case " ${FAKE_SC_FAIL:-} " in *" $method $path "*) fail 500 ;; esac
case "$method $path" in
  "GET /api/v3/labels") cat "$D/labels.json" ;;
  "POST /api/v3/labels")
    n=$(jq 'length + 1' "$D/labels.json")
    jq -c --argjson n "$n" '. + [{id: $n, name: input.name}]' "$D/labels.json" "$body" > "$D/labels.tmp" && mv "$D/labels.tmp" "$D/labels.json"
    echo "{\"id\":$n}" ;;
  "POST /api/v3/stories")
    n=$(($(cat "$D/counter") + 1)); echo "$n" > "$D/counter"
    jq -c --argjson n "$n" '. + {id: $n, app_url: ("https://shortcut.example/story/" + ($n|tostring)), labels: [(.labels // [])[] | {name: .name}]}' "$body" > "$D/stories/$n.json"
    cat "$D/stories/$n.json" ;;
  "GET /api/v3/stories/"*)
    f="$D/stories/${path##*/}.json"; [ -f "$f" ] || fail 404; cat "$f" ;;
  "PUT /api/v3/stories/"*)
    f="$D/stories/${path##*/}.json"; [ -f "$f" ] || fail 404
    jq -c '. + input | .labels = [(.labels // [])[] | {name: .name}]' "$f" "$body" > "$f.tmp" && mv "$f.tmp" "$f"
    cat "$f" ;;
  "POST /api/v3/stories/"*"/comments")
    id=${path#/api/v3/stories/}; id=${id%/comments}
    jq -r .text "$body" >> "$D/comments-$id.log"; echo '{}' ;;
  "POST /api/v3/documents")
    n=$(ls "$D/docs" | wc -l | tr -d ' '); n=$((n + 1)); id="doc-$n"
    jq -c --arg id "$id" '. + {id: $id}' "$body" > "$D/docs/$id.json"
    cat "$D/docs/$id.json" ;;
  "GET /api/v3/documents/"*)
    f="$D/docs/${path##*/}.json"; [ -f "$f" ] || fail 404; cat "$f" ;;
  "PUT /api/v3/documents/"*)
    f="$D/docs/${path##*/}.json"; [ -f "$f" ] || fail 404
    jq -c '. + input' "$f" "$body" > "$f.tmp" && mv "$f.tmp" "$f"; cat "$f" ;;
  *) fail 404 ;;
esac
SH
  chmod +x "$1"
}

HEAD='| # | Task | Owner | Story | Scope | Deadline | Status | Quote |
|---|---|---|---|---|---|---|---|'

new_case() {  # <name> -> prints the case dir; $dir/fake is the ticket command, $dir/store the fake state
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/store" "$dir/rec"
  write_fake "$dir/fake"
  printf '%s\n' "$dir"
}

# rec <case-dir> <rows> -> prints the record path (meeting date 2026-11-04)
rec() {
  local f="$1/rec/2026-11-04.md"
  {
    printf '## Team standup - Krisp aa11bb22 https://app.krisp.example/m/aa11bb22\n'
    printf '> Release scope agreed.\n> Two follow-ups for the backend.\n\n'
    printf '%s\n%s\n' "$HEAD" "$2"
  } > "$f"
  printf '%s\n' "$f"
}

ROW_NEW='| 1 | Ship the widget fix | Alex | | today | 2026-11-05 | open | "we ship the widget fix tomorrow" @12:03 |'
ROW_AGENTIC='| 2 | Add the retry helper [agentic] | Sam | | week | 2026-11-06 | open | "agents write the retry helper" @31:40 |'
ROW_DONE='| 3 | Rotate the staging key | Alex | | today | 2026-11-05 | done | "already rotated" @40:00 |'
ROW_DROPPED='| 4 | Rewrite the exporter | Sam | | week | 2026-11-06 | dropped | "park that" @41:10 |'

sync() {  # <case-dir> <args...>; runs the sync script against the fake
  local dir=$1
  shift
  FAKE_SC_DIR="$dir/store" FAKE_TEAM="$TEAM" FM_MEETING_TODOS_TICKET_CMD="$dir/fake" "$SYNC" "$@" 2>&1
}

writes() { { cat "$1/store/writes.log" 2>/dev/null || true; } | wc -l | tr -d ' '; }
story_json() { cat "$1/store/stories/$2.json"; }

test_first_run_creates_stories_labels_and_one_doc() {
  local dir f out s1 s2 doc content
  dir=$(new_case first-run)
  f=$(rec "$dir" "$ROW_NEW
$ROW_AGENTIC
$ROW_DONE
$ROW_DROPPED")
  out=$(sync "$dir" "$f") || fail "first sync failed: $out"
  # stories
  [ "$(find "$dir/store/stories" -type f | wc -l | tr -d ' ')" = 2 ] || fail "expected 2 stories (done and dropped rows make none): $(find "$dir/store/stories" -type f)"
  s1=$(story_json "$dir" 1001)
  assert_equals "Ship the widget fix" "$(printf '%s' "$s1" | jq -r .name)" "story name"
  assert_equals "$TEAM" "$(printf '%s' "$s1" | jq -r .group_id)" "team is not Engineering"
  assert_equals "2026-11-05T12:30:00Z" "$(printf '%s' "$s1" | jq -r .deadline)" "deadline"
  assert_equals "null" "$(printf '%s' "$s1" | jq -r '.epic_id')" "a non-agentic story got an epic"
  assert_equals "standup-2026-11-04 todo-today" "$(printf '%s' "$s1" | jq -r '[.labels[].name] | join(" ")')" "labels of story 1"
  assert_contains "$(printf '%s' "$s1" | jq -r .description)" "we ship the widget fix tomorrow" "description lacks the quote"
  assert_contains "$(printf '%s' "$s1" | jq -r .description)" "https://app.krisp.example/m/aa11bb22" "description lacks the Krisp link"
  s2=$(story_json "$dir" 1002)
  assert_equals "Add the retry helper" "$(printf '%s' "$s2" | jq -r .name)" "agentic tag was not stripped from the name"
  assert_equals "6074" "$(printf '%s' "$s2" | jq -r .epic_id)" "agentic story is not on the agentic epic"
  assert_equals "2026-11-06T12:30:00Z" "$(printf '%s' "$s2" | jq -r .deadline)" "week deadline"
  assert_equals "standup-2026-11-04 todo-week" "$(printf '%s' "$s2" | jq -r '[.labels[].name] | join(" ")')" "labels of story 2"
  # labels created once each
  assert_equals "standup-2026-11-04 todo-today todo-week" "$(jq -r '[.[].name] | join(" ")' "$dir/store/labels.json")" "labels created"
  # ids written back
  grep -qF '| 1 | Ship the widget fix | Alex | sc-1001 | today |' "$f" || fail "sc-1001 not written back: $(cat "$f")"
  grep -qF '| 2 | Add the retry helper [agentic] | Sam | sc-1002 | week |' "$f" || fail "sc-1002 not written back"
  grep -qF '| 3 | Rotate the staging key | Alex | | today |' "$f" || fail "the done row got a story id"
  # one doc
  [ "$(find "$dir/store/docs" -type f | wc -l | tr -d ' ')" = 1 ] || fail "expected one doc"
  doc=$(cat "$dir/store/docs/doc-1.json")
  assert_equals "Standup Wed 4 Nov - agreed to-dos" "$(printf '%s' "$doc" | jq -r .title)" "doc title"
  assert_equals "markdown" "$(printf '%s' "$doc" | jq -r .content_format)" "doc format"
  content=$(printf '%s' "$doc" | jq -r .content)
  assert_contains "$content" "https://app.krisp.example/m/aa11bb22" "doc lacks the Krisp link"
  assert_contains "$content" "Release scope agreed." "doc lacks summary line 1"
  assert_contains "$content" "Two follow-ups for the backend." "doc lacks summary line 2"
  assert_contains "$content" "[sc-1001](https://shortcut.example/story/1001)" "doc lacks the story link"
  assert_contains "$content" "2026-11-06" "doc lacks the week deadline"
  assert_contains "$content" "Rotate the staging key" "doc lacks the done row"
  head -1 "$f" | grep -qE ' \| doc doc-1 [0-9a-f]{10}$' || fail "doc id not recorded in the heading: $(head -1 "$f")"
  assert_contains "$out" "created sc-1001" "output does not report the created story"
  pass "a first run creates stories (Engineering, deadline, labels, agentic epic), writes ids back, and writes one doc"
}

test_rerun_on_an_unchanged_file_writes_nothing() {
  local dir f before out w
  dir=$(new_case rerun)
  f=$(rec "$dir" "$ROW_NEW
$ROW_AGENTIC")
  sync "$dir" "$f" >/dev/null || fail "first sync failed"
  before=$(writes "$dir")
  cp "$f" "$dir/record.before"
  out=$(sync "$dir" "$f") || fail "second sync failed: $out"
  assert_equals "$before" "$(writes "$dir")" "a re-run made Shortcut writes"
  cmp -s "$f" "$dir/record.before" || fail "a re-run changed the record file"
  assert_contains "$out" "unchanged" "output does not say unchanged"
  pass "re-running on an unchanged file makes no Shortcut writes and leaves the file alone"
}

test_dry_run_plans_without_writing() {
  local dir f out s1 s2 doc content
  dir=$(new_case dry)
  f=$(rec "$dir" "$ROW_NEW")
  cp "$f" "$dir/record.before"
  out=$(sync "$dir" "$f" --dry-run) || fail "dry run failed: $out"
  assert_equals 0 "$(writes "$dir")" "a dry run made Shortcut writes"
  cmp -s "$f" "$dir/record.before" || fail "a dry run changed the record file"
  assert_contains "$out" "would create a story" "dry run did not plan the story"
  assert_contains "$out" "would create the doc" "dry run did not plan the doc"
  pass "--dry-run reports the plan and changes nothing"
}

test_deadline_move_changes_deadline_and_comments_the_reason() {
  local dir f out w
  dir=$(new_case move)
  f=$(rec "$dir" "$ROW_NEW
$ROW_AGENTIC")
  sync "$dir" "$f" >/dev/null || fail "first sync failed"
  sed -i.bak 's/| sc-1002 | week | 2026-11-06 | open |/| sc-1002 | week | 2026-11-10 (moved: waiting on design) | moved |/' "$f"
  sed -i.bak 's/Add the retry helper \[agentic\]/Add the retry helper [agentic]/' "$f"
  out=$(sync "$dir" "$f") || fail "move sync failed: $out"
  assert_equals "2026-11-10T12:30:00Z" "$(story_json "$dir" 1002 | jq -r .deadline)" "deadline not moved"
  assert_equals "Deadline moved 2026-11-06 -> 2026-11-10: waiting on design" "$(cat "$dir/store/comments-1002.log")" "move comment wrong"
  [ ! -f "$dir/store/comments-1001.log" ] || fail "an unmoved story got a comment"
  assert_contains "$(jq -r .content "$dir/store/docs/doc-1.json")" "2026-11-10" "doc was not updated with the new deadline"
  w=$(writes "$dir")
  sync "$dir" "$f" >/dev/null || fail "re-run after a move failed"
  assert_equals "$w" "$(writes "$dir")" "a re-run after a move wrote again"
  pass "a moved deadline changes the Shortcut deadline, comments the old date and reason once, and updates the doc"
}

test_existing_story_gets_missing_labels_and_deadline_without_a_move_comment() {
  local dir f out w
  dir=$(new_case existing)
  mkdir -p "$dir/store/stories"
  echo '{"id":4242,"name":"Old story","deadline":null,"labels":[{"name":"keep-me"}],"app_url":"https://shortcut.example/story/4242"}' > "$dir/store/stories/4242.json"
  f=$(rec "$dir" '| 1 | Ship the widget fix | Alex | sc-4242 | today | 2026-11-05 | open | "we ship the widget fix tomorrow" @12:03 |')
  sync "$dir" "$f" >/dev/null || fail "sync failed"
  assert_equals "2026-11-05T12:30:00Z" "$(story_json "$dir" 4242 | jq -r .deadline)" "deadline not set"
  assert_equals "keep-me standup-2026-11-04 todo-today" "$(story_json "$dir" 4242 | jq -r '[.labels[].name] | join(" ")')" "labels not merged"
  [ ! -f "$dir/store/comments-4242.log" ] || fail "setting a first deadline commented a move"
  assert_equals "0" "$(grep -c 'POST /api/v3/stories$' "$dir/store/writes.log" || true)" "an existing story was created again"
  pass "an existing story gets its missing labels and a first deadline, with no move comment"
}

test_same_state_story_is_left_alone() {
  local dir f out w
  dir=$(new_case same)
  mkdir -p "$dir/store/stories"
  echo '{"id":4242,"name":"Old story","deadline":"2026-11-05T12:30:00Z","labels":[{"name":"standup-2026-11-04"},{"name":"todo-today"}],"app_url":"https://shortcut.example/story/4242"}' > "$dir/store/stories/4242.json"
  echo '[{"id":1,"name":"standup-2026-11-04"},{"id":2,"name":"todo-today"}]' > "$dir/store/labels.json"
  f=$(rec "$dir" '| 1 | Ship the widget fix | Alex | sc-4242 | today | 2026-11-05 | open | "we ship the widget fix tomorrow" @12:03 |')
  sync "$dir" "$f" >/dev/null || fail "sync failed"
  assert_no_grep "PUT /api/v3/stories" "$dir/store/writes.log" "an up-to-date story was written"
  assert_no_grep "POST /api/v3/labels" "$dir/store/writes.log" "an existing label was created again"
  pass "a story that already matches is not written, and existing labels are not created again"
}

test_later_rows_get_the_later_label_and_their_own_doc_table() {
  local dir f s content
  dir=$(new_case later)
  f=$(rec "$dir" "$ROW_NEW
| 2 | Look at the exporter someday | Sam | | later | 2026-11-18 | open | \"maybe at some point\" @50:00 |")
  sync "$dir" "$f" >/dev/null || fail "sync failed"
  s=$(story_json "$dir" 1002)
  assert_equals "standup-2026-11-04 todo-later" "$(printf '%s' "$s" | jq -r '[.labels[].name] | join(" ")')" "later labels"
  assert_equals "2026-11-18T12:30:00Z" "$(printf '%s' "$s" | jq -r .deadline)" "later placeholder deadline"
  content=$(jq -r .content "$dir/store/docs/doc-1.json")
  assert_contains "$content" "Later - agreed softly or with no date" "doc lacks the later section"
  assert_contains "$content" "not at risk" "later section does not say it is not at risk"
  pass "a later row gets todo-later, the two-week placeholder deadline, and its own doc section"
}

test_a_later_story_with_a_stated_timing_moves_and_drops_the_later_label() {
  local dir f
  dir=$(new_case later-moved)
  f=$(rec "$dir" "| 1 | Look at the exporter someday | Sam | | later | 2026-11-18 | open | \"maybe at some point\" @50:00 |")
  sync "$dir" "$f" >/dev/null || fail "first sync failed"
  sed -i.bak 's/| sc-1001 | later | 2026-11-18 | open |/| sc-1001 | week | 2026-11-06 (moved: Sam gave a date in the next standup) | moved |/' "$f"
  sync "$dir" "$f" >/dev/null || fail "move sync failed"
  assert_equals "2026-11-06T12:30:00Z" "$(story_json "$dir" 1001 | jq -r .deadline)" "deadline not updated"
  assert_equals "standup-2026-11-04 todo-week" "$(story_json "$dir" 1001 | jq -r '[.labels[].name] | join(" ")')" "stale todo-later label kept"
  assert_equals "Deadline moved 2026-11-18 -> 2026-11-06: Sam gave a date in the next standup" "$(cat "$dir/store/comments-1001.log")" "comment wrong"
  pass "a later story given a real timing moves its Deadline with a comment and swaps todo-later for the new scope label"
}

test_done_and_dropped_rows_never_touch_a_story() {
  local dir f out w
  dir=$(new_case closed)
  mkdir -p "$dir/store/stories"
  echo '{"id":4242,"name":"Old story","deadline":"2026-11-01T12:30:00Z","labels":[],"app_url":"https://shortcut.example/story/4242"}' > "$dir/store/stories/4242.json"
  f=$(rec "$dir" '| 1 | Ship the widget fix | Alex | sc-4242 | today | 2026-11-05 | done | "we ship the widget fix tomorrow" @12:03 |')
  sync "$dir" "$f" >/dev/null || fail "sync failed"
  assert_no_grep "stories" "$dir/store/writes.log" "a done row wrote to its story"
  assert_contains "$(jq -r .content "$dir/store/docs/doc-1.json")" "[sc-4242](https://shortcut.example/story/4242)" "doc lacks the done row's story link"
  pass "done and dropped rows leave their stories alone but still appear in the doc"
}

test_invalid_record_is_refused_before_any_call() {
  local dir f out rc
  dir=$(new_case invalid)
  f=$(rec "$dir" '| 1 | T | A | | soon | 2026-11-05 | open | "q" @1:02 |')
  out=$(sync "$dir" "$f"); rc=$?
  [ "$rc" = 2 ] || fail "invalid record exit was $rc, expected 2"
  assert_contains "$out" "Scope must be today, week or later" "invalid record error missing"
  [ ! -f "$dir/store/calls.log" ] || fail "an invalid record reached Shortcut"
  out=$(sync "$dir"); rc=$?
  [ "$rc" = 2 ] || fail "missing argument exit was $rc"
  assert_contains "$out" "usage:" "usage missing"
  pass "an invalid record or missing argument is refused with exit 2 before any Shortcut call"
}

test_a_failed_story_call_is_reported_and_other_rows_continue() {
  local dir f out rc
  dir=$(new_case failure)
  f=$(rec "$dir" "$ROW_NEW
$ROW_AGENTIC")
  out=$(FAKE_SC_FAIL="PUT /api/v3/documents/doc-1 POST /api/v3/stories" sync "$dir" "$f"); rc=$?
  [ "$rc" = 1 ] || fail "a failed story call exited $rc, expected 1"
  assert_contains "$out" "row 1" "the failing row is not named"
  assert_contains "$out" "HTTP 500" "the HTTP code is not shown"
  [ ! -d "$dir/store/docs" ] || [ -z "$(ls "$dir/store/docs")" ] || fail "a doc was written although a row failed"
  head -1 "$f" | grep -q '| doc' && fail "a doc id was recorded although a row failed"
  out=$(sync "$dir" "$f") || fail "the retry after the failure failed: $out"
  grep -qF '| sc-' "$f" || fail "the retry wrote no story ids"
  pass "a failed Shortcut call is reported with its row, writes no doc, and a re-run finishes the job"
}

test_a_missing_story_is_reported() {
  local dir f out rc
  dir=$(new_case missing)
  f=$(rec "$dir" '| 1 | Ship the widget fix | Alex | sc-9999 | today | 2026-11-05 | open | "we ship the widget fix tomorrow" @12:03 |')
  out=$(sync "$dir" "$f"); rc=$?
  [ "$rc" = 1 ] || fail "a missing story exited $rc"
  assert_contains "$out" "sc-9999" "the missing story is not named"
  assert_contains "$out" "HTTP 404" "the 404 is not shown"
  pass "a row naming a story Shortcut does not have is reported"
}

test_two_meetings_get_two_docs_with_distinct_titles() {
  local dir f out w
  dir=$(new_case two)
  f=$(rec "$dir" "$ROW_NEW")
  {
    printf '\n## Backend sync - Krisp cc33dd44 https://app.krisp.example/m/cc33dd44\n> Sync notes.\n\n%s\n' "$HEAD"
    printf '| 1 | Tune the queue | Sam | | week | 2026-11-06 | open | "tune the queue" @05:00 |\n'
  } >> "$f"
  sync "$dir" "$f" >/dev/null || fail "sync failed"
  [ "$(find "$dir/store/docs" -type f | wc -l | tr -d ' ')" = 2 ] || fail "expected two docs"
  assert_equals "Standup Wed 4 Nov - agreed to-dos (Team standup)" "$(jq -r .title "$dir/store/docs/doc-1.json")" "first doc title"
  assert_equals "Standup Wed 4 Nov - agreed to-dos (Backend sync)" "$(jq -r .title "$dir/store/docs/doc-2.json")" "second doc title"
  grep -c '| doc doc-' "$f" | grep -qx 2 || fail "both headings should record a doc id"
  pass "a file with two meetings writes two docs, each titled with its meeting"
}

test_sync_refuses_when_shortcut_is_off() {
  local dir f out rc
  dir=$(new_case off)
  f=$(rec "$dir" "$ROW_NEW")
  out=$(env -u FM_MEETING_TODOS_TICKET_CMD FM_SHORTCUT_TICKETS=off FAKE_SC_DIR="$dir/store" "$SYNC" "$f" 2>&1); rc=$?
  [ "$rc" = 1 ] || fail "sync with tickets off exited $rc"
  assert_contains "$out" "Shortcut tickets are off" "no off message"
  pass "the sync stops with a clear message when Shortcut tickets are off"
}

fm_test_run \
  test_first_run_creates_stories_labels_and_one_doc \
  test_rerun_on_an_unchanged_file_writes_nothing \
  test_dry_run_plans_without_writing \
  test_deadline_move_changes_deadline_and_comments_the_reason \
  test_existing_story_gets_missing_labels_and_deadline_without_a_move_comment \
  test_same_state_story_is_left_alone \
  test_later_rows_get_the_later_label_and_their_own_doc_table \
  test_a_later_story_with_a_stated_timing_moves_and_drops_the_later_label \
  test_done_and_dropped_rows_never_touch_a_story \
  test_invalid_record_is_refused_before_any_call \
  test_a_failed_story_call_is_reported_and_other_rows_continue \
  test_a_missing_story_is_reported \
  test_two_meetings_get_two_docs_with_distinct_titles \
  test_sync_refuses_when_shortcut_is_off
