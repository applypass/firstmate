#!/usr/bin/env bash
# Fork-only (applypass): tests/fm-reemit-shrink.test.sh - behavior test for the
# short context re-emit (bin/fm-reemit-lib.sh via bin/fm-session-start.sh --reemit).
#
# Builds a home shaped like a busy main home (many tasks with long status
# tails, large captain, shared-captain and learnings files, a large backlog),
# with neutral names. Asserts:
#   - the re-emit stays under Claude's 10,000-character hook cap while the full
#     digest is far larger
#   - every safety line survives: lock, wake queue, the wake acknowledgement
#     command, the supervision Current state and wake-handling lines, and the
#     closing NEXT STEP, which points at the supervision file
#   - a second re-emit with no change names the file of each unchanged record
#     instead of resending it, and a changed record is sent again
#   - a different session (new lock pid) starts over with a full summary
#   - a read-only re-emit leaves the lock owner's re-emit files alone
#   - a slow detached network worker does not hold the hook output open
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
if [ "${1:-} ${2:-}" = "auth status" ] && [ -n "${FM_FAKE_GH_AUTH_SLEEP:-}" ]; then
  sleep "$FM_FAKE_GH_AUTH_SLEEP"
fi
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

# assert_supervision_summary <output> <home> <label>: the supervision pointer,
# its key lines, and a NEXT STEP that points at the file, not at a block above.
assert_supervision_summary() {
  local out=$1 home=$2 label=$3
  assert_contains "$out" "Full block: $home/state/.reemit-supervision.txt" "$label did not point at the supervision file"
  assert_contains "$out" "- Lock: held by this session" "$label dropped the Current state lock line"
  assert_contains "$out" "- Away/quiet mode: inactive." "$label dropped the Current state away line"
  assert_contains "$out" "1. Drain first with \`bin/fm-wake-drain.sh\`." "$label dropped the drain-first step"
  assert_contains "$out" "run the exact \`--ack-through\` command printed as \`WAKE_ACK_REQUIRED\`" "$label dropped the ack step"
  assert_contains "$out" "Do not run \`bin/fm-watch-arm.sh\` after an ordinary wake" "$label dropped the do-not-arm step"
  assert_contains "$out" "Follow the supervision operating instructions block in $home/state/.reemit-supervision.txt" \
    "$label NEXT STEP did not point at the supervision file"
  assert_not_contains "$out" "instructions block above" "$label NEXT STEP pointed at a block that is not above"
  assert_contains "$(cat "$home/state/.reemit-supervision.txt")" "SUPERVISION OPERATING INSTRUCTIONS" \
    "$label did not write the supervision file"
}

