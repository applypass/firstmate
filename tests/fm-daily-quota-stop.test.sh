#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for the daily Claude quota stop
# (bin/fm-daily-quota-stop.sh, its PreToolUse transport, its installer, and the
# launch gate in bin/fm-spawn.sh). A fake quota-axi on PATH answers every read:
# no real quota-axi, claude, codex, op, or network is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# tests/lib.sh turns the gate off for fixtures; this suite tests it.
unset FM_DAILY_QUOTA_STOP
export TZ=UTC

TMP_ROOT=$(fm_test_tmproot fm-daily-quota-stop)
STOP="$ROOT/bin/fm-daily-quota-stop.sh"
CHECK="$ROOT/bin/fm-daily-quota-pretool-check.sh"
INSTALL="$ROOT/bin/fm-daily-quota-guard-install.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"
# 2026-10-20 12:00:00 UTC (a Tuesday); the weekly reset is 2026-10-24 08:00 UTC.
DAY1=1792497600
DAY2=$((DAY1 + 86400))
export FM_DAILY_QUOTA_NOW=$DAY1

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
# Fake quota-axi: prints $FAKE_QUOTA_JSON, or fails when $FAKE_QUOTA_FAIL is set.
[ -z "${FAKE_QUOTA_FAIL:-}" ] || { echo "$FAKE_QUOTA_FAIL" >&2; exit 1; }
cat "$FAKE_QUOTA_JSON"
SH
chmod +x "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$PATH"
export FAKE_QUOTA_JSON="$TMP_ROOT/quota.json"

# set_used <percent used> [next weekly reset ISO]
set_used() {
  local used=$1 resets=${2:-2026-10-24T08:00:00.000000+00:00}
  jq -n --argjson rem $((100 - used)) --arg resets "$resets" '{
    schemaVersion: 5,
    providers: [{provider: "claude", state: {status: "fresh", stale: false},
      windows: [
        {id: "five_hour", kind: "session", percentRemaining: 90},
        {id: "seven_day", kind: "weekly", resetsAt: $resets, percentRemaining: $rem}]}]}' > "$FAKE_QUOTA_JSON"
}

reset_fleet() { rm -rf "$HOME_DIR/state" "$HOME_DIR/config"; unset FAKE_QUOTA_FAIL FM_DAILY_QUOTA_ALLOW_UNREADABLE; export FM_DAILY_QUOTA_NOW=$DAY1; }

# run_check <spawn|nm-run> [args...]: CHECK_OUT holds stderr, CHECK_RC the code.
run_check() {
  local what=$1
  shift
  CHECK_OUT=$("$STOP" check "$what" --home "$HOME_DIR" "$@" 2>&1)
  CHECK_RC=$?
}

test_under_threshold_allows() {
  reset_fleet
  set_used 40; run_check spawn
  expect_code 0 "$CHECK_RC" "first read of the day sets the baseline and allows"
  set_used 59; run_check spawn
  expect_code 0 "$CHECK_RC" "19% used today allows"
  [ -z "$CHECK_OUT" ] || fail "allowed check printed: $CHECK_OUT"
  pass "under 20% used today allows"
}

test_refuse_at_20() {
  reset_fleet
  set_used 40; run_check spawn
  set_used 60; run_check spawn
  expect_code 3 "$CHECK_RC" "20% used today refuses"
  assert_contains "$CHECK_OUT" "used 20% of the weekly Claude quota today" "message names the number"
  assert_contains "$CHECK_OUT" "20% daily line" "message names the threshold"
  assert_contains "$CHECK_OUT" "worker launch" "message names the refused work"
  run_check nm-run
  assert_contains "$CHECK_OUT" "no-mistakes run" "nm-run message names the refused work"
  pass "20% used today refuses and names number and threshold"
}

test_hold_at_25_until_next_day() {
  reset_fleet
  set_used 40; run_check spawn
  set_used 65; run_check spawn
  expect_code 3 "$CHECK_RC" "25% used today refuses"
  assert_contains "$CHECK_OUT" "holding every new worker launch until 2026-10-21 00:00 UTC" "hold says when it clears"
  # Usage falling back under the line later the same day does not lift a hold.
  set_used 62; run_check spawn
  expect_code 3 "$CHECK_RC" "hold persists the rest of the day"
  assert_contains "$CHECK_OUT" "holding every new" "still a hold"
  pass "25% holds until the next local day"
}

