#!/usr/bin/env bash
# Behavior tests for bin/fm-review-round-cap.sh (applypass fork): the review
# fix-round cap, the agent-timeout fail-fast, and the brief rule it feeds.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAP="$ROOT/bin/fm-review-round-cap.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-round-cap)

# new_home <name>: an isolated home with state/ and data/.
new_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/data" "$h/config"
  printf '%s\n' "$h"
}

cap() { local h=$1; shift; FM_HOME="$h" FM_REVIEW_FIX_CAP="${CAPVAL:-}" "$CAP" "$@"; }

write_findings() { printf '%s\n' "$@" > "$TMP_ROOT/findings.txt"; }

test_default_cap_is_two() {
  local h out; h=$(new_home default)
  out=$(FM_HOME="$h" "$CAP" cap)
  [ "$out" = 2 ] || fail "default cap should be 2, got $out"
}

test_config_file_and_env_override() {
  local h out; h=$(new_home cfg)
  echo 4 > "$h/config/review-fix-cap"
  out=$(FM_HOME="$h" "$CAP" cap)
  [ "$out" = 4 ] || fail "config cap should be 4, got $out"
  out=$(FM_HOME="$h" FM_REVIEW_FIX_CAP=1 "$CAP" cap)
  [ "$out" = 1 ] || fail "env cap should win, got $out"
}

test_invalid_cap_refused() {
  local h; h=$(new_home bad)
  FM_HOME="$h" FM_REVIEW_FIX_CAP=two "$CAP" fix t1 r1 review >/dev/null 2>&1 && fail "non-numeric cap should be refused"
  [ ! -e "$h/state/t1.status" ] || fail "refused cap must not write status"
}

test_rounds_allowed_then_capped() {
  local h out rc; h=$(new_home rounds)
  write_findings "1 high src/app.ts:10 missing null check" "2 low README.md typo"
  out=$(FM_HOME="$h" "$CAP" fix t1 r1 review --findings "$TMP_ROOT/findings.txt") || fail "round 1 should be allowed"
  [ "$out" = "fix-allowed: round 1 of 2" ] || fail "round 1 output: $out"
  write_findings "3 high src/app.ts:12 null check still missing"
  out=$(FM_HOME="$h" "$CAP" fix t1 r1 review --findings "$TMP_ROOT/findings.txt") || fail "round 2 should be allowed"
  [ "$out" = "fix-allowed: round 2 of 2" ] || fail "round 2 output: $out"
  [ ! -e "$h/state/t1.status" ] || fail "no status before the cap"

  write_findings "4 high src/app.ts:14 null check regressed" "5 med lib/x.sh:3 quoting"
  rc=0
  FM_HOME="$h" "$CAP" fix t1 r1 review --findings "$TMP_ROOT/findings.txt" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 3 ] || fail "third round should exit 3, got $rc"
  assert_grep '[key=nm-r1-review-cap]' "$h/state/t1.status" "needs-decision with the cap key"
  assert_grep 'after 2 of 2 rounds' "$h/state/t1.status" "status names the round count"
  local snap="$h/data/t1/nm-r1-review-rounds.txt"
  [ -f "$snap" ] || fail "snapshot file missing"
  assert_grep 'fix rounds already sent: 2 (cap 2)' "$snap" "snapshot round count"
  assert_grep '  - src/app.ts' "$snap" "repeated theme file recorded"
  assert_grep 'lib/x.sh:3 quoting' "$snap" "remaining findings listed"
  # A capped call does not consume a round.
  [ "$(wc -l < "$h/state/t1.fix-rounds" | tr -d ' ')" = 2 ] || fail "capped call must not record a round"
}

test_rounds_counted_per_run_and_step() {
  local h; h=$(new_home perstep)
  FM_HOME="$h" "$CAP" fix t1 r1 review >/dev/null || fail "r1 review 1"
  FM_HOME="$h" "$CAP" fix t1 r1 review >/dev/null || fail "r1 review 2"
  FM_HOME="$h" "$CAP" fix t1 r1 test >/dev/null || fail "another step has its own count"
  FM_HOME="$h" "$CAP" fix t1 r2 review >/dev/null || fail "another run has its own count"
  FM_HOME="$h" "$CAP" fix t2 r1 review >/dev/null || fail "another task has its own count"
}

