#!/usr/bin/env bash
# tests/fm-usage-limit.test.sh - usage-limit detection and auto-resume (fork-only).
#
# Replays the 14 Nov stop: a Claude usage limit hit at 02:50 IST, reset 03:10, and a
# second mate and a worker sat idle. The screens below are representative text, not
# captures of a real pane. The real fm-usage-limit.sh, fm-usage-limit-tick.sh and
# fm-send.sh run over a stubbed tmux whose panes show canned screens. Pinned:
#   1. Replay: both stops are recorded with the reset parsed in the screen's zone;
#      nothing is sent before reset; at reset each gets a resume; once the screen
#      recovers the records clear. No human input.
#   2. An unparseable reset falls back to quota-axi (read-only, five_hour/seven_day).
#   3. An option list never picks credits or extra usage.
#   4. An endpoint still stopped after the retries surfaces exactly once.
#   5. Detection is idempotent and ignores a screen that only mentions a limit.
#   6. Sleep/wake (fork-only, docs/usage-limit-resume.md): a wall-clock gap across ticks
#      plus a connection-error stop at an idle prompt is recorded and resumed after the
#      settle time; a retrying spinner, a quoted marker and a working agent are not stops;
#      a connection stop with no gap waits longer; retries are bounded and surface once;
#      a usage-limit screen stays on the usage-limit path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DETECT="$ROOT/bin/fm-usage-limit.sh"
TICK="$ROOT/bin/fm-usage-limit-tick.sh"

TMP_ROOT=$(fm_test_tmproot fm-usage-limit)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux: capture-pane prints $SCREENS/<window-name>; send-keys is logged.
make_stubs() { # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
win=''
prev=''
for a in "$@"; do
  [ "$prev" = -t ] && win=${a##*:}
  prev=$a
done
case "${1:-}" in
  send-keys) printf '%s %s\n' "$win" "$*" >> "$FM_SEND_LOG"; exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) cat "$FM_SCREENS/$win" 2>/dev/null; exit 0 ;;
  list-windows) printf 'fm-mate\nfm-work\n'; exit 0 ;;
esac
exit 0
SH
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/tmux" "$fb/sleep"
}

setup_case() { # <name> -> case dir with a mate (m1) and a worker (w1)
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/screens"
  make_stubs "$dir"
  fm_write_secondmate_meta "$dir/home/state/m1.meta" "$dir/home" "sess:fm-mate"
  fm_write_meta "$dir/home/state/w1.meta" "window=sess:fm-work" "kind=ship" "harness=claude"
  : >"$dir/send.log"
  printf '%s\n' "$dir"
}

LIMIT_SCREEN=$'some earlier output\n5-hour limit reached - resets 3:10am (Asia/Kolkata)\n  1. Stop and wait for limit to reset\n  2. Add funds to continue with extra usage'
OK_SCREEN=$'working on the task\n> '

tick() { # <case-dir> <now-epoch> [env...]
  local dir=$1 now=$2
  shift 2
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_SCREENS="$dir/screens" FM_SEND_LOG="$dir/send.log" FM_SEND_SETTLE=0 \
    ${1+"$@"} "$TICK" --now "$now" 2>"$dir/tick.err"
}

