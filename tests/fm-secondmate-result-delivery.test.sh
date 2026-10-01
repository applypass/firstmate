#!/usr/bin/env bash
# fm-secondmate-result-delivery.test.sh - a secondmate's result must always reach
# the main firstmate by script, not by the mate model's memory
# (docs/secondmate-parent-channel.md). Replays the 2026-10-01 miss in a temp home
# pair: the mate acknowledges a marked request, then the worker's result exists
# only in its report and chat while the supervision branch records a captain
# verdict in the mate home.
#
#   1. fm-branch-report.sh in a seeded mate home also publishes a captain
#      verdict onto the parent channel, with corr= when exactly one marked
#      request is open, once only; routine verdicts and a main home publish
#      nothing.
#   2. A handled steering record with no status line appended since it arrived
#      is reported once by fm_task_inbox_silent_handled.
#   3. End to end: with publication on, main's channel receives the result and
#      the pending reply resolves; with it disabled, the acknowledged-and-idle
#      request still escalates to main.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-result-delivery)
export FM_PENDING_REPLY_GRACE_SECS=120

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

branch_report() {  # <home> <verdict> <summary>
  local home=$1 verdict=$2 summary=$3
  printf 'turn=t1\nrows=1\ntasks=\nunscoped=1\nwake=heartbeat\nposture=attended\n' > "$home/state/.supervision-host-turn"
  env FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 \
    "$ROOT/bin/fm-branch-report.sh" --task fleet --verdict "$verdict" --summary "$summary" 2>&1
}

test_captain_verdict_in_a_mate_home_reaches_the_parent_channel() {
  local corr status
  make_pair publish classify
  status="$PARENT/state/classify.status"
  export FM_PENDING_REPLY_NOW=1000
  corr=$(fm_pending_reply_create "$PARENT" "$PARENT/state" classify "follow-up")
  fm_pending_reply_mark_delivered "$PARENT/state" "$corr"
  branch_report "$MATE" routine "nothing new" >/dev/null
  [ ! -s "$status" ] || fail "a routine verdict must publish nothing"
  branch_report "$MATE" captain "follow-up finished: 3 rows fixed" >/dev/null
  grep -q "^done \[at=[0-9]*\] \[corr=$corr\]: follow-up finished: 3 rows fixed" "$status" \
    || grep -q "corr=$corr.*follow-up finished: 3 rows fixed" "$status" \
    || fail "the captain outcome must reach the parent channel with corr (got: $(cat "$status" 2>/dev/null))"
  [ "$(grep -c "follow-up finished" "$status")" = 1 ] || fail "one captain outcome must publish exactly one line"
  fm_pending_reply_try_resolve "$PARENT/state" "$corr" || fail "the published line must resolve the pending reply"
  # The mate's own later report is harmless: the record is already resolved.
  FM_HOME="$MATE" "$ROOT/bin/fm-secondmate-report.sh" done "$corr" "same result" >/dev/null
  fm_pending_reply_try_resolve "$PARENT/state" "$corr" || fail "a later helper line must stay harmless"
  pass "a captain verdict recorded in a mate home is published on the parent channel with corr"
}

test_without_one_open_request_the_line_carries_no_corr() {
  local status
  make_pair nocorr classify
  status="$PARENT/state/classify.status"
  branch_report "$MATE" captain "finding for the captain" >/dev/null
  grep -q "finding for the captain" "$status" || fail "the outcome must still be published"
  ! grep -q "corr=" "$status" || fail "no corr without exactly one open request"
  pass "an outcome with no single open request is published without corr"
}

test_main_home_publishes_nothing() {
  local home="$TMP_ROOT/main-home"
  mkdir -p "$home/state"
  branch_report "$home" captain "main outcome" | grep -q "recorded seq" || fail "main home must still record"
  [ -z "$(ls "$home/state"/*.status 2>/dev/null)" ] || fail "a main home must publish no status line"
  pass "a main home is unchanged"
}

