#!/usr/bin/env bash
# shellcheck disable=SC1091
# Fork-only: behavior tests for the wake-noise cuts in bin/fm-wake-noise-lib.sh and their
# wiring in the watcher's signal triage (bin/fm-watch.sh). tests/fm-wake-noise-replay.test.sh
# counts the effect over one whole day; these cases pin each rule on its own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-noise-lib.sh
. "$ROOT/bin/fm-wake-noise-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-noise)
export TZ=UTC

NOW=$(date +%s)
utc_stamp() { date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%MZ; }
LATER=$(utc_stamp $((NOW + 7200)))
PAST=$(utc_stamp $((NOW - 7200)))

test_known_wait_is_announced_once_then_quiet() {
  local state="$TMP_ROOT/kw1"
  local ev="blocked [at=$NOW]: external-wait until=$LATER: vendor fix"
  mkdir -p "$state"
  fm_noise_span_quiet "$state" mate1 "$ev" && fail "the first sight of a known wait must wake"
  fm_noise_span_quiet "$state" mate1 "$ev" || fail "the same wait again must stay quiet"
  fm_noise_span_quiet "$state" mate2 "$ev" && fail "another task's wait is its own and wakes once"
  fm_noise_span_quiet "$state" mate2 "$ev" || fail "and then stays quiet"
  pass "a known wait wakes once, then stays quiet until it ends"
}

test_wait_wakes_again_after_it_ends() {
  local state="$TMP_ROOT/kw2"
  local ev="blocked [at=$NOW]: external-wait until=$PAST: vendor fix"
  mkdir -p "$state"
  fm_noise_span_quiet "$state" mate1 "$ev" && fail "an ended wait is not quiet"
  fm_noise_span_quiet "$state" mate1 "$ev" && fail "an ended wait is announced each time"
  pass "a wait whose time has passed is not quiet"
}

test_daily_cap_is_one_wait_for_the_fleet() {
  local state="$TMP_ROOT/kw3"
  mkdir -p "$state"
  fm_noise_span_quiet "$state" mate1 "blocked [at=$NOW]: system: resource-exhausted (daily quota cap) external-wait until=$LATER: daily quota stop: refusing" \
    && fail "the first cap line wakes"
  fm_noise_span_quiet "$state" mate2 "blocked [at=$NOW]: resource-exhausted (daily quota cap) external-wait until=$LATER: out of daily quota" \
    || fail "a second task's cap line is the same fleet wait"
  fm_noise_span_quiet "$state" mate3 "paused [at=$NOW]: system: daily quota stop: holding every new worker launch until $LATER" \
    || fail "the hold line for the same clear time is the same wait"
  pass "the daily quota cap is one wait for the whole fleet"
}

test_other_events_are_never_quiet() {
  local state="$TMP_ROOT/kw4"
  mkdir -p "$state"
  fm_noise_span_quiet "$state" mate1 "blocked [at=$NOW]: captain-decision: pick a or b" && fail "a decision is not a known wait"
  fm_noise_span_quiet "$state" mate1 "done [at=$NOW]: finished" && fail "a done line is not a known wait"
  fm_noise_span_quiet "$state" mate1 "blocked [at=$NOW]: external-wait: no end time" && fail "a wait with no end time is not known"
  # One loud event in a span keeps the whole span loud, even after the wait was announced.
  local ev="blocked [at=$NOW]: external-wait until=$LATER: vendor fix"
  fm_noise_span_quiet "$state" mate1 "$ev" && fail "first sight"
  fm_noise_span_quiet "$state" mate1 "$ev ; done [at=$NOW]: finished" && fail "a span with a done line wakes"
  # A wait that rode a loud span was announced by that wake, so it is quiet afterwards.
  local ev2="blocked [at=$NOW]: external-wait until=$LATER: another vendor fix"
  fm_noise_span_quiet "$state" mate1 "done [at=$NOW]: finished ; $ev2" && fail "mixed span wakes"
  fm_noise_span_quiet "$state" mate1 "$ev2" || fail "a wait announced inside a loud span stays quiet after"
  pass "only a span made of announced known waits is quiet"
}

