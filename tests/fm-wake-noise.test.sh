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

test_known_wait_is_announced_once_then_quiet
test_wait_wakes_again_after_it_ends
test_daily_cap_is_one_wait_for_the_fleet
test_other_events_are_never_quiet
test_watcher_absorbs_a_repeated_known_wait
