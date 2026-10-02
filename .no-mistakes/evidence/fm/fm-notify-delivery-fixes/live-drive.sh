#!/usr/bin/env bash
# Live drive of the sc-6090 fixes against two disposable lab homes.
set -u
R=$PWD
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
P=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); M=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$P" >/dev/null; bin/fm-lab-home.sh create "$M" >/dev/null
trap 'rm -rf "$P" "$M"' EXIT
printf 'classify\n' > "$M/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$M/.fm-secondmate-parent"
. bin/fm-pending-reply-lib.sh
export FM_PENDING_REPLY_GRACE_SECS=120 FM_PENDING_REPLY_ACK_SECS=1800
phase() { fm_pending_reply_get "$(fm_pending_reply_path "$P/state" "$CORR")" phase; }
br() { printf 'turn=t1\nrows=1\ntasks=\nunscoped=1\nwake=heartbeat\nposture=attended\n' > "$M/state/.supervision-host-turn"
  env FM_HOME="$M" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 bin/fm-branch-report.sh "$@"; echo "  [rc=$?]"; }

echo "=== S1: main sends marked request; mate acknowledges with working: relayed ==="
export FM_PENDING_REPLY_NOW=5000
CORR=$(fm_pending_reply_create "$P" "$P/state" classify "classify follow-up"); fm_pending_reply_mark_delivered "$P/state" "$CORR"
echo "corr=$CORR phase=$(phase)"
FM_HOME="$M" bin/fm-secondmate-report.sh working "$CORR" "relayed"
echo "parent channel:"; sed 's/^/  /' "$P/state/classify.status"
fm_pending_reply_tick_one "$P/state" "$CORR" idle ""
echo "after tick at t+0 (mate pane idle): phase=$(phase)   <- must NOT be resolved"
export FM_PENDING_REPLY_NOW=6000; fm_pending_reply_tick_one "$P/state" "$CORR" idle ""
echo "after tick at t+1000s: phase=$(phase)   <- still open, below 1800s ack bound"

echo; echo "=== S2: captain verdict without --kind is refused ==="
br --task worker --verdict captain --summary "classify follow-up complete"
ls "$M/state/branch-outcomes.jsonl" 2>/dev/null || echo "  outcome store: nothing recorded"

echo; echo "=== S3: captain verdict --kind result in mate home publishes to MAIN's channel ==="
br --task worker --verdict captain --kind result --summary "classify follow-up complete for corr=$CORR; see report.md"
echo "parent channel:"; sed 's/^/  /' "$P/state/classify.status"
echo "phase after publish tick: $(fm_pending_reply_tick_one "$P/state" "$CORR" idle ""; phase)  <- uncorrelated publish must not close it"
echo "--- decision and blocker kinds ---"
br --task worker --verdict captain --kind decision --summary "pick schema A or B"
br --task other --verdict captain --kind blocker --summary "worker other needs a login"
br --task worker --verdict routine --summary "nothing new"
echo "parent channel:"; sed 's/^/  /' "$P/state/classify.status"

echo; echo "=== S4: acknowledged-only request escalates on the age bound ==="
export FM_PENDING_REPLY_NOW=6900; fm_pending_reply_tick_one "$P/state" "$CORR" idle ""
echo "after tick at t+1900s: phase=$(phase)"
grep pending-reply-unreported "$P/state/classify.status" | sed 's/^/  /'
echo "--- mate's correlated done closes it ---"
FM_HOME="$M" bin/fm-secondmate-report.sh done "$CORR" "classify follow-up complete"
fm_pending_reply_tick_one "$P/state" "$CORR" idle ""; echo "phase=$(phase)"

echo; echo "=== S5: main home records a captain outcome and publishes nothing ==="
printf 'turn=t1\nrows=1\ntasks=\nunscoped=1\nwake=heartbeat\nposture=attended\n' > "$P/state/.supervision-host-turn"
before=$(cat "$P/state/classify.status" | wc -l)
env FM_HOME="$P" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 bin/fm-branch-report.sh --task fleet --verdict captain --kind result --summary "main outcome"
echo "  parent status lines before=$before after=$(wc -l < "$P/state/classify.status"); other .status files: $(ls "$P/state" | grep -c '\.status$')"