test_reemit_is_short_keeps_safety_lines_and_omits_unchanged_records() {
  local rec root home fakebin full first second third before after1 after2 sequence generation unchanged_line
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
  [ "$after1" -lt 10000 ] || fail "first re-emit is $after1 bytes, not under the 10,000-character hook cap"
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
  assert_supervision_summary "$first" "$home" "first re-emit"

  sequence=$(printf '%s\n' "$first" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' | tail -1)
  generation=$(printf '%s\n' "$first" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "no wake acknowledgement in the first re-emit"
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null || fail "the first re-emit wake acknowledgement failed"

  second=$(run_reemit "$home" "$root" "$fakebin")
  after2=${#second}
  printf 'reemit size: second re-emit with no change %s bytes\n' "$after2"
  [ "$after2" -lt 10000 ] || fail "second re-emit is $after2 bytes, not under the 10,000-character hook cap"
  assert_not_contains "$second" "done: queued after startup" "second re-emit showed an acknowledged wake"
  unchanged_line=$(printf '%s\n' "$second" | grep -F 'unchanged since the last re-emit, not resent:')
  assert_contains "$unchanged_line" " task-12 " "second re-emit did not name an unchanged task"
  assert_contains "$unchanged_line" "(each in $home/state/<id>.status and $home/state/<id>.meta)" \
    "second re-emit did not name the files that hold an unchanged task"
  assert_not_contains "$second" "step 60 of task-12" "second re-emit resent an unchanged task line"
  assert_contains "$second" "$home/data/captain.md: unchanged since the last re-emit" \
    "second re-emit did not name an unchanged context file"
  assert_supervision_summary "$second" "$home" "second re-emit"
  [ "$after2" -lt "$after1" ] || fail "second re-emit ($after2) is not smaller than the first ($after1)"

  printf 'working [at=1800000000]: a brand new line for task-7\n' >> "$home/state/task-7.status"
  third=$(run_reemit "$home" "$root" "$fakebin")
  assert_contains "$third" "a brand new line for task-7" "a changed record was not resent"
  assert_not_contains "$third" "step 60 of task-8" "a record that did not change was resent"
  assert_contains "$(printf '%s\n' "$third" | grep -F 'unchanged since the last re-emit, not resent:')" " task-8 " \
    "a record that did not change was not named as unchanged"

  pass "re-emit is under the hook cap, keeps its safety lines, and names the files of unchanged records"
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

test_a_read_only_reemit_leaves_the_owner_files_alone() {
  local rec root home fakebin holder_pid out sup_before full_before seen_before
  rec=$(new_world busy-read-only)
  IFS='|' read -r root home fakebin <<FIXTURE
$rec
FIXTURE
  build_busy_home "$root" "$home" "$fakebin"
  run_reemit "$home" "$root" "$fakebin" >/dev/null
  sup_before=$(cat "$home/state/.reemit-supervision.txt")
  full_before=$(cat "$home/state/.reemit-full-digest.txt")

  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"
  { printf '%s\n' "$holder_pid"; sed '1d' "$home/state/.reemit-seen"; } > "$home/state/.reemit-seen.new"
  mv "$home/state/.reemit-seen.new" "$home/state/.reemit-seen"
  seen_before=$(cat "$home/state/.reemit-seen")
  out=$(FM_FAKE_LIVE_HOLDER_PID="$holder_pid" run_reemit "$home" "$root" "$fakebin")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "READ-ONLY SESSION" "a competing live lock owner did not force read-only mode"
  assert_contains "$out" "- Lock: read-only" "the read-only re-emit did not print its own Current state"
  assert_not_contains "$out" "$home/state/.reemit-supervision.txt" "the read-only re-emit pointed at the owner's supervision file"
  assert_contains "$out" "task-12 | " "the read-only re-emit hid a task line behind the owner's unchanged-record hashes"
  assert_not_contains "$out" "unchanged since the last re-emit" "the read-only re-emit called records it never received unchanged"
  [ "$(cat "$home/state/.reemit-supervision.txt")" = "$sup_before" ] || fail "a read-only re-emit overwrote the owner's supervision file"
  [ "$(cat "$home/state/.reemit-full-digest.txt")" = "$full_before" ] || fail "a read-only re-emit overwrote the owner's full digest"
  [ "$(cat "$home/state/.reemit-seen")" = "$seen_before" ] || fail "a read-only re-emit rewrote the owner's unchanged-record hashes"
  pass "a read-only re-emit ignores the owner's unchanged-record hashes and leaves the owner's re-emit files alone"
}

test_a_slow_network_worker_does_not_hold_the_reemit_output_open() {
  local rec root home fakebin started elapsed out
  rec=$(new_world busy-slow-network)
  IFS='|' read -r root home fakebin <<FIXTURE
$rec
FIXTURE
  build_busy_home "$root" "$home" "$fakebin"
  started=$(date +%s)
  out=$(FM_FAKE_GH_AUTH_SLEEP=30 run_reemit "$home" "$root" "$fakebin" | cat)
  elapsed=$(($(date +%s) - started))
  assert_contains "$out" "NEXT STEP" "the re-emit did not finish"
  [ "$elapsed" -lt 20 ] || fail "the re-emit output stayed open ${elapsed}s behind the detached network worker"
  pass "a slow detached network worker does not hold the re-emit output open"
}

test_reemit_is_short_keeps_safety_lines_and_omits_unchanged_records
test_a_new_session_starts_over_with_the_full_summary
test_a_read_only_reemit_leaves_the_owner_files_alone
test_a_slow_network_worker_does_not_hold_the_reemit_output_open

echo "# fm-reemit-shrink.test.sh: all assertions passed"
