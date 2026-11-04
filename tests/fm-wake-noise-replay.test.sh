#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: replay of one real supervision day through the real wake producers.
#
# tests/fixtures/wake-noise/replay-day.tsv holds the wake-producing events of
# one day (4 Nov 2026, local midnight to midnight), reduced to line shapes,
# states, and timing under neutral names. This test replays it on a virtual
# clock and counts every wake that the producers raise:
#   - the never-wait sweep (bin/fm-never-wait.sh sweep)
#   - the reply timer (fm_pending_reply_tick in bin/fm-pending-reply-lib.sh)
#   - the daily quota stop (bin/fm-daily-quota-stop.sh), which writes a status line
#   - the watcher's status classification (status_span_first_actionable_record,
#     the span classifier behind signal_files_actionable in bin/fm-watch.sh)
#     over each status file, committed through the wake library as the watcher does
# Each wake costs the supervisor one full turn, so the count is the cost. The
# baseline below is the count before any fix; each later step asserts a lower count.
# The watcher's pane-evidence absorb (signal_crew_provably_working) needs live panes
# and is not modelled, so the replay counts every actionable span as a wake.
#
# Event kinds in the fixture: line (a status line), request (a marked request is
# delivered), operator-resolve (the supervisor closes a pending-reply decision),
# quota (a launch hits the daily quota stop), turn (a ledger turn event in the
# mate's home).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The replay drives the real producers, so the fixture-wide switches that turn
# them off stay off here.
unset FM_NEVER_WAIT FM_DAILY_QUOTA_STOP

FIXTURE="$ROOT/tests/fixtures/wake-noise/replay-day.tsv"
TMP_ROOT=$(fm_test_tmproot fm-wake-noise-replay)
DAY0=1793730600                  # 2026-11-04 00:00 IST
export TZ=Asia/Kolkata
TICK=60                          # virtual seconds between looks at the fixture
TURN_SECS=300                    # one supervisor turn, in virtual seconds
SWEEP_EVERY=1800                 # virtual seconds between sweep and reply-timer passes

# Wake count before any fix, and after each step (one commit per step). The
# replay asserts the latest value, and that every step lowered the one before it.
# Append the next step's count here when its commit lands.
COUNTS=(86 86 86 86 85)          # # COUNTS[0] = baseline, COUNTS[n] = after step n
# Never-wait findings (SELF-FIX or ALARM text), counting those read inside an open turn.
# Steps 1 to 3 remove notices but not turns: on this day each one landed in a turn that
# another mate's status line had already started, so those steps keep the wake count
# flat. Steps 1 and 2 are checked by the findings they remove, step 3 by the spans it
# keeps quiet (ABSORBED). Every later step must lower COUNTS.
FINDINGS=(11 1 0 0 0)
FLAT_STEPS=" 1 2 3 "

H="$TMP_ROOT/home"
STATE="$H/state"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN" "$H/data"

REAL_DATE=$(command -v date)
cat > "$FAKEBIN/date" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\$1" = "+%s" ] && [ -n "\${FM_VCLOCK:-}" ]; then printf '%s\n' "\$FM_VCLOCK"; exit 0; fi
exec "$REAL_DATE" "\$@"
SH
chmod +x "$FAKEBIN/date"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
jq -n --argjson rem "$((100 - ${FAKE_QUOTA_USED:-0}))" '{
  schemaVersion: 5,
  providers: [{provider: "claude", state: {status: "fresh", stale: false},
    windows: [{id: "seven_day", kind: "weekly", resetsAt: "2026-11-09T00:00:00.000000+00:00", percentRemaining: $rem}]}]}'
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$FAKEBIN/send-hook" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/send-hook"

# The sweep runs from a copy of bin/ whose task ledger is a no-op: the ledger
# bookkeeping costs several process starts per task and decides no wake here.
SWEEP_BIN="$TMP_ROOT/bin"
cp -R "$ROOT/bin" "$SWEEP_BIN"
cat > "$SWEEP_BIN/fm-task-ledger.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in path) printf '%s\n' "${FM_HOME:-/nonexistent}/.no-ledger" ;; open-block) exit 1 ;; esac
exit 0
SH
chmod +x "$SWEEP_BIN/fm-task-ledger.sh"

