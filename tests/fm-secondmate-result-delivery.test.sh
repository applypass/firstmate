#!/usr/bin/env bash
# fm-secondmate-result-delivery.test.sh - a secondmate's result must always reach
# the main firstmate by script, not by the mate model's memory
# (docs/secondmate-parent-channel.md). Replays the 2026-10-01 miss in a temp home
# pair: the mate acknowledges a marked request, then the worker's result exists
# only in its report and chat while the supervision branch records a captain
# verdict in the mate home.
#
#   1. fm-branch-report.sh in a seeded mate home also publishes a captain
#      verdict onto the parent channel, once only, as an uncorrelated
#      needs-decision that never closes a pending reply. Routine verdicts and a
#      main home publish nothing.
#   2. A handled steering record with no status line since it arrived is
#      reported once, and only after the worker's turn ends or the age bound
#      passes - never on the move alone; records handled in an inbox from
#      before this check are history.
#   3. End to end: with publication on, main's channel receives the result;
#      either way the acknowledged request stays open and escalates to main on
#      the age bound while the mate pane sits idle, and not before, until the
#      mate's own correlated report closes it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-result-delivery)
export FM_PENDING_REPLY_GRACE_SECS=120
export FM_PENDING_REPLY_ACK_SECS=1800

# A parent home plus a local mate home bound to it as <id>.
make_pair() {  # <name> <id> -> sets PARENT, MATE
  PARENT="$TMP_ROOT/$1-parent"
  MATE="$TMP_ROOT/$1-mate"
  mkdir -p "$PARENT/state" "$MATE/state"
  printf '%s\n' "$2" > "$MATE/.fm-secondmate-home"
  cat > "$MATE/.fm-secondmate-parent" <<EOT
schema=fm-secondmate-parent.v1
route=local
parent_home=$PARENT
EOT
}

branch_report() {  # <home> <task> <verdict> <summary>
  local home=$1 task=$2 verdict=$3 summary=$4
  printf 'turn=t1\nrows=1\ntasks=\nunscoped=1\nwake=heartbeat\nposture=attended\n' > "$home/state/.supervision-host-turn"
  env FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 \
    "$ROOT/bin/fm-branch-report.sh" --task "$task" --verdict "$verdict" --summary "$summary" 2>&1
}

phase_in() {  # <state> <corr>
  fm_pending_reply_get "$(fm_pending_reply_path "$1" "$2")" phase
}

test_captain_verdict_reaches_the_parent_channel_uncorrelated() {
  local corr status
  make_pair publish classify
  status="$PARENT/state/classify.status"
  export FM_PENDING_REPLY_NOW=1000
  corr=$(fm_pending_reply_create "$PARENT" "$PARENT/state" classify "follow-up")
  fm_pending_reply_mark_delivered "$PARENT/state" "$corr"
  branch_report "$MATE" fleet routine "nothing new" >/dev/null
  [ ! -s "$status" ] || fail "a routine verdict must publish nothing"
  # Even a summary that quotes the request's corr publishes no corr= token.
  branch_report "$MATE" fleet captain "follow-up finished for corr=$corr: 3 rows fixed" >/dev/null
  grep -q "^needs-decision \[at=[0-9]*\]: captain outcome for fleet: follow-up finished" "$status" \
    || fail "the outcome must reach the parent channel as needs-decision (got: $(cat "$status" 2>/dev/null))"
  [ "$(grep -c "follow-up finished" "$status")" = 1 ] || fail "one captain outcome must publish exactly one line"
  ! grep -q "corr=" "$status" || fail "a script-published outcome must carry no corr= (got: $(cat "$status"))"
  if fm_pending_reply_try_resolve "$PARENT/state" "$corr"; then
    fail "a script-published outcome must not resolve the pending reply"
  fi
  # Closing the request stays with the mate's own correlated report.
  FM_HOME="$MATE" "$ROOT/bin/fm-secondmate-report.sh" "done" "$corr" "3 rows fixed" >/dev/null
  fm_pending_reply_try_resolve "$PARENT/state" "$corr" || fail "the mate's correlated report must resolve it"
  pass "a captain verdict in a mate home reaches the parent channel uncorrelated and resolves nothing"
}