test_watcher_absorbs_a_repeated_known_wait() {
  local home="$TMP_ROOT/watch" out="$TMP_ROOT/watch.out" pid i=0
  mkdir -p "$home/state" "$home/config" "$home/data"
  : > "$home/state/wtask.meta"
  printf 'blocked [at=%s]: external-wait until=%s: vendor fix\n' "$NOW" "$LATER" > "$home/state/wtask.status"
  FM_HOME=$home FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_NEVER_WAIT=off bash "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  while [ "$i" -lt 150 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fail "the first sight of the wait did not wake the watcher"; fi
  wait "$pid" 2>/dev/null
  assert_contains "$(cat "$out")" "signal" "the first sight wakes the watcher"
  # The supervisor has drained that wake. The same wait again: the watcher stays up.
  rm -f "$home/state/.wake-queue" "$home/state/.watcher-down"
  printf 'blocked [at=%s]: external-wait until=%s: vendor fix\n' "$((NOW + 60))" "$LATER" >> "$home/state/wtask.status"
  FM_HOME=$home FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_NEVER_WAIT=off bash "$ROOT/bin/fm-watch.sh" > "$out.2" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 60 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    pass "the watcher absorbs the same known wait the second time"
  else
    wait "$pid" 2>/dev/null
    fail "the repeated known wait woke the watcher: $(cat "$out.2")"
  fi
}

test_recent_activity_is_not_a_missed_reply() {
  local state="$TMP_ROOT/act" mate="$TMP_ROOT/act-mate"
  mkdir -p "$state" "$mate/data/ticket-ledger"
  printf 'kind=secondmate\nhome=%s\n' "$mate" > "$state/m1.meta"
  : > "$state/m1.status"
  fm_noise_task_recently_active "$state" m1 "$NOW" && fail "no sign of life is not activity"
  printf 'working [at=%s]: reading the code\n' "$((NOW - 300))" >> "$state/m1.status"
  fm_noise_task_recently_active "$state" m1 "$NOW" || fail "a status line 5 minutes ago is activity"
  fm_noise_task_recently_active "$state" m1 "$((NOW + 3000))" && fail "a 55 minute old line is not activity"
  # A turn in the mate's own ledger counts.
  printf '{"at":%s,"event":"turn","session":"x"}\n' "$((NOW + 2900))" >> "$mate/data/ticket-ledger/_fleet-overhead.jsonl"
  fm_noise_task_recently_active "$state" m1 "$((NOW + 3000))" || fail "a recent ledger turn is activity"
  # The system's own lines are not the mate's activity.
  : > "$state/m2.status"
  printf 'blocked [key=pending-reply-0123456789abcdef] [at=%s]: pending-reply-missed: x\n' "$NOW" >> "$state/m2.status"
  printf 'blocked [at=%s]: system: daily quota stop: x\n' "$NOW" >> "$state/m2.status"
  fm_noise_task_recently_active "$state" m2 "$NOW" && fail "system lines are not activity"
  pass "recent mate activity is told apart from system lines and old lines"
}

