#!/usr/bin/env bash
# shellcheck disable=SC1091
# Fork-only: behavior tests for the wake-noise cuts in bin/fm-wake-noise-lib.sh and their
# wiring in the watcher's signal triage (bin/fm-watch.sh). tests/fm-wake-noise-replay.test.sh
# counts the effect over one whole day; these cases pin each rule on its own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The reply-timer library brings the shared classifier and the wake-noise library with it.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"

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
  # Only activity after <since> counts.
  fm_noise_task_recently_active "$state" m1 "$NOW" "$((NOW - 300))" && fail "activity at <since> is not after it"
  fm_noise_task_recently_active "$state" m1 "$NOW" "$((NOW - 301))" || fail "activity after <since> counts"
  fm_noise_task_recently_active "$state" m1 "$((NOW + 3000))" && fail "a 55 minute old line is not activity"
  # A turn in the mate's own ledger counts.
  printf '{"at":%s,"event":"turn","session":"x"}\n' "$((NOW + 2900))" >> "$mate/data/ticket-ledger/_fleet-overhead.jsonl"
  fm_noise_task_recently_active "$state" m1 "$((NOW + 3000))" || fail "a recent ledger turn is activity"
  # The system's own lines are not the mate's activity.
  : > "$state/m2.status"
  printf 'blocked [key=pending-reply-0123456789abcdef] [at=%s]: pending-reply-missed: x\n' "$NOW" >> "$state/m2.status"
  printf 'blocked [at=%s]: system: a machine-written note\n' "$NOW" >> "$state/m2.status"
  fm_noise_task_recently_active "$state" m2 "$NOW" && fail "system lines are not activity"
  pass "recent mate activity is told apart from system lines and old lines"
}

# Append <line> to <status-file> and print the span offset it starts at.
append_line() {  # <status-file> <line>
  wc -c < "$1" | tr -d ' '
  printf '%s\n' "$2" >> "$1"
}

test_open_problem_wakes_once_and_repeats_are_counted() {
  local state="$TMP_ROOT/prob" ev="needs-decision [key=merge-ok] [at=$NOW]: pick a or b" off
  mkdir -p "$state"
  : > "$state/m1.status"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" && fail "a new problem wakes"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" || fail "the same open problem stated again is quiet"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" || fail "and again"
  [ "$(cat "$state"/wake-noise/problem-*)" = "2 merge-ok" ] || fail "two repeats are counted: $(cat "$state"/wake-noise/problem-*)"
  : > "$state/m2.status"
  off=$(append_line "$state/m2.status" "$ev")
  fm_noise_span_quiet "$state" m2 "$ev" "$off" && fail "another task's problem is its own"
  # A resolved line closes the problem: the next statement of the key is new.
  printf 'resolved [key=merge-ok] [at=%s]: answered\n' "$((NOW + 10))" >> "$state/m1.status"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" && fail "a resolved problem opens anew"
  # Outcome reports are one each and never coalesce.
  local out="blocked [key=branch-outcome-7] [at=$NOW]: captain outcome for m1: x"
  off=$(append_line "$state/m1.status" "$out")
  fm_noise_span_quiet "$state" m1 "$out" "$off" && fail "first outcome"
  off=$(append_line "$state/m1.status" "$out")
  fm_noise_span_quiet "$state" m1 "$out" "$off" && fail "an outcome line is never coalesced"
  pass "an open problem wakes once; repeats are counted until it is resolved"
}

test_open_problem_closes_where_the_shared_fold_closes_it() {
  local state="$TMP_ROOT/prob2" ev="needs-decision [key=merge-ok] [at=$NOW]: pick a or b" off
  mkdir -p "$state"
  : > "$state/m1.status"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" && fail "a new problem wakes"
  # The supervisor takes the decision over; the mate asking again is a new decision.
  printf 'captain-held [key=merge-ok] [at=%s]: the captain owns this now\n' "$((NOW + 10))" >> "$state/m1.status"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" && fail "a captain-held transfer closes the problem"
  # A ship's terminal line clears every open decision.
  printf 'kind=ship\n' > "$state/s1.meta"
  : > "$state/s1.status"
  off=$(append_line "$state/s1.status" "$ev")
  fm_noise_span_quiet "$state" s1 "$ev" "$off" && fail "a new problem wakes"
  printf 'done [at=%s]: shipped\n' "$((NOW + 10))" >> "$state/s1.status"
  off=$(append_line "$state/s1.status" "$ev")
  fm_noise_span_quiet "$state" s1 "$ev" "$off" && fail "a terminal done line closes the problem"
  # A respawned task starts a new status file: its first ask is new.
  : > "$state/m1.status"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" && fail "a respawned task's problem is new"
  pass "an open problem closes on every event the shared decision fold closes it on"
}

