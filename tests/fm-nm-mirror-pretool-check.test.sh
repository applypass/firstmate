#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for bin/fm-nm-mirror-pretool-check.sh.
#
# Uses throwaway git repos only: a "forge" bare repo, a no-mistakes "gate" bare
# repo, and a worktree with remotes origin and no-mistakes. No network, no real
# no-mistakes, claude or codex. The check only reads, so the tests also assert
# the gate refs are untouched after a refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-mirror-check)
CHECK="$ROOT/bin/fm-nm-mirror-pretool-check.sh"
RUN='no-mistakes axi run --intent "ship it"'

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# new_case <name>: forge + gate + worktree on branch feat with one base commit
# and one feature commit, pushed to both remotes. Sets W (worktree), GATE, FORGE.
new_case() {
  local d="$TMP_ROOT/$1"
  FORGE="$d/forge.git"; GATE="$d/gate.git"; W="$d/wt"
  mkdir -p "$d"
  git init -q --bare -b main "$FORGE"
  git init -q --bare -b main "$GATE"
  git init -q -b main "$W"
  git -C "$W" remote add origin "$FORGE"
  git -C "$W" remote add no-mistakes "$GATE"
  echo base > "$W/a"; git -C "$W" add a; git -C "$W" commit -qm base
  git -C "$W" push -q origin main
  git -C "$W" checkout -q -b feat
  echo one > "$W/b"; git -C "$W" add b; git -C "$W" commit -qm one
  git -C "$W" push -q origin feat
  git -C "$W" push -q no-mistakes feat
}

run_check() {  # <command>
  CHECK_OUT=$("$CHECK" --command "$1" --cwd "$W" --claude 2>&1)
  CHECK_RC=$?
}

assert_allowed() {  # <label> <command>
  run_check "$2"
  expect_code 0 "$CHECK_RC" "allowed: $1"
  [ -z "$CHECK_OUT" ] || fail "allowed case printed output: $1: $CHECK_OUT"
}

test_clean_fast_forward_allowed() {
  new_case ff
  echo two > "$W/c"; git -C "$W" add c; git -C "$W" commit -qm two
  assert_allowed "mirror behind HEAD (fast-forward)" "$RUN"
  pass "clean fast-forward is allowed"
}

test_no_mirror_branch_allowed() {
  new_case nomirror
  git -C "$GATE" update-ref -d refs/heads/feat
  assert_allowed "no mirror branch yet" "$RUN"
  pass "missing mirror branch is allowed"
}

test_rebased_copy_allowed() {
  new_case rebased
  # Rebase the feature commit onto a new main commit: same patch, new SHA.
  # origin/feat and the mirror both keep the pre-rebase commit; the run
  # pushes the rebased branch itself.
  git -C "$W" checkout -q main
  echo m2 > "$W/m"; git -C "$W" add m; git -C "$W" commit -qm m2
  git -C "$W" checkout -q feat
  git -C "$W" rebase -q main
  assert_allowed "mirror holds only an equivalent pre-rebase copy" "$RUN"
  pass "a pre-rebase mirror whose patches HEAD already carries is allowed"
}

test_diverged_mirror_refused_fast() {
  new_case div
  # The pipeline's fix commit exists only in the mirror; the worker then
  # moves on locally without syncing it back.
  git -C "$W" checkout -q -b scratch
  echo fix > "$W/fix"; git -C "$W" add fix; git -C "$W" commit -qm "no-mistakes(review): fix"
  git -C "$W" push -q -f no-mistakes scratch:feat
  local mirror before after start end
  mirror=$(git -C "$GATE" rev-parse refs/heads/feat)
  git -C "$W" checkout -q feat
  echo two > "$W/c"; git -C "$W" add c; git -C "$W" commit -qm two
  local head
  head=$(git -C "$W" rev-parse HEAD)
  before=$(git -C "$GATE" for-each-ref)
  start=$(date +%s%N 2>/dev/null || date +%s)
  run_check "$RUN"
  end=$(date +%s%N 2>/dev/null || date +%s)
  after=$(git -C "$GATE" for-each-ref)
  expect_code 2 "$CHECK_RC" "diverged mirror is refused"
  assert_contains "$CHECK_OUT" '"permissionDecision":"deny"' "deny object"
  assert_contains "$CHECK_OUT" "$mirror" "message names the mirror SHA"
  assert_contains "$CHECK_OUT" "$head" "message names the local HEAD SHA"
  assert_contains "$CHECK_OUT" "no-mistakes sync" "message names the safe fix"
  assert_contains "$CHECK_OUT" "Never force-push" "message forbids touching the mirror"
  [ "$before" = "$after" ] || fail "check changed the gate refs"
  case "$start$end" in
    *[!0-9]*) ;;
    *) [ $(( (end - start) / 1000000 )) -lt 1000 ] || fail "refusal took $(( (end - start) / 1000000 )) ms" ;;
  esac
  pass "diverged mirror is refused in under a second, naming both SHAs, without touching the gate"
}

