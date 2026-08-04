#!/usr/bin/env bash
# Behavior tests for taking, keeping, and clearing the helm
# (docs/session-handover.md, "Taking the helm from an idle holder").
#
# Subjects: bin/fm-lock.sh's acquisition, status, release, and clear paths, and
# the two-proof decision in bin/fm-helm-lib.sh.
#
# The rule under test: a live holder is not automatically a working holder, but
# only a holder that is BOTH provably unattended AND measurably silent loses the
# helm automatically. A timer alone is never enough, an attended holder always
# keeps it, and every refusal names the holder and the command that clears it.
#
# Hermetic: `ps` is faked so ancestry, harness identity, and the controlling
# terminal are all controlled, while holder pids are real background processes so
# the liveness check is genuine.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-helm-takeover)

BG_PIDS=()
cleanup_bg() {
  local p
  for p in "${BG_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup_bg EXIT

# start_proc: a real live process, so kill -0 sees a genuine pid. Sets PROC_PID
# rather than printing it: a command substitution would wait on the background
# process's inherited stdout.
start_proc() {
  sleep 300 >/dev/null 2>&1 &
  PROC_PID=$!
  BG_PIDS+=("$PROC_PID")
}

# make_fake_ps <fakebin> <me-pid> <holder-pid>: both pids look like a live claude
# harness, every other queried pid looks like a shell whose parent is <me-pid> so
# an ancestry walk from the script under test resolves to <me-pid>, and the
# controlling terminal of any pid comes from <fakebin>/.tty-<pid> when present
# (default: none, i.e. unattended).
make_fake_ps() {
  local fakebin=$1 me=$2 holder=$3
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
case "\$*" in
  *"tty="*)
    if [ -f "$fakebin/.tty-\$pid" ]; then cat "$fakebin/.tty-\$pid"; else printf '??\n'; fi
    exit 0
    ;;
  *"comm="*)
    case "\$pid" in
      $me|$holder) printf '/usr/local/bin/claude\n' ;;
      *) printf '/bin/zsh\n' ;;
    esac
    exit 0
    ;;
  *"args="*)
    case "\$pid" in
      $me|$holder) printf 'claude\n' ;;
      *) printf 'zsh\n' ;;
    esac
    exit 0
    ;;
  *"ppid="*)
    case "\$pid" in
      $me|$holder) printf '1\n' ;;
      *) printf '%s\n' "$me" ;;
    esac
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# make_home <dir>: a home with a state dir, plus the fake ps and the two real
# pids the scenario needs. Sets HOME_DIR, FAKEBIN, ME_PID, HOLDER_PID.
make_home() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/data"
  HOME_DIR=$dir
  FAKEBIN=$(fm_fakebin "$dir")
  start_proc; ME_PID=$PROC_PID
  start_proc; HOLDER_PID=$PROC_PID
  make_fake_ps "$FAKEBIN" "$ME_PID" "$HOLDER_PID"
  printf '%s\n' "$HOLDER_PID" > "$dir/state/.lock"
}

set_tty() {
  printf '%s\n' "$2" > "$FAKEBIN/.tty-$1"
}

# ps output for a terminal that cannot be read at all.
break_tty_read() {
  cat > "$FAKEBIN/ps" <<SH
#!/usr/bin/env bash
set -u
pid=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
case "\$*" in
  *"tty="*) exit 1 ;;
  *"comm="*) printf '/usr/local/bin/claude\n'; exit 0 ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
  *"ppid="*)
    case "\$pid" in
      $ME_PID|$HOLDER_PID) printf '1\n' ;;
      *) printf '%s\n' "$ME_PID" ;;
    esac
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$FAKEBIN/ps"
}

# backdate <file> <seconds-ago>: age a file's mtime deterministically. Sleeping
# for a short threshold instead makes the outcome depend on where a one-second
# boundary happens to fall, which is exactly how a suite becomes flaky under load.
backdate() {
  local f=$1 secs=$2 stamp
  stamp=$(date -v-"${secs}"S +%Y%m%d%H%M.%S 2>/dev/null) \
    || stamp=$(date -d "-${secs} seconds" +%Y%m%d%H%M.%S 2>/dev/null) \
    || fail "no portable way to backdate a file mtime on this host"
  touch -t "$stamp" "$f" || fail "could not backdate $f"
}

