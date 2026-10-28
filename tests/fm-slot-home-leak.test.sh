#!/usr/bin/env bash
# Fork-only (applypass): a retired second-mate home must not haunt its pool slot.
#
# `treehouse return` resets tracked files only, so a leased second-mate home kept
# its gitignored `.fm-secondmate-home` marker and `state/.lock` in the returned
# slot; a ship worker later given that slot looked like a second-mate primary to
# the Stop hooks. These tests drive the real teardown and spawn scripts:
#   (1) retiring a leased second-mate home leaves no marker or lock in the slot;
#   (2) a refused retirement keeps the home intact;
#   (3) spawn refuses a slot carrying a second-mate marker or home lock, launches
#       nothing there, and still launches a clean slot.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-slot-home-leak)
TEARDOWN="$ROOT/bin/fm-teardown.sh"

# A repo that doubles as the firstmate root, with a leased secondmate home that
# is a linked worktree of it. The fake `treehouse return` mimics the real one:
# it resets tracked files and keeps gitignored ones (verified against treehouse
# v3.1.0: ignored files survive `return --force`).
make_retire_case() {
  local name=$1 case_dir root home fakebin
  case_dir="$TMP_ROOT/$name"
  root="$case_dir/root"
  home="$case_dir/home-slot"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"
  git init --quiet -b main "$root"
  printf 'state/\ndata/\nconfig/\n.fm-secondmate-home*\n.fm-secondmate-parent*\n' > "$root/.gitignore"
  git -C "$root" add .gitignore
  git -C "$root" -c user.name=t -c user.email=t@example.invalid commit -qm init
  git -C "$root" worktree add --quiet --detach "$home" HEAD
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-parent"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'x\n' > "$home/state/leftover"
  printf 'x\n' > "$home/data/charter.md"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${FM_FAKE_TREEHOUSE_FAIL:-0}" = 1 ]; then echo "treehouse: return failed" >&2; exit 1; fi
if [ "\${1:-}" = return ]; then
  for a in "\$@"; do wt=\$a; done
  git -C "\$wt" reset -q --hard
  git -C "\$wt" clean -fdq
fi
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$home" \
    "home=$home" \
    "project=$root" \
    "kind=secondmate" \
    "mode=local-only" \
    "spawn_gen=slot-home-leak-task-x1"
  printf '%s\n' "$case_dir"
}

run_retire() {  # <case-dir> [args...]
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$case_dir/root" FM_HOME="$case_dir/root" \
  FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@" 2>&1
}

test_retiring_a_leased_home_renames_its_markers() {
  local case_dir home out rc
  case_dir=$(make_retire_case retire-renames)
  home="$case_dir/home-slot"

  out=$(run_retire "$case_dir" --force); rc=$?
  expect_code 0 "$rc" "retiring a leased second-mate home should succeed"$'\n'"$out"
  assert_absent "$home/.fm-secondmate-home" "retirement left the live home marker in the returned slot"
  assert_absent "$home/.fm-secondmate-parent" "retirement left the live parent marker in the returned slot"
  assert_present "$home/.fm-secondmate-home.retired-task-x1" "retirement did not leave the renamed home marker"
  assert_present "$home/.fm-secondmate-parent.retired-task-x1" "retirement did not leave the renamed parent marker"
  assert_absent "$home/state/.lock" "retirement left state/.lock in the returned slot"
  [ -e "$home/.git" ] || fail "retirement removed the pool slot itself"
  pass "retiring a leased second-mate home leaves only renamed markers and no lock"
}

test_markers_are_renamed_before_the_return_call() {
  local case_dir home out rc
  case_dir=$(make_retire_case retire-order)
  home="$case_dir/home-slot"
  # Record what the slot looks like at the moment treehouse return runs.
  sed -i.bak 's|^if \[ "\${1:-}" = return \]; then|if [ "${1:-}" = return ]; then\n  { ls -a "${@: -1}"; } > "'"$case_dir"'/at-return.txt"|' "$case_dir/fakebin/treehouse"
  out=$(run_retire "$case_dir" --force); rc=$?
  expect_code 0 "$rc" "retirement should succeed"$'\n'"$out"
  assert_contains "$(cat "$case_dir/at-return.txt")" ".fm-secondmate-home.retired-task-x1" "markers were not renamed before the return call"
  case "$(cat "$case_dir/at-return.txt")" in
    *$'\n'.fm-secondmate-home$'\n'*) fail "the live marker was still present when treehouse return ran" ;;
  esac
  pass "markers are renamed before treehouse return runs"
}