ist() { TZ=Asia/Kolkata date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" +%s 2>/dev/null \
  || TZ=Asia/Kolkata date -d "$1" +%s; }

msg_count() { # <case-dir> <id>
  find "$1/home/state/$2.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '
}

test_replay_14_nov() {
  local dir t0 reset out
  dir=$(setup_case replay)
  printf '%s\n' "$LIMIT_SCREEN" >"$dir/screens/fm-mate"
  printf '%s\n' "$LIMIT_SCREEN" >"$dir/screens/fm-work"
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  tick "$dir" "$t0" >/dev/null
  for id in m1 w1; do
    [ -f "$dir/home/state/$id.usage-limit" ] || fail "$id: no usage-limit record"
  done
  assert_contains "$(cat "$dir/home/state/m1.usage-limit")" "kind=mate" "mate kind"
  assert_contains "$(cat "$dir/home/state/w1.usage-limit")" "kind=worker" "worker kind"
  assert_contains "$(cat "$dir/home/state/w1.usage-limit")" "reset_epoch=$reset" "reset parsed in IST"
  assert_contains "$(cat "$dir/home/state/w1.usage-limit")" "first_seen=$t0" "first seen"
  tick "$dir" $((t0 + 60)) >/dev/null
  assert_contains "$(cat "$dir/home/state/w1.usage-limit")" "first_seen=$t0" "detection is idempotent"
  [ "$(msg_count "$dir" m1)" = 0 ] && [ "$(msg_count "$dir" w1)" = 0 ] \
    || fail "nothing may be sent before reset"
  [ ! -s "$dir/send.log" ] || fail "no key may be typed before reset: $(cat "$dir/send.log")"
  tick "$dir" $((reset + 120)) >/dev/null
  [ "$(msg_count "$dir" m1)" = 1 ] || fail "the mate got no resume at reset"
  [ "$(msg_count "$dir" w1)" = 1 ] || fail "the worker got no resume at reset"
  assert_contains "$(cat "$dir"/home/state/w1.inbox/*.msg)" "usage limit has reset" "resume text"
  # Both agents pick up the work: the limit screen is gone on the next tick.
  printf '%s\n' "$OK_SCREEN" >"$dir/screens/fm-mate"
  printf '%s\n' "$OK_SCREEN" >"$dir/screens/fm-work"
  out=$(tick "$dir" $((reset + 240)))
  [ -z "$out" ] || fail "a recovered endpoint prints nothing: $out"
  for id in m1 w1; do
    [ ! -e "$dir/home/state/$id.usage-limit" ] || fail "$id: record not cleared after recovery"
  done
  pass "usage-limit: 14 Nov replay records, waits for reset, resumes both, clears"
}

test_quota_fallback() {
  local dir now out reset_iso reset
  dir=$(setup_case quota)
  printf 'Claude usage limit reached.\nTry again later.\n' >"$dir/screens/fm-work"
  now=$(ist '2026-11-14 02:50')
  reset=$((now + 1200))
  reset_iso=$(date -u -r "$reset" +%Y-%m-%dT%H:%M:%S.000000+00:00 2>/dev/null \
    || date -u -d "@$reset" +%Y-%m-%dT%H:%M:%S.000000+00:00)
  cat >"$dir/fakebin/quota-axi" <<SH
#!/usr/bin/env bash
case "\$*" in *--no-credential-refresh*) ;; *) echo "missing --no-credential-refresh" >&2; exit 9 ;; esac
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[
 {"id":"five_hour","percentRemaining":0,"resetsAt":"$reset_iso"},
 {"id":"seven_day","percentRemaining":40,"resetsAt":"2026-11-20T00:00:00.000000+00:00"}]}]}
JSON
SH
  chmod +x "$dir/fakebin/quota-axi"
  out=$(printf 'Claude usage limit reached.\n' | env PATH="$dir/fakebin:$PATH" "$DETECT" --harness claude --now "$now")
  assert_contains "$out" "reset=$reset" "detect CLI falls back to quota"
  assert_contains "$out" "reset_source=quota" "detect CLI names the source"
  tick "$dir" "$now" >/dev/null
  assert_contains "$(cat "$dir/home/state/w1.usage-limit")" "reset_epoch=$reset" "tick uses the quota reset"
  assert_contains "$(cat "$dir/home/state/w1.usage-limit")" "reset_source=quota" "tick records the quota source"
  pass "usage-limit: an unparseable reset falls back to quota-axi"
}

test_menu_never_picks_credits() {
  local dir now reset out
  dir=$(setup_case menu)
  now=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  # The highlighted option spends extra usage: the only key allowed is Escape.
  printf '5-hour limit reached - resets 3:10am (Asia/Kolkata)\n  1. Stop and wait for limit to reset\n❯ 2. Add funds to continue with extra usage\n' >"$dir/screens/fm-work"
  tick "$dir" "$now" >/dev/null
  tick "$dir" $((reset + 120)) >/dev/null
  # The doorbell itself ends with Enter; a menu key is the line sent before it (no -l).
  [ "$(grep -c -- 'send-keys -t sess:fm-work Escape' "$dir/send.log")" -ge 1 ] || fail "menu not dismissed with Escape"
  if grep -B1 -- '-l :' "$dir/send.log" | grep -q 'send-keys -t sess:fm-work Enter'; then
    fail "Enter was sent as a menu key before the resume"
  fi
  [ "$(grep -c 'Enter' "$dir/send.log")" = "$(grep -c -- '-l :' "$dir/send.log")" ] \
    || fail "an Enter beyond the doorbell submits was sent: $(cat "$dir/send.log")"
  # The highlighted option waits: Enter is allowed.
  printf '5-hour limit reached - resets 3:10am (Asia/Kolkata)\n❯ 1. Stop and wait for limit to reset\n  2. Add funds to continue with extra usage\n' >"$dir/screens/fm-work"
  out=$(printf '%s\n' "$(cat "$dir/screens/fm-work")" | "$DETECT" --now "$now")
  assert_contains "$out" "key=Enter" "a waiting highlight takes Enter"
  out=$(printf 'Your organization is out of usage credits\n' | "$DETECT" --now "$now")
  assert_not_contains "$out" "key=Enter" "out-of-credits has no Enter"
  pass "usage-limit: an option list never picks credits or extra usage"
}

