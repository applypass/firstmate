#!/usr/bin/env bash
# Behavior tests for the validation release gate (bin/fm-validation-gate.sh).
#
# The gate holds a ship task's full no-mistakes run until firstmate releases
# it. no-mistakes starts a run when its per-repo bare gate receives a push, and
# `no-mistakes axi run` pushes with --no-verify, so the gate is a companion
# pre-receive hook inside that bare gate. These cases never contact a real
# no-mistakes daemon: each builds a scratch bare gate whose pre-receive keeps
# no-mistakes' companion contract (exec hooks/pre-receive.no-mistakes-user when
# executable) and whose post-receive records that a pipeline would have started.
set -u

# A fleet pane already carries these; every case sets what it needs itself.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

GATE="$ROOT/bin/fm-validation-gate.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-validation-gate)

fm_git_identity 'Gate Tests' 'gate@example.invalid'

# tests/lib.sh pins the suite to the upstream default (off). These cases opt in
# through a defaults file of their own, so the fork's tracked default never
# decides a verdict here.
ON_DEFAULTS="$TMP_ROOT/defaults-on"
printf 'on\n' >"$ON_DEFAULTS"
OFF_DEFAULTS="$TMP_ROOT/defaults-absent"

with_gate_on() { FM_TEST_VALIDATION_GATE_DEFAULTS="$ON_DEFAULTS" "$@"; }
with_gate_off() { FM_TEST_VALIDATION_GATE_DEFAULTS="$OFF_DEFAULTS" "$@"; }

# make_gate <bare-dir>: a scratch no-mistakes gate that keeps the companion
# contract and logs "started <ref> <sha>" for every ref the post-receive sees.
make_gate() {
  local gate=$1
  git init -q --bare "$gate"
  cat >"$gate/hooks/pre-receive" <<'SH'
#!/bin/sh
# no-mistakes pre-receive hook (test stand-in for daemon admit-push)
GATE_DIR=$(git rev-parse --absolute-git-dir 2>/dev/null || :)
USER_HOOK="$GATE_DIR/hooks/pre-receive.no-mistakes-user"
if [ -x "$USER_HOOK" ]; then
  exec "$USER_HOOK"
fi
exit 0
SH
  cat >"$gate/hooks/post-receive" <<'SH'
#!/bin/sh
GATE_DIR=$(git rev-parse --absolute-git-dir 2>/dev/null || :)
while read -r old new ref; do
  printf 'started %s %s\n' "$ref" "$new" >>"$GATE_DIR/pipeline-started.log"
done
exit 0
SH
  chmod +x "$gate/hooks/pre-receive" "$gate/hooks/post-receive"
}

# make_world <name>: a home, a project with origin and a scratch gate, and a
# task worktree on fm/<name>. Sets HOME_DIR PROJ_DIR WT_DIR GATE_DIR STATE_DIR.
make_world() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  GATE_DIR="$case_dir/gate.git"
  fm_test_spawn_home "$HOME_DIR" codex
  STATE_DIR=$(cd "$HOME_DIR/state" && pwd -P)
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "fm/$name"
  make_gate "$GATE_DIR"
  git -C "$PROJ_DIR" remote add no-mistakes "$GATE_DIR"
}

commit_in() {  # <worktree> <message>
  printf '%s\n' "$2" >>"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q -m "$2"
}

# push_gate <worktree> <task-id> [git push args...]: push HEAD to the gate as
# `no-mistakes axi run` does (--no-verify), from a pane carrying the task's gate.
push_gate() {
  local wt=$1 id=$2 branch
  shift 2
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
  FM_VALIDATION_GATE="$STATE_DIR/$id.validation-gate" \
    git -C "$wt" push --no-verify "$@" no-mistakes "HEAD:refs/heads/$branch" 2>&1
}

started_count() {
  [ -f "$GATE_DIR/pipeline-started.log" ] || { echo 0; return; }
  wc -l <"$GATE_DIR/pipeline-started.log" | tr -d ' '
}

