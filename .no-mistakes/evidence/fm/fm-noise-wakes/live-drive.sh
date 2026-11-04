#!/usr/bin/env bash
# Live drive of the real watcher, daily quota stop, and never-wait sweep in a disposable lab home.
set -u
ROOT=$1
cd "$ROOT"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_NEVER_WAIT FM_DAILY_QUOTA_STOP
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-bin.XXXXXX")
trap 'rm -rf "$LAB" "$FAKE"' EXIT
# quota-axi is the external quota reader; stand in a disposable provider reading FAKE_QUOTA_USED.
cat > "$FAKE/quota-axi" <<'SH'
#!/usr/bin/env bash
jq -n --argjson rem "$((100 - ${FAKE_QUOTA_USED:-0}))" '{schemaVersion: 5, providers: [{provider: "claude", state: {status: "fresh", stale: false}, windows: [{id: "seven_day", kind: "weekly", resetsAt: "2026-11-09T00:00:00.000000+00:00", percentRemaining: $rem}]}]}'
SH
chmod +x "$FAKE/quota-axi"
export PATH="$FAKE:$PATH" FM_HOME=$LAB
S=$LAB/state
NOW=$(date +%s)
LATER=$(TZ=UTC date -r $((NOW+7200)) +%Y-%m-%dT%H:%MZ)
WOPTS=(FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_NEVER_WAIT=off)