test_open_problem_with_a_new_fact_wakes() {
  local state="$TMP_ROOT/prob3" off ev
  mkdir -p "$state"
  : > "$state/m1.status"
  ev="blocked [key=deploy] [at=$NOW]: CI failing"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" && fail "a new problem wakes"
  ev="blocked [key=deploy] [at=$((NOW + 60))]: CI failing"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" || fail "the same verb and note again is a repeat"
  ev="blocked [key=deploy] [at=$((NOW + 120))]: CI failing on a new test"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" && fail "a changed note is a new fact"
  ev="needs-decision [key=deploy] [at=$((NOW + 180))]: CI failing on a new test"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_quiet "$state" m1 "$ev" "$off" && fail "a changed verb is a new fact"
  pass "a same-key line with a changed verb or note wakes"
}

test_recent_activity_only_holds_an_acknowledged_reply() {
  local home="$TMP_ROOT/reply" state corr sent="$TMP_ROOT/reply-sent.log" hook="$TMP_ROOT/reply-hook"
  state="$home/state"
  mkdir -p "$state"
  : > "$sent"
  # shellcheck disable=SC2016 # $1 belongs to the generated hook, not this shell.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> %q\n' "$sent" > "$hook"
  chmod +x "$hook"
  # The first repost is not held back by activity: the mate never answered.
  FM_PENDING_REPLY_NOW=5000 FM_PENDING_REPLY_GRACE_SECS=0 FM_PENDING_REPLY_SEND_HOOK=$hook bash -c '
    . "$1/bin/fm-pending-reply-lib.sh"
    corr=$(fm_pending_reply_create "$2" "$2/state" r1 "status of phase 7")
    fm_pending_reply_mark_delivered "$2/state" "$corr"
    printf "working [at=5100]: running tests\n" >> "$2/state/r1.status"
    fm_pending_reply_observe_busy "$2/state" "$corr" busy
    fm_pending_reply_observe_busy "$2/state" "$corr" idle
    FM_PENDING_REPLY_NOW=5300 fm_pending_reply_send_recovery "$2/state" "$corr"' _ "$ROOT" "$home" \
    || fail "recent activity must not hold back the first repost"
  assert_grep "r1" "$sent" "the first repost went out"
  # Acknowledged, past the bound: activity from before the request does not count.
  export FM_PENDING_REPLY_ACK_SECS=900 FM_PENDING_REPLY_WAKE_HOLD_SECS=0
  export FM_PENDING_REPLY_NOW=6000
  printf 'working [at=5900]: earlier work\n' > "$state/r2.status"
  corr=$(fm_pending_reply_create "$home" "$state" r2 "classify follow-up")
  fm_pending_reply_mark_delivered "$state" "$corr"
  printf 'working [corr=%s]: on it\n' "$corr" >> "$state/r2.status"
  fm_pending_reply_tick_one "$state" "$corr" idle ""
  [ "$(phase_of_rec "$state" "$corr")" = acknowledged ] || fail "setup: r2 is acknowledged"
  export FM_PENDING_REPLY_NOW=7000
  fm_pending_reply_tick_one "$state" "$corr" idle ""
  [ "$(phase_of_rec "$state" "$corr")" = escalated ] \
    || fail "activity before the request must not hold back the escalation, got $(phase_of_rec "$state" "$corr")"
  # Acknowledged, past the bound, with progress since the request: not a missed reply.
  export FM_PENDING_REPLY_NOW=6000
  : > "$state/r3.status"
  corr=$(fm_pending_reply_create "$home" "$state" r3 "classify follow-up")
  fm_pending_reply_mark_delivered "$state" "$corr"
  printf 'working [corr=%s]: on it\n' "$corr" >> "$state/r3.status"
  fm_pending_reply_tick_one "$state" "$corr" idle ""
  printf 'working [at=6500]: halfway\n' >> "$state/r3.status"
  export FM_PENDING_REPLY_NOW=7000
  fm_pending_reply_tick_one "$state" "$corr" idle ""
  [ "$(phase_of_rec "$state" "$corr")" = acknowledged ] \
    || fail "an acknowledged mate with progress since the request is not a missed reply, got $(phase_of_rec "$state" "$corr")"
  unset FM_PENDING_REPLY_NOW FM_PENDING_REPLY_ACK_SECS FM_PENDING_REPLY_WAKE_HOLD_SECS
  pass "recent activity since the request holds back only an acknowledged reply's escalation"
}

