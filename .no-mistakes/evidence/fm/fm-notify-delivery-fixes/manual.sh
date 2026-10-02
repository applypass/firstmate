set -u
R=$PWD; LAB=$1
P=$LAB/parent; M=$LAB/mate; mkdir -p $P/state $M/state
echo classify > $M/.fm-secondmate-home
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' $P > $M/.fm-secondmate-parent
. bin/fm-pending-reply-lib.sh
export FM_PENDING_REPLY_ACK_SECS=1800 FM_PENDING_REPLY_GRACE_SECS=120 FM_PENDING_REPLY_NOW=5000
CORR=$(fm_pending_reply_create $P $P/state classify "classify follow-up"); fm_pending_reply_mark_delivered $P/state $CORR
ph(){ echo "  -> main pending-reply phase: $(fm_pending_reply_get "$(fm_pending_reply_path $P/state $CORR)" phase)"; }
echo "## 1. mate acks with working: (the 2026-10-01 'relayed' ack)"
echo '$ FM_HOME=mate bin/fm-secondmate-report.sh working $CORR relayed'; FM_HOME=$M bin/fm-secondmate-report.sh working $CORR relayed
fm_pending_reply_tick_one $P/state $CORR idle ""; ph
echo "## 2. inside age bound (t+300s), mate pane idle"; export FM_PENDING_REPLY_NOW=5300; fm_pending_reply_tick_one $P/state $CORR idle ""; ph
echo "## 3. branch records captain verdict in mate home, without --kind"
printf 'turn=t1\nrows=1\ntasks=\nunscoped=1\nwake=heartbeat\nposture=attended\n' > $M/state/.supervision-host-turn
echo '$ bin/fm-branch-report.sh --task worker --verdict captain --summary ...'
FM_HOME=$M FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 bin/fm-branch-report.sh --task worker --verdict captain --summary "classify done"; echo "  exit=$?"
echo "## 4. same with --kind result"
echo '$ bin/fm-branch-report.sh --task worker --verdict captain --kind result --summary "classify follow-up complete; see report.md (corr='$CORR')"'
FM_HOME=$M FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 bin/fm-branch-report.sh --task worker --verdict captain --kind result --summary "classify follow-up complete; see report.md (corr=$CORR)"; echo "  exit=$?"
echo "  main channel parent/state/classify.status:"; sed 's/^/    /' $P/state/classify.status
export FM_PENDING_REPLY_NOW=5900; fm_pending_reply_tick_one $P/state $CORR idle ""; ph
echo "## 5. past ack age bound (t+1800s)"; export FM_PENDING_REPLY_NOW=6900; fm_pending_reply_tick_one $P/state $CORR idle ""; ph
echo "  main channel tail:"; tail -1 $P/state/classify.status | sed 's/^/    /'
echo "## 6. mate posts terminal correlated line"
FM_HOME=$M bin/fm-secondmate-report.sh done $CORR "classify follow-up complete"
fm_pending_reply_tick_one $P/state $CORR idle ""; ph