test_failed_return_stops_with_a_manual_cleanup_message() {
  local case_dir home out rc
  case_dir=$(make_retire_case retire-return-fails)
  home="$case_dir/home-slot"

  out=$(FM_FAKE_TREEHOUSE_FAIL=1 run_retire "$case_dir" --force); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed treehouse return should fail the retirement"$'\n'"$out"
  assert_contains "$out" "$home needs manual cleanup" "the error did not name the slot needing manual cleanup"
  assert_contains "$out" ".fm-secondmate-home.retired-task-x1" "the error did not name the renamed marker"
  assert_present "$home/.fm-secondmate-home.retired-task-x1" "the renamed marker must remain"
  assert_present "$home/state/leftover" "a failed return must not delete home state"
  assert_present "$home/data/charter.md" "a failed return must not delete home data"
  pass "a failed return stops with a manual-cleanup message and deletes nothing else"
}

make_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project pool fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"
  git init --quiet -b main "$project"
  printf 'state/\n.fm-secondmate-home*\n.fm-secondmate-parent*\n' > "$project/.gitignore"
  git -C "$project" add .gitignore
  git -C "$project" -c user.name=t -c user.email=t@example.invalid commit -qm init
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$project" "$pool" "$fakebin"
}

test_spawn_refuses_a_slot_with_home_leftovers() {
  local leftover id rec case_dir home project pool fakebin out status want
  for leftover in marker lock; do
    id="slot-home-$leftover"
    rec=$(make_spawn_case "spawn-$leftover" "$id")
    IFS='|' read -r case_dir home project pool fakebin <<REC
$rec
REC
    case $leftover in
      marker) printf 'autoapply\n' > "$pool/.fm-secondmate-home"; want="$pool/.fm-secondmate-home" ;;
      lock) mkdir -p "$pool/state"; printf '1\n' > "$pool/state/.lock"; want="$pool/state/.lock" ;;
    esac
    out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --scout); status=$?
    [ "$status" -ne 0 ] || fail "spawn into a slot with a second-mate $leftover should refuse"$'\n'"$out"
    assert_contains "$out" "$want" "the refusal did not name $want"
    assert_absent "$home/state/$id.meta" "a refused spawn must not record a task"
    assert_present "$want" "a refused spawn must not delete another home's $leftover"
  done
  pass "spawn refuses a slot carrying a second-mate marker or home lock and launches nothing"
}

test_spawn_accepts_a_renamed_marker_slot() {
  local id=slot-home-retired rec case_dir home project pool fakebin out status
  rec=$(make_spawn_case spawn-retired "$id")
  IFS='|' read -r case_dir home project pool fakebin <<REC
$rec
REC
  printf 'autoapply\n' > "$pool/.fm-secondmate-home.retired-autoapply"
  printf 'autoapply\n' > "$pool/.fm-secondmate-parent.retired-autoapply"
  out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --scout); status=$?
  expect_code 0 "$status" "a slot with renamed markers should launch"$'\n'"$out"
  assert_present "$pool/.fm-secondmate-home.retired-autoapply" "spawn must leave the renamed marker alone"
  pass "spawn accepts a slot carrying renamed markers"
}

test_spawn_still_launches_a_clean_slot() {
  local id=slot-home-clean rec case_dir home project pool fakebin out status
  rec=$(make_spawn_case spawn-clean "$id")
  IFS='|' read -r case_dir home project pool fakebin <<REC
$rec
REC
  out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --scout); status=$?
  expect_code 0 "$status" "a clean slot should still launch"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the clean spawn did not report success"
  pass "spawn still launches a clean slot"
}

test_retiring_a_leased_home_renames_its_markers
test_markers_are_renamed_before_the_return_call
test_failed_return_stops_with_a_manual_cleanup_message
test_spawn_refuses_a_slot_with_home_leftovers
test_spawn_accepts_a_renamed_marker_slot
test_spawn_still_launches_a_clean_slot

echo "# all fm-slot-home-leak tests passed"
