#!/usr/bin/env bash
# Behavior and timing checks for the fast paths of fm-send, fm-wake-drain and
# fm-decide (applypass fork).
#
# The three scripts run in every captain turn, so their wall time is part of the
# captain's wait. The checks below pin two things for each script: the answer is
# the same as the slow path gave, and the call stays under a generous bound on a
# fixture home with a long status log. The bounds sit far above the measured
# times (a loaded CI host still passes) and far below the times the slow paths
# took on the same fixture, so a regression to a whole-log fold or a synchronous
# network call fails here without making the suite flaky.
# Nothing here reaches a real home, Shortcut, 1Password or a terminal.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-scripts-fast)
LOG_LINES=${FM_FAST_TEST_LOG_LINES:-2500}
SEND_BOUND=${FM_FAST_TEST_SEND_BOUND:-6}
DECIDE_BOUND=${FM_FAST_TEST_DECIDE_BOUND:-3}
TOKEN=tok-secret-123
OWNER=11111111-2222-4333-8444-555555555555

# make_log <file> <lines>: a status log with an open decision (key open-k), many
# decisions opened and later resolved, blocked ones and plain progress.
make_log() {
  awk -v n="$2" 'BEGIN {
    t = 1790000000
    printf "needs-decision [key=open-k] [at=%d]: still waiting on the captain\n", t
    for (i = 1; i <= n; i++) {
      t++
      if (i % 5 == 1) printf "needs-decision [key=k%d] [at=%d]: option %d or %d for item %d\n", i, t, i, i + 1, i
      else if (i % 5 == 2) printf "resolved [key=k%d] [at=%d]: answered: take the first\n", i - 1, t
      else if (i % 50 == 3) printf "blocked [key=b%d] [at=%d]: waiting on an external check\n", i, t
      else printf "working [at=%d]: progress line %d with a few more words in it\n", t, i
    }
  }' > "$1"
}

# now_seconds: wall clock as integer milliseconds (bash 5 EPOCHREALTIME).
now_ms() { local t=${EPOCHREALTIME/./}; printf '%s' "${t%???}"; }

test_fast_fold_matches_full_fold() {
  local dir log full fast again
  dir="$TMP_ROOT/fold"; mkdir -p "$dir/state"
  log="$dir/state/t1.status"
  make_log "$log" 400
  full=$(bash -c '. "$1"; status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$log")
  fast=$(bash -c '. "$1"; fm_fast_status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$log")
  [ -n "$full" ] || fail "fixture error: the log should leave decisions open"
  assert_equals "$full" "$fast" "the cursor-backed fold must equal the whole-log fold on a cold cursor"
  [ -f "$dir/state/.t1.open-decisions-cursor" ] || fail "the fast fold should leave its cursor beside the log"
  printf 'resolved [key=open-k] [at=1790009999]: answered\n' >> "$log"
  printf 'needs-decision [key=late-k] [at=1790010000]: a decision opened after the cursor\n' >> "$log"
  full=$(bash -c '. "$1"; status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$log")
  again=$(bash -c '. "$1"; fm_fast_status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$log")
  assert_equals "$full" "$again" "the cursor-backed fold must equal the whole-log fold after appends"
  assert_not_contains "$again" "open-k" "the appended close must drop open-k from the open set"
  assert_contains "$again" "late-k" "the appended decision must be in the open set"
  : > "$dir/state/empty.status"
  assert_equals "" "$(bash -c '. "$1"; fm_fast_status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$dir/state/empty.status")" \
    "an empty log has no open decisions"
  assert_equals "" "$(bash -c '. "$1"; fm_fast_status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$dir/state/absent.status")" \
    "an absent log has no open decisions"
  pass "the cursor-backed open-decision fold equals the whole-log fold"
}

make_send_stubs() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done; printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/tmux" "$fb/sleep"
}

test_resolve_key_send_stays_fast_on_a_long_log() {
  local dir home start end rc ms
  dir="$TMP_ROOT/send"; home="$dir/home"
  mkdir -p "$home/state"
  make_send_stubs "$dir"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  make_log "$home/state/t1.status" "$LOG_LINES"
  # The wake drain keeps every log's cursor warm in a live home; fold once here
  # the way a drain would, so the timed call reads only what the send appends.
  bash -c '. "$1"; status_open_decisions_incremental "$2" >/dev/null' _ "$ROOT/bin/fm-classify-lib.sh" "$home/state/t1.status"
  start=$(now_ms)
  env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" t1 --resolve-key open-k "take the first option" >/dev/null 2>"$dir/err"
  rc=$?
  end=$(now_ms)
  ms=$((end - start))
  expect_code 0 "$rc" "the answer send should succeed: $(cat "$dir/err")"
  assert_grep 'resolved [key=open-k]' "$home/state/t1.status" "the answer should close open-k"
  [ "$ms" -lt $((SEND_BOUND * 1000)) ] || fail "fm-send --resolve-key took ${ms} ms on a ${LOG_LINES}-line log (bound ${SEND_BOUND} s)"
  pass "fm-send --resolve-key answers in ${ms} ms on a ${LOG_LINES}-line status log"
}

# decide_case <name>: a home with a Shortcut config and a fake curl that waits
# FAKE_CURL_DELAY seconds before it answers. Echoes the case dir.
decide_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/defaults" "$dir/home/data" "$dir/home/state" "$dir/home/config" "$dir/home/.claude"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
  cp "$ROOT/defaults/shortcut-tickets" "$dir/code/defaults/shortcut-tickets"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
  printf 'owner_id=%s\ntoken_ref=op://v/i/f\n' "$OWNER" > "$dir/home/config/shortcut-tickets"
  fm_fake_shortcut_curl "$dir/fakebin"
  mv "$dir/fakebin/curl" "$dir/fakebin/curl.fake"
  cat > "$dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
sleep "${FAKE_CURL_DELAY:-0}"
if [ "${FAKE_CURL_COMMENT_FAIL:-}" = 1 ]; then
  out=
  for a in "$@"; do
    [ "${prev:-}" != -o ] || out=$a
    case "$a" in */comments) printf 'POST %s\n' "$a" >> "$FAKE_CURL_LOG"; cat >/dev/null; printf '{}' > "$out"; printf 500; exit 0 ;; esac
    prev=$a
  done
