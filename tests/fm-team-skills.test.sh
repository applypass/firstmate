#!/usr/bin/env bash
# tests/fm-team-skills.test.sh - bin/fm-team-skills.sh links team-skills/ into the
# skills folders of a temp HOME: install is idempotent, never overwrites a real
# directory or a link pointing elsewhere, uninstall removes only its own links,
# --dry-run changes nothing, and a link it cannot create or remove exits 1.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-team-skills.sh"
SKILLS=$(cd -P "$ROOT/team-skills" && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-team-skills)

new_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h"
  printf '%s\n' "$h"
}

run() {  # <home> <args...>: sets OUT and RC
  local h=$1; shift
  OUT=$(HOME="$h" "$SCRIPT" "$@" 2>&1)
  RC=$?
}

test_install_links_every_skill_into_both_folders() {
  local h name n=0; h=$(new_home fresh)
  run "$h" install
  assert_equals 0 "$RC" "install failed: $OUT"
  for src in "$SKILLS"/*/; do
    [ -f "$src/SKILL.md" ] || continue
    name=$(basename "$src"); n=$((n + 1))
    for dir in .claude/skills .agents/skills; do
      [ -L "$h/$dir/$name" ] || fail "missing link $dir/$name"
      assert_equals "${src%/}" "$(readlink "$h/$dir/$name")" "$dir/$name points elsewhere"
      assert_present "$h/$dir/$name/SKILL.md" "$dir/$name does not resolve to a skill"
    done
  done
  [ "$n" -gt 0 ] || fail "no skills found under team-skills/"
  pass "install links every skill into ~/.claude/skills and ~/.agents/skills"
}

test_install_is_idempotent() {
  local h; h=$(new_home idempotent)
  run "$h" install; run "$h" install
  assert_equals 0 "$RC" "second install failed: $OUT"
  assert_contains "$OUT" "0 new link(s)" "second install created links"
  assert_not_contains "$OUT" "Conflicts" "own links reported as conflicts"
  pass "a second install changes nothing"
}

test_install_never_overwrites_conflicts() {
  local h; h=$(new_home conflicts)
  mkdir -p "$h/.claude/skills/tdd" "$h/.agents/skills" "$h/elsewhere/diagnose"
  printf 'mine\n' > "$h/.claude/skills/tdd/SKILL.md"
  ln -s "$h/elsewhere/diagnose" "$h/.agents/skills/diagnose"
  run "$h" install
  assert_equals 0 "$RC" "install with conflicts failed: $OUT"
  assert_contains "$OUT" "$h/.claude/skills/tdd (existing file or directory)" "real directory not listed"
  assert_contains "$OUT" "$h/.agents/skills/diagnose (link to $h/elsewhere/diagnose)" "foreign link not listed"
  assert_equals mine "$(cat "$h/.claude/skills/tdd/SKILL.md")" "real directory was modified"
  assert_equals "$h/elsewhere/diagnose" "$(readlink "$h/.agents/skills/diagnose")" "foreign link was replaced"
  [ -L "$h/.claude/skills/zoom-out" ] || fail "non-conflicting skills were not installed"
  pass "install skips and lists conflicts without touching them"
}

test_uninstall_removes_only_own_links() {
  local h; h=$(new_home uninstall)
  mkdir -p "$h/.claude/skills/tdd" "$h/elsewhere/diagnose"
  ln -s "$h/elsewhere/diagnose" "$h/.claude/skills/diagnose"
  run "$h" install; run "$h" uninstall
  assert_equals 0 "$RC" "uninstall failed: $OUT"
  assert_absent "$h/.claude/skills/zoom-out" "own link survived uninstall"
  assert_absent "$h/.agents/skills/zoom-out" "own link survived uninstall"
  assert_present "$h/.claude/skills/tdd/." "real directory was removed"
  assert_equals "$h/elsewhere/diagnose" "$(readlink "$h/.claude/skills/diagnose")" "foreign link was removed"
  pass "uninstall removes only links it owns"
}

test_dry_run_changes_nothing() {
  local h; h=$(new_home dry)
  run "$h" --dry-run install
  assert_equals 0 "$RC" "dry run failed: $OUT"
  assert_contains "$OUT" "[dry-run] link" "dry run printed no plan"
  assert_absent "$h/.claude" "dry run created ~/.claude"
  assert_absent "$h/.agents" "dry run created ~/.agents"
  run "$h" install; run "$h" --dry-run uninstall
  [ -L "$h/.claude/skills/zoom-out" ] || fail "dry-run uninstall removed a link"
  pass "--dry-run changes nothing"
}

test_failed_link_or_removal_exits_1() {
  local h; h=$(new_home failing)
  mkdir -p "$h/.agents" && chmod 555 "$h/.agents"
  run "$h" install
  chmod 755 "$h/.agents"
  assert_equals 1 "$RC" "install with an unwritable ~/.agents must exit 1: $OUT"
  assert_contains "$OUT" "Failed:" "failed links not reported"
  assert_contains "$OUT" "link $h/.agents/skills/zoom-out" "failed link not listed"
  [ -L "$h/.claude/skills/zoom-out" ] || fail "writable folder was not linked"
  assert_absent "$h/.agents/skills" "unwritable folder gained a skills dir"
  run "$h" install
  assert_equals 0 "$RC" "install after fixing permissions failed: $OUT"
  chmod 555 "$h/.claude/skills"
  run "$h" uninstall
  chmod 755 "$h/.claude/skills"
  assert_equals 1 "$RC" "uninstall with an unwritable folder must exit 1: $OUT"
  assert_contains "$OUT" "remove $h/.claude/skills/zoom-out" "failed removal not listed"
  [ -L "$h/.claude/skills/zoom-out" ] || fail "link vanished despite failed removal"
  assert_absent "$h/.agents/skills/zoom-out" "writable folder link survived uninstall"
  pass "a link the script could not create or remove exits 1"
}

test_bad_usage_exits_2() {
  local h; h=$(new_home usage)
  run "$h"; assert_equals 2 "$RC" "no command must exit 2"
  run "$h" frobnicate; assert_equals 2 "$RC" "unknown argument must exit 2"
  pass "bad usage exits 2"
}

test_every_skill_carries_license_or_credit() {
  local d name
  for d in "$ROOT"/team-skills/*/; do
    [ -f "$d/SKILL.md" ] || continue
    name=$(basename "$d")
    assert_present "$d/SOURCE" "$name has no SOURCE note"
    [ -f "$d/LICENSE" ] || assert_grep "Credit:" "$d/SOURCE" "$name has neither LICENSE nor a credit line"
  done
  pass "every skill has a SOURCE note and a LICENSE or credit line"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_install_links_every_skill_into_both_folders
  test_install_is_idempotent
  test_install_never_overwrites_conflicts
  test_uninstall_removes_only_own_links
  test_dry_run_changes_nothing
  test_failed_link_or_removal_exits_1
  test_bad_usage_exits_2
  test_every_skill_carries_license_or_credit
fi
