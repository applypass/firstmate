#!/usr/bin/env bash
# Fork-only (applypass): bin/fm-secondmate-fresh-session.sh - a second mate
# restarts with a short handover note once it finishes a piece of work.
#
# Everything runs through the real commands (fm-secondmate-report.sh, the
# parent-channel library, fm-secondmate-fresh-session.sh sweep, the real
# fm-control relaunch, fm-send, the real pending-reply records) against a
# session-provider stub that models the agent's exit and relaunch:
#
#   1. report done -> restart requested -> the mate is relaunched and the fresh
#      session is pointed at a handover note of under 40 lines.
#   2. A mate in the middle of a request is NOT restarted: another open request,
#      an unread steering message, an unacknowledged wake row, or a busy agent
#      each defer the restart and leave every durable record untouched.
#   3. An unread steering message survives the restart and a deferral.
#   4. A child whose work landed (merged PR or landed cleanup record) asks for
#      the same fresh session; a child's PR-ready line, a pure acknowledgement
#      without --item, a main home, a remote route, and
#      FM_SECONDMATE_FRESH_SESSION=off ask for nothing.
#   5. A corr with no pending-reply record does not defer forever, and a failed
#      relaunch leaves a line in state/fresh-session.log.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FRESH="$ROOT/bin/fm-secondmate-fresh-session.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-fresh-session)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'chmod -R u+w "$TMP_ROOT" 2>/dev/null; rm -rf -- "$TMP_ROOT"' EXIT