fi
exec "$(dirname "$0")/curl.fake" "$@"
SH
  chmod +x "$dir/fakebin/curl"
  fm_fake_exit0 "$dir/fakebin" tmux treehouse no-mistakes gh gh-axi
  : > "$dir/curl.log"
  printf '%s\n' "$dir"
}

# decide_run <case-dir> <args...>: fm-decide in background mode (the default).
decide_run() {
  local dir=$1
  shift
  (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS -u FM_DECIDE_SYNC FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    SHORTCUT_API_TOKEN="$TOKEN" FAKE_CURL_LOG="$dir/curl.log" FM_DECIDE_DATE=2026-10-09 \
    FM_DECIDE_SYNC_ATTEMPTS="${FM_DECIDE_SYNC_ATTEMPTS:-3}" FM_DECIDE_SYNC_DELAY=0 \
    PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-decide.sh" "$@" 2>&1)
}

# wait_for_grep <fixed-pattern> <file> [seconds]: poll until the file has it.
wait_for_grep() {
  local n=$((${3:-40} * 5)) i
  for ((i = 0; i < n; i++)); do
    grep -qF -- "$1" "$2" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

test_decide_returns_before_shortcut_answers() {
  local dir out start end ms
  dir=$(decide_case decide-fast)
  start=$(now_ms)
  out=$(FAKE_CURL_DELAY=4 decide_run "$dir" record df-1 "Ship option B." --story sc-6523) || fail "record failed: $out"
  end=$(now_ms)
  ms=$((end - start))
  [ "$ms" -lt $((DECIDE_BOUND * 1000)) ] || fail "fm-decide record took ${ms} ms while Shortcut took 4 s per call (bound ${DECIDE_BOUND} s)"
  assert_contains "$out" "posting to Shortcut in the background" "the record did not say the post runs in the background"
  assert_grep '- [df-1] 2026-10-09 Ship option B. (shortcut: pending sc-6523)' "$dir/home/data/decided.md" "the local entry should be written before the post"
  wait_for_grep '(shortcut: sc-6523 ' "$dir/home/data/decided.md" 60 || fail "the background job never stamped the entry: $(cat "$dir/home/data/.decided-sync.log" 2>/dev/null)"
  assert_equals 1 "$(grep -c 'comments' "$dir/curl.log")" "the story should get exactly one comment"
  assert_grep 'Captain decision [df-1]: Ship option B.' "$dir/curl.log" "the comment text is missing"
  pass "fm-decide record returns in ${ms} ms and the background job stamps the entry"
}

test_decide_without_story_files_a_chore_in_the_background() {
  local dir out
  dir=$(decide_case decide-chore)
  out=$(decide_run "$dir" record df-2 "No story yet.") || fail "record failed: $out"
  assert_grep '- [df-2] 2026-10-09 No story yet. (shortcut: ' "$dir/home/data/decided.md" "the entry is missing"
  wait_for_grep '(shortcut: sc-7777 ' "$dir/home/data/decided.md" 60 || fail "the job never filed a chore and stamped it: $(cat "$dir/home/data/.decided-sync.log" 2>/dev/null)"
  grep -qx 'POST https://api.app.shortcut.com/api/v3/stories' "$dir/curl.log" || fail "no chore story was filed"
  assert_grep 'stories/7777/comments' "$dir/curl.log" "the decision was not commented on the new chore"
  out=$(decide_run "$dir" record df-2 "No story yet.") || fail "replay failed: $out"
  assert_equals 1 "$(grep -c '^- \[df-2\]' "$dir/home/data/decided.md")" "a replay appended a second entry"
  pass "a decision with no story is recorded at once and gets its chore story from the background job"
}

test_decide_final_failure_queues_a_note_and_sync_recovers() {
  local dir out
  dir=$(decide_case decide-fail)
  out=$(FAKE_CURL_COMMENT_FAIL=1 FM_DECIDE_SYNC_ATTEMPTS=2 decide_run "$dir" record df-3 "Will not post." --story sc-6523) || fail "record failed: $out"
  wait_for_grep 'after 2 tries' "$dir/home/data/.decided-sync.log" 40 || fail "the job never gave up: $(cat "$dir/home/data/.decided-sync.log" 2>/dev/null)"
  assert_grep '(shortcut: pending sc-6523)' "$dir/home/data/decided.md" "the entry should stay pending after the final failure"
  assert_grep 'df-3' "$dir/home/state/inbox"/* "a note for the primary was not queued"
  assert_equals 2 "$(grep -c 'comments' "$dir/curl.log")" "the job should try exactly the configured number of times"
  decide_run "$dir" audit >/dev/null && fail "audit should list the pending entry"
  out=$(decide_run "$dir" sync) || fail "sync failed: $out"
  assert_grep '(shortcut: sc-6523 ' "$dir/home/data/decided.md" "sync did not post the pending entry"
  pass "a failed post leaves the entry pending, queues one note for the primary, and sync posts it later"
}

fm_test_run \
  test_fast_fold_matches_full_fold \
  test_resolve_key_send_stays_fast_on_a_long_log \
  test_decide_returns_before_shortcut_answers \
  test_decide_without_story_files_a_chore_in_the_background \
  test_decide_final_failure_queues_a_note_and_sync_recovers
