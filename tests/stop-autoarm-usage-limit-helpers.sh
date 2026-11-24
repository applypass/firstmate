#!/usr/bin/env bash
# Fork-only: usage-limit tests for bin/fm-claude-stop-autoarm.sh, sourced by
# tests/fm-claude-stop-autoarm.test.sh so the upstream test file stays unchanged
# beyond a few lines. They use that file's helpers (make_primary_dir,
# write_arm_fixture, run_autoarm, expect_code, pass, fail).
# A usage-limit turn end fires Claude's StopFailure, not Stop, and Claude ignores
# that hook's exit code. The tracked StopFailure entry records main's usage limit
# and nothing else: an arm there could consume a worker's signal and lose it in
# a dropped rewake. Here the arm marks the pending signal seen, as fm-watch.sh
# does when it consumes one, so any arm leaves a trace.
# Main's pane for the StopFailure case: a fake tmux shows the limit banner above
# an empty composer until something is typed, then a recovered screen.
make_main_pane() { # <dir>
  mkdir -p "$1/fakebin" "$1/screens"
  local dash=$'\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80' bar=$'\xe2\x94\x82'
  printf 'earlier output\n5-hour limit reached - resets 3:10am (Asia/Kolkata)\n%s\n%s\n%s\n' \
    $'\xe2\x95\xad'"$dash$dash"$'\xe2\x95\xae' "$bar >      $bar" $'\xe2\x95\xb0'"$dash$dash"$'\xe2\x95\xaf' > "$1/screens/fm-main"
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) printf '%s\n' "$*" >> "$FM_SEND_LOG"; printf 'working\n> \n' > "$FM_SCREENS/fm-main"; exit 0 ;;
  display-message) case "$*" in *cursor_y*) printf '3\n' ;; *) printf 'fakepane\n' ;; esac; exit 0 ;;
  capture-pane) cat "$FM_SCREENS/fm-main"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/tmux"
}

test_stop_failure_resumes_main_and_leaves_signals() {
  local dir cmd out status payload now
  cmd=$(jq -r '[.hooks.StopFailure[]?.hooks[] | .command][0] // empty' "$ROOT/.claude/settings.json")
  [ -n "$cmd" ] || fail "no StopFailure entry in .claude/settings.json"
  now=$(TZ=Asia/Kolkata date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-14 03:12:00' +%s 2>/dev/null \
    || TZ=Asia/Kolkata date -d '2026-11-14 03:12' +%s)
  for payload in server_error rate_limit; do
    dir=$(make_primary_dir "$TMP_ROOT/stop-failure-$payload")
    cp -R "$ROOT/bin/." "$dir/bin/"
    make_main_pane "$dir"
    : > "$dir/send.log"
    printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' > "$dir/state/.primary-endpoint"
    : > "$dir/state/task.meta"
    printf 'done: PR 105 merged\n' > "$dir/state/task.status"
    write_arm_fixture "$dir" actionable
    sed -i.bak '2i\
wc -c < "$FM_HOME/state/task.status" > "$FM_HOME/state/.seen-task"
' "$dir/bin/fm-watch-arm.sh"
    # A notification-started turn hits the limit: no watcher runs to sweep main's pane.
    out=$(printf '{"session_id":"sess-autoarm","hook_event_name":"StopFailure","error":"%s"}\n' "$payload" \
      | env -u GROK_AGENT -u GROK_HOOK_EVENT -u TMUX -u HERDR_ENV PATH="$dir/fakebin:$PATH" FM_HOME="$dir" \
        CLAUDE_PROJECT_DIR="$dir" FM_HOOK_CMD="$cmd" FM_SCREENS="$dir/screens" FM_SEND_LOG="$dir/send.log" \
        FM_USAGE_LIMIT_NOW="$now" FM_USAGE_LIMIT_TICK_SECS=0 \
        "$FAKE_CLAUDE" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; bash -c "$FM_HOOK_CMD"' 2>&1)
    status=$?
    expect_code 0 "$status" "a $payload StopFailure must exit 0 with nothing to deliver"
    [ -z "$out" ] || fail "a $payload StopFailure printed output: $out"
    [ ! -e "$dir/state/arm-ran" ] || fail "a $payload StopFailure armed a watcher"
    [ ! -e "$dir/state/.seen-task" ] || fail "a $payload StopFailure consumed the pending task signal"
    [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "a $payload StopFailure wrote the autoarm ledger"
    [ ! -e "$dir/state/primary.usage-limit" ] || fail "a $payload StopFailure left a primary record: $(cat "$dir/state/primary.usage-limit")"
    if [ "$payload" = rate_limit ]; then
      grep -q 'usage limit has reset' "$dir/send.log" \
        || fail "main's limit was never resumed without a watcher: $(cat "$dir/send.log")"
    else
      [ ! -s "$dir/send.log" ] || fail "a server_error stop typed into main: $(cat "$dir/send.log")"
    fi
  done
  pass "auto-arm: a StopFailure resumes main's usage limit after reset and leaves pending signals unconsumed"
}

# A normal Stop proves main finished a turn, so main's StopFailure record (which proves the opposite)
# is stale. An unrecognised banner would otherwise leave the record until its age bound.
test_normal_stop_clears_main_limit_record() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/normal-stop-clears-record")
  cp -R "$ROOT/bin/." "$dir/bin/"
  write_arm_fixture "$dir" clean   # never start a real watcher
  printf 'backend=tmux\ntarget=sess:fm-main\nharness=claude\n' > "$dir/state/.primary-endpoint"
  printf 'endpoint=primary\nkind=primary\nfirst_seen=%s\n' "$(date +%s)" > "$dir/state/primary.usage-limit"
  out=$(run_autoarm "$dir" '{"session_id":"sess-autoarm","hook_event_name":"Stop","stop_hook_active":false}' 2>/dev/null); status=$?
  expect_code 0 "$status" "a normal Stop with nothing pending must exit 0"
  [ ! -e "$dir/state/primary.usage-limit" ] \
    || fail "a normal Stop left main's limit record: $(cat "$dir/state/primary.usage-limit")"
  pass "auto-arm: a normal Stop clears main's stale limit record"
}