test_unrelated_captain_outcome_never_closes_a_pending_reply() {
  local corr status
  make_pair unrelated classify
  status="$PARENT/state/classify.status"
  export FM_PENDING_REPLY_NOW=2000
  corr=$(fm_pending_reply_create "$PARENT" "$PARENT/state" classify "follow-up")
  fm_pending_reply_mark_delivered "$PARENT/state" "$corr"
  branch_report "$MATE" other captain "worker other needs a login" >/dev/null
  grep -q "worker other needs a login" "$status" || fail "main must see the outcome"
  if fm_pending_reply_try_resolve "$PARENT/state" "$corr"; then
    fail "an unrelated captain outcome must not close the pending reply"
  fi
  [ "$(phase_in "$PARENT/state" "$corr")" = awaiting_report ] \
    || fail "the reply must stay open, got $(phase_in "$PARENT/state" "$corr")"
  pass "an unrelated captain outcome reaches main and leaves the open request open"
}

test_main_home_publishes_nothing() {
  local home="$TMP_ROOT/main-home"
  mkdir -p "$home/state"
  branch_report "$home" fleet captain "main outcome" | grep -q "recorded seq" || fail "main home must still record"
  [ -z "$(ls "$home/state"/*.status 2>/dev/null)" ] || fail "a main home must publish no status line"
  pass "a main home is unchanged"
}

test_silent_handled_waits_for_the_turn_end() {
  local state="$TMP_ROOT/silent/state" rec old
  mkdir -p "$state"
  # A record handled in an inbox from before this check is history.
  old=$(fm_task_inbox_write "$state" worker "old request")
  mv "$old" "$state/worker.inbox/handled/"
  rm "$state/worker.inbox/.silent-seen"
  touch "$state/worker.turn-ended"
  [ -z "$(fm_task_inbox_silent_handled "$state" worker)" ] || fail "the first run must only seed history"
  rec=$(fm_task_inbox_write "$state" worker "do the follow-up")
  # A turn end from before the move does not count.
  touch -t 200001010000 "$state/worker.turn-ended"
  mv "$rec" "$state/worker.inbox/handled/"
  [ -z "$(fm_task_inbox_silent_handled "$state" worker)" ] \
    || fail "the move alone must not report the request: the worker is still working"
  touch "$state/worker.turn-ended"
  [ "$(fm_task_inbox_silent_handled "$state" worker)" = "${rec##*/}" ] \
    || fail "a turn end with no status line since the request must report it"
  [ -z "$(fm_task_inbox_silent_handled "$state" worker)" ] || fail "each record is reported once"
  rec=$(fm_task_inbox_write "$state" worker "second request")
  mv "$rec" "$state/worker.inbox/handled/"
  printf 'done [at=%s]: result for request\n' "$(date +%s)" >> "$state/worker.status"
  touch "$state/worker.turn-ended"
  [ -z "$(fm_task_inbox_silent_handled "$state" worker)" ] || fail "a status line since the request satisfies it"
  rec=$(fm_task_inbox_write "$state" worker "ring only" fire-and-forget)
  mv "$rec" "$state/worker.inbox/handled/"
  touch -t 200001010000 "$state/worker.status"
  touch "$state/worker.turn-ended"
  [ -z "$(fm_task_inbox_silent_handled "$state" worker)" ] || fail "fire-and-forget records expect no result"
  pass "a handled request with no status line is reported once, after the worker's turn ends"
}

