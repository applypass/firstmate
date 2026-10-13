#!/usr/bin/env bash
# tests/fm-fork-footprint.test.sh - bin/fm-fork-footprint.sh keeps the applypass
# fork easy to resync with upstream. Each case builds a throwaway repo with an
# upstream ref, a fork base, and a branch, then runs the real script on it:
# edits outside a Fork-only block go red, fork-only files and in-block additions
# stay green, and the ledger lets a listed file change.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-fork-footprint.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-footprint)

GIT=(git -c user.name='Firstmate Tests' -c user.email='tests@example.invalid')

# new_repo <name>: upstream has app.sh and lib.sh; the fork base adds a ledger
# listing lib.sh only; branch "feat" starts from the base.
new_repo() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/.fork"
  git -C "$dir" init -q -b upstream
  printf 'one\ntwo\nthree\nfour\nfive\n' > "$dir/app.sh"
  printf 'a\nb\nc\n' > "$dir/lib.sh"
  git -C "$dir" add -A
  "${GIT[@]}" -C "$dir" commit -qm upstream
  git -C "$dir" checkout -q -b main
  printf '%s\n' '- `lib.sh` - fork needs it' > "$dir/.fork/ledger.md"
  git -C "$dir" add -A
  "${GIT[@]}" -C "$dir" commit -qm 'fork base'
  git -C "$dir" checkout -q -b feat
  printf '%s\n' "$dir"
}

commit_all() {
  git -C "$1" add -A
  "${GIT[@]}" -C "$1" commit -qm change
}

# run_check <repo>: sets OUT and RC.
run_check() {
  OUT=$(cd "$1" && "$CHECK" --base main --upstream upstream 2>&1)
  RC=$?
}

test_fork_only_file_is_green() {
  local d; d=$(new_repo fork-only)
  printf 'new\n' > "$d/new-fork-file.sh"; commit_all "$d"
  run_check "$d"
  assert_equals 0 "$RC" "a new fork-only file must pass: $OUT"
  assert_contains "$OUT" "Fork footprint vs upstream main" "summary heading missing"
  assert_contains "$OUT" "touched by this change: 0" "fork-only file counted as upstream"
  pass "fork-only file stays green"
}

test_in_block_addition_is_green() {
  local d; d=$(new_repo in-block)
  sed -i.bak '2a\
# Fork-only: applypass hook\
run_hook\
# Fork-only end' "$d/app.sh"; rm -f "$d/app.sh.bak"; commit_all "$d"
  run_check "$d"
  assert_equals 0 "$RC" "an in-block addition must pass: $OUT"
  assert_contains "$OUT" "app.sh (+3/-0): Fork-only block" "block not reported"
  pass "in-block edit stays green"
}

test_edit_outside_block_is_red() {
  local d; d=$(new_repo outside)
  sed -i.bak 's/three/THREE/' "$d/app.sh"; rm -f "$d/app.sh.bak"; commit_all "$d"
  run_check "$d"
  assert_equals 1 "$RC" "a rewritten upstream line must fail"
  assert_contains "$OUT" "app.sh:3: removes or rewrites" "violation not named with its line"
  assert_contains "$OUT" "FAIL" "result line missing"
  pass "edit outside a block goes red"
}

test_unmarked_addition_is_red() {
  local d; d=$(new_repo unmarked)
  sed -i.bak '2a\
extra' "$d/app.sh"; rm -f "$d/app.sh.bak"; commit_all "$d"
  run_check "$d"
  assert_equals 1 "$RC" "an unmarked addition must fail"
  assert_contains "$OUT" "not opened by a Fork-only marker" "reason missing"
  pass "unmarked addition goes red"
}

test_deletion_is_red() {
  local d; d=$(new_repo deletion)
  sed -i.bak '2d' "$d/app.sh"; rm -f "$d/app.sh.bak"; commit_all "$d"
  run_check "$d"
  assert_equals 1 "$RC" "deleting an upstream line must fail"
  pass "deletion goes red"
}

test_oversized_block_is_red() {
  local d i; d=$(new_repo oversized)
  { printf '# Fork-only: too big\n'; for i in $(seq 1 45); do printf 'x%s\n' "$i"; done; } >> "$d/app.sh"
  commit_all "$d"
  run_check "$d"
  assert_equals 1 "$RC" "a block over the line limit must fail"
  assert_contains "$OUT" "max 40" "limit not named"
  pass "oversized block goes red"
}

test_ledger_file_may_change() {
  local d; d=$(new_repo ledger)
  sed -i.bak 's/b/B/' "$d/lib.sh"; rm -f "$d/lib.sh.bak"; commit_all "$d"
  run_check "$d"
  assert_equals 0 "$RC" "a ledger file may change: $OUT"
  assert_contains "$OUT" "on the fork ledger" "ledger status not reported"
  pass "ledger file stays green"
}

test_missing_upstream_ref_is_an_error() {
  local d; d=$(new_repo noref)
  OUT=$(cd "$d" && "$CHECK" --base main --upstream nope/main 2>&1); RC=$?
  assert_equals 2 "$RC" "a missing upstream ref must be a usage error"
  assert_contains "$OUT" "upstream ref 'nope/main' not found" "message missing"
  pass "missing upstream ref is reported"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_fork_only_file_is_green
  test_in_block_addition_is_green
  test_edit_outside_block_is_red
  test_unmarked_addition_is_red
  test_deletion_is_red
  test_oversized_block_is_red
  test_ledger_file_may_change
  test_missing_upstream_ref_is_an_error
fi
