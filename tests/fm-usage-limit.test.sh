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
#   7. Reset parse (23 Nov): "resets 2:30am" read at 03:10 the same day is today, not
#      tomorrow; a time far past still rolls to tomorrow.
#   8. Primary chat (23 Nov): the primary session's pane is recorded at session start; a
#      usage-limit stop recorded by main's StopFailure hook is filled in from the screen, left
#      alone before reset, and resumed after it; main's own prose is never a stop.
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
    for a in "$@"; do case "$a" in *cursor_y*) cat "$FM_SCREENS/$win.cy" 2>/dev/null || printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf 'capture\n' >> "${FM_ORDER_LOG:-/dev/null}"; cat "$FM_SCREENS/$win" 2>/dev/null; exit 0 ;;
  list-windows) printf 'fm-mate\nfm-work\nfm-main\n'; exit 0 ;;
esac
exit 0
SH
  # Hermetic: the real quota-axi must never answer a test's reset lookup.
printf '#!/usr/bin/env bash\nexit 1\n' >"$fb/quota-axi"
chmod +x "$fb/quota-axi"
cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf 'sleep\n' >> "${FM_ORDER_LOG:-/dev/null}"
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

# --- reset parse: a time a few hours past is today (23 Nov) ----------------------
utc() { TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" +%s 2>/dev/null \
  || TZ=UTC date -d "$1" +%s; }

reset_of() { # <now-epoch> <banner>
  printf '%s\n' "$2" | "$DETECT" --now "$1" | sed -n 's/^reset=//p'
}

test_reset_few_hours_past_is_today() {
  local banner got
  banner='5-hour limit reached - resets 2:30am (UTC)'
  got=$(reset_of "$(utc '2026-11-23 03:10')" "$banner")
  [ "$got" = "$(utc '2026-11-23 02:30')" ] || fail "02:30 read at 03:10 must be today, got $got"
  got=$(reset_of "$(utc '2026-11-23 07:50')" "$banner")
  [ "$got" = "$(utc '2026-11-23 02:30')" ] || fail "02:30 read at 07:50 (5h20m past) must be today, got $got"
  got=$(reset_of "$(utc '2026-11-23 15:00')" "$banner")
  [ "$got" = "$(utc '2026-11-24 02:30')" ] || fail "02:30 read at 15:00 (far past) must be tomorrow, got $got"
  got=$(reset_of "$(utc '2026-11-23 01:00')" "$banner")
  [ "$got" = "$(utc '2026-11-23 02:30')" ] || fail "02:30 read at 01:00 must be today, got $got"
  got=$(reset_of "$(utc '2026-11-24 00:30')" '5-hour limit reached - resets 11:30pm (UTC)')
  [ "$got" = "$(utc '2026-11-23 23:30')" ] || fail "23:30 read at 00:30 next day must be the past reset, got $got"
  pass "usage-limit: a reset time a few hours past is today (or yesterday), a far-past one is tomorrow"
}

# --- primary chat: main's own pane is recorded and resumed (23 Nov) --------------
BOX_TOP=$'\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae'
BOX_BOTTOM=$'\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf'
BAR=$'\xe2\x94\x82'
LIMIT_LINES=$'earlier output\n5-hour limit reached - resets 3:10am (Asia/Kolkata)'
# Main's chat: the limit banner above an empty composer, cursor on the prompt row (3).
PRIMARY_SCREEN="$LIMIT_LINES"$'\n'"$BOX_TOP"$'\n'"$BAR >      $BAR"$'\n'"$BOX_BOTTOM"
PRIMARY_TYPED="$LIMIT_LINES"$'\n'"$BOX_TOP"$'\n'"$BAR > fix  $BAR"$'\n'"$BOX_BOTTOM"

hook_record() { # <case-dir> <first-seen>: what main's rate_limit StopFailure hook writes
  printf 'endpoint=primary\nkind=primary\nfirst_seen=%s\n' "$2" >"$1/home/state/primary.usage-limit"
}

main_screen() { # <case-dir> <screen>
  printf '%s\n' "$2" >"$1/screens/fm-main"
  printf '3\n' >"$1/screens/fm-main.cy"
}

test_primary_endpoint_record() {
  local dir
  dir=$(setup_case primrec)
  env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET -u TERM_PROGRAM \
    -u REX_SESSION -u REX_BLOCK -u FM_SUPERVISOR_BACKEND PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir/home" "$ROOT/bin/fm-primary-endpoint.sh" record >/dev/null 2>&1
  [ ! -e "$dir/home/state/.primary-endpoint" ] || fail "no pane found: nothing may be recorded"
  env -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET PATH="$dir/fakebin:$PATH" TMUX_PANE=sess:fm-main \
    CLAUDECODE=1 FM_HOME="$dir/home" "$ROOT/bin/fm-primary-endpoint.sh" record >/dev/null 2>&1
  assert_contains "$(cat "$dir/home/state/.primary-endpoint")" "target=sess:fm-main" "primary target recorded"
  assert_contains "$(cat "$dir/home/state/.primary-endpoint")" "backend=tmux" "primary backend recorded"
  pass "usage-limit: the primary session's pane is recorded at session start"
}

test_primary_stop_recorded_and_resumed() {
  local dir t0 reset out
  dir=$(setup_case primary)
  main_screen "$dir" "$PRIMARY_SCREEN"
  env -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET PATH="$dir/fakebin:$PATH" TMUX_PANE=sess:fm-main \
    CLAUDECODE=1 FM_HOME="$dir/home" "$ROOT/bin/fm-primary-endpoint.sh" record >/dev/null 2>&1
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  tick "$dir" "$t0" >/dev/null
  [ ! -e "$dir/home/state/primary.usage-limit" ] || fail "a banner alone, with no StopFailure record, recorded main"
  hook_record "$dir" "$t0"
  tick "$dir" "$t0" >/dev/null
  [ -f "$dir/home/state/primary.usage-limit" ] || fail "primary stop not recorded"
  assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "kind=primary" "primary kind"
  assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "reset_epoch=$reset" "primary reset parsed"
  tick "$dir" $((t0 + 60)) >/dev/null
  ! grep -q 'fm-main' "$dir/send.log" || fail "nothing may be typed into main before reset: $(cat "$dir/send.log")"
  tick "$dir" $((reset + 120)) >/dev/null
  grep 'fm-main' "$dir/send.log" | grep -q 'usage limit has reset' \
    || fail "main's chat got no resume at reset: $(cat "$dir/send.log")"
  printf '%s\n' "$OK_SCREEN" >"$dir/screens/fm-main"
  out=$(tick "$dir" $((reset + 240)))
  [ -z "$out" ] || fail "a recovered primary prints nothing: $out"
  [ ! -e "$dir/home/state/primary.usage-limit" ] || fail "primary record not cleared after recovery"
  pass "usage-limit: a stop in the primary chat is recorded, waits for reset, resumes, clears"
}

test_primary_stuck_surfaces_once() {
  local dir t0 reset out lines n
  dir=$(setup_case primstuck)
  main_screen "$dir" "$PRIMARY_SCREEN"
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  hook_record "$dir" "$t0"
  tick "$dir" "$t0" >/dev/null
  lines=''
  for n in 1 2 3 4 5 6 7 8; do
    out=$(tick "$dir" $((reset + 100 + n * 130)))
    lines="$lines$out"$'\n'
  done
  [ "$(printf '%s' "$lines" | grep -c 'usage-limit stuck')" = 1 ] \
    || fail "a stuck primary must surface exactly once: $lines"
  assert_contains "$lines" "endpoint=primary" "evidence names the primary"
  [ "$(grep 'fm-main' "$dir/send.log" | grep -c 'usage limit has reset')" = 3 ] \
    || fail "primary retries are bounded to 3: $(cat "$dir/send.log")"
  pass "usage-limit: a stuck primary surfaces once after bounded retries"
}

test_primary_composer_must_be_empty() {
  local dir t0 reset screen
  dir=$(setup_case primguard)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  hook_record "$dir" "$t0"
  # A half-typed composer, then a screen with no provable composer at all.
  for screen in "$PRIMARY_TYPED" "$LIMIT_LINES"; do
    main_screen "$dir" "$screen"
    tick "$dir" "$t0" >/dev/null
    tick "$dir" $((reset + 120)) >/dev/null
    tick "$dir" $((reset + 300)) >/dev/null
    ! grep -q 'fm-main' "$dir/send.log" || fail "typed into a composer not proven empty: $(cat "$dir/send.log")"
    assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "attempts=0" "a skipped tick spends no attempt"
  done
  main_screen "$dir" "$PRIMARY_SCREEN"
  tick "$dir" $((reset + 420)) >/dev/null
  grep 'fm-main' "$dir/send.log" | grep -q 'usage limit has reset' \
    || fail "main got no resume once its composer was empty: $(cat "$dir/send.log")"
  pass "usage-limit: main is typed into only when its composer is proven empty"
}

test_primary_gets_no_sleep_resume() {
  local dir t0 wake
  dir=$(setup_case primsleep)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  main_screen "$dir" "$WORKING_SCREEN"
  t0=$(ist '2026-11-14 03:23')
  tick "$dir" "$t0" >/dev/null
  wake=$(ist '2026-11-14 08:38')
  main_screen "$dir" "$CONN_SCREEN"
  tick "$dir" "$wake" >/dev/null
  tick "$dir" $((wake + 60)) >/dev/null
  tick "$dir" $((wake + 300)) >/dev/null
  [ ! -e "$dir/home/state/primary.sleep-resume" ] || fail "main got a sleep-resume record"
  ! grep -q 'fm-main' "$dir/send.log" || fail "main got a sleep resume: $(cat "$dir/send.log")"
  pass "sleep-resume: main's own chat gets no sleep or network resume"
}

test_primary_banner_must_be_last_output() {
  local dir t0 reset screen box
  dir=$(setup_case primlast)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  box="$BOX_TOP"$'\n'"$BAR >      $BAR"$'\n'"$BOX_BOTTOM"
  # With no StopFailure record: a relayed stuck line, replies that mention or end on the limit,
  # a captain prompt quoting a banner while main thinks, and a banner left above a later reply.
  # None is a stop, so nothing is recorded and nothing is typed.
  for screen in \
    $'> check on the mate\n\xe2\x8f\xba Relayed: usage-limit stuck: endpoint=m1 5-hour limit reached - resets 3:10am\n  I will retry it after the reset.' \
    $'\xe2\x8f\xba The mate hit the 5-hour limit reached banner earlier; it resets 3:10am.\n  Nothing to do yet.' \
    $'\xe2\x8f\xba relmate hit its usage limit, it resets at 3:10am.' \
    $'\xe2\x8f\xba Done. PR 105 now resumes main after\n  the usage limit resets.' \
    $'> relmate shows 5-hour limit reached - resets 3:10am, wait?\n\xe2\x9c\xbb Thinking\xe2\x80\xa6 (esc to interrupt)' \
    "$LIMIT_LINES"$'\n> usage limit has reset - carry on\n\xe2\x8f\xba Picking the task back up.'; do
    main_screen "$dir" "$screen"$'\n'"$box"
    tick "$dir" "$t0" >/dev/null
    tick "$dir" $((reset + 120)) >/dev/null
    [ ! -e "$dir/home/state/primary.usage-limit" ] || fail "main recorded as stopped below a later line: $screen"
    ! grep -q 'fm-main' "$dir/send.log" || fail "typed into main that was not stopped: $(cat "$dir/send.log")"
  done
  # Main's own StopFailure hook leaves a record with no reset; the tick fills it in, sending nothing yet.
  hook_record "$dir" "$t0"
  main_screen "$dir" "$PRIMARY_SCREEN"
  tick "$dir" $((t0 + 60)) >/dev/null
  assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "reset_epoch=$reset" "hook record gets the screen reset"
  ! grep -q 'fm-main' "$dir/send.log" || fail "a hook record made the tick type before reset: $(cat "$dir/send.log")"
  tick "$dir" $((reset + 120)) >/dev/null
  grep 'fm-main' "$dir/send.log" | grep -q 'usage limit has reset' \
    || fail "main got no resume with the banner right above its composer: $(cat "$dir/send.log")"
  pass "usage-limit: main is stopped only when the banner is the last output above its composer"
}

test_secondmate_home_records_no_primary() {
  local dir
  dir=$(setup_case primsm)
  printf 'm9\n' >"$dir/home/.fm-secondmate-home"
  printf 'backend=tmux\ntarget=sess:old\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  env -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET PATH="$dir/fakebin:$PATH" TMUX_PANE=sess:fm-main \
    CLAUDECODE=1 FM_HOME="$dir/home" "$ROOT/bin/fm-primary-endpoint.sh" record >/dev/null 2>&1
  [ ! -e "$dir/home/state/.primary-endpoint" ] || fail "a secondmate home must record no primary endpoint"
  pass "usage-limit: a secondmate home records no primary endpoint and drops an old one"
}

# --- primary chat: the hook record proves the stop (24 Nov review) ----------------
# A shape the banner matcher does not recognise. main's StopFailure hook already proved the stop,
# so an unreadable screen must neither clear the record nor leave main unresumed.
test_primary_unrecognized_banner_keeps_record() {
  local dir t0 reset screen n box
  box="$BOX_TOP"$'\n'"$BAR >      $BAR"$'\n'"$BOX_BOTTOM"
  t0=$(ist '2026-11-14 02:50')
  reset=$((t0 + 900))
  screen=$'\xe2\x8f\xba Running the retag batch\n  5-hour limit reached - resets 3:10am (Asia/Kolkata)'
  dir=$(setup_case primshape)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  hook_record "$dir" "$t0"
  main_screen "$dir" "$screen"$'\n'"$box"
  printf '%s\n' "$(($(printf '%s\n' "$screen" | wc -l) + 1))" >"$dir/screens/fm-main.cy"   # composer row
  tick "$dir" "$((t0 + 60))" >/dev/null
  [ -f "$dir/home/state/primary.usage-limit" ] || fail "the first sweep cleared main's record"
  ! grep -q 'fm-main' "$dir/send.log" || fail "typed before the assumed reset"
  for n in 1 2 3 4 5; do
    out=$(tick "$dir" $((reset + 100 + n * 130)))
    [ -z "$out" ] || fail "an unconfirmed stop must print no stuck line: $out"
  done
  [ -f "$dir/home/state/primary.usage-limit" ] || fail "record lost before its age bound"
  [ "$(grep 'fm-main' "$dir/send.log" | grep -c 'usage limit has reset')" = 1 ] \
    || fail "an unreadable screen gets exactly one resume: $(cat "$dir/send.log")"
  tick "$dir" $((t0 + 8 * 3600 + 60)) >/dev/null
  [ ! -e "$dir/home/state/primary.usage-limit" ] || fail "an unconfirmed record outlived its age bound"
  pass "usage-limit: an unrecognised banner shape keeps main's record, resumes once, and ages out"
}

# Output below the banner that is not a new turn (a hint bullet, an upsell line) keeps it a stop.
test_primary_banner_with_trailing_output_is_a_stop() {
  local dir t0 reset screen shape=0 box
  box="$BOX_TOP"$'\n'"$BAR >      $BAR"$'\n'"$BOX_BOTTOM"
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  for screen in \
    $'  \xe2\x8e\xbf  5-hour limit reached - resets 3:10am (Asia/Kolkata)\n     \xe2\x80\xa2 /upgrade to increase your usage limit.' \
    "$LIMIT_LINES"$'\nUpgrade your plan at claude.ai/settings to keep going.'; do
    shape=$((shape + 1))
    dir=$(setup_case "primtrail$shape")
    printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
    hook_record "$dir" "$t0"
    main_screen "$dir" "$screen"$'\n'"$box"
    printf '%s\n' "$(($(printf '%s\n' "$screen" | wc -l) + 1))" >"$dir/screens/fm-main.cy"
    tick "$dir" "$((t0 + 60))" >/dev/null
    assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "reset_epoch=$reset" "shape $shape: banner reset read"
    assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "reset_source=screen" "shape $shape: banner confirmed"
  done
  pass "usage-limit: output below main's banner that is not a new turn keeps it a stop"
}

# A banner a sweep read, then gone from the screen, is positive evidence that main resumed.
test_primary_confirmed_stop_clears_when_main_resumes() {
  local dir t0 reset
  dir=$(setup_case primconfirmed)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  hook_record "$dir" "$t0"
  main_screen "$dir" "$PRIMARY_SCREEN"
  tick "$dir" "$t0" >/dev/null
  assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "reset_source=screen" "banner confirmed"
  main_screen "$dir" "$LIMIT_LINES"$'\n> carry on\n\xe2\x8f\xba Picking the task back up.\n'"$BOX_TOP"$'\n'"$BAR >      $BAR"$'\n'"$BOX_BOTTOM"
  tick "$dir" $((reset - 600)) >/dev/null
  [ ! -e "$dir/home/state/primary.usage-limit" ] || fail "a confirmed banner followed by a reply must clear the record"
  ! grep -q 'fm-main' "$dir/send.log" || fail "typed into main after it resumed: $(cat "$dir/send.log")"
  pass "usage-limit: a confirmed stop clears once main shows a later reply"
}

# A local command the captain runs below the banner never reaches the model, so main is still stopped.
test_primary_local_command_keeps_record() {
  local dir t0 reset screen box
  dir=$(setup_case primlocal)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  box="$BOX_TOP"$'\n'"$BAR >      $BAR"$'\n'"$BOX_BOTTOM"
  hook_record "$dir" "$t0"
  main_screen "$dir" "$PRIMARY_SCREEN"
  tick "$dir" "$t0" >/dev/null
  assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "reset_source=screen" "banner confirmed"
  screen="$LIMIT_LINES"$'\n\n> /usage\n\xe2\x8e\xbf Status dialog dismissed\n> !ls\n  \xe2\x8e\xbf  notes.md'
  main_screen "$dir" "$screen"$'\n'"$box"
  printf '%s\n' "$(($(printf '%s\n' "$screen" | wc -l) + 1))" >"$dir/screens/fm-main.cy"
  tick "$dir" $((t0 + 300)) >/dev/null
  [ -f "$dir/home/state/primary.usage-limit" ] || fail "a local command below the banner cleared main's record"
  screen="$LIMIT_LINES"$'\n\n> /usage\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Settings:  Status   Config   Usage\n\n  Current session\n  \xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88 100% used\n  Resets 9pm (UTC)\n\n  Current week (all models)\n  \xe2\x96\x88\xe2\x96\x88 40% used\n  Resets Dec 1, 9pm (UTC)\n\n  Current week (Opus)\n  \xe2\x96\x88 10% used\n  Resets Dec 1, 9pm (UTC)\n\n  Extra usage\n  Not enabled\n\n  Esc to cancel\n! ls\n  \xe2\x8e\xbf  notes.md'
  main_screen "$dir" "$screen"$'\n'"$box"
  printf '%s\n' "$(($(printf '%s\n' "$screen" | wc -l) + 1))" >"$dir/screens/fm-main.cy"
  tick "$dir" $((t0 + 600)) >/dev/null
  [ -f "$dir/home/state/primary.usage-limit" ] || fail "an open /usage panel below the banner cleared main's record"
  tick "$dir" $((reset + 120)) >/dev/null
  grep 'fm-main' "$dir/send.log" | grep -q 'usage limit has reset' \
    || fail "main got no resume after a local command below its banner: $(cat "$dir/send.log")"
  pass "usage-limit: local command output below main's banner keeps the record and the resume"
}

# An open /usage panel below the banner lists other reset times; only the banner's counts.
test_primary_reset_read_from_banner_only() {
  local dir t0 reset screen
  dir=$(setup_case primpanel)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  screen="$LIMIT_LINES"$'\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Current session\n  Resets 9pm (UTC)\n\n  Current week (all models)\n  Resets Dec 1, 9pm (UTC)\n\n  Esc to cancel'
  main_screen "$dir" "$screen"$'\n'"$BOX_TOP"$'\n'"$BAR >      $BAR"$'\n'"$BOX_BOTTOM"
  printf '%s\n' "$(($(printf '%s\n' "$screen" | wc -l) + 1))" >"$dir/screens/fm-main.cy"
  hook_record "$dir" "$t0"
  tick "$dir" $((t0 + 60)) >/dev/null
  assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "reset_epoch=$reset" "first sweep reads the banner's reset"
  hook_record "$dir" "$t0"
  printf 'reset_epoch=%s\nreset_source=assumed\nattempts=0\nlast_attempt=0\nsurfaced=0\n' $((t0 + 18000)) \
    >>"$dir/home/state/primary.usage-limit"
  tick "$dir" $((t0 + 120)) >/dev/null
  assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "reset_epoch=$reset" "a guessed reset is refined from the banner"
  ! grep -q 'fm-main' "$dir/send.log" || fail "typed into main before its reset: $(cat "$dir/send.log")"
  pass "usage-limit: main's reset comes from its banner, never from a /usage panel below it"
}

# Claude draws an empty composer while it works, so an empty box alone never licenses typing.
test_primary_busy_main_gets_no_resume() {
  local dir t0 screen
  dir=$(setup_case primbusy)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  t0=$(ist '2026-11-14 02:50')
  hook_record "$dir" "$t0"
  screen=$'> continue\n\xc2\xb7 Burrowing\xe2\x80\xa6 (3m 26s \xe2\x86\x93 2.5k tokens)'
  main_screen "$dir" "$screen"$'\n'"$BOX_TOP"$'\n'"$BAR >      $BAR"$'\n'"$BOX_BOTTOM"
  tick "$dir" $((t0 + 60)) >/dev/null
  tick "$dir" $((t0 + 1200)) >/dev/null
  tick "$dir" $((t0 + 1400)) >/dev/null
  ! grep -q 'fm-main' "$dir/send.log" || fail "typed a resume into a busy main: $(cat "$dir/send.log")"
  assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "attempts=0" "a busy tick spends no attempt"
  pass "usage-limit: main is never typed into while it is busy"
}

# --wait-primary: the waiter run by main's StopFailure hook.
wait_primary() { # <case-dir> <now-epoch> [env...]; returns 1 when the waiter never exits
  local dir=$1 now=$2 pid i
  shift 2
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_SCREENS="$dir/screens" FM_SEND_LOG="$dir/send.log" FM_SEND_SETTLE=0 \
    FM_USAGE_LIMIT_NOW="$now" FM_USAGE_LIMIT_TICK_SECS=0 \
    ${1+"$@"} "$TICK" --wait-primary >"$dir/wait.out" 2>&1 &
  pid=$!
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }
    /bin/sleep 0.1
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 1
}