test_stuck_surfaces_once() {
  local dir now reset out n lines
  dir=$(setup_case stuck)
  now=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  printf '%s\ntoken=sk-abcdefghij1234567890\n' "$LIMIT_SCREEN" >"$dir/screens/fm-work"
  tick "$dir" "$now" >/dev/null
  lines=''
  for n in 1 2 3 4 5 6 7 8; do
    out=$(tick "$dir" $((reset + 100 + n * 130)))
    lines="$lines$out"$'\n'
  done
  [ "$(printf '%s' "$lines" | grep -c 'usage-limit stuck')" = 1 ] \
    || fail "a stuck endpoint must surface exactly once: $lines"
  assert_contains "$lines" "endpoint=w1" "evidence names the endpoint"
  assert_contains "$lines" "first_seen=" "evidence has first-seen"
  assert_contains "$lines" "5-hour limit reached" "evidence has the last screen lines"
  assert_not_contains "$lines" "sk-abcdefghij" "secrets are redacted"
  [ "$(msg_count "$dir" w1)" = 3 ] || fail "retries are bounded to 3, saw $(msg_count "$dir" w1)"
  pass "usage-limit: a stuck endpoint surfaces once with redacted evidence after bounded retries"
}

test_plain_mention_is_not_a_stop() {
  local dir now
  dir=$(setup_case mention)
  now=$(ist '2026-11-14 02:50')
  { for i in $(seq 1 30); do echo "line $i of normal output"; done; echo 'grep "limit reached" bin/x.sh'; } >"$dir/screens/fm-work"
  { echo 'Stop and wait for limit to reset'; for i in $(seq 1 30); do echo "later line $i"; done; } >"$dir/screens/fm-mate"
  tick "$dir" "$now" >/dev/null
  [ ! -e "$dir/home/state/w1.usage-limit" ] || fail "a quoted limit string is not a stop"
  [ ! -e "$dir/home/state/m1.usage-limit" ] || fail "a scrolled-off limit string is not a stop"
  pass "usage-limit: output that only mentions a limit is ignored"
}

test_crew_state_not_idle() {
  local dir out
  dir=$(setup_case crewstate)
  printf '%s\n' "$LIMIT_SCREEN" >"$dir/screens/fm-mate"
  tick "$dir" "$(ist '2026-11-14 02:50')" >/dev/null
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-crew-state.sh" m1 2>&1)
  assert_contains "$out" "state: blocked" "a limit stop is not healthy idle"
  assert_contains "$out" "auto-resume pending" "crew state names the pending resume"
  pass "usage-limit: crew state reports a stopped mate as blocked, not idle"
}

test_replay_14_nov
test_crew_state_not_idle
test_quota_fallback
test_menu_never_picks_credits
test_stuck_surfaces_once
test_plain_mention_is_not_a_stop

# --- sleep/wake: the 14 Nov overnight case ---------------------------------------
# The laptop hibernated 03:24-08:38 IST. Every request in flight died; on wake the
# agent shows a connection error at an idle prompt (shape seen on 13 Nov network drops).
CONN_SCREEN=$'earlier output\n\xe2\x8f\xba Running the retag batch\n  API Error: Can\'t reach the API server \xe2\x80\x94 check your internet or DNS (ENOTFOUND)\n\n\xe2\x9d\xaf \n  Opus 5.5 | ctx 11% | HEAD'
WORKING_SCREEN=$'\xe2\x8f\xba Running the retag batch\n\xc2\xb7 Burrowing\xe2\x80\xa6 (3m 26s \xe2\x86\x93 2.5k tokens)\n\xe2\x9d\xaf '
RETRY_SCREEN=$'\xe2\x8f\xba Running the retag batch\n  API Error: Can\'t reach the API server \xe2\x80\x94 check your internet or DNS (ENOTFOUND)\n  Retrying in 8 seconds\xe2\x80\xa6 (attempt 3/10)'