run_lock() {
  env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" "$@" \
    bash "$ROOT/bin/fm-lock.sh" 2>&1
}

# --- refusals: the holder keeps the helm --------------------------------------

test_refuses_an_attended_holder_and_prints_the_clearing_command() {
  local out status
  make_home "$TMP_ROOT/attended"
  set_tty "$HOLDER_PID" ttys005
  backdate "$HOME_DIR/state/.lock" 7200
  out=$(run_lock); status=$?
  expect_code 1 "$status" "an attended holder must keep the helm"
  assert_contains "$out" "another live firstmate session holds the lock" "the refusal must keep its established wording"
  assert_contains "$out" "holder: pid $HOLDER_PID" "the refusal must name what holds the helm"
  assert_contains "$out" "ttys005" "the refusal must name the holder's terminal"
  assert_contains "$out" "attended" "the refusal must say why it refused"
  assert_contains "$out" "clear --pid $HOLDER_PID" "the refusal must print the one command that clears it"
  assert_grep "$HOLDER_PID" "$HOME_DIR/state/.lock" "a refused acquisition must leave the holder recorded"
  pass "fm-lock: refuses an attended holder, naming it, its terminal, and the clearing command"
}

test_refuses_an_unattended_holder_that_is_still_working() {
  local out status
  make_home "$TMP_ROOT/recent"
  out=$(run_lock FM_HELM_IDLE_TAKEOVER=3600); status=$?
  expect_code 1 "$status" "silence shorter than the threshold must not lose the helm"
  assert_contains "$out" "was active" "the refusal must say the holder was recently active"
  assert_contains "$out" "of silence" "the refusal must name the silence the takeover needs"
  pass "fm-lock: an unattended holder that was recently active keeps the helm"
}

test_refuses_when_the_terminal_cannot_be_read() {
  local out status
  make_home "$TMP_ROOT/unknown-tty"
  break_tty_read
  backdate "$HOME_DIR/state/.lock" 7200
  out=$(run_lock); status=$?
  expect_code 1 "$status" "an unprovable holder must keep the helm however long it has been quiet"
  assert_contains "$out" "cannot be proven unattended" "the refusal must say the proof was unavailable"
  pass "fm-lock: silence alone never takes the helm - the unattended proof is required"
}

test_mid_turn_work_counts_as_activity() {
  local out status transcript
  make_home "$TMP_ROOT/midturn"
  transcript="$HOME_DIR/transcript.jsonl"
  printf 'partial turn\n' > "$transcript"
  {
    printf 'pid=%s\n' "$HOLDER_PID"
    printf 'epoch=%s\n' "$(date +%s)"
    printf 'transcript=%s\n' "$transcript"
  } > "$HOME_DIR/state/.helm-activity"
  # Its last completed turn and its claim on the helm are both long past.
  backdate "$HOME_DIR/state/.helm-activity" 7200
  backdate "$HOME_DIR/state/.lock" 7200
  # It has not ended a turn since, but it is still writing.
  printf 'more of the same turn\n' >> "$transcript"
  out=$(run_lock); status=$?
  expect_code 1 "$status" "a holder still writing mid-turn must keep the helm"
  assert_contains "$out" "was active" "the refusal must recognise mid-turn work as activity"
  pass "fm-lock: a holder working through a long single turn is not mistaken for an idle one"
}

# --- the takeover -------------------------------------------------------------

test_takes_the_helm_from_a_silent_unattended_holder() {
  local out status
  make_home "$TMP_ROOT/takeover"
  # Two hours of silence, well past the 1800-second default, which this exercises
  # rather than overriding.
  backdate "$HOME_DIR/state/.lock" 7200
  out=$(run_lock); status=$?
  expect_code 0 "$status" "a provably unattended, silent holder must lose the helm"
  assert_contains "$out" "lock acquired" "the replacement must end up holding the helm"
  assert_contains "$out" "HELM TAKEN OVER" "a takeover must be reported loudly, never as a routine acquisition"
  assert_contains "$out" "pid $HOLDER_PID held it" "the report must name the session it took the helm from"
  assert_contains "$out" "no terminal" "the report must say why the takeover was allowed"
  assert_contains "$out" "was NOT stopped" "the report must say the other session is untouched"
  assert_grep "$ME_PID" "$HOME_DIR/state/.lock" "the helm must now record the new session"
  assert_grep "from=$HOLDER_PID" "$HOME_DIR/state/.helm-takeover" "a takeover must leave an auditable record"
  pass "fm-lock: takes the helm from a provably unattended, measurably silent holder and says so"
}