write_task_meta() {  # <id> [kind]
  fm_write_meta "$STATE_DIR/$1.meta" "worktree=$WT_DIR" "kind=${2:-ship}" \
    "mode=no-mistakes" "branch=fm/$1" "validation_gate=on"
}

prepare_ship() {  # <id> [extra prepare args...]
  local id=$1
  shift
  with_gate_on "$GATE" prepare --config "$HOME_DIR/config" --state "$STATE_DIR" \
    --kind ship --mode no-mistakes --forge none --worktree "$WT_DIR" --id "$id" "$@"
}

release_task() {  # <id>
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" "$GATE" release "$@"
}

test_pre_release_push_is_refused() {
  local out status
  make_world held
  write_task_meta held
  prepare_ship held >/dev/null || fail "prepare should succeed on a gate with companion support"
  commit_in "$WT_DIR" 'feat: iterate'
  out=$(push_gate "$WT_DIR" held)
  status=$?
  [ "$status" -ne 0 ] || fail "a push to the gate before release should be refused: $out"
  assert_contains "$out" "has not been released" "the refusal should say the run is not released"
  assert_contains "$out" "push to origin" "the refusal should tell the worker what to do instead"
  assert_equals 0 "$(started_count)" "a refused push must not start a pipeline"
  pass "a push to the no-mistakes gate before release is refused and starts no run"
}

test_released_head_is_accepted_and_only_that_head() {
  local out status head
  make_world released
  write_task_meta released
  prepare_ship released >/dev/null || fail "prepare should succeed"
  commit_in "$WT_DIR" 'feat: final version'
  head=$(git -C "$WT_DIR" rev-parse HEAD)
  out=$(release_task released) || fail "release should succeed: $out"
  assert_contains "$out" "$head" "release should name the released head"
  assert_equals "released $head" "$(cat "$STATE_DIR/released.validation-gate")" \
    "release should record the worktree HEAD"
  out=$(push_gate "$WT_DIR" released)
  status=$?
  expect_code 0 "$status" "the released head should be admitted: $out"
  assert_equals 1 "$(started_count)" "the released push should start exactly one run"

  commit_in "$WT_DIR" 'feat: one more change'
  out=$(push_gate "$WT_DIR" released)
  status=$?
  [ "$status" -ne 0 ] || fail "a head other than the released one should be refused: $out"
  assert_equals 1 "$(started_count)" "a later head must not start a second run without a new release"
  pass "release admits exactly the released head; a later head needs a new release"
}

test_release_refuses_an_ungated_task() {
  local out
  make_world ungated
  write_task_meta ungated
  out=$(release_task ungated 2>&1) && fail "release of a task with no gate should fail: $out"
  assert_contains "$out" "not gated" "the refusal should say the task is not gated"
  pass "release refuses a task the gate never held"
}

test_origin_push_is_always_accepted() {
  local out status
  make_world origin
  write_task_meta origin
  prepare_ship origin >/dev/null || fail "prepare should succeed"
  commit_in "$WT_DIR" 'feat: iterate'
  out=$(FM_VALIDATION_GATE="$STATE_DIR/origin.validation-gate" \
    git -C "$WT_DIR" push -q origin HEAD:refs/heads/fm/origin 2>&1)
  status=$?
  expect_code 0 "$status" "a push to origin while held should succeed: $out"
  pass "pushes to origin are never gated"
}