test_silent_handled_record_is_reported_once() {
  local state="$TMP_ROOT/silent/state" rec out at
  mkdir -p "$state"
  rec=$(fm_task_inbox_write "$state" worker "do the follow-up")
  mv "$rec" "$state/worker.inbox/handled/"
  # A status line appended before the request arrived does not count.
  : > "$state/worker.status"
  touch -t 200001010000 "$state/worker.status"
  out=$(fm_task_inbox_silent_handled "$state" worker)
  [ "$out" = "${rec##*/}" ] || fail "a handled record with no later status line must be reported (got '$out')"
  [ -z "$(fm_task_inbox_silent_handled "$state" worker)" ] || fail "each record is reported once"
  rec=$(fm_task_inbox_write "$state" worker "second request")
  mv "$rec" "$state/worker.inbox/handled/"
  printf 'done [at=%s]: result for request\n' "$(date +%s)" >> "$state/worker.status"
  [ -z "$(fm_task_inbox_silent_handled "$state" worker)" ] || fail "a status line since the request satisfies it"
  rec=$(fm_task_inbox_write "$state" worker "ring only" fire-and-forget)
  mv "$rec" "$state/worker.inbox/handled/"
  touch -t 200001010000 "$state/worker.status"
  [ -z "$(fm_task_inbox_silent_handled "$state" worker)" ] || fail "fire-and-forget records expect no result"
  at=$(rec=$(fm_task_inbox_write "$state" worker "old"); sed -i.bak 's/^at=.*/at=2001-01-01T00:00:00Z/' "$rec"; rm -f "$rec.bak"; mv "$rec" "$state/worker.inbox/handled/"; printf '%s' "$rec")
  [ -z "$(fm_task_inbox_silent_handled "$state" worker)" ] || fail "records older than the lookback are history"
  pass "a handled request with no status line since it arrived is reported once"
}

# The 2026-10-01 sequence. $1=publish|skip controls whether the supervision
# branch's captain verdict is recorded (fix 2 on or off).
replay() {  # <publish|skip> -> sets PARENT, MATE, CORR
  local mode=$1
  make_pair "replay-$mode" classify
  export FM_PENDING_REPLY_NOW=5000
  CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" classify "classify follow-up")
  fm_pending_reply_mark_delivered "$PARENT/state" "$CORR"
  # The mate acknowledges through the script, as it did at 20:28.
  FM_HOME="$MATE" "$ROOT/bin/fm-secondmate-report.sh" working "$CORR" "relayed" >/dev/null
  fm_pending_reply_tick_one "$PARENT/state" "$CORR" busy ""
  # The worker finishes: result only in report.md and chat, no status line.
  export FM_PENDING_REPLY_NOW=5100
  fm_pending_reply_tick_one "$PARENT/state" "$CORR" idle ""
  if [ "$mode" = publish ]; then
    branch_report "$MATE" captain "classify follow-up complete; see report.md" >/dev/null
  fi
  export FM_PENDING_REPLY_NOW=5400
  fm_pending_reply_tick_one "$PARENT/state" "$CORR" idle ""
}

test_replay_result_reaches_main() {
  replay publish
  grep -q "classify follow-up complete" "$PARENT/state/classify.status" \
    || fail "main's channel must receive the result"
  [ "$(phase_of_replay)" = resolved ] || fail "the pending reply must resolve, got $(phase_of_replay)"
  ! grep -q "pending-reply-unreported" "$PARENT/state/classify.status" || fail "no escalation once the result arrived"
  pass "replay: the result reaches main and closes the pending reply"
}

test_replay_without_publication_escalates() {
  replay skip
  [ "$(phase_of_replay)" = escalated ] || fail "an acknowledged, idle, silent request must escalate, got $(phase_of_replay)"
  grep -q "pending-reply-unreported: task=classify .*no result reached main" "$PARENT/state/classify.status" \
    || fail "the escalation must name the mate and say no result reached main"
  pass "replay: with publication disabled the acknowledged request still escalates to main"
}

phase_of_replay() {
  fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$CORR")" phase
}

test_captain_verdict_in_a_mate_home_reaches_the_parent_channel
test_without_one_open_request_the_line_carries_no_corr
test_main_home_publishes_nothing
test_silent_handled_record_is_reported_once
test_replay_result_reaches_main
test_replay_without_publication_escalates

printf 'ok - all secondmate result delivery tests passed\n'
