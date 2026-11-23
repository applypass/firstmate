#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for bin/fm-nm-base-skip-pretool-check.sh.
#
# The forge is a stub `gh` on PATH that prints the PR base from $STUB_BASE (or
# fails when unset), so no network or real no-mistakes is involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-base-skip)
CHECK="$ROOT/bin/fm-nm-base-skip-pretool-check.sh"
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_BASE:-}" ] || exit 1
printf '%s\n' "$STUB_BASE"
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

RUN='no-mistakes axi run --intent "ship it"'

# A clone whose origin names the project, as a worker worktree does. The default
# project declares CI test checks in .fork/ci-test-checks.
make_clone() {  # <project>
  mkdir -p "$TMP_ROOT/clones/$1"
  git -C "$TMP_ROOT/clones/$1" init -q
  git -C "$TMP_ROOT/clones/$1" remote add origin "https://github.com/applypass/$1.git"
}
make_clone apply_pass_backend
make_clone apply_pass_frontend
make_clone ai_backend
make_clone never-declared

run_check_in() {  # <project> <base or empty> <command>
  CHECK_OUT=$(STUB_BASE="$2" "$CHECK" --command "$3" --cwd "$TMP_ROOT/clones/$1" --claude 2>&1)
  CHECK_RC=$?
}

run_check() {  # <base or empty> <command>
  run_check_in apply_pass_backend "$1" "$2"
}

test_dev_base_without_skip_refused() {
  run_check dev "$RUN"
  expect_code 2 "$CHECK_RC" "dev base without --skip test is refused"
  assert_contains "$CHECK_OUT" '[nm-base-skip]' "names the check"
  assert_contains "$CHECK_OUT" 'skips the local test step' "says why"
  pass "dev-base run without --skip test is refused"
}

test_dev_base_with_skip_allowed() {
  run_check dev "$RUN --skip test"
  expect_code 0 "$CHECK_RC" "dev base with --skip test"
  [ -z "$CHECK_OUT" ] || fail "allowed case printed output: $CHECK_OUT"
  run_check dev "$RUN --skip push,pr,ci,test"
  expect_code 0 "$CHECK_RC" "dev base with a skip list holding test"
  pass "dev-base run that skips test is allowed"
}

test_dev_base_with_other_skips_refused() {
  run_check dev "$RUN --skip push,pr,ci"
  expect_code 2 "$CHECK_RC" "dev base skipping other steps only"
  run_check dev "$RUN --skip pr,ci,testing"
  expect_code 2 "$CHECK_RC" "a step merely named like test does not count"
  pass "a skip list without the test step is refused on dev"
}

test_dev_base_frontend_declares_checks() {
  run_check_in apply_pass_frontend dev "$RUN"
  expect_code 2 "$CHECK_RC" "frontend declares CI test checks, so dev must skip test"
  run_check_in apply_pass_frontend dev "$RUN --skip test"
  expect_code 0 "$CHECK_RC" "frontend dev run that skips test"
  pass "a project with declared CI test checks is held to --skip test on dev"
}

test_dev_base_without_ci_test_checks_keeps_local_tests() {
  local project
  for project in ai_backend never-declared; do
    run_check_in "$project" dev "$RUN"
    expect_code 0 "$CHECK_RC" "$project dev run without skip keeps the local test step"
    [ -z "$CHECK_OUT" ] || fail "allowed case printed output: $CHECK_OUT"
    run_check_in "$project" dev "$RUN --skip push,pr,ci,test"
    expect_code 2 "$CHECK_RC" "$project dev run must not skip the only tests"
    assert_contains "$CHECK_OUT" 'declares no CI test check' "says why"
    assert_contains "$CHECK_OUT" 'Re-run the same command without' "names the fix"
  done
  pass "a dev-bound project with no CI test checks keeps the local test step"
}

test_unreadable_project_keeps_local_tests() {
  CHECK_OUT=$(STUB_BASE=dev "$CHECK" --command "$RUN --skip test" --cwd "$TMP_ROOT" --claude 2>&1)
  expect_code 2 $? "no origin remote means no declared checks, so skipping test is refused"
  pass "an unreadable project is treated as having no CI test checks"
}

test_captain_override_declares_checks() {
  mkdir -p "$TMP_ROOT/home/config"
  printf '%s\n' 'never-declared smoke' > "$TMP_ROOT/home/config/ci-test-checks"
  CHECK_OUT=$(FM_HOME="$TMP_ROOT/home" STUB_BASE=dev "$CHECK" --command "$RUN" --cwd "$TMP_ROOT/clones/never-declared" --claude 2>&1)
  expect_code 2 $? "an override declaring checks makes dev require --skip test"
  pass "config/ci-test-checks can declare checks for a project"
}

test_main_base_keeps_tests() {
  run_check main "$RUN"
  expect_code 0 "$CHECK_RC" "main base without skip"
  [ -z "$CHECK_OUT" ] || fail "allowed case printed output: $CHECK_OUT"
  run_check main "$RUN --skip test"
  expect_code 2 "$CHECK_RC" "main base skipping test"
  assert_contains "$CHECK_OUT" 'keeps the test step' "says main keeps tests"
  pass "main-base run keeps the test step"
}

test_unknown_base_keeps_full_run() {
  run_check "" "$RUN"
  expect_code 0 "$CHECK_RC" "unknown base, no skip"
  run_check "" "$RUN --skip test"
  expect_code 0 "$CHECK_RC" "unknown base is left alone"
  pass "an unreadable base leaves the command alone"
}

test_base_branch_flag_wins() {
  run_check main "$RUN --base-branch dev"
  expect_code 2 "$CHECK_RC" "--base-branch dev overrides the PR base"
  run_check dev "$RUN --base-branch main"
  expect_code 0 "$CHECK_RC" "--base-branch main overrides the PR base"
  pass "--base-branch decides the base"
}

test_only_new_runs_checked() {
  local c
  for c in 'no-mistakes axi run' 'no-mistakes axi status' 'no-mistakes axi respond --run 1' 'git status'; do
    run_check dev "$c"
    expect_code 0 "$CHECK_RC" "not a new run: $c"
  done
  pass "only a new run is checked"
}

test_hook_payload() {
  local out
  out=$(printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' 'no-mistakes axi run --intent x' "$TMP_ROOT/clones/apply_pass_backend" \
    | STUB_BASE=dev "$CHECK" --claude 2>&1)
  expect_code 2 $? "payload command is checked"
  assert_contains "$out" '"permissionDecision":"deny"' "deny object"
  pass "the PreToolUse payload drives the check"
}

test_installer_registers_hook() {
  local dir="$TMP_ROOT/inst"
  mkdir -p "$dir"
  HOME="$TMP_ROOT" "$ROOT/bin/fm-op-guard-install.sh" "$dir" || fail "installer failed"
  jq -e '[.hooks.PreToolUse[].hooks[].command | select(contains("fm-nm-base-skip-pretool-check.sh"))] | length == 1' \
    "$dir/.claude/settings.local.json" >/dev/null || fail "installer did not register the check once"
  pass "the op guard installer registers the base-skip check"
}

test_dev_base_without_skip_refused
test_dev_base_with_skip_allowed
test_dev_base_with_other_skips_refused
test_dev_base_frontend_declares_checks
test_dev_base_without_ci_test_checks_keeps_local_tests
test_unreadable_project_keeps_local_tests
test_captain_override_declares_checks
test_main_base_keeps_tests
test_unknown_base_keeps_full_run
test_base_branch_flag_wins
test_only_new_runs_checked
test_hook_payload
test_installer_registers_hook