test_open_problem_wakes_once_and_repeats_are_counted() {
  local state="$TMP_ROOT/prob" ev="needs-decision [key=captain-hold-ab12-1] [at=$NOW]: pick a or b"
  mkdir -p "$state"
  : > "$state/m1.status"
  printf '%s\n' "$ev" >> "$state/m1.status"
  fm_noise_span_quiet "$state" m1 "$ev" && fail "a new problem wakes"
  printf '%s\n' "$ev" >> "$state/m1.status"
  fm_noise_span_quiet "$state" m1 "$ev" || fail "the same open problem stated again is quiet"
  fm_noise_span_quiet "$state" m1 "$ev" || fail "and again"
  assert_grep " 2 captain-hold-ab12-1" "$(ls "$state"/wake-noise/problem-*)" "two repeats are counted"
  fm_noise_span_quiet "$state" m2 "$ev" && fail "another task's problem is its own"
  # A resolved line closes the problem: the next statement of the key is new.
  printf 'resolved [key=captain-hold-ab12-1] [at=%s]: answered\n' "$((NOW + 10))" >> "$state/m1.status"
  fm_noise_span_quiet "$state" m1 "needs-decision [key=captain-hold-ab12-1] [at=$((NOW + 20))]: pick again" && fail "a closed problem opens anew"
  # Outcome reports are one each and never coalesce.
  local out="blocked [key=branch-outcome-7] [at=$NOW]: captain outcome for m1: x"
  fm_noise_span_quiet "$state" m1 "$out" && fail "first outcome"
  fm_noise_span_quiet "$state" m1 "$out" && fail "an outcome line is never coalesced"
  pass "an open problem wakes once; repeats are counted until it is resolved"
}

test_routine_notices_are_held_for_the_next_real_wake() {
  local state="$TMP_ROOT/held" r="done [key=child-outcome-ab12-done] [at=$NOW]: a child finished"
  mkdir -p "$state"
  fm_noise_span_routine "$state" m1 "$r" 100 || fail "a lone routine notice is held"
  [ "$(fm_noise_held_start "$state" m1 250)" = 100 ] || fail "the next span starts where the held one began"
  fm_noise_span_routine "$state" m1 "$r ; $r" 100 || fail "more routine notices are held too"
  fm_noise_span_routine "$state" m1 "$r ; done [at=$NOW]: real work finished" 100 && fail "a real event ends the hold"
  [ "$(fm_noise_held_start "$state" m1 250)" = 250 ] || fail "the hold is cleared once a real event wakes"
  fm_noise_span_routine "$state" m1 "blocked [at=$NOW]: captain-decision: pick" 100 && fail "a decision is never routine"
  # A hold ends after its limit, so a lone notice still arrives.
  FM_NOISE_HOLD_SECS=0 fm_noise_span_routine "$state" m2 "$r" 10 || fail "first sight is held"
  FM_NOISE_HOLD_SECS=0 fm_noise_span_routine "$state" m2 "$r" 10 && fail "a hold past its limit wakes"
  pass "routine notices wait for the next real wake, up to the hold limit"
}

test_watcher_holds_a_routine_notice_then_carries_it() {
  local home="$TMP_ROOT/watch2" out="$TMP_ROOT/watch2.out" pid i=0
  mkdir -p "$home/state" "$home/config" "$home/data"
  : > "$home/state/rtask.meta"
  printf 'done [key=child-outcome-ab12-done] [at=%s]: a child finished\n' "$NOW" > "$home/state/rtask.status"
  FM_HOME=$home FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_NEVER_WAIT=off bash "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  while [ "$i" -lt 60 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; fail "a lone routine notice woke the watcher: $(cat "$out")"; }
  # A real event arrives: the watcher wakes and the wake covers both lines.
  printf 'done [at=%s]: real work finished\n' "$((NOW + 5))" >> "$home/state/rtask.status"
  i=0
  while [ "$i" -lt 150 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fail "the real event did not wake the watcher"; fi
  wait "$pid" 2>/dev/null
  assert_contains "$(cat "$out")" "signal" "the real event wakes the watcher"
  pass "the watcher holds a routine notice and wakes on the next real event"
}

test_known_wait_is_announced_once_then_quiet
test_watcher_holds_a_routine_notice_then_carries_it
test_routine_notices_are_held_for_the_next_real_wake
test_open_problem_wakes_once_and_repeats_are_counted
test_recent_activity_is_not_a_missed_reply
test_wait_wakes_again_after_it_ends
test_daily_cap_is_one_wait_for_the_fleet
test_other_events_are_never_quiet
test_watcher_absorbs_a_repeated_known_wait