test_silent_handled_reports_after_the_age_bound() {
  local state="$TMP_ROOT/silent-age/state" rec
  mkdir -p "$state"
  # The first request of a new inbox is checked, not seeded as history.
  rec=$(fm_task_inbox_write "$state" worker "long job")
  : > "$state/worker.status"
  touch -t 200001010000 "$state/worker.status"
  mv "$rec" "$state/worker.inbox/handled/"
  [ -z "$(fm_task_inbox_silent_handled "$state" worker)" ] || fail "inside the age bound nothing is reported"
  [ "$(FM_TASK_INBOX_SILENT_AGE_SECS=0 fm_task_inbox_silent_handled "$state" worker)" = "${rec##*/}" ] \
    || fail "past the age bound the silent request must be reported without a turn end"
  pass "a handled request with no status line is reported once the age bound passes"
}

# The 2026-10-01 sequence. $1=publish|skip controls whether the supervision
# branch's captain verdict is recorded (fix 2 on or off). The mate pane is idle
# from the moment it relays, as a real mate pane is while its worker runs.
replay() {  # <publish|skip> -> sets PARENT, MATE, CORR
  local mode=$1
  make_pair "replay-$mode" classify
  export FM_PENDING_REPLY_NOW=5000
  CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" classify "classify follow-up")
  fm_pending_reply_mark_delivered "$PARENT/state" "$CORR"
  # The mate relays the request to its worker and acknowledges, as at 20:28.
  FM_HOME="$MATE" "$ROOT/bin/fm-secondmate-report.sh" working "$CORR" "relayed" >/dev/null
  fm_pending_reply_tick_one "$PARENT/state" "$CORR" idle ""
  export FM_PENDING_REPLY_NOW=5300
  fm_pending_reply_tick_one "$PARENT/state" "$CORR" idle ""
  [ "$(phase_of_replay)" = acknowledged ] \
    || fail "an idle mate pane while its worker runs must not escalate, got $(phase_of_replay)"
  # The worker finishes 15 minutes later: result only in report.md and chat.
  export FM_PENDING_REPLY_NOW=5900
  if [ "$mode" = publish ]; then
    branch_report "$MATE" worker captain "classify follow-up complete; see report.md" >/dev/null
  fi
  fm_pending_reply_tick_one "$PARENT/state" "$CORR" idle ""
  export FM_PENDING_REPLY_NOW=6800
  fm_pending_reply_tick_one "$PARENT/state" "$CORR" idle ""
}

test_replay_result_reaches_main() {
  replay publish
  grep -q "^needs-decision .*classify follow-up complete" "$PARENT/state/classify.status" \
    || fail "main's channel must receive the result"
  [ "$(phase_of_replay)" = escalated ] \
    || fail "the published outcome must not close the request; the age bound still fires, got $(phase_of_replay)"
  FM_HOME="$MATE" "$ROOT/bin/fm-secondmate-report.sh" "done" "$CORR" "classify follow-up complete" >/dev/null
  fm_pending_reply_tick_one "$PARENT/state" "$CORR" idle ""
  [ "$(phase_of_replay)" = resolved ] || fail "the mate's correlated report must resolve it, got $(phase_of_replay)"
  pass "replay: the result reaches main, and only the mate's correlated report closes the request"
}

test_replay_without_publication_escalates() {
  replay skip
  [ "$(phase_of_replay)" = escalated ] || fail "an acknowledged request past the age bound must escalate, got $(phase_of_replay)"
  grep -q "pending-reply-unreported: task=classify .*no result reached main" "$PARENT/state/classify.status" \
    || fail "the escalation must name the mate and say no result reached main"
  pass "replay: with publication disabled the acknowledged request escalates to main on the age bound"
}

phase_of_replay() {
  fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$CORR")" phase
}

test_captain_verdict_reaches_the_parent_channel_uncorrelated
test_unrelated_captain_outcome_never_closes_a_pending_reply
test_main_home_publishes_nothing
test_silent_handled_waits_for_the_turn_end
test_silent_handled_reports_after_the_age_bound
test_replay_result_reaches_main
test_replay_without_publication_escalates

printf 'ok - all secondmate result delivery tests passed\n'