export PATH="$FAKEBIN:$PATH"
export FM_HOME="$H" FM_STATE_OVERRIDE="$STATE" FM_WAKE_QUEUE="$STATE/.wake-queue"
export FM_NEVER_WAIT_UNTHROTTLED=1
export FM_PENDING_REPLY_SEND_HOOK="$FAKEBIN/send-hook" FM_PENDING_REPLY_GRACE_SECS=120
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# The wake-noise library arrives with step 3; earlier commits replay without it.
# shellcheck source=bin/fm-wake-noise-lib.sh
[ ! -f "$ROOT/bin/fm-wake-noise-lib.sh" ] || . "$ROOT/bin/fm-wake-noise-lib.sh"
# Library settings the sourced files leave on.
set +e

ABSORBED=0                       # status spans the known-wait cut kept quiet
WAKES="$TMP_ROOT/wakes.log"      # "<offset>\t<class>\t<text>"
: > "$WAKES"
declare -A CLASSIFIED_SIZE=()    # status size at the last classification, per file
declare -A REPLY_SIZE=()         # status size at the last visit, per pending record
declare -A MATE_SEEN=()          # mates with a status file, for the classifier pass

vclock() { export FM_VCLOCK=$((DAY0 + $1)); export FM_PENDING_REPLY_NOW=$FM_VCLOCK FM_DAILY_QUOTA_NOW=$FM_VCLOCK; }

mate_home() { printf '%s/mates/%s' "$H" "$1"; }

ensure_mate() {  # <mate>
  local m=$1
  [ -z "${MATE_SEEN[$m]:-}" ] || return 0
  MATE_SEEN[$m]=1
  mkdir -p "$(mate_home "$m")/data/ticket-ledger" "$(mate_home "$m")/state"
  printf 'kind=secondmate\nhome=%s\n' "$(mate_home "$m")" > "$STATE/$m.meta"
  : > "$STATE/$m.status"
}

apply_line() {  # <mate> <line template without stamp>
  local m=$1 tpl=$2
  ensure_mate "$m"
  # The fixture writes "until=@<offset>" for a wait end time; resolve it to the UTC stamp.
  while [[ "$tpl" =~ until=@([0-9]+) ]]; do
    tpl=${tpl/until=@${BASH_REMATCH[1]}/until=$("$REAL_DATE" -u -r $((DAY0 + BASH_REMATCH[1])) +%Y-%m-%dT%H:%MZ)}
  done
  printf '%s\n' "$(status_stamp_line "$tpl")" >> "$STATE/$m.status"
}

apply_request() {  # <mate> <corr>
  local m=$1 corr=$2 made
  ensure_mate "$m"
  made=$(fm_pending_reply_create "$H" "$STATE" "$m" "neutral request for $m")
  mv "$(fm_pending_reply_path "$STATE" "$made")" "$(fm_pending_reply_path "$STATE" "$corr")"
  sed -i.bak "s/^corr_id=.*/corr_id=$corr/" "$(fm_pending_reply_path "$STATE" "$corr")"
  rm -f "$(fm_pending_reply_path "$STATE" "$corr").bak"
  fm_pending_reply_mark_delivered "$STATE" "$corr" "$FM_VCLOCK"
}

apply_operator_resolve() {  # <mate> <corr>
  local m=$1 corr=$2 rec note
  rec=$(fm_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] || return 0
  if [ "$(fm_pending_reply_get "$rec" phase)" = escalated ]; then
    note=$(fm_pending_reply_close_note_for_key "pending-reply-$corr" "$m" operator-resolve-key) || return 0
    printf '%s\n' "$(status_stamp_line "resolved [key=pending-reply-$corr]: $note")" >> "$STATE/$m.status"
  else
    # This run has not escalated it (yet); the answer still ends the request.
    printf '%s\n' "$(status_stamp_line "done [corr=$corr]: corr=$corr neutral answer")" >> "$STATE/$m.status"
  fi
}