test_no_verify_and_hookspath_overrides_still_refused() {
  local out status empty
  make_world bypass
  write_task_meta bypass
  prepare_ship bypass >/dev/null || fail "prepare should succeed"
  commit_in "$WT_DIR" 'feat: iterate'
  empty="$TMP_ROOT/empty-hooks"
  mkdir -p "$empty"
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$empty" \
    push_gate "$WT_DIR" bypass -c "core.hooksPath=$empty")
  status=$?
  [ "$status" -ne 0 ] || fail "--no-verify plus hooksPath overrides should still be refused: $out"
  out=$(FM_VALIDATION_GATE="$STATE_DIR/bypass.validation-gate" \
    git -c "core.hooksPath=$empty" -C "$WT_DIR" push --no-verify no-mistakes HEAD:refs/heads/fm/bypass 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "git -c core.hooksPath push --no-verify should still be refused: $out"
  assert_equals 0 "$(started_count)" "no override may start a pipeline"
  pass "--no-verify and core.hooksPath overrides cannot skip the gate"
}

test_push_without_the_pane_variable_is_upstream_behaviour() {
  local out status
  make_world nonfleet
  write_task_meta nonfleet
  prepare_ship nonfleet >/dev/null || fail "prepare should succeed"
  commit_in "$WT_DIR" 'feat: captain push'
  out=$(git -C "$WT_DIR" push --no-verify no-mistakes HEAD:refs/heads/fm/nonfleet 2>&1)
  status=$?
  expect_code 0 "$status" "a push that carries no task gate should be admitted: $out"
  assert_equals 1 "$(started_count)" "an ungated push should start a run as upstream does"
  pass "a push with no task gate variable keeps upstream behaviour"
}

test_ref_deletion_is_allowed() {
  local out status
  make_world deletion
  write_task_meta deletion
  prepare_ship deletion >/dev/null || fail "prepare should succeed"
  git -C "$WT_DIR" push -q --no-verify no-mistakes HEAD:refs/heads/scratch 2>/dev/null \
    || fail "seeding a scratch ref without the variable should succeed"
  out=$(FM_VALIDATION_GATE="$STATE_DIR/deletion.validation-gate" \
    git -C "$WT_DIR" push --no-verify no-mistakes :refs/heads/scratch 2>&1)
  status=$?
  expect_code 0 "$status" "a ref deletion while held should be admitted: $out"
  pass "a held task may still delete a gate ref, which starts no run"
}

test_prepare_refuses_foreign_companion_and_missing_support() {
  local out
  make_world foreign
  printf '#!/bin/sh\nexit 0\n' >"$GATE_DIR/hooks/pre-receive.no-mistakes-user"
  chmod +x "$GATE_DIR/hooks/pre-receive.no-mistakes-user"
  out=$(prepare_ship foreign 2>&1) && fail "prepare over a foreign companion should fail: $out"
  assert_contains "$out" "not firstmate's" "the refusal should name the foreign companion"
  assert_grep 'exit 0' "$GATE_DIR/hooks/pre-receive.no-mistakes-user" \
    "a refused prepare must leave the foreign companion untouched"
  assert_absent "$STATE_DIR/foreign.validation-gate" "a refused prepare must not hold the task"

  make_world nosupport
  printf '#!/bin/sh\nexit 0\n' >"$GATE_DIR/hooks/pre-receive"
  out=$(prepare_ship nosupport 2>&1) && fail "prepare on a gate that runs no companion should fail: $out"
  assert_contains "$out" "does not run" "the refusal should say the gate runs no companion"

  make_world noremote
  git -C "$PROJ_DIR" remote remove no-mistakes
  out=$(prepare_ship noremote 2>&1) && fail "prepare with no no-mistakes remote should fail: $out"
  assert_contains "$out" "no-mistakes init" "the refusal should name the missing initialization"
  pass "prepare refuses a foreign companion, a gate without companion support, and a missing gate"
}

test_prepare_is_idempotent_and_relaunch_keeps_a_release() {
  local head
  make_world relaunch
  write_task_meta relaunch
  prepare_ship relaunch >/dev/null || fail "first prepare should succeed"
  prepare_ship relaunch >/dev/null || fail "a repeated prepare over its own companion should succeed"
  commit_in "$WT_DIR" 'feat: final'
  head=$(git -C "$WT_DIR" rev-parse HEAD)
  release_task relaunch >/dev/null || fail "release should succeed"
  prepare_ship relaunch --relaunch 1 >/dev/null || fail "a relaunch prepare should succeed"
  assert_equals "released $head" "$(cat "$STATE_DIR/relaunch.validation-gate")" \
    "a relaunch must keep an existing release"
  prepare_ship relaunch >/dev/null || fail "a fresh prepare should succeed"
  assert_equals held "$(cat "$STATE_DIR/relaunch.validation-gate")" \
    "a fresh spawn of the id must hold it again"
  pass "prepare is idempotent, a relaunch keeps a release, and a fresh spawn holds again"
}

test_prepare_scope() {
  local out
  make_world scope
  out=$(with_gate_on "$GATE" prepare --config "$HOME_DIR/config" --state "$STATE_DIR" \
    --kind scout --mode '' --forge none --worktree "$WT_DIR" --id scope-scout) \
    || fail "a scout prepare should succeed"
  assert_equals "$STATE_DIR/scope-scout.validation-gate" "$out" \
    "a scout pane still carries its gate path so a promotion is gated"
  assert_absent "$STATE_DIR/scope-scout.validation-gate" "a scout is not held"
  for args in "--kind ship --mode direct-PR --forge none" "--kind ship --mode no-mistakes --forge gerrit"; do
    # shellcheck disable=SC2086  # deliberate word splitting of the flag set
    out=$(with_gate_on "$GATE" prepare --config "$HOME_DIR/config" --state "$STATE_DIR" \
      $args --worktree "$WT_DIR" --id scope-other) || fail "prepare ($args) should succeed"
    assert_absent "$STATE_DIR/scope-other.validation-gate" "($args) must not be held"
  done
  out=$(with_gate_on "$GATE" prepare --config "$HOME_DIR/config" --state "$STATE_DIR" \
    --kind secondmate --mode secondmate --forge none --worktree "$WT_DIR" --id scope-mate) \
    || fail "a secondmate prepare should succeed"
  assert_equals "" "$out" "a secondmate pane carries no gate"
  printf 'off\n' >"$HOME_DIR/config/validation-gate"
  out=$(prepare_ship scope-off) || fail "prepare with the home switched off should succeed"
  assert_equals "" "$out" "a home that switches the gate off carries no gate"
  assert_absent "$STATE_DIR/scope-off.validation-gate" "a home switched off holds nothing"
  assert_absent "$GATE_DIR/hooks/pre-receive.no-mistakes-user" "a home switched off installs nothing"
  pass "only no-mistakes ships without a forge binding are held; the home switch wins"
}

test_switch_resolution() {
  local home="$TMP_ROOT/switch-home"
  mkdir -p "$home/config"
  with_gate_off "$GATE" enabled --config "$home/config" && fail "an absent switch file must mean off"
  with_gate_on "$GATE" enabled --config "$home/config" || fail "the tracked default on must mean on"
  printf 'off\n' >"$home/config/validation-gate"
  with_gate_on "$GATE" enabled --config "$home/config" && fail "config off must override the default"
  printf 'on\n' >"$home/config/validation-gate"
  with_gate_off "$GATE" enabled --config "$home/config" || fail "config on must enable an off default"
  "$GATE" enabled --config "$TMP_ROOT/no-such-config" && fail "the suite's pinned default must be off"
  FM_TEST_VALIDATION_GATE_DEFAULTS='' "$GATE" enabled --config "$TMP_ROOT/no-such-config" \
    || fail "the fork's tracked defaults/validation-gate should resolve on"
  pass "the switch resolves config first, then the tracked default, and absent means off"
}

# Spawn integration: drive the real fm-spawn against a fake pane and read the
# launch command the pane received.
# The caller runs this in a command substitution, so the launch log path is
# derived from the id rather than returned.
launch_log() { printf '%s' "$TMP_ROOT/$1-launch.log"; }

run_world_spawn() {  # <id> [args...]
  local id=$1 fakebin LAUNCH_LOG
  shift
  fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/$id-fake")
  fm_test_spawn_brief "$HOME_DIR" "$id"
  LAUNCH_LOG=$(launch_log "$id")
  : >"$LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$TMP_ROOT/$id-pane.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$fakebin" "$id" "$PROJ_DIR" "$@"
}

test_spawn_installs_the_gate() {
  local out status
  make_world spawn-on
  out=$(with_gate_on run_world_spawn spawn-on --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a gated no-mistakes ship spawn should succeed: $out"
  LAUNCH_LOG=$(launch_log spawn-on)
  assert_present "$GATE_DIR/hooks/pre-receive.no-mistakes-user" "spawn should install the companion"
  assert_equals held "$(cat "$STATE_DIR/spawn-on.validation-gate")" "spawn should hold the task"
  assert_grep "FM_VALIDATION_GATE=" "$LAUNCH_LOG" "the launch should carry the task's gate path"
  assert_grep "spawn-on.validation-gate" "$LAUNCH_LOG" "the launch should point at this task's gate file"
  assert_grep 'validation_gate=on' "$STATE_DIR/spawn-on.meta" "the task record should carry the gate decision"
  pass "a no-mistakes ship spawn installs the companion, holds the task, and exports its gate"
}

test_spawn_with_switch_absent_installs_nothing() {
  local out status
  make_world spawn-off
  out=$(with_gate_off run_world_spawn spawn-off --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an ungated no-mistakes ship spawn should succeed: $out"
  LAUNCH_LOG=$(launch_log spawn-off)
  assert_absent "$GATE_DIR/hooks/pre-receive.no-mistakes-user" "switch absent must install nothing"
  assert_absent "$STATE_DIR/spawn-off.validation-gate" "switch absent must hold nothing"
  assert_no_grep "FM_VALIDATION_GATE" "$LAUNCH_LOG" "switch absent must leave the launch unchanged"
  assert_no_grep 'validation_gate=' "$STATE_DIR/spawn-off.meta" "switch absent must record no gate decision"
  pass "with the switch file absent, spawn behaves as upstream"
}

# run_world_relaunch <id>: drive the real fm-spawn --relaunch against the fake
# pane, which reports a bare shell so the endpoint reads agent-free.
run_world_relaunch() {
  local id=$1 fakebin LAUNCH_LOG
  fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/$id-relaunch-fake")
  mv "$fakebin/tmux" "$fakebin/tmux-spawn"
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *pane_current_command*) echo zsh; exit 0 ;; esac
exec "${0%/*}/tmux-spawn" "$@"
SH
  chmod +x "$fakebin/tmux"
  LAUNCH_LOG=$(launch_log "$id")
  : >"$LAUNCH_LOG"
  FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$fakebin" "$id" --relaunch
}

test_relaunch_keeps_the_spawn_decision() {
  local out status
  make_world relaunch-plain
  out=$(with_gate_off run_world_spawn relaunch-plain --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an ungated spawn should succeed: $out"
  out=$(with_gate_on run_world_relaunch relaunch-plain)
  status=$?
  expect_code 0 "$status" "a relaunch after the switch turns on should succeed: $out"
  LAUNCH_LOG=$(launch_log relaunch-plain)
  assert_grep 'codex' "$LAUNCH_LOG" "the relaunch should deliver a replacement launch"
  assert_no_grep "FM_VALIDATION_GATE" "$LAUNCH_LOG" "a task spawned ungated must relaunch ungated"
  assert_absent "$STATE_DIR/relaunch-plain.validation-gate" "a task spawned ungated must not be held on relaunch"
  assert_absent "$GATE_DIR/hooks/pre-receive.no-mistakes-user" "a task spawned ungated installs nothing on relaunch"
  assert_no_grep 'validation_gate=' "$STATE_DIR/relaunch-plain.meta" "the relaunch must not record a gate decision"

  make_world relaunch-gated
  out=$(with_gate_on run_world_spawn relaunch-gated --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a gated spawn should succeed: $out"
  out=$(with_gate_off run_world_relaunch relaunch-gated)
  status=$?
  expect_code 0 "$status" "a relaunch after the switch turns off should succeed: $out"
  LAUNCH_LOG=$(launch_log relaunch-gated)
  assert_grep "relaunch-gated.validation-gate" "$LAUNCH_LOG" "a task spawned gated must relaunch gated"
  assert_equals held "$(cat "$STATE_DIR/relaunch-gated.validation-gate")" "a gated task stays held across relaunch"
  assert_equals 1 "$(grep -c '^validation_gate=on$' "$STATE_DIR/relaunch-gated.meta")" \
    "the relaunch must keep exactly one gate decision in the task record"
  pass "a relaunch follows the gate decision recorded at spawn, not the current switch"
}

test_spawn_refuses_when_the_gate_cannot_be_installed() {
  local out status
  make_world spawn-refuse
  git -C "$PROJ_DIR" remote remove no-mistakes
  out=$(with_gate_on run_world_spawn spawn-refuse --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a gated spawn with no gate to install into should be refused: $out"
  assert_contains "$out" "no-mistakes init" "the refusal should say what is missing"
  pass "spawn stops rather than launching a gated ship it cannot gate"
}

test_brief_renders_the_gated_definition_of_done() {
  local home="$TMP_ROOT/brief-home" on off
  mkdir -p "$home/data" "$home/config"
  with_gate_on env FM_HOME="$home" "$BRIEF" brief-gated some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "a gated brief should scaffold"
  on="$home/data/brief-gated/brief.md"
  assert_grep 'Delivery contract: mode=no-mistakes' "$on" "the gated brief keeps the machine-readable contract line"
  assert_grep 'Ship branch: fm/brief-gated' "$on" "the gated brief keeps the ship branch line"
  assert_grep 'ready for final validation' "$on" "the gated brief names the iterate-phase ready report"
  assert_grep 'push your branch to origin' "$on" "the gated brief tells the worker to push to origin"
  assert_grep "NEVER pass \`--yes\`" "$on" "the gated brief keeps the --yes ban"
  assert_grep 'checks green' "$on" "the gated brief keeps the CI-ready report"
  assert_no_grep 'it is not a request to push from this copy' "$on" "the gated brief drops the no-push handoff"
  with_gate_off env FM_HOME="$home" "$BRIEF" brief-plain some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "an ungated brief should scaffold"
  off="$home/data/brief-plain/brief.md"
  assert_grep 'it is not a request to push from this copy' "$off" "switch absent keeps today's handoff text"
  assert_no_grep 'ready for final validation' "$off" "switch absent must not render the gated text"
  pass "the brief renders the gated Definition of done only when the switch is on"
}

test_promote_holds_a_promoted_ship() {
  local id=promote-gated out status
  make_world promote
  fm_write_meta "$STATE_DIR/$id.meta" "window=fm-$id" "kind=scout" "worktree=$WT_DIR"
  mkdir -p "$HOME_DIR/data/$id"
  cat >"$HOME_DIR/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Investigate the gate.

## Firstmate spec
Scout it.

# Setup
This is a SCOUT task: the deliverable is a written report, not a PR.
EOF
  out=$(with_gate_on env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-promote.sh" "$id" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion to a gated no-mistakes ship should succeed: $out"
  assert_equals held "$(cat "$STATE_DIR/$id.validation-gate")" "promotion should hold the new ship"
  assert_grep 'validation_gate=on' "$STATE_DIR/$id.meta" "promotion should record the gate decision"
  assert_present "$GATE_DIR/hooks/pre-receive.no-mistakes-user" "promotion should install the companion"
  assert_grep 'ready for final validation' "$HOME_DIR/data/$id/ship-instructions.md" \
    "the promoted worker should receive the gated Definition of done"
  pass "promoting a scout to a no-mistakes ship holds it and hands it the gated contract"
}

test_pre_release_push_is_refused
test_released_head_is_accepted_and_only_that_head
test_release_refuses_an_ungated_task
test_origin_push_is_always_accepted
test_no_verify_and_hookspath_overrides_still_refused
test_push_without_the_pane_variable_is_upstream_behaviour
test_ref_deletion_is_allowed
test_prepare_refuses_foreign_companion_and_missing_support
test_prepare_is_idempotent_and_relaunch_keeps_a_release
test_prepare_scope
test_switch_resolution
test_spawn_installs_the_gate
test_spawn_with_switch_absent_installs_nothing
test_relaunch_keeps_the_spawn_decision
test_spawn_refuses_when_the_gate_cannot_be_installed
test_brief_renders_the_gated_definition_of_done
test_promote_holds_a_promoted_ship

echo "# all fm-validation-gate tests passed"
