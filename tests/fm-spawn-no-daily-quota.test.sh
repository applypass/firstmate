#!/usr/bin/env bash
# tests/fm-spawn-no-daily-quota.test.sh - a launch is never refused or held for a
# daily share of the weekly quota. The fake quota-axi reports 50% of the week
# used (the old stop refused at 20% and held at 25%); the real spawn must still
# launch, must not read quota-axi, and must not export any daily-quota variable.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-no-stop)
case_dir="$TMP_ROOT/case"
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
fm_test_spawn_home "$home" claude
fm_git_worktree "$proj" "$wt" wt-nq
fm_test_spawn_brief "$home" nq-a1

cat > "$fakebin/quota-axi" <<SH
#!/bin/sh
echo called >> "$case_dir/quota-axi.calls"
printf '{"schemaVersion":5,"providers":[{"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"id":"seven_day","kind":"weekly","percentRemaining":50}]}]}\n'
SH
chmod +x "$fakebin/quota-axi"

launchlog="$case_dir/launch.log"
panelog="$case_dir/pane.log"
: > "$launchlog"
: > "$panelog"
out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
  fm_test_run_spawn "$home" "$wt" "$fakebin" nq-a1 "$proj" --mode no-mistakes --yolo off 2>&1)
status=$?
expect_code 0 "$status" "spawn at 50% of the week used today is not refused: $out"
assert_not_contains "$out" "daily quota stop" "spawn prints no quota refusal"
[ ! -e "$case_dir/quota-axi.calls" ] || fail "spawn read quota-axi"
assert_not_contains "$(cat "$launchlog" "$panelog")" "FM_DAILY_QUOTA" "no daily-quota variable reaches the worker"
settings="$wt/.claude/settings.local.json"
if [ -f "$settings" ]; then
  assert_not_contains "$(cat "$settings")" "fm-daily-quota-pretool-check" "no daily-quota hook is registered in the worker"
fi
pass "a launch at an over-20%-today reading is not refused and reads no quota"