make_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          if [ -e "$D/remote-relaunch-start" ] && [ ! -e "$D/remote-relaunch-end" ]; then
            : > "$D/local-relaunch-during-remote"
          fi
          printf 'zsh' > "$D/command.$target"
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) cat "$D/becomes" > "$D/command.$target" ;;
        ': Firstmate instruction waiting: list '*)
          printf 'doorbell\n' >> "$D/rings"
          if [ -x "$D/on-doorbell" ]; then
            "$D/on-doorbell" "$payload"
          fi
          if [ -f "$D/answer-inbox" ]; then
            # Model the mate: read the newest instruction it was handed and
            # report back on the parent channel, carrying the correlation token
            # the request itself embedded.
            inbox=$(cat "$D/answer-inbox")
            corr=$(cat "$inbox"/*.msg 2>/dev/null \
              | grep -oE 'corr=[0-9a-f]{16}' | head -1)
            if [ -n "$corr" ]; then
              printf 'done [%s]: open records written down\n' "$corr" \
                >> "$(cat "$D/answer-status")"
            fi
          fi
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    target=
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ]; then target=$a; fi
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          if [ -f "$D/command.$target" ]; then cat "$D/command.$target"; else cat "$D/command"; fi
          printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
      prev=$a
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ''|*[!0-9]*) ;;
  *) /bin/sleep 0.01 ;;
esac
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> -> a parent home with a stub session provider.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  printf 'claude\n' > "$dir/home/config/secondmate-harness"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/rings"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_stub "$dir"
  printf '%s\n' "$dir"
}

# add_local_mate <case-dir> <id> [harness] [backend-line]
# A live LOCAL second mate: a real git worktree for its home, plus the durable
# record this home keeps for it.
add_local_mate() {
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-}
  local home="$dir/home" smhome="$dir/$id-home"
  fm_git_worktree "$dir/$id-repo" "$smhome" "sm-$id"
  mkdir -p "$smhome/state" "$smhome/data" "$smhome/bin" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# agents\n' > "$smhome/AGENTS.md"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
}


# The harness exit command is a whole line of the pane transcript; assert_grep is
# a substring match, so these read the line exactly.
assert_stopped() {  # <case-dir> <msg>
  grep -qx '/exit' "$1/fake/literal" || fail "$2"
}
assert_not_stopped() {  # <case-dir> <msg>
  ! grep -qx '/exit' "$1/fake/literal" || fail "$2"
}

# bind_mate <case-dir> <id>: the parent binding a seeded home carries, plus the
# semantic idle record the harness's own hook would have written.
bind_mate() {
  local dir=$1 id=$2 smhome
  smhome="$dir/$id-home"
  cat > "$smhome/.fm-secondmate-parent" <<EOT
schema=fm-secondmate-parent.v1
route=local
parent_home=$dir/home
EOT
  set_agent_state "$dir" "$id" idle
}

# set_agent_state <case-dir> <id> <idle|busy>
set_agent_state() {
  local dir=$1 id=$2 state=$3 st="$1/home/state"
  printf 'g1\n' > "$st/$id.busy-gen"
  printf 'v1 gen=g1 seq=1 state=%s source=claude-hook event=Stop ts=%s\n' "$state" "$(date +%s)" > "$st/$id.busy-state"
}

# open_request <case-dir> <id> -> corr: a reply-bearing request to the mate,
# recorded by the real pending-reply library.
open_request() {
  local dir=$1 id=$2
  bash -c '. "$1/bin/fm-pending-reply-lib.sh"
    corr=$(fm_pending_reply_create "$2" "$3" "$4" "do the audit") || exit 1
    fm_pending_reply_mark_delivered "$3" "$corr"
    printf "%s" "$corr"' \
    _ "$ROOT" "$dir/home" "$dir/home/state" "$id"
}

mate_report() {  # <case-dir> <id> <verb> <corr> <note>
  local dir=$1 id=$2
  FM_HOME="$dir/$id-home" "$REPORT" --item work-1 "$3" "$4" "$5" || fail "the report helper refused"
}

sweep() {  # <case-dir>
  local dir=$1
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
    FM_CONTROL_LAUNCH_WAIT=0.05 "$FRESH" sweep 2>&1
}

# --- T1: report done -> restart requested -> fresh session gets the note ------
test_report_done_restarts_with_handover_note() {
  local dir corr out note msg
  dir=$(new_case "done")
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  corr=$(open_request "$dir" sm1)
  mkdir -p "$dir/sm1-home/state"
  printf 'working [at=1]: slice 2 under way\n' > "$dir/sm1-home/state/child1.status"
  printf 'kind=ship\n' > "$dir/sm1-home/state/child1.meta"

  mate_report "$dir" sm1 "done" "$corr" "audit clean"

  assert_present "$dir/sm1-home/state/fresh-session.request" "a done report must request a fresh session"
  assert_present "$dir/sm1-home/data/fresh-session-handover.md" "the handover note must be written in the mate's home"
  assert_not_stopped "$dir" "requesting must not touch the running agent"

  out=$(sweep "$dir")
  assert_contains "$out" "restarted sm1" "an idle mate with no open request must be restarted"$'\n'"$out"
  assert_stopped "$dir" "the old agent must be stopped by the relaunch"
  assert_absent "$dir/sm1-home/state/fresh-session.request" "the request marker must be consumed"

  note=$(cat "$dir/sm1-home/data/fresh-session-handover.md")
  [ "$(printf '%s\n' "$note" | wc -l)" -le 40 ] || fail "the handover note must stay under 40 lines"
  assert_contains "$note" "audit clean" "the note must say what finished"
  assert_contains "$note" "child1: working" "the note must list the child still in flight"
  assert_contains "$note" "bin/fm-session-start.sh" "the note must send the fresh session through session start"

  msg=$(cat "$dir/home/state/sm1.inbox"/*.msg)
  assert_contains "$msg" "$dir/sm1-home/data/fresh-session-handover.md" "the fresh session must be pointed at the note"
  assert_contains "$msg" "not a request" "the pointer must not open a reply expectation"
  pass "T1 report done -> restart -> fresh session pointed at the handover note"
}

# --- T2: a mate mid-request is never restarted -------------------------------
test_mid_request_is_not_restarted() {
  local dir corr other out
  dir=$(new_case midreq)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  corr=$(open_request "$dir" sm1)
  other=$(open_request "$dir" sm1)
  mate_report "$dir" sm1 "done" "$corr" "first piece done"

  out=$(sweep "$dir")
  assert_contains "$out" "deferred sm1" "a second open request must defer the restart"
  assert_contains "$out" "$other" "the deferral must name the open request"
  assert_not_stopped "$dir" "a mate mid-request must not be stopped"
  assert_present "$dir/sm1-home/state/fresh-session.request" "the request must stay for a later pass"
  grep -q '^phase=awaiting_report$' "$dir/home/state/pending-replies/$other" \
    || fail "the open request's record was changed by the deferral"

  # The same mate restarts once that request is answered.
  mate_report "$dir" sm1 "done" "$other" "second piece done"
  out=$(sweep "$dir")
  assert_contains "$out" "restarted sm1" "the mate must restart once no request is open"$'\n'"$out"
  pass "T2 an open request defers the restart and is left untouched"
}

# --- T3: unread steering, an unacknowledged wake, and a busy agent defer -------
test_unread_work_and_busy_agent_defer() {
  local dir corr out
  dir=$(new_case unread)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  corr=$(open_request "$dir" sm1)
  mate_report "$dir" sm1 "done" "$corr" "done"

  mkdir -p "$dir/home/state/sm1.inbox"
  printf 'please also check the ledger\n' > "$dir/home/state/sm1.inbox/0001.msg"
  out=$(sweep "$dir")
  assert_contains "$out" "deferred sm1: a steering message to it is unread" "an unread steering message must defer"
  assert_present "$dir/home/state/sm1.inbox/0001.msg" "the unread message must survive the deferral"
  assert_not_stopped "$dir" "the agent was stopped with an unread message"

  # The mate reads it; the next pass must keep the handled record and restart.
  mkdir -p "$dir/home/state/sm1.inbox/handled"
  mv "$dir/home/state/sm1.inbox/0001.msg" "$dir/home/state/sm1.inbox/handled/"
  printf '5\t1\twake\tx\tsomething still unacknowledged\n' > "$dir/sm1-home/state/.wake-queue"
  out=$(sweep "$dir")
  assert_contains "$out" "unacknowledged row" "an unacknowledged wake must defer"
  assert_present "$dir/sm1-home/state/.wake-queue" "the wake queue must survive the deferral"
  assert_not_stopped "$dir" "the agent was stopped with an unacknowledged wake"

  : > "$dir/sm1-home/state/.wake-queue"
  set_agent_state "$dir" sm1 busy
  out=$(sweep "$dir")
  assert_contains "$out" "not provably idle" "a busy agent must defer"
  assert_not_stopped "$dir" "a busy agent was stopped"

  set_agent_state "$dir" sm1 idle
  out=$(sweep "$dir")
  assert_contains "$out" "restarted sm1" "every check clear must restart"$'\n'"$out"
  assert_present "$dir/home/state/sm1.inbox/handled/0001.msg" "the handled message record was lost in the restart"
  pass "T3 unread steering, an unacknowledged wake, and a busy agent each defer; nothing is lost"
}

# --- T4: a landed child asks for a fresh session; other child lines do not ----
test_child_landed_requests() {
  local dir out
  dir=$(new_case child)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  # A PR-ready line and a decision line go through the shared report path.
  FM_HOME="$dir/sm1-home" bash -c '. "$1/bin/fm-parent-channel-lib.sh"; fm_parent_channel_report "$2" "$2/state" "done [key=child-pr-x]: child x PR ready"; fm_parent_channel_report "$2" "$2/state" "needs-decision: pick one"' \
    _ "$ROOT" "$dir/sm1-home"
  assert_absent "$dir/sm1-home/state/fresh-session.request" "a PR-ready or decision line must not request a restart"
  # A pure acknowledgement (no --item) must not request one either.
  FM_HOME="$dir/sm1-home" "$REPORT" "done" abcdef0123456789 "re-read AGENTS.md" || fail "the ack report refused"
  assert_absent "$dir/sm1-home/state/fresh-session.request" "an acknowledgement without --item must not request a restart"
  # A merged child PR is a landed piece of work.
  FM_HOME="$dir/sm1-home" bash -c '. "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$2" "$2/state" child1 https://github.com/o/r/pull/7 self attended' \
    _ "$ROOT" "$dir/sm1-home" || true
  assert_present "$dir/sm1-home/state/fresh-session.request" "a merged child PR must request a fresh session"
  pass "T4 a landed child requests a fresh session; PR-ready, decision and ack lines do not"
}

# --- T5: nothing is requested where it does not apply -------------------------
test_no_request_where_not_applicable() {
  local dir
  dir=$(new_case n/a)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  FM_SECONDMATE_FRESH_SESSION=off FM_HOME="$dir/sm1-home" "$FRESH" request --source report --verb "done" "x"
  assert_absent "$dir/sm1-home/state/fresh-session.request" "the kill switch must stop requests"
  FM_HOME="$dir/home" "$FRESH" request --source report --verb "done" "x"
  assert_absent "$dir/home/state/fresh-session.request" "a main home has nobody to restart it"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$dir/sm1-home/.fm-secondmate-parent"
  FM_HOME="$dir/sm1-home" "$FRESH" request --source report --verb "done" "x"
  assert_absent "$dir/sm1-home/state/fresh-session.request" "a remote mate is not covered"
  pass "T5 no request for the kill switch, a main home, or a remote route"
}

# --- T7: a corr with no record does not defer; a failed relaunch is logged ----
test_no_record_corr_and_failed_relaunch() {
  local dir out
  dir=$(new_case norec)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  mate_report "$dir" sm1 "done" "abcdef0123456789" "closed a fire-and-forget request"
  out=$(sweep "$dir")
  assert_contains "$out" "restarted sm1" "a corr with no pending-reply record must not defer"$'\n'"$out"

  # A relaunch that cannot start leaves a trace the parent can read.
  mkdir -p "$dir/home/state/sm1.inbox/handled"
  mv "$dir/home/state/sm1.inbox/"*.msg "$dir/home/state/sm1.inbox/handled/" 2>/dev/null || true
  set_agent_state "$dir" sm1 idle
  mate_report "$dir" sm1 "done" "abcdef0123456789" "second"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/fakebin/tmux"
  out=$(sweep "$dir")
  assert_present "$dir/sm1-home/state/fresh-session.request.failed" "a failed relaunch must keep its marker as .failed"$'\n'"$out"
  assert_present "$dir/home/state/fresh-session.log" "a failed relaunch must leave a line in the parent log"$'\n'"$out"
  pass "T7 a corr with no record restarts, and a failed relaunch is logged"
}

# --- T6: the watcher's own poll applies the request -----------------------
test_watcher_poll_applies_request() {
  local dir corr pid i=0 out
  dir=$(new_case watcher)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  corr=$(open_request "$dir" sm1)
  mate_report "$dir" sm1 "done" "$corr" "audit clean"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2>&1 &
  pid=$!
  while [ "$i" -lt 300 ] && [ -e "$dir/sm1-home/state/fresh-session.request" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  sleep 1
  out=$(cat "$dir/watch.out")
  assert_absent "$dir/sm1-home/state/fresh-session.request" "the watcher poll never applied the request"$'\n'"$out"
  assert_stopped "$dir" "the watcher poll did not relaunch the mate"
  assert_present "$dir/home/state/sm1.inbox" "the fresh session pointer was not delivered"
  pass "T6 the watcher poll restarts a mate that finished its work"
}

test_report_done_restarts_with_handover_note
test_mid_request_is_not_restarted
test_unread_work_and_busy_agent_defer
test_child_landed_requests
test_no_record_corr_and_failed_relaunch
test_no_request_where_not_applicable
test_watcher_poll_applies_request

echo "# all fm-secondmate-fresh-session tests passed"