test_wake_gap_resumes_connection_stop() {
  local dir t0 wake out
  dir=$(setup_case wake)
  printf '%s\n' "$WORKING_SCREEN" >"$dir/screens/fm-mate"
  printf '%s\n' "$WORKING_SCREEN" >"$dir/screens/fm-work"
  t0=$(ist '2026-11-14 03:23')
  tick "$dir" "$t0" >/dev/null
  tick "$dir" $((t0 + 60)) >/dev/null
  # Hibernate 03:24 -> 08:38. The next tick is the first after the wake.
  wake=$(ist '2026-11-14 08:38')
  printf '%s\n' "$CONN_SCREEN" >"$dir/screens/fm-mate"
  printf '%s\n' "$CONN_SCREEN" >"$dir/screens/fm-work"
  tick "$dir" "$wake" >/dev/null
  for id in m1 w1; do
    [ -f "$dir/home/state/$id.sleep-resume" ] || fail "$id: no sleep-resume record after the wake"
    assert_contains "$(cat "$dir/home/state/$id.sleep-resume")" "cause=wake" "$id: cause is the wake"
    assert_contains "$(cat "$dir/home/state/$id.sleep-resume")" "first_seen=$wake" "$id: first seen"
  done
  assert_contains "$(cat "$dir/home/state/m1.sleep-resume")" "kind=mate" "mate kind"
  [ ! -e "$dir/home/state/w1.usage-limit" ] || fail "a connection stop is not a usage-limit stop"
  [ "$(msg_count "$dir" m1)" = 0 ] && [ "$(msg_count "$dir" w1)" = 0 ] \
    || fail "nothing is sent before the post-wake settle time"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-crew-state.sh" w1 2>&1)
  assert_contains "$out" "state: blocked" "a stopped endpoint is not healthy idle"
  assert_contains "$out" "sleep-resume" "crew state names the sleep-resume stop"
  tick "$dir" $((wake + 60)) >/dev/null
  [ "$(msg_count "$dir" m1)" = 1 ] || fail "the mate got no resume after the wake"
  [ "$(msg_count "$dir" w1)" = 1 ] || fail "the worker got no resume after the wake"
  assert_contains "$(cat "$dir"/home/state/w1.inbox/*.msg)" "connection dropped" "resume text names the cause"
  printf '%s\n' "$WORKING_SCREEN" >"$dir/screens/fm-mate"
  printf '%s\n' "$WORKING_SCREEN" >"$dir/screens/fm-work"
  out=$(tick "$dir" $((wake + 120)))
  [ -z "$out" ] || fail "a recovered endpoint prints nothing: $out"
  for id in m1 w1; do
    [ ! -e "$dir/home/state/$id.sleep-resume" ] || fail "$id: record not cleared after recovery"
  done
  pass "sleep-resume: a wake gap plus a connection stop is recorded, resumed after settle, then cleared"
}

test_retrying_or_working_is_not_a_stop() {
  local dir t0 wake
  dir=$(setup_case retrying)
  t0=$(ist '2026-11-14 03:23')
  printf '%s\n' "$WORKING_SCREEN" >"$dir/screens/fm-work"
  tick "$dir" "$t0" >/dev/null
  wake=$(ist '2026-11-14 08:38')
  # The agent is still retrying by itself: leave it alone.
  printf '%s\n' "$RETRY_SCREEN" >"$dir/screens/fm-work"
  # An old error line far above a working agent is not a stop either.
  { echo "API Error: Can't reach the API server (ENOTFOUND)"; for i in $(seq 1 25); do echo "line $i"; done; } >"$dir/screens/fm-mate"
  tick "$dir" "$wake" >/dev/null
  tick "$dir" $((wake + 600)) >/dev/null
  [ ! -e "$dir/home/state/w1.sleep-resume" ] || fail "a retrying agent is not a stop"
  [ ! -e "$dir/home/state/m1.sleep-resume" ] || fail "a scrolled-off error is not a stop"
  # A quoted marker (a command or code on screen) is not a stop.
  printf 'grep "ENOTFOUND" bin/x.sh\n\xe2\x9d\xaf \n' >"$dir/screens/fm-work"
  tick "$dir" $((wake + 700)) >/dev/null
  [ ! -e "$dir/home/state/w1.sleep-resume" ] || fail "a quoted marker is not a stop"
  [ "$(msg_count "$dir" w1)" = 0 ] || fail "nothing is sent to a non-stopped endpoint"
  pass "sleep-resume: a retrying spinner, a scrolled-off error and a quoted marker are ignored"
}

