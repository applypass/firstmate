#!/usr/bin/env bash
# Fork-only (applypass): tests/fm-reemit-shrink.test.sh - behavior test for the
# short context re-emit (bin/fm-reemit-lib.sh via bin/fm-session-start.sh --reemit).
#
# Builds a home shaped like a busy main home (many tasks with long status
# tails, large captain, shared-captain and learnings files, a large backlog),
# with neutral names. Asserts:
#   - the re-emit stays under 15 KB while the full digest is far larger
#   - every safety line survives: lock, wake queue, open decisions, the wake
#     acknowledgement command, and the closing NEXT STEP
#   - a second re-emit with no change omits the unchanged records, and a changed
#     record is sent again
#   - a different session (new lock pid) starts over with a full summary
# Prints the before (full digest) and after (re-emit) sizes in bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-reemit-shrink-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

new_world() {
  local name=$1 w root home fakebin
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

make_fake_toolchain() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' manual > "${fakebin%/*}/home-placeholder" 2>/dev/null || true
}

make_fake_ps_claude() {
  local fakebin=$1
  make_fake_ps_harness "$fakebin" claude
}

make_fake_ps_harness() {
  local fakebin=$1 harness=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
# The ancestry this stub reports defaults to the harness the fixture was built
# for, so a case that builds a pi (or codex) fixture gets pi (or codex) ancestry
# without having to repeat it per run; FM_FAKE_HARNESS still overrides it.
harness=\${FM_FAKE_HARNESS:-$harness}
SH
  cat >> "$fakebin/ps" <<'SH'
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ -z "${FM_FAKE_HARNESS_PID:-}" ] || [ "$pid" = "$FM_FAKE_HARNESS_PID" ] \
      || [ "$pid" = "${FM_FAKE_LIVE_HOLDER_PID:-}" ]; then
      printf '/usr/local/bin/%s\n' "$harness"
    else
      printf '/bin/bash\n'
    fi
    exit 0
    ;;
  *"args="*)
    if [ -z "${FM_FAKE_HARNESS_PID:-}" ] || [ "$pid" = "$FM_FAKE_HARNESS_PID" ] \
      || [ "$pid" = "${FM_FAKE_LIVE_HOLDER_PID:-}" ]; then
      printf '%s\n' "$harness"
    else
      printf 'bash\n'
    fi
    exit 0
    ;;
  *"ppid="*)
    [ -n "${FM_FAKE_HARNESS_PID:-}" ] || exit 1
    /bin/ps -o ppid= -p "$pid"
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$harness" > "$fakebin/.harness-name"
}

# build_busy_home <root> <home> <fakebin>: a home shaped like a busy main home,
# with neutral names. Echoes nothing.
build_busy_home() {
  local root=$1 home=$2 fakebin=$3 i j
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  for i in $(seq 1 12); do
    printf 'window=fm-sess:w%s\nkind=ship\nproject=proj-%s\nbranch=fm/task-%s\n' "$i" "$i" "$i" > "$home/state/task-$i.meta"
    for j in $(seq 1 60); do
      printf 'working [at=%s]: step %s of task-%s finished, waiting on the next gate, padding padding padding padding\n' "$((1700000000 + j))" "$j" "$i"
    done > "$home/state/task-$i.status"
  done
  awk 'BEGIN { for (i = 0; i < 500; i++) printf "preference line %04d padding padding padding padding padding padding\n", i }' > "$home/data/captain.md"
  awk 'BEGIN { for (i = 0; i < 250; i++) printf "shared preference %04d padding padding padding padding padding padding\n", i }' > "$home/data/captain-shared.md"
  awk 'BEGIN { for (i = 0; i < 600; i++) printf "learning %04d padding padding padding padding padding padding padding\n", i }' > "$home/data/learnings.md"
  awk 'BEGIN { print "## In flight"; for (i = 0; i < 12; i++) printf "- task-%d: neutral task title %d\n", i, i; print "## Queued"; for (i = 0; i < 2000; i++) printf "- queued-%d: neutral queued title %d\n", i, i; print "## Done"; for (i = 0; i < 500; i++) printf "- done-%d: neutral done title %d\n", i, i }' > "$home/data/backlog.md"
}

run_reemit() {  # <home> <root> <fakebin>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$2" FM_FAKE_HARNESS_PID=$$ PATH="$3:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    "$SESSION_START" --reemit
}