test_day_rollover_resets() {
  reset_fleet
  set_used 40; run_check spawn
  set_used 66; run_check spawn
  expect_code 3 "$CHECK_RC" "held on day 1"
  export FM_DAILY_QUOTA_NOW=$DAY2
  run_check spawn
  expect_code 0 "$CHECK_RC" "new local day starts a fresh baseline at the current reading"
  set_used 86; run_check spawn
  expect_code 3 "$CHECK_RC" "20% spent on day 2 refuses again"
  pass "day rollover resets the budget"
}

test_weekly_reset_mid_day() {
  reset_fleet
  set_used 80; run_check spawn
  expect_code 0 "$CHECK_RC" "baseline 80"
  # The week reset at 09:00 today: usage restarts near zero and the next reset
  # is a week after 09:00.
  set_used 12 "2026-10-27T09:00:00.000000+00:00"; run_check spawn
  expect_code 0 "$CHECK_RC" "usage below the old baseline after a reset counts from zero, 12% allows"
  set_used 21 "2026-10-27T09:00:00.000000+00:00"; run_check spawn
  expect_code 3 "$CHECK_RC" "21% since the reset refuses"
  assert_contains "$CHECK_OUT" "used 21%" "counts from zero at the reset"
  # Reset happened today before the day's first read: no snapshot needed.
  reset_fleet
  set_used 22 "2026-10-27T09:00:00.000000+00:00"; run_check spawn
  expect_code 3 "$CHECK_RC" "first read of the day after a reset today counts everything since the reset"
  pass "weekly reset mid-day counts from the reset"
}

test_unreadable_refuses_plainly() {
  reset_fleet
  export FAKE_QUOTA_FAIL="keychain approval pending"
  run_check spawn
  expect_code 3 "$CHECK_RC" "unreadable quota refuses"
  assert_contains "$CHECK_OUT" "Claude quota could not be read" "plain message"
  assert_contains "$CHECK_OUT" "keychain approval pending" "reason shown"
  assert_contains "$CHECK_OUT" "FM_DAILY_QUOTA_ALLOW_UNREADABLE=1" "names the captain's override"
  unset FAKE_QUOTA_FAIL
  echo '{"schemaVersion":5,"providers":[{"provider":"claude","windows":[{"kind":"session","percentRemaining":50}]}]}' > "$FAKE_QUOTA_JSON"
  run_check spawn
  expect_code 3 "$CHECK_RC" "a snapshot with no weekly window refuses"
  assert_contains "$CHECK_OUT" "no weekly Claude window" "reason names the missing window"
  echo 'not json' > "$FAKE_QUOTA_JSON"
  run_check spawn
  expect_code 3 "$CHECK_RC" "garbage output refuses"
  pass "unreadable quota refuses and says why"
}

test_unreadable_override_is_one_shot() {
  reset_fleet
  export FAKE_QUOTA_FAIL="down"
  CHECK_OUT=$(FM_DAILY_QUOTA_ALLOW_UNREADABLE=1 "$STOP" check spawn --home "$HOME_DIR" 2>&1)
  expect_code 0 $? "env override lets one launch through"
  assert_contains "$CHECK_OUT" "captain's one-shot grant" "override is announced"
  run_check spawn
  expect_code 3 "$CHECK_RC" "the env override does not persist"
  "$STOP" allow-unreadable --home "$HOME_DIR" >/dev/null || fail "allow-unreadable failed"
  run_check nm-run
  expect_code 0 "$CHECK_RC" "the recorded grant lets one run start"
  run_check nm-run
  expect_code 3 "$CHECK_RC" "the grant is consumed by its first use"
  pass "unreadable-quota override is one-shot"
}

test_thresholds_config() {
  reset_fleet
  mkdir -p "$HOME_DIR/config"
  printf '# daily line\nrefuse = 5\nhold=7\n' > "$HOME_DIR/config/daily-quota-stop"
  set_used 40; run_check spawn
  set_used 45; run_check spawn
  expect_code 3 "$CHECK_RC" "configured 5% line refuses"
  assert_contains "$CHECK_OUT" "5% daily line" "message shows the configured line"
  set_used 47; run_check spawn
  assert_contains "$CHECK_OUT" "holding every new" "configured 7% hold line"
  pass "thresholds come from config/daily-quota-stop"
}