test_only_new_runs_checked() {
  new_case reattach
  git -C "$W" checkout -q -b scratch
  echo fix > "$W/fix"; git -C "$W" add fix; git -C "$W" commit -qm fix
  git -C "$W" push -q -f no-mistakes scratch:feat
  git -C "$W" checkout -q feat
  run_check "$RUN"
  expect_code 2 "$CHECK_RC" "new run is refused on a diverged mirror"
  local c
  for c in 'no-mistakes axi run' 'no-mistakes axi status' 'no-mistakes axi respond --action fix' \
    'no-mistakes rerun' 'no-mistakes sync --check' 'git status' 'echo hi'; do
    assert_allowed "$c" "$c"
  done
  pass "reattach, respond, status, sync and unrelated commands are never blocked"
}

test_fail_open() {
  new_case open
  local out
  out=$(printf 'not json' | "$CHECK" --claude 2>&1); expect_code 0 $? "malformed stdin"
  out=$(printf '' | "$CHECK" --claude 2>&1); expect_code 0 $? "empty stdin"
  git -C "$W" checkout -q --detach
  run_check "$RUN"; expect_code 0 "$CHECK_RC" "detached HEAD"
  git -C "$W" checkout -q feat
  git -C "$W" remote remove no-mistakes
  run_check "$RUN"; expect_code 0 "$CHECK_RC" "no no-mistakes remote"
  CHECK_OUT=$("$CHECK" --command "$RUN" --cwd "$TMP_ROOT" --claude 2>&1)
  expect_code 0 $? "not a git repo"
  pass "unreadable or missing state fails open"
}

test_hook_payload() {
  new_case payload
  git -C "$W" checkout -q -b scratch
  echo fix > "$W/fix"; git -C "$W" add fix; git -C "$W" commit -qm fix
  git -C "$W" push -q -f no-mistakes scratch:feat
  git -C "$W" checkout -q feat
  local out
  out=$(jq -nc --arg c "$RUN" --arg d "$W" '{tool_input:{command:$c},cwd:$d}' | "$CHECK" --claude 2>&1)
  expect_code 2 $? "payload cwd is used"
  assert_contains "$out" '"permissionDecision":"deny"' "payload deny object"
  pass "the PreToolUse payload's command and cwd drive the check"
}

test_installer_registers_hook() {
  local dir="$TMP_ROOT/inst"
  mkdir -p "$dir"
  HOME="$TMP_ROOT" "$ROOT/bin/fm-op-guard-install.sh" "$dir" || fail "installer failed"
  jq -e '[.hooks.PreToolUse[].hooks[].command | select(contains("fm-nm-mirror-pretool-check.sh"))] | length == 1' \
    "$dir/.claude/settings.local.json" >/dev/null || fail "installer did not register the mirror check once"
  pass "the op guard installer also registers the mirror check"
}

test_scripts_are_shellcheck_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-nm-mirror-pretool-check.sh" 2>&1) || fail "not lint-clean: $out"
  pass "mirror check is clean under bin/fm-lint.sh"
}

test_clean_fast_forward_allowed
test_no_mirror_branch_allowed
test_rebased_copy_allowed
test_diverged_mirror_refused_fast
test_only_new_runs_checked
test_fail_open
test_hook_payload
test_installer_registers_hook
test_scripts_are_shellcheck_clean
