#!/usr/bin/env bash
# Fork-only: behavior tests for the handbook pointer block in bin/fm-brief.sh (bin/fm-handbook-lib.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-handbook-brief)

# make_home <name> <with-index: 1|0> - a home fixture, optionally holding the handbook INDEX.md.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  if [ "$2" = 1 ]; then
    mkdir -p "$home/data/firstmate-handbook"
    printf '# Firstmate handbook\n' > "$home/data/firstmate-handbook/INDEX.md"
  fi
  printf '%s\n' "$home"
}

foreign_project() {
  local proj="$TMP_ROOT/foreign-proj"
  [ -d "$proj" ] || {
    git init -q "$proj" || fail "could not initialize foreign project fixture"
    git -C "$proj" -c user.name=fixture -c user.email=fixture@example.invalid \
      commit -q --allow-empty -m init || fail "could not commit in foreign project fixture"
  }
  printf '%s\n' "$proj"
}

test_ship_brief_names_absolute_index_for_firstmate_repo() {
  local home brief
  home=$(make_home ship-with-index 1)
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" hb-ship1 firstmate --mode local-only --project "$ROOT" >/dev/null 2>&1 \
    || fail "ship scaffold for the firstmate repo exited non-zero"
  brief="$home/data/hb-ship1/brief.md"
  assert_grep "# Firstmate handbook" "$brief" "ship brief missing the handbook block"
  assert_grep "$home/data/firstmate-handbook/INDEX.md" "$brief" "ship brief did not name the absolute INDEX.md path"
  assert_grep "Read-only" "$brief" "ship brief did not say the handbook is read-only"
  assert_grep "makes stale, or \"none\"" "$brief" "ship brief did not ask for the stale topic file"
  pass "fm-brief.sh: ship brief on the firstmate repo names the absolute handbook INDEX.md"
}

test_scout_brief_names_absolute_index_for_firstmate_repo() {
  local home brief
  home=$(make_home scout-with-index 1)
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" hb-scout1 firstmate --scout --project "$ROOT" >/dev/null 2>&1 \
    || fail "scout scaffold for the firstmate repo exited non-zero"
  brief="$home/data/hb-scout1/brief.md"
  assert_grep "$home/data/firstmate-handbook/INDEX.md" "$brief" "scout brief did not name the absolute INDEX.md path"
  pass "fm-brief.sh: scout brief on the firstmate repo names the absolute handbook INDEX.md"
}

test_block_absent_when_index_missing() {
  local home brief
  home=$(make_home no-index 0)
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" hb-ship2 firstmate --mode local-only --project "$ROOT" >/dev/null 2>&1 \
    || fail "ship scaffold without an INDEX.md exited non-zero"
  brief="$home/data/hb-ship2/brief.md"
  grep -q "Firstmate handbook" "$brief" && fail "handbook block emitted although INDEX.md is absent"
  pass "fm-brief.sh: no handbook block when the home has no INDEX.md"
}

test_block_absent_for_non_firstmate_project() {
  local home brief proj
  home=$(make_home foreign 1)
  proj=$(foreign_project)
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" hb-ship3 other --mode local-only --project "$proj" >/dev/null 2>&1 \
    || fail "ship scaffold for a foreign project exited non-zero"
  brief="$home/data/hb-ship3/brief.md"
  grep -q "Firstmate handbook" "$brief" && fail "handbook block emitted for a non-firstmate project"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" hb-scout3 other --scout --project "$proj" >/dev/null 2>&1 \
    || fail "scout scaffold for a foreign project exited non-zero"
  grep -q "Firstmate handbook" "$home/data/hb-scout3/brief.md" && fail "handbook block emitted in a foreign scout brief"
  pass "fm-brief.sh: no handbook block for a non-firstmate project"
}

test_block_absent_without_project() {
  local home
  home=$(make_home no-project 1)
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" hb-ship4 firstmate --mode local-only >/dev/null 2>&1 \
    || fail "ship scaffold without --project exited non-zero"
  grep -q "Firstmate handbook" "$home/data/hb-ship4/brief.md" && fail "handbook block emitted without --project"
  pass "fm-brief.sh: no handbook block when --project is not passed"
}

test_ship_brief_names_absolute_index_for_firstmate_repo
test_scout_brief_names_absolute_index_for_firstmate_repo
test_block_absent_when_index_missing
test_block_absent_for_non_firstmate_project
test_block_absent_without_project