test_shared_budget_and_report_once() {
  reset_fleet
  local mate="$TMP_ROOT/mate" status="$TMP_ROOT/task.status" n
  mkdir -p "$mate"
  set_used 40; run_check spawn
  # A different home sharing the fleet home sees the same baseline.
  set_used 61
  "$STOP" check spawn --home "$mate" --fleet-home "$HOME_DIR" --status-file "$status" >/dev/null 2>&1
  expect_code 3 $? "a second home refuses from the shared baseline"
  [ ! -d "$mate/state" ] || fail "the second home wrote its own state instead of the fleet home's"
  "$STOP" check spawn --home "$mate" --fleet-home "$HOME_DIR" --status-file "$status" >/dev/null 2>&1
  n=$(grep -c '^blocked ' "$status")
  [ "$n" = 1 ] || fail "refusal reported $n times to the status file, expected once"
  assert_grep "used 21% of the weekly Claude quota today" "$status" "report carries the number"
  set_used 66
  "$STOP" check spawn --home "$mate" --fleet-home "$HOME_DIR" --status-file "$status" >/dev/null 2>&1
  assert_grep "paused [at=" "$status" "crossing the hold line reports once as a wait"
  assert_grep " until 2026-10-21T00:00Z" "$status" "the wait names when it clears"
  pass "homes share one budget and each level reports once"
}

test_secondmate_reports_to_parent_channel() {
  reset_fleet
  local mate="$TMP_ROOT/mate2" parent="$TMP_ROOT/parent" n
  mkdir -p "$mate/state" "$parent/state"
  printf 'mate1' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$mate/.fm-secondmate-parent"
  set_used 40; run_check spawn
  set_used 61
  # The mate launches with the main home named as the fleet home.
  FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=$HOME_DIR "$STOP" check spawn --home "$mate" >/dev/null 2>&1
  expect_code 3 $? "mate home refuses from the main home's baseline"
  FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=$HOME_DIR "$STOP" check spawn --home "$mate" >/dev/null 2>&1
  n=$(grep -c '^blocked ' "$parent/state/mate1.status")
  [ "$n" = 1 ] || fail "parent channel got $n lines, expected one"
  assert_grep "daily quota stop" "$parent/state/mate1.status" "line reaches the parent channel"
  [ ! -e "$mate/state/daily-quota-day-start" ] || fail "mate home kept its own baseline"
  pass "a secondmate home reports once to its parent channel and shares the main baseline"
}

test_pretool_gate() {
  reset_fleet
  local hook_out rc
  set_used 40; run_check spawn
  set_used 70
  nm() {
    hook_out=$("$CHECK" --claude --home "$HOME_DIR" --command "$1" 2>&1)
    rc=$?
  }
  nm 'no-mistakes axi run --intent "ship it"'
  expect_code 2 "$rc" "a new run is refused over the line"
  assert_contains "$hook_out" '"permissionDecision":"deny"' "deny object"
  assert_contains "$hook_out" "no-mistakes run" "reason names the refused work"
  nm 'cd x && no-mistakes axi run --wait 5m --intent "x" > /tmp/o 2>&1 &'
  expect_code 2 "$rc" "a new run behind other words is refused"
  for c in 'no-mistakes axi run' 'no-mistakes axi run --wait 5m' 'no-mistakes axi respond --action approve' \
    'no-mistakes axi status' 'echo "no-mistakes axi run --intent x"' 'git status'; do
    nm "$c"
    expect_code 0 "$rc" "never blocked: $c"
    [ -z "$hook_out" ] || fail "allowed command produced output: $c: $hook_out"
  done
  reset_fleet; set_used 41
  nm 'no-mistakes axi run --intent "ship it"'
  expect_code 0 "$rc" "a new run starts under the line"
  rc=$(printf '{"tool_input":{"command":"no-mistakes axi run --intent y"}}' | "$CHECK" --claude --home "$HOME_DIR" >/dev/null 2>&1; echo $?)
  expect_code 0 "$rc" "claude payload under the line allows"
  set_used 90
  rc=$(printf '{"tool_input":{"command":"no-mistakes axi run --intent y"}}' | "$CHECK" --claude --home "$HOME_DIR" >/dev/null 2>&1; echo $?)
  expect_code 2 "$rc" "claude payload over the line is refused"
  pass "the hook gates only new no-mistakes runs"
}