watch_for() {  # <label> <seconds> [extra env...]: run the real watcher; report WOKE or STAYED-UP
  local label=$1 secs=$2; shift 2
  local out="$LAB/w.out" i=0 lim=$((secs*10))
  env "${WOPTS[@]}" "$@" bash bin/fm-watch.sh > "$out" 2>&1 &
  local pid=$!
  while [ $i -lt $lim ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid 2>/dev/null; echo "[$label] watcher STAYED UP for ${secs}s (no wake)"
  else wait $pid 2>/dev/null; echo "[$label] watcher WOKE: $(grep -m1 -E '^(signal|stale|heartbeat)' "$out" || head -1 "$out")"; fi
  rm -f "$S/.wake-queue" "$S/.watcher-down"
}
drain() { rm -f "$S/.wake-queue" "$S/.watcher-down"; }

echo "=== S1/S2: daily quota stop writes a labelled system line with the cap reason ==="
: > "$S/mate1.meta"; : > "$S/mate1.status"
FAKE_QUOTA_USED=10 FM_DAILY_QUOTA_NOW=$((NOW-1)) bin/fm-daily-quota-stop.sh check spawn --home "$LAB" --status-file "$S/mate1.status" 2>/dev/null; echo "baseline check exit=$?"
FAKE_QUOTA_USED=31 bin/fm-daily-quota-stop.sh check spawn --home "$LAB" --status-file "$S/mate1.status"; echo "refuse check exit=$?"
echo "--- mate1.status:"; cat "$S/mate1.status"
echo "--- never-wait sweep 20 min later (a system line must not be judged as the worker's block):"
bin/fm-never-wait.sh sweep --now $((NOW+1200)) ; echo "(sweep exit=$?)"

echo; echo "=== S2b: never-wait judges the latest blocked line, not the first ==="
: > "$S/mate2.meta"
printf 'blocked [at=%s]: waiting on stuff\n' "$NOW" > "$S/mate2.status"
printf 'blocked [at=%s]: external-wait until=%s: vendor fix in flight\n' "$((NOW+60))" "$LATER" >> "$S/mate2.status"
cat "$S/mate2.status"
echo "--- sweep output:"; bin/fm-never-wait.sh sweep --now $((NOW+120)); echo "(sweep exit=$?)"
echo "--- adversarial: legal first line, illegal latest line must be rejected"
: > "$S/mate3.meta"
printf 'blocked [at=%s]: external-wait until=%s: vendor fix\n' "$NOW" "$LATER" > "$S/mate3.status"
printf 'blocked [at=%s]: waiting on stuff\n' "$((NOW+60))" >> "$S/mate3.status"
bin/fm-never-wait.sh sweep --now $((NOW+3000)) | grep -i mate3 || echo "(no finding for mate3)"
rm -f "$S"/mate2.* "$S"/mate3.* "$S"/mate1.*; rm -rf "$S/never-wait"

echo; echo "=== S3: a known wait wakes once, then stays quiet until it ends ==="
: > "$S/kw.meta"
printf 'blocked [at=%s]: external-wait until=%s: deploy window\n' "$NOW" "$LATER" > "$S/kw.status"
watch_for "first sight" 15
printf 'blocked [at=%s]: external-wait until=%s: deploy window\n' "$((NOW+60))" "$LATER" >> "$S/kw.status"
watch_for "same wait again" 6
echo "--- adversarial: a changed clear time is a new fact"
LATER2=$(TZ=UTC date -r $((NOW+9000)) +%Y-%m-%dT%H:%MZ)
printf 'blocked [at=%s]: external-wait until=%s: deploy window\n' "$((NOW+90))" "$LATER2" >> "$S/kw.status"
watch_for "new clear time" 15
echo "--- adversarial: a wait whose time has passed wakes"
PASTT=$(TZ=UTC date -r $((NOW-600)) +%Y-%m-%dT%H:%MZ)
printf 'blocked [at=%s]: external-wait until=%s: old wait\n' "$((NOW+100))" "$PASTT" >> "$S/kw.status"
watch_for "past wait" 15
printf 'blocked [at=%s]: external-wait until=%s: old wait\n' "$((NOW+110))" "$PASTT" >> "$S/kw.status"
watch_for "past wait again" 15
echo "records:"; ls "$S/wake-noise"
rm -f "$S"/kw.*

echo; echo "=== S5: one wake per open problem; a new fact wakes; closure reopens ==="
: > "$S/op.meta"
printf 'needs-decision [key=deploy] [at=%s]: approve prod deploy?\n' "$NOW" > "$S/op.status"
watch_for "open problem first" 15
printf 'needs-decision [key=deploy] [at=%s]: approve prod deploy?\n' "$((NOW+60))" >> "$S/op.status"
watch_for "same key/verb/note repeat" 6
cat "$S"/wake-noise/problem-* 2>/dev/null | sed 's/^/problem record: /'
printf 'needs-decision [key=deploy] [at=%s]: CI green now, approve prod deploy?\n' "$((NOW+90))" >> "$S/op.status"
watch_for "changed note (new fact)" 15
printf 'captain-held [key=deploy] [at=%s]: tracked by the captain\n' "$((NOW+100))" >> "$S/op.status"
watch_for "captain-held transfer" 15
printf 'needs-decision [key=deploy] [at=%s]: CI green now, approve prod deploy?\n' "$((NOW+120))" >> "$S/op.status"
watch_for "same line after captain-held closure" 15
rm -f "$S"/op.*

echo; echo "=== S6: a routine child-outcome notice rides the next real wake, or its hold limit ==="
: > "$S/rt.meta"
printf 'done [key=child-outcome-c1-done-ab12] [at=%s]: child c1 done: pr=101\n' "$NOW" > "$S/rt.status"
watch_for "lone routine notice" 6
printf 'needs-decision [key=merge] [at=%s]: merge pr 102?\n' "$((NOW+30))" >> "$S/rt.status"
watch_for "real event after held notice" 15
echo "held record after the wake: $(ls "$S/wake-noise" | grep held- || echo none)"
: > "$S/rt2.meta"
printf 'done [key=child-outcome-c2-done-cd34] [at=%s]: child c2 done: pr=103\n' "$NOW" > "$S/rt2.status"
watch_for "lone notice with FM_NOISE_HOLD_SECS=3" 15 FM_NOISE_HOLD_SECS=3
echo "--- adversarial: captain-held beside a held notice"
: > "$S/rt3.meta"
printf 'done [key=child-outcome-c3-done-ef56] [at=%s]: child c3 done\n' "$NOW" > "$S/rt3.status"
watch_for "lone notice rt3" 5
printf 'captain-held [key=merge-ok] [at=%s]: tracked by the captain\n' "$((NOW+5))" >> "$S/rt3.status"
watch_for "captain-held beside held notice" 15
echo "lab removed on exit: $LAB"