test_a_dead_holder_still_loses_the_helm_immediately() {
  local out status
  make_home "$TMP_ROOT/dead"
  kill "$HOLDER_PID" 2>/dev/null
  wait "$HOLDER_PID" 2>/dev/null || true
  out=$(run_lock); status=$?
  expect_code 0 "$status" "a dead holder must never block acquisition"
  assert_contains "$out" "lock acquired" "the replacement must take a stale helm"
  assert_not_contains "$out" "HELM TAKEN OVER" "a stale helm is not a takeover from a working session"
  pass "fm-lock: a dead holder's helm is still claimed immediately, with no takeover ceremony"
}

# --- status, release, clear ---------------------------------------------------

test_status_reports_the_holder_and_whether_a_takeover_is_available() {
  local out
  make_home "$TMP_ROOT/status"
  set_tty "$HOLDER_PID" ttys009
  out=$(env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "held by live harness pid $HOLDER_PID" "status must name the holder"
  assert_contains "$out" "ttys009" "status must report the holder's terminal"
  assert_contains "$out" "takeover: refused" "status must say whether the helm can be taken"
  rm -f "$FAKEBIN/.tty-$HOLDER_PID"
  backdate "$HOME_DIR/state/.lock" 7200
  out=$(env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" \
    bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "takeover: available" "status must report an available takeover"
  assert_grep "$HOLDER_PID" "$HOME_DIR/state/.lock" "status must never change who holds the helm"
  pass "fm-lock status: reports the holder, its terminal, and whether the helm can be taken"
}

test_release_only_works_for_the_session_that_holds_the_helm() {
  local out status
  make_home "$TMP_ROOT/release"
  out=$(env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" bash "$ROOT/bin/fm-lock.sh" release 2>&1); status=$?
  expect_code 1 "$status" "a session that does not hold the helm must not release it"
  assert_contains "$out" "does not hold the lock" "the refusal must say why"
  assert_present "$HOME_DIR/state/.lock" "a refused release must leave the helm alone"
  printf '%s\n' "$ME_PID" > "$HOME_DIR/state/.lock"
  out=$(env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" bash "$ROOT/bin/fm-lock.sh" release 2>&1) \
    || fail "the holder must be able to release its own helm: $out"
  assert_contains "$out" "lock released" "a successful release must say so"
  assert_absent "$HOME_DIR/state/.lock" "release must free the helm"
  pass "fm-lock release: only the session holding the helm can give it up"
}

test_clear_refuses_a_pid_that_does_not_hold_the_helm() {
  local out status other
  make_home "$TMP_ROOT/clear"
  other=$((HOLDER_PID + 100000))
  out=$(env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" \
    bash "$ROOT/bin/fm-lock.sh" clear --pid "$other" 2>&1); status=$?
  expect_code 1 "$status" "clearing the wrong pid must be refused"
  assert_contains "$out" "does not hold the lock" "the refusal must name the mismatch"
  assert_present "$HOME_DIR/state/.lock" "a refused clear must leave the helm alone"
  out=$(env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" \
    bash "$ROOT/bin/fm-lock.sh" clear --pid "$HOLDER_PID" 2>&1) \
    || fail "clearing the recorded holder must succeed: $out"
  assert_contains "$out" "lock cleared" "a successful clear must say so"
  assert_contains "$out" "still running and was not touched" "clear must be honest that it stopped nothing"
  assert_absent "$HOME_DIR/state/.lock" "clear must free the helm"
  pass "fm-lock clear: only clears the recorded holder, and never pretends to have stopped it"
}

run_all() {
  test_refuses_an_attended_holder_and_prints_the_clearing_command
  test_refuses_an_unattended_holder_that_is_still_working
  test_refuses_when_the_terminal_cannot_be_read
  test_mid_turn_work_counts_as_activity
  test_takes_the_helm_from_a_silent_unattended_holder
  test_a_dead_holder_still_loses_the_helm_immediately
  test_status_reports_the_holder_and_whether_a_takeover_is_available
  test_release_only_works_for_the_session_that_holds_the_helm
  test_clear_refuses_a_pid_that_does_not_hold_the_helm
}

run_all