test_connection_stop_without_wake_waits_longer() {
  local dir t0
  dir=$(setup_case nowake)
  printf '%s\n' "$CONN_SCREEN" >"$dir/screens/fm-work"
  t0=$(ist '2026-11-14 10:00')
  tick "$dir" "$t0" >/dev/null
  tick "$dir" $((t0 + 60)) >/dev/null
  assert_contains "$(cat "$dir/home/state/w1.sleep-resume")" "cause=network" "no wake gap: a network stop"
  tick "$dir" $((t0 + 90)) >/dev/null
  [ "$(msg_count "$dir" w1)" = 0 ] || fail "a network stop waits for the settle time"
  tick "$dir" $((t0 + 130)) >/dev/null
  [ "$(msg_count "$dir" w1)" = 1 ] || fail "a network stop resumes after the settle time"
  pass "sleep-resume: a connection stop with no wake gap resumes only after the longer settle time"
}

test_sleep_resume_bounded_and_surfaced_once() {
  local dir t0 wake n out lines
  dir=$(setup_case swstuck)
  t0=$(ist '2026-11-14 03:23')
  printf '%s\n' "$WORKING_SCREEN" >"$dir/screens/fm-work"
  tick "$dir" "$t0" >/dev/null
  wake=$(ist '2026-11-14 08:38')
  printf '%s\ntoken=sk-abcdefghij1234567890\n' "$CONN_SCREEN" >"$dir/screens/fm-work"
  lines=''
  for n in 0 1 2 3 4 5 6 7 8 9; do
    out=$(tick "$dir" $((wake + n * 130)))
    lines="$lines$out"$'\n'
  done
  [ "$(printf '%s' "$lines" | grep -c 'sleep-resume stuck')" = 1 ] \
    || fail "a stuck endpoint must surface exactly once: $lines"
  assert_contains "$lines" "endpoint=w1" "evidence names the endpoint"
  assert_contains "$lines" "ENOTFOUND" "evidence has the last screen lines"
  assert_not_contains "$lines" "sk-abcdefghij" "secrets are redacted"
  [ "$(msg_count "$dir" w1)" = 3 ] || fail "retries are bounded to 3, saw $(msg_count "$dir" w1)"
  pass "sleep-resume: retries are bounded and a stuck endpoint surfaces once with redacted evidence"
}

test_limit_screen_stays_on_limit_path() {
  local dir t0 wake
  dir=$(setup_case swlimit)
  t0=$(ist '2026-11-14 03:23')
  printf '%s\n' "$WORKING_SCREEN" >"$dir/screens/fm-work"
  tick "$dir" "$t0" >/dev/null
  wake=$(ist '2026-11-14 08:38')
  printf '%s\n%s\n' "$LIMIT_SCREEN" "  API Error: Can't reach the API server (ENOTFOUND)" >"$dir/screens/fm-work"
  tick "$dir" "$wake" >/dev/null
  [ -f "$dir/home/state/w1.usage-limit" ] || fail "a limit screen is a usage-limit stop"
  [ ! -e "$dir/home/state/w1.sleep-resume" ] || fail "a limit screen never takes the sleep-resume path"
  pass "sleep-resume: a usage-limit screen stays on the usage-limit path"
}

test_sleep_message_is_a_stop() {
  local dir t0 wake
  dir=$(setup_case slept)
  printf '%s\n' "$WORKING_SCREEN" >"$dir/screens/fm-work"
  t0=$(ist '2026-11-14 03:23')
  tick "$dir" "$t0" >/dev/null
  wake=$(ist '2026-11-14 08:38')
  printf '%s\n' $'\xe2\x8f\xba Running the retag batch\n  API Error: Your computer went to sleep mid-response. The response above may be incomplete.\n\n\xe2\x9d\xaf ' >"$dir/screens/fm-work"
  tick "$dir" "$wake" >/dev/null
  assert_contains "$(cat "$dir/home/state/w1.sleep-resume")" "shape=Your computer went to sleep" "sleep shape recorded"
  tick "$dir" $((wake + 60)) >/dev/null
  [ "$(msg_count "$dir" w1)" = 1 ] || fail "the sleep message gets one resume"
  pass "sleep-resume: Claude's own 'computer went to sleep' error is a stop"
}

test_wake_gap_resumes_connection_stop
test_sleep_message_is_a_stop
test_retrying_or_working_is_not_a_stop
test_connection_stop_without_wake_waits_longer
test_sleep_resume_bounded_and_surfaced_once
test_limit_screen_stays_on_limit_path