# The first sweep waits one tick, so Claude has drawn the banner before the waiter reads it.
test_wait_primary_sleeps_before_first_sweep() {
  local dir t0 reset
  dir=$(setup_case waitorder)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  hook_record "$dir" "$t0"
  main_screen "$dir" "$PRIMARY_SCREEN"
  : >"$dir/order.log"
  wait_primary "$dir" $((reset + 120)) FM_ORDER_LOG="$dir/order.log" FM_UL_MAX_ATTEMPTS=1 FM_UL_RETRY_SECS=0 \
    || fail "the waiter did not exit: $(cat "$dir/wait.out")"
  [ "$(head -n 1 "$dir/order.log")" = sleep ] \
    || fail "the waiter swept main's pane before its first sleep: $(tr '\n' ' ' <"$dir/order.log")"
  grep 'fm-main' "$dir/send.log" | grep -q 'usage limit has reset' \
    || fail "the waiter never resumed main: $(cat "$dir/send.log")"
  pass "usage-limit: the waiter sleeps one tick before it first sweeps main"
}

# The waiter must leave the one stuck line to a watcher tick.
test_wait_primary_leaves_stuck_line_to_watcher() {
  local dir t0 reset out
  dir=$(setup_case waitstuck)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  t0=$(ist '2026-11-14 02:50')
  reset=$(ist '2026-11-14 03:10')
  printf 'endpoint=primary\nkind=primary\nfirst_seen=%s\nreset_epoch=%s\nreset_source=screen\nattempts=3\nlast_attempt=%s\nsurfaced=0\n' \
    "$t0" "$reset" "$((reset + 100))" >"$dir/home/state/primary.usage-limit"
  main_screen "$dir" "$PRIMARY_SCREEN"
  wait_primary "$dir" $((reset + 1000)) || fail "the waiter did not exit after the attempts were spent"
  [ ! -s "$dir/wait.out" ] || fail "the waiter printed output: $(cat "$dir/wait.out")"
  assert_contains "$(cat "$dir/home/state/primary.usage-limit")" "surfaced=0" "the waiter must not take the stuck line"
  out=$(tick "$dir" $((reset + 1000)))
  [ "$(printf '%s\n' "$out" | grep -c 'usage-limit stuck')" = 1 ] || fail "the watcher tick owns the stuck line: $out"
  pass "usage-limit: the waiter leaves the one stuck line to a watcher tick"
}