test_hook_fail_open() {
  reset_fleet
  local rc
  rc=$(printf '' | "$CHECK" --claude >/dev/null 2>&1; echo $?)
  expect_code 0 "$rc" "empty payload fails open"
  rc=$(printf 'not json' | "$CHECK" --claude >/dev/null 2>&1; echo $?)
  expect_code 0 "$rc" "malformed payload fails open"
  pass "the hook fails open on bad input"
}

test_installer() {
  local target="$TMP_ROOT/wt" f cmd out
  mkdir -p "$target/.claude"
  echo '{"permissions":{"allow":["Bash(ls)"]}}' > "$target/.claude/settings.local.json"
  "$INSTALL" "$target" --home "$HOME_DIR" --fleet-home "$HOME_DIR" --status-file "$TMP_ROOT/w.status" || fail "install failed"
  "$INSTALL" "$target" --home "$HOME_DIR" || fail "second install failed"
  f="$target/.claude/settings.local.json"
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | contains("fm-daily-quota-pretool-check.sh"))] | length' "$f")" = 1 ] || fail "hook not registered exactly once"
  [ "$(jq -r '.permissions.allow[0]' "$f")" = "Bash(ls)" ] || fail "existing settings lost"
  reset_fleet
  set_used 40; run_check spawn
  set_used 70
  cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f")
  out=$(printf '{"tool_input":{"command":"no-mistakes axi run --intent z"}}' | bash -c "$cmd" 2>&1)
  expect_code 2 $? "the registered hook refuses: $out"
  pass "installer merges, is idempotent, and registers a working hook"
}

# The launch gate in bin/fm-spawn.sh: a fresh launch is refused before any
# mutation; relaunching an existing task is running work and is never gated.
test_spawn_gate() {
  reset_fleet
  local out rc fm="$TMP_ROOT/spawnhome"
  mkdir -p "$fm"
  set_used 40; FM_HOME=$fm "$STOP" check spawn --home "$fm" >/dev/null 2>&1
  set_used 70
  out=$(FM_HOME=$fm "$ROOT/bin/fm-spawn.sh" some-task "$TMP_ROOT/no-such-project" 2>&1); rc=$?
  expect_code 1 "$rc" "a fresh launch over the line is refused"
  assert_contains "$out" "daily quota stop: holding every new worker launch" "spawn prints the refusal"
  [ ! -e "$fm/state/some-task.meta" ] || fail "refused launch left task state"
  out=$(FM_HOME=$fm "$ROOT/bin/fm-spawn.sh" some-task --relaunch 2>&1); rc=$?
  assert_not_contains "$out" "daily quota stop" "relaunch is not gated"
  out=$(FM_HOME=$fm FM_DAILY_QUOTA_STOP=off "$ROOT/bin/fm-spawn.sh" some-task "$TMP_ROOT/no-such-project" 2>&1)
  assert_not_contains "$out" "daily quota stop" "the test switch turns the gate off"
  pass "spawn refuses fresh launches and never relaunches"
}

test_scripts_are_shellcheck_clean() {
  local out f
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  for f in fm-daily-quota-lib.sh fm-daily-quota-stop.sh fm-daily-quota-pretool-check.sh fm-daily-quota-guard-install.sh; do
    out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/$f" 2>&1) || fail "bin/$f is not lint-clean: $out"
  done
  pass "daily quota scripts are clean under bin/fm-lint.sh"
}

test_under_threshold_allows
test_refuse_at_20
test_hold_at_25_until_next_day
test_day_rollover_resets
test_weekly_reset_mid_day
test_unreadable_refuses_plainly
test_unreadable_override_is_one_shot
test_thresholds_config
test_shared_budget_and_report_once
test_secondmate_reports_to_parent_channel
test_pretool_gate
test_hook_fail_open
test_installer
test_spawn_gate
test_scripts_are_shellcheck_clean