phase_of_rec() { fm_pending_reply_get "$(fm_pending_reply_path "$1" "$2")" phase; }

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

test_watcher_releases_a_held_notice_after_its_limit() {
  local home="$TMP_ROOT/watch3" out="$TMP_ROOT/watch3.out" pid i=0
  mkdir -p "$home/state" "$home/config" "$home/data"
  : > "$home/state/htask.meta"
  printf 'done [key=child-outcome-cd34-done] [at=%s]: a child finished\n' "$NOW" > "$home/state/htask.status"
  # No later line arrives: the held notice must still wake once its hold ends.
  FM_HOME=$home FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_NEVER_WAIT=off FM_NOISE_HOLD_SECS=3 \
    bash "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  while [ "$i" -lt 150 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fail "a held notice past its limit never woke the watcher"; fi
  wait "$pid" 2>/dev/null
  assert_contains "$(cat "$out")" "signal" "the held notice wakes the watcher"
  [ ! -e "$home/state/wake-noise/held-htask" ] || fail "the released hold is cleared"
  pass "a held routine notice arrives on its own once its hold ends"
}

test_watcher_wakes_on_a_captain_held_transfer_beside_a_held_notice() {
  local home="$TMP_ROOT/watch4" out="$TMP_ROOT/watch4.out" pid i=0
  mkdir -p "$home/state" "$home/config" "$home/data"
  : > "$home/state/ctask.meta"
  printf 'done [key=child-outcome-ef56-done] [at=%s]: a child finished\n' "$NOW" > "$home/state/ctask.status"
  FM_HOME=$home FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_NEVER_WAIT=off \
    bash "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  while [ "$i" -lt 40 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; fail "a lone routine notice woke the watcher: $(cat "$out")"; }
  # The supervisor's decision moves to the captain: that transfer must wake, hold or not.
  printf 'captain-held [key=merge-ok] [at=%s]: tracked by the captain\n' "$((NOW + 5))" >> "$home/state/ctask.status"
  i=0
  while [ "$i" -lt 150 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fail "a captain-held transfer beside a held notice did not wake"; fi
  wait "$pid" 2>/dev/null
  assert_contains "$(cat "$out")" "signal" "the transfer wakes the watcher"
  [ ! -e "$home/state/wake-noise/held-ctask" ] || fail "the hold ends with the wake that carried it"
  pass "a captain-held transfer is never absorbed by the routine hold"
}

test_captain_held_span_is_never_quiet() {
  local state="$TMP_ROOT/cheld" off ev="blocked [at=$NOW]: external-wait until=$LATER: vendor fix"
  mkdir -p "$state/wake-noise"
  : > "$state/m1.status"
  off=$(append_line "$state/m1.status" "$ev")
  fm_noise_span_held_by_captain "$state" m1 "$state/m1.status" "$off" && fail "a span with no transfer is not held by the captain"
  printf '1 0\n' > "$state/wake-noise/held-m1"
  off=$(append_line "$state/m1.status" "captain-held [key=merge-ok] [at=$NOW]: tracked by the captain")
  fm_noise_span_held_by_captain "$state" m1 "$state/m1.status" "$off" || fail "a span with a transfer is held by the captain"
  [ ! -e "$state/wake-noise/held-m1" ] || fail "a transfer ends the routine hold"
  pass "a span holding a captain-held transfer is never absorbed"
}

test_known_wait_is_announced_once_then_quiet
test_watcher_holds_a_routine_notice_then_carries_it
test_routine_notices_are_held_for_the_next_real_wake
test_open_problem_wakes_once_and_repeats_are_counted
test_open_problem_closes_where_the_shared_fold_closes_it
test_open_problem_with_a_new_fact_wakes
test_recent_activity_only_holds_an_acknowledged_reply
test_watcher_releases_a_held_notice_after_its_limit
test_watcher_wakes_on_a_captain_held_transfer_beside_a_held_notice
test_captain_held_span_is_never_quiet
test_recent_activity_is_not_a_missed_reply
test_wait_wakes_again_after_it_ends
test_other_events_are_never_quiet
test_watcher_absorbs_a_repeated_known_wait