test_reemit_is_short_keeps_safety_lines_and_omits_unchanged_records() {
  local rec root home fakebin full first second third before after1 after2 sequence
  rec=$(new_world busy)
  IFS='|' read -r root home fakebin <<FIXTURE
$rec
FIXTURE
  build_busy_home "$root" "$home" "$fakebin"

  full=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT "$SESSION_START")
  before=${#full}
  append_wake "$home/state" signal task-1 "done: queued after startup" || fail "seed wake failed"

  first=$(run_reemit "$home" "$root" "$fakebin")
  after1=${#first}
  printf 'reemit size: before (full digest) %s bytes, after (first re-emit) %s bytes\n' "$before" "$after1"
  [ "$after1" -lt 15360 ] || fail "first re-emit is $after1 bytes, not under 15 KB"
  [ "$before" -gt $((after1 * 4)) ] || fail "the fixture full digest ($before bytes) is not much larger than the re-emit"

  assert_contains "$first" "RE-EMIT CUE" "re-emit lost its cue"
  assert_contains "$first" "SESSION START (CONTEXT RE-EMIT) - $home" "re-emit lost its header"
  assert_contains "$first" "LOCK" "re-emit dropped the lock section"
  assert_contains "$first" "WAKE QUEUE" "re-emit dropped the wake queue"
  assert_contains "$first" "done: queued after startup" "re-emit dropped a queued wake"
  assert_contains "$first" "WAKE_ACK_REQUIRED" "re-emit dropped the wake acknowledgement command"
  assert_contains "$first" "NEXT STEP" "re-emit dropped the closing reminder"
  assert_contains "$first" "task-12 | " "re-emit did not list a task in flight on one line"
  assert_contains "$first" ".reemit-full-digest.txt" "re-emit did not point at the full digest file"
  assert_not_contains "$first" "preference line 0001" "re-emit still carried the captain file body"
  assert_not_contains "$first" "step 3 of task-1 finished" "re-emit still carried status tails"
  assert_present "$home/state/.reemit-full-digest.txt" "the full digest file was not written"
  assert_contains "$(cat "$home/state/.reemit-full-digest.txt")" "preference line 0001" "the full digest file lost the captain file"

  # Acknowledge the wake so the second re-emit differs only by what we change.
  sequence=$(printf '%s\n' "$first" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' | tail -1)
  [ -n "$sequence" ] || fail "no wake acknowledgement sequence in the first re-emit"

  second=$(run_reemit "$home" "$root" "$fakebin")
  after2=${#second}
  printf 'reemit size: second re-emit with no change %s bytes\n' "$after2"
  assert_contains "$second" "unchanged since the last re-emit" "second re-emit did not mark unchanged records"
  assert_not_contains "$second" "task-12 | " "second re-emit resent an unchanged task line"
  [ "$after2" -lt "$after1" ] || fail "second re-emit ($after2) is not smaller than the first ($after1)"
  assert_contains "$second" "WAKE_ACK_REQUIRED" "second re-emit dropped the wake acknowledgement command"

  printf 'working [at=1800000000]: a brand new line for task-7\n' >> "$home/state/task-7.status"
  third=$(run_reemit "$home" "$root" "$fakebin")
  assert_contains "$third" "a brand new line for task-7" "a changed record was not resent"
  assert_not_contains "$third" "task-8 | " "a record that did not change was resent"

  pass "re-emit is under 15 KB, keeps its safety lines, and omits unchanged records"
}

test_a_new_session_starts_over_with_the_full_summary() {
  local rec root home fakebin first again
  rec=$(new_world busy-newsession)
  IFS='|' read -r root home fakebin <<FIXTURE
$rec
FIXTURE
  build_busy_home "$root" "$home" "$fakebin"
  first=$(run_reemit "$home" "$root" "$fakebin")
  assert_contains "$first" "task-12 | " "first re-emit lacked the task line"
  printf 'some-other-session\n' > "$home/state/.reemit-seen"
  again=$(run_reemit "$home" "$root" "$fakebin")
  assert_contains "$again" "task-12 | " "a record from another session suppressed the summary"
  pass "a re-emit record from another session never suppresses a summary"
}

test_reemit_is_short_keeps_safety_lines_and_omits_unchanged_records
test_a_new_session_starts_over_with_the_full_summary

echo "# fm-reemit-shrink.test.sh: all assertions passed"