apply_quota() {  # <mate> <refuse|hold>
  local m=$1 level=$2
  ensure_mate "$m"
  # Day start at 10% used; the refuse line is 20% a day, the hold line 25%.
  # The first call of a day records the baseline, so a call just before it reads 10%.
  if [ -z "${QUOTA_BASELINE:-}" ]; then
    QUOTA_BASELINE=1
    FAKE_QUOTA_USED=10 FM_DAILY_QUOTA_NOW=$((FM_VCLOCK - 1)) \
      "$ROOT/bin/fm-daily-quota-stop.sh" check spawn --home "$H" --status-file "$STATE/$m.status" >/dev/null 2>&1 || true
  fi
  if [ "$level" = hold ]; then FAKE_QUOTA_USED=37; else FAKE_QUOTA_USED=31; fi
  export FAKE_QUOTA_USED
  "$ROOT/bin/fm-daily-quota-stop.sh" check spawn --home "$H" --status-file "$STATE/$m.status" >/dev/null 2>&1 || true
}

apply_turn() {  # <mate>
  local m=$1
  ensure_mate "$m"
  printf '{"at":%s,"event":"turn","session":"none"}\n' "$FM_VCLOCK" >> "$(mate_home "$m")/data/ticket-ledger/_fleet-overhead.jsonl"
}

# A wake that lands while the supervisor is still inside the turn an earlier
# wake started (TURN_SECS) is read in that turn and costs no extra turn.
LAST_WAKE=-100000
record_wake() {  # <offset> <class> <text>
  if [ $(($1 - LAST_WAKE)) -lt "$TURN_SECS" ]; then
    printf '%s\tmerged-%s\t%s\n' "$1" "$2" "$3" >> "$WAKES"
    return 0
  fi
  LAST_WAKE=$1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$WAKES"
}