# An orphaned waiter (pane gone, no capture works) ends at the record's age bound.
test_wait_primary_ends_at_age_bound() {
  local dir t0
  dir=$(setup_case waitorphan)
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' >"$dir/home/state/.primary-endpoint"
  t0=$(ist '2026-11-14 02:50')
  hook_record "$dir" "$t0"
  wait_primary "$dir" $((t0 + 8 * 3600 + 60)) \
    || fail "an orphaned waiter never exited: $(cat "$dir/wait.out")"
  pass "usage-limit: the waiter ends once the record is past its age bound"
}

test_reset_few_hours_past_is_today
test_primary_endpoint_record
test_primary_stop_recorded_and_resumed
test_primary_stuck_surfaces_once
test_primary_composer_must_be_empty
test_primary_gets_no_sleep_resume
test_primary_banner_must_be_last_output
test_secondmate_home_records_no_primary
test_primary_unrecognized_banner_keeps_record
test_primary_confirmed_stop_clears_when_main_resumes
test_primary_banner_with_trailing_output_is_a_stop
test_primary_reset_read_from_banner_only
test_primary_local_command_keeps_record
test_primary_busy_main_gets_no_resume
test_wait_primary_sleeps_before_first_sweep
test_wait_primary_leaves_stuck_line_to_watcher
test_wait_primary_ends_at_age_bound