test_zero_cap_sends_first_gate_to_firstmate() {
  local h rc=0; h=$(new_home zero)
  FM_HOME="$h" FM_REVIEW_FIX_CAP=0 "$CAP" fix t1 r1 review >/dev/null 2>&1 || rc=$?
  [ "$rc" = 3 ] || fail "cap 0 should exit 3, got $rc"
  assert_grep '[key=nm-r1-review-cap]' "$h/state/t1.status" "cap 0 escalates"
  assert_grep '(not supplied)' "$h/data/t1/nm-r1-review-rounds.txt" "snapshot without findings"
}

test_grant_adds_rounds() {
  local h rc=0; h=$(new_home grant)
  FM_HOME="$h" FM_REVIEW_FIX_CAP=1 "$CAP" fix t1 r1 review >/dev/null || fail "round 1"
  FM_HOME="$h" FM_REVIEW_FIX_CAP=1 "$CAP" fix t1 r1 review >/dev/null 2>&1 || rc=$?
  [ "$rc" = 3 ] || fail "capped before grant"
  FM_HOME="$h" "$CAP" grant t1 r1 review 2 >/dev/null || fail "grant"
  [ "$(FM_HOME="$h" FM_REVIEW_FIX_CAP=1 "$CAP" fix t1 r1 review)" = "fix-allowed: round 2 of 3" ] || fail "granted round"
  FM_HOME="$h" "$CAP" grant t1 r1 review 0 >/dev/null 2>&1 && fail "grant 0 should be refused"
}

test_timeout_reports_at_once() {
  local h rc=0; h=$(new_home timeout)
  FM_HOME="$h" "$CAP" timeout t1 r1 review --error "agent timed out after 30 minutes" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 3 ] || fail "timeout should exit 3, got $rc"
  assert_grep '[key=nm-r1-review-timeout]' "$h/state/t1.status" "timeout key"
  assert_grep 'not retrying' "$h/state/t1.status" "timeout says no silent retry"
}

test_non_timeout_error_is_ignored() {
  local h rc=0; h=$(new_home notimeout)
  FM_HOME="$h" "$CAP" timeout t1 r1 test --error "3 tests failed" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "non-timeout error should exit 1, got $rc"
  [ ! -e "$h/state/t1.status" ] || fail "non-timeout error must not write status"
}

test_rejects_bad_ids() {
  local h; h=$(new_home ids)
  FM_HOME="$h" "$CAP" fix 't 1' r1 review >/dev/null 2>&1 && fail "space in task id should be refused"
  FM_HOME="$h" "$CAP" fix t1 '../r' review >/dev/null 2>&1 && fail "path in run id should be refused"
  FM_HOME="$h" "$CAP" bogus >/dev/null 2>&1 && fail "unknown command should be refused"
  return 0
}

test_ledger_hook_runs_when_flag_present() {
  local h; h=$(new_home ledger)
  touch "$h/config/fleet-ledger"
  FM_HOME="$h" FM_REVIEW_FIX_CAP=0 "$CAP" fix t1 r1 review >/dev/null 2>&1
  [ -s "$h/state/t1.status" ] || fail "status written with the ledger flag present"
}

test_generated_no_mistakes_brief_carries_the_rule() {
  local h ship; h=$(new_home brief)
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" capworker sample --mode no-mistakes >/dev/null 2>&1
  ship="$h/data/capworker/brief.md"
  assert_grep 'Review fix rounds are capped at 2 per run and step' "$ship" "brief states the cap"
  assert_grep "fm-review-round-cap.sh' fix capworker <run> <step>" "$ship" "brief names the fix command with the task id"
  assert_grep "fm-review-round-cap.sh' timeout capworker <run> <step>" "$ship" "brief names the timeout command"
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" dpworker sample --mode direct-PR >/dev/null 2>&1
  assert_no_grep 'Review fix rounds are capped' "$h/data/dpworker/brief.md" "non-pipeline modes get no cap rule"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$t"
  pass "$t"
done
echo "PASS: fm-review-round-cap"