# The watcher's status-signal pass: one wake per poll with any actionable span.
classify_signals() {  # <offset>
  local off=$1 f size start record needs rc endpoint rest ident actionable=0 files=''
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    # A file with no new bytes has no new span: skip the costly classifier call.
    size=$(wc -c < "$f" | tr -d ' ')
    [ "${CLASSIFIED_SIZE[$f]:-}" != "$size" ] || continue
    CLASSIFIED_SIZE[$f]=$size
    start=$(fm_wake_signal_seen_size "$STATE" "$f")
    record=''; needs=0
    status_span_first_actionable_record "$f" "$start" record needs
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$record" ] && continue
    endpoint=${record%%$'\t'*}; rest=${record#*$'\t'}; ident=${rest%%$'\t'*}
    fm_wake_status_seen_commit "$STATE" "$f" "$endpoint" "$ident" || true
    # The watcher's known-wait hook (signal_files_actionable in bin/fm-watch.sh).
    if [ "$rc" -eq 0 ] && declare -F fm_noise_span_quiet >/dev/null && fm_noise_span_quiet "$STATE" "$(basename "$f" .status)" "${record#*$'\t'*$'\t'}" 2>/dev/null; then rc=1; needs=0; ABSORBED=$((ABSORBED + 1)); fi
    if [ "$rc" -eq 0 ] || [ "$needs" -eq 1 ]; then
      actionable=1
      files="$files $(basename "$f" .status)"
    fi
  done
  [ "$actionable" -eq 0 ] || record_wake "$off" signal "signal:$files"
}

# The reply timer's per-record decisions (fm_pending_reply_tick runs the same
# locked steps). The public wrappers re-source the wake library on every call,
# which makes a day of passes far too slow, so the replay calls the locked
# functions directly; no backend is probed, so only acknowledged requests age.
reply_pass() {
  local rec corr phase status recs=() size due wake_due ack
  for rec in "$STATE"/pending-replies/*; do [ -f "$rec" ] && recs+=("$rec"); done
  [ "${#recs[@]}" -gt 0 ] || return 0
  # One awk pass reads every record's phase and timers (the record format is
  # key=value lines); a settled record needs no work, and a record is visited
  # only when its status file grew or a timer on it is due: the library's
  # per-record steps are no-ops otherwise and cost many process starts.
  while IFS='|' read -r rec phase status wake_due ack; do
    size=$(wc -c < "$status" 2>/dev/null | tr -d ' ')
    due=0
    case "$phase" in
      escalated) [ -n "$wake_due" ] && [ "$wake_due" -le "$FM_VCLOCK" ] && due=1 ;;
      acknowledged) [ -n "$ack" ] && [ $((ack + 1800)) -le "$FM_VCLOCK" ] && due=1 ;;
      recovery_sent|resolved) due=1 ;;
    esac
    [ "$due" -eq 1 ] || [ "${REPLY_SIZE[$rec]:-}" != "$size" ] || continue
    REPLY_SIZE[$rec]=$size
    corr=$(fm_pending_reply_get "$rec" corr_id)
    phase=$(fm_pending_reply_get "$rec" phase)
    status=$(fm_pending_reply_get "$rec" parent_status)
    case "$phase" in
      resolved) _fm_pending_reply_close_escalation_locked "$STATE" "$corr" || true ;;
      escalated)
        _fm_pending_reply_try_resolve_locked "$STATE" "$corr" "$status" >/dev/null 2>&1 \
          || _fm_pending_reply_wake_held_escalation_locked "$STATE" "$corr" >/dev/null 2>&1 || true ;;
      awaiting_report|recovery_sent|acknowledged)
        _fm_pending_reply_try_resolve_locked "$STATE" "$corr" >/dev/null 2>&1 && continue
        case "$(fm_pending_reply_get "$rec" phase)" in
          recovery_sent|acknowledged) _fm_pending_reply_maybe_escalate_locked "$STATE" "$corr" >/dev/null 2>&1 || true ;;
        esac ;;
    esac
  done < <(awk -F= '
    FNR == 1 { if (path != "") emit(); path = FILENAME; ph = ""; ps = ""; wd = ""; ak = ""; es = ""; cl = "" }
    $1 == "phase" { ph = $2 } $1 == "parent_status" { ps = $2 } $1 == "escalation_wake_due_epoch" { wd = $2 }
    $1 == "ack_line_epoch" { ak = $2 } $1 == "escalated_epoch" { es = $2 } $1 == "escalation_closed_epoch" { cl = $2 }
    function emit() { if (ph == "resolved" && !(es != "" && cl == "")) return; print path "|" ph "|" ps "|" wd "|" ak }
    END { if (path != "") emit() }' "${recs[@]}")
}

BLOCK_HOT=0                      # a status file ends in an open blocked line (or just did)

# Does any task's trailing status line open or keep a block?
refresh_block_hot() {
  local f last any=0
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    last=$(tail -n 1 "$f")
    case "$last" in blocked*) any=1 ;; esac
  done
  BLOCK_HOT=$any
}

unresolved_records() {
  local rec
  for rec in "$STATE"/pending-replies/*; do
    [ -f "$rec" ] || continue
    grep -q '^phase=resolved' "$rec" 2>/dev/null || return 0
    grep -q '^escalated_epoch=.' "$rec" 2>/dev/null && ! grep -q '^escalation_closed_epoch=.' "$rec" 2>/dev/null && return 0
  done
  return 1
}

# One producer pass at virtual offset <off>. The sweep and the reply timer run
# only when they have something to decide (an open block, an open request):
# they print and write nothing otherwise, and a pass costs real process time.
run_producers() {  # <offset> <sweep:0|1> <reply:0|1>
  local off=$1 out t0=$SECONDS t1 t2 t3
  vclock "$off"
  [ "$3" -eq 0 ] || reply_pass
  t1=$SECONDS
  if [ "$2" -eq 1 ]; then
    out=$("$SWEEP_BIN/fm-never-wait.sh" sweep --now "$FM_VCLOCK" 2>/dev/null) || out=
    [ -z "$out" ] || record_wake "$off" never-wait "$out"
  fi
  t2=$SECONDS
  classify_signals "$off"
  t3=$SECONDS
  refresh_block_hot
  [ -z "${FM_REPLAY_PROFILE:-}" ] || printf 'pass %s sweep=%s reply=%s: reply=%ss nw=%ss cls=%ss\n' "$off" "$2" "$3" $((t1-t0)) $((t2-t1)) $((t3-t2)) >&2
}

replay() {
  local t=0 off kind mate arg changed sweep reply
  local -a E_OFF=() E_KIND=() E_MATE=() E_ARG=()
  while IFS=$'\t' read -r off kind mate arg; do
    case "$off" in ''|'#'*) continue ;; esac
    E_OFF+=("$off"); E_KIND+=("$kind"); E_MATE+=("$mate"); E_ARG+=("$arg")
  done < "$FIXTURE"
  local i=0 n=${#E_OFF[@]}
  while [ "$t" -lt "${FM_REPLAY_SECONDS:-86400}" ]; do
    changed=0
    while [ "$i" -lt "$n" ] && [ "${E_OFF[$i]}" -le "$t" ]; do
      vclock "${E_OFF[$i]}"
      case "${E_KIND[$i]}" in
        line) apply_line "${E_MATE[$i]}" "${E_ARG[$i]}"; changed=1 ;;
        request) apply_request "${E_MATE[$i]}" "${E_ARG[$i]}" ;;
        operator-resolve) apply_operator_resolve "${E_MATE[$i]}" "${E_ARG[$i]}"; changed=1 ;;
        quota) apply_quota "${E_MATE[$i]}" "${E_ARG[$i]}"; changed=1 ;;
        turn) apply_turn "${E_MATE[$i]}" ;;
      esac
      i=$((i + 1))
    done
    sweep=0; reply=0
    if [ $((t % SWEEP_EVERY)) -eq 0 ]; then
      [ "$BLOCK_HOT" -eq 0 ] || sweep=1
      ! unresolved_records || reply=1
    fi
    # A line that ends a block needs one more sweep to close it.
    if [ "$changed" -eq 1 ] && [ "$BLOCK_HOT" -eq 1 ]; then sweep=1; fi
    if [ "$changed" -eq 1 ] || [ "$sweep" -eq 1 ] || [ "$reply" -eq 1 ]; then
      run_producers "$t" "$sweep" "$reply"
    fi
    t=$((t + TICK))
  done
}

count_class() { awk -F'\t' -v c="$1" '$2 == c' "$WAKES" | wc -l | tr -d ' '; }

replay
TOTAL=$(grep -vc $'\tmerged-' "$WAKES")
SIGNAL=$(count_class signal)
NEVER_WAIT=$(count_class never-wait)
FOUND=$(grep -c 'never-wait' "$WAKES" || true)
printf '# replay wake count: total=%s (signal=%s never-wait=%s) never-wait findings=%s absorbed=%s\n' "$TOTAL" "$SIGNAL" "$NEVER_WAIT" "$FOUND" "$ABSORBED"
if [ -n "${FM_REPLAY_KEEP:-}" ]; then cp "$WAKES" "$FM_REPLAY_KEEP"; fi

LATEST=$((${#COUNTS[@]} - 1))
[ "$TOTAL" -eq "${COUNTS[$LATEST]}" ] \
  || fail "replayed wake count is $TOTAL, expected ${COUNTS[$LATEST]} after step $LATEST"
[ "$ABSORBED" -ge "$((LATEST >= 3 ? 1 : 0))" ] || fail "the known-wait cut kept no span quiet"
[ "$FOUND" -eq "${FINDINGS[$LATEST]}" ] \
  || fail "replayed never-wait findings are $FOUND, expected ${FINDINGS[$LATEST]} after step $LATEST"
n=1
while [ "$n" -le "$LATEST" ]; do
  case "$FLAT_STEPS" in
    *" $n "*)
      [ "${COUNTS[$n]}" -le "${COUNTS[$((n - 1))]}" ] || fail "step $n raised the wake count"
      [ "$n" -ge 3 ] || [ "${FINDINGS[$n]}" -lt "${FINDINGS[$((n - 1))]}" ] \
        || fail "step $n (${FINDINGS[$n]} findings) did not lower step $((n - 1)) (${FINDINGS[$((n - 1))]})" ;;
    *)
      [ "${COUNTS[$n]}" -lt "${COUNTS[$((n - 1))]}" ] \
        || fail "step $n (${COUNTS[$n]} wakes) did not lower step $((n - 1)) (${COUNTS[$((n - 1))]})" ;;
  esac
  n=$((n + 1))
done
pass "replayed wake count is $TOTAL after step $LATEST (baseline ${COUNTS[0]})"
