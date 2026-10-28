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
#   4. A child whose work landed (merged PR) asks for
#      the same fresh session; a child's PR-ready line, a pure acknowledgement
#      without --item, a main home, a remote route, and
#      FM_SECONDMATE_FRESH_SESSION=off ask for nothing.
#   5. A corr with no pending-reply record does not defer forever, and a failed
#      relaunch leaves fm-control's error in state/fresh-session.log; one that
#      Claude's background-work exit dialog blocked closes that dialog.
#   7. A mate whose Claude transcript passes FM_SECONDMATE_CONTEXT_LIMIT is
#      restarted under the same guards, with no finished work; a small context,
#      a disabled limit, and a transcript older than the last restart are not.
#   6. The real ledger pass reports a child's done line (its PR-ready report)
#      and asks for nothing; a merged PR or a local-only fast-forward
#      (bin/fm-merge-local.sh) asks for one, once per landing.
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
          if [ -f "$D/background-work" ]; then
            # Claude keeps running and asks what to do with its background task.
            cp "$D/background-work" "$D/pane"
          else
            printf 'zsh' > "$D/command.$target"
          fi
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
              # The mate reads the request, which moves it to handled/.
              for m in "$inbox"/*.msg; do
                [ -f "$m" ] && grep -q "$corr" "$m" || continue
                mkdir -p "$inbox/handled"
                mv "$m" "$inbox/handled/"
              done
            fi
          fi
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      # Esc picks "Stay" in Claude's exit dialog.
      [ "$payload" != Escape ] || [ ! -f "$D/background-work" ] || rm -f "$D/pane"
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
  capture-pane)
    if [ -f "$D/pane" ]; then cat "$D/pane"; else printf '╭────╮\n│    │\n╰────╯\n'; fi
    exit 0 ;;
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
  arm_answer "$dir" "$id"
}

# arm_answer / disarm_answer <case-dir> [id]: whether the modelled mate answers
# the persist-first request the moment it is rung. A mate answers by default.
arm_answer() {
  printf '%s' "$1/home/state/$2.inbox" > "$1/fake/answer-inbox"
  printf '%s' "$1/home/state/$2.status" > "$1/fake/answer-status"
}
disarm_answer() {
  rm -f "$1/fake/answer-inbox" "$1/fake/answer-status"
}

# persist_requests <case-dir> <id>: how many persist-first requests the mate was sent.
persist_requests() {
  grep -l 'persist the open work you are holding' "$1/home/state/$2.inbox"/*.msg "$1/home/state/$2.inbox"/handled/*.msg 2>/dev/null | wc -l | tr -d ' '
}

# answer_persist <case-dir> <id>: the mate's correlated answer, written late.
answer_persist() {
  local corr
  corr=$(grep -ho 'corr=[0-9a-f]\{16\}' "$1/home/state/$2.inbox"/*.msg "$1/home/state/$2.inbox"/handled/*.msg 2>/dev/null | head -1)
  [ -n "$corr" ] || fail "no persist request carrying a correlation token was sent"
  printf 'done [%s]: open records written down\n' "$corr" >> "$1/home/state/$2.status"
}


# The harness exit command is a whole line of the pane transcript; assert_grep is
# a substring match, so these read the line exactly.
assert_stopped() {  # <case-dir> <msg>
  grep -qx '/exit' "$1/fake/literal" || fail "$2"
}
assert_not_stopped() {  # <case-dir> <msg>
  ! grep -qx '/exit' "$1/fake/literal" || fail "$2"
}

# bind_mate <case-dir> <id>: the parent binding a seeded home carries. Like a
# real second mate it has no semantic busy-state record; the parent reads its
# pane.
bind_mate() {
  local dir=$1 id=$2 smhome
  smhome="$dir/$id-home"
  cat > "$smhome/.fm-secondmate-parent" <<EOT
schema=fm-secondmate-parent.v1
route=local
parent_home=$dir/home
EOT
}

# set_agent_state <case-dir> <idle|busy>: what the mate's pane shows.
set_agent_state() {
  case "$2" in
    busy) printf '✻ Working… (3s · esc to interrupt)\n' > "$1/fake/pane" ;;
    *) rm -f "$1/fake/pane" ;;
  esac
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

sweep() {  # <case-dir> [reply-grace-secs]
  local dir=$1
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_PENDING_REPLY_GRACE_SECS="${2:-0}" \
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
  set_agent_state "$dir" busy
  out=$(sweep "$dir")
  assert_contains "$out" "not provably idle (busy)" "a busy agent must defer"
  assert_not_stopped "$dir" "a busy agent was stopped"

  # An idle-looking pane right after the report may still be mid-turn.
  set_agent_state "$dir" idle
  out=$(sweep "$dir" 9999)
  assert_contains "$out" "grace window" "an idle pane inside the grace window must defer"
  assert_not_stopped "$dir" "a mate inside the grace window was stopped"

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
  local dir out log
  dir=$(new_case norec)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  mate_report "$dir" sm1 "done" "abcdef0123456789" "closed a fire-and-forget request"
  out=$(sweep "$dir")
  assert_contains "$out" "restarted sm1" "a corr with no pending-reply record must not defer"$'\n'"$out"

  # A relaunch that cannot start leaves a trace the parent can read.
  mkdir -p "$dir/home/state/sm1.inbox/handled"
  mv "$dir/home/state/sm1.inbox/"*.msg "$dir/home/state/sm1.inbox/handled/" 2>/dev/null || true
  set_agent_state "$dir" idle
  mate_report "$dir" sm1 "done" "abcdef0123456789" "second"
  # The persist request still goes through and is answered, but every session
  # command that would stop the agent fails.
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux.real"
  # shellcheck disable=SC2016 # the variables expand when the fake tmux runs.
  printf '#!/usr/bin/env bash\ncase "$*" in *"/exit"*) exit 1 ;; esac\nexec "$(dirname "$0")/tmux.real" "$@"\n' > "$dir/fakebin/tmux"
  chmod +x "$dir/fakebin/tmux"
  if out=$(sweep "$dir"); then
    fail "a failed relaunch must make the sweep exit non-zero"$'\n'"$out"
  fi
  assert_present "$dir/sm1-home/state/fresh-session.request.failed" "a failed relaunch must keep its marker as .failed"$'\n'"$out"
  log=$(cat "$dir/home/state/fresh-session.log")
  assert_contains "$log" "$(printf '%s\n' "$out" | grep '^failed sm1: .')" "the parent log must carry fm-control's error"$'\n'"$out"
  pass "T7 a corr with no record restarts, and a failed relaunch is logged"
}

# --- T9: a failed relaunch does not leave Claude's exit dialog open ----------
test_background_work_dialog_is_dismissed() {
  local dir out
  dir=$(new_case bgwork)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  printf '%s\n' '   Background work is running' \
    '   The following will stop when you exit:' '' '   shell · sleep 45' '' \
    '   ❯ 1. Exit and stop tasks' '     2. Move to background and exit' '     3. Stay' '' \
    '   Enter to confirm · Esc to cancel' > "$dir/fake/background-work"
  mate_report "$dir" sm1 "done" "abcdef0123456789" "finished while a background task runs"
  if out=$(sweep "$dir"); then
    fail "a relaunch the dialog blocked must make the sweep exit non-zero"$'\n'"$out"
  fi
  assert_present "$dir/sm1-home/state/fresh-session.request.failed" "a blocked relaunch must keep its marker as .failed"$'\n'"$out"
  grep -qx Escape "$dir/fake/keys" || fail "the sweep must close the exit dialog with Escape"$'\n'"$out"
  assert_absent "$dir/fake/pane" "the mate was left in Claude's exit dialog"$'\n'"$out"
  pass "T9 a relaunch blocked by background work leaves the mate usable"
}

# add_done_child <case-dir> <child-id>: a ship child in sm1's home whose ledger ends in done.
add_done_child() {
  local dir=$1 cid=$2 st="$1/sm1-home/state"
  mkdir -p "$dir/sm1-home/projects/$cid"
  git -C "$dir/sm1-home/projects/$cid" init -q
  git -C "$dir/sm1-home/projects/$cid" commit -q --allow-empty -m init
  printf 'window=fmses:fm-%s\nworktree=%s\nproject=%s\nharness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\n' \
    "$cid" "$dir/sm1-home/projects/$cid" "$dir/sm1-home/projects/$cid" > "$st/$cid.meta"
  printf 'done: %s handed to no-mistakes\n' "$cid" > "$st/$cid.status"
}

ledger_scan() {  # <case-dir>
  FM_HOME="$1/sm1-home" "$ROOT/bin/fm-inactive-reconcile.sh" scan >/dev/null 2>&1 || true
}

# --- T8: a done ledger line asks for nothing; each landing asks once ---------
test_each_landing_requests_once() {
  local dir out proj
  dir=$(new_case landing)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1

  add_done_child "$dir" child1
  ledger_scan "$dir"
  grep -q 'child child1 done' "$dir/home/state/sm1.status" || fail "the ledger pass did not report child1"
  assert_absent "$dir/sm1-home/state/fresh-session.request" "a child's done ledger line is PR-ready, not a landing"

  FM_HOME="$dir/sm1-home" bash -c '. "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$2" "$2/state" child1 https://github.com/o/r/pull/7 self attended' \
    _ "$ROOT" "$dir/sm1-home" || true
  assert_present "$dir/sm1-home/state/fresh-session.request" "a merged child PR must request a fresh session"
  assert_contains "$(cat "$dir/sm1-home/data/fresh-session-handover.md")" "pull/7" "the note must name the landed PR"
  out=$(sweep "$dir")
  assert_contains "$out" "restarted sm1" "the merged child must restart the mate"$'\n'"$out"

  FM_HOME="$dir/sm1-home" bash -c '. "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$2" "$2/state" child1 https://github.com/o/r/pull/7 poll attended' \
    _ "$ROOT" "$dir/sm1-home" || true
  assert_absent "$dir/sm1-home/state/fresh-session.request" "the poll seeing the same merged PR must not request a second restart"
  FM_HOME="$dir/sm1-home" bash -c '. "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$2" "$2/state" child1 https://github.com/o/r/pull/8 self attended' \
    _ "$ROOT" "$dir/sm1-home" || true
  assert_present "$dir/sm1-home/state/fresh-session.request" "a later landing for the same child must request a fresh session"
  rm -f "$dir/sm1-home/state/fresh-session.request"

  proj="$dir/sm1-home/projects/child3"
  mkdir -p "$proj"
  git -C "$proj" init -q -b main
  git -C "$proj" commit -q --allow-empty -m init
  git -C "$proj" checkout -q -b fm/child3
  git -C "$proj" commit -q --allow-empty -m slice
  git -C "$proj" checkout -q main
  printf 'window=fmses:fm-child3\nworktree=%s\nproject=%s\nharness=codex\nkind=ship\nmode=local-only\nyolo=off\n' \
    "$proj" "$proj" > "$dir/sm1-home/state/child3.meta"
  FM_HOME="$dir/sm1-home" "$ROOT/bin/fm-merge-local.sh" child3 >/dev/null 2>&1 || fail "the local-only merge refused"
  assert_present "$dir/sm1-home/state/fresh-session.request" "a local-only landing must request a fresh session"
  pass "T8 a done ledger line asks for nothing; a merged PR or local-only landing each request a fresh session once per landing"
}

# --- T9: a context past the limit restarts the mate ------------------------
# write_transcript <case-dir> <id> <cache-read-tokens>: a Claude transcript for
# the mate's home, in the layout the sweep reads.
write_transcript() {
  local dir=$1 id=$2 tokens=$3 enc tdir
  enc=$(printf '%s' "$dir/$id-home" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
  tdir="$dir/projects/$enc"
  mkdir -p "$tdir"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":%s,"output_tokens":9}}}\n' "$tokens" >> "$tdir/s1.jsonl"
}

csweep() {  # <case-dir> [limit]
  local dir=$1
  env FM_CLAUDE_PROJECTS_DIR="$dir/projects" FM_SECONDMATE_CONTEXT_LIMIT="${2:-100000}" FM_SECONDMATE_CONTEXT_CHECK_SECS=0 \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_PENDING_REPLY_GRACE_SECS=0 FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
    FM_CONTROL_LAUNCH_WAIT=0.05 "$FRESH" sweep 2>&1
}

test_context_limit_restarts_mate() {
  local dir out note
  dir=$(new_case ctx)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  printf 'working [at=1]: slice 2 under way\n' > "$dir/sm1-home/state/child1.status"
  printf 'kind=ship\n' > "$dir/sm1-home/state/child1.meta"

  write_transcript "$dir" sm1 40000
  out=$(csweep "$dir")
  assert_absent "$dir/sm1-home/state/fresh-session.request" "a small context must not ask for a restart"
  assert_not_stopped "$dir" "a small context must not stop the agent"

  write_transcript "$dir" sm1 250000
  out=$(csweep "$dir" 0)
  assert_absent "$dir/sm1-home/state/fresh-session.request" "a limit of 0 turns the check off"

  # An unread steering message defers the restart; the request waits.
  mkdir -p "$dir/home/state/sm1.inbox"
  printf 'do the next thing\n' > "$dir/home/state/sm1.inbox/001.msg"
  out=$(csweep "$dir")
  assert_present "$dir/sm1-home/state/fresh-session.request" "a large context must file a request"
  assert_contains "$out" "deferred sm1" "an unread message must defer the context restart"$'\n'"$out"
  assert_not_stopped "$dir" "a deferred restart must not stop the agent"
  assert_present "$dir/home/state/sm1.inbox/001.msg" "the unread message must survive"

  rm -f "$dir/home/state/sm1.inbox/001.msg"
  out=$(csweep "$dir")
  assert_contains "$out" "restarted sm1" "the idle mate must be restarted once nothing is open"$'\n'"$out"
  assert_stopped "$dir" "the old agent must be stopped"
  note=$(cat "$dir/sm1-home/data/fresh-session-handover.md")
  assert_contains "$note" "context was 250105 tokens" "the note must say why the mate restarted"
  assert_contains "$note" "child1: working" "the note must list the child still in flight"
  assert_contains "$note" "open captain decisions" "the note must point at the open decisions"
  if grep -rq "finished piece of work" "$dir/home/state/sm1.inbox" 2>/dev/null; then
    fail "a context restart must not tell the mate it finished work"
  fi

  # The old transcript is older than the restart, so it asks for nothing again.
  sleep 1
  : > "$dir/fake/literal"
  out=$(csweep "$dir")
  assert_absent "$dir/sm1-home/state/fresh-session.request" "the old session's transcript must not request a second restart"
  pass "T9 a context past the limit restarts the mate under the same guards"
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
    FM_PENDING_REPLY_GRACE_SECS=0 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
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

# --- T10: persist first, on both triggers -------------------------------------
# persist_first_flow <case-dir>: the mate holds a restart marker, answers nothing
# at first. Asserts the request goes out before any relaunch, a repeat sweep sends
# no second one, a timeout keeps the marker and the mate, and the answer releases it.
persist_first_flow() {
  local dir=$1 out
  disarm_answer "$dir"
  out=$(FM_SECONDMATE_PERSIST_WAIT=0 sweep "$dir")
  assert_contains "$out" "deferred sm1" "the first pass must ask, not restart"$'\n'"$out"
  assert_not_stopped "$dir" "the mate was restarted before it answered"
  assert_present "$dir/sm1-home/state/fresh-session.request" "the marker must stay while the mate has not answered"
  [ "$(persist_requests "$dir" sm1)" = 1 ] || fail "exactly one persist request must be sent"

  out=$(FM_SECONDMATE_PERSIST_WAIT=0 sweep "$dir")
  assert_contains "$out" "did not confirm within 0s" "an unanswered request must report its timeout"$'\n'"$out"
  assert_not_stopped "$dir" "a mate that did not answer in time was restarted"
  assert_present "$dir/sm1-home/state/fresh-session.request" "a timeout must keep the marker for a later sweep"
  [ "$(persist_requests "$dir" sm1)" = 1 ] || fail "a repeated sweep must not send a second persist request"

  out=$(sweep "$dir")
  assert_not_stopped "$dir" "a mate still waiting must not be restarted"
  [ "$(persist_requests "$dir" sm1)" = 1 ] || fail "a sweep while waiting must not send a second persist request"

  answer_persist "$dir" sm1
  mkdir -p "$dir/home/state/sm1.inbox/handled"
  mv "$dir/home/state/sm1.inbox"/*.msg "$dir/home/state/sm1.inbox/handled/" 2>/dev/null || true
  out=$(sweep "$dir")
  assert_contains "$out" "restarted sm1" "the correlated answer must release the restart"$'\n'"$out"
  assert_stopped "$dir" "the answer must lead to the relaunch"
  assert_absent "$dir/sm1-home/state/fresh-session.request" "the marker must be consumed after the restart"
  assert_absent "$dir/home/state/sm1.fresh-session-persist" "the persist record must be cleared"
  [ "$(persist_requests "$dir" sm1)" = 1 ] || fail "the restart must not send another persist request"
}

test_finished_work_persists_first() {
  local dir corr
  dir=$(new_case persist-done)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  corr=$(open_request "$dir" sm1)
  mate_report "$dir" sm1 "done" "$corr" "audit clean"
  persist_first_flow "$dir"
  pass "T10a finished-work restart persists open work first, waits for the answer, and never double-asks"
}

test_context_limit_persists_first() {
  local dir
  dir=$(new_case persist-ctx)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  disarm_answer "$dir"
  write_transcript "$dir" sm1 250000
  FM_SECONDMATE_PERSIST_WAIT=0 csweep "$dir" >/dev/null
  assert_present "$dir/sm1-home/state/fresh-session.request" "a large context must file a request"
  assert_not_stopped "$dir" "the context sweep restarted the mate before it answered"
  [ "$(persist_requests "$dir" sm1)" = 1 ] || fail "the context sweep must send the persist request"
  persist_first_flow "$dir"
  pass "T10b context-limit restart persists open work first, waits for the answer, and never double-asks"
}

test_answering_mate_restarts_after_request() {
  local dir out req_line stop_line corr
  dir=$(new_case persist-order)
  add_local_mate "$dir" sm1
  bind_mate "$dir" sm1
  corr=$(open_request "$dir" sm1)
  mate_report "$dir" sm1 "done" "$corr" "audit clean"
  out=$(sweep "$dir")
  assert_contains "$out" "restarted sm1" "a mate that answers at once must restart in the same pass"$'\n'"$out"
  [ "$(persist_requests "$dir" sm1)" = 1 ] || fail "the persist request must go out before the relaunch"
  req_line=$(grep -n 'persist the open work' "$dir/fake/literal" | head -1 | cut -d: -f1)
  stop_line=$(grep -nx '/exit' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$stop_line" ] || fail "the mate was never relaunched"
  pass "T10c an answering mate is asked once, then relaunched"
}

test_report_done_restarts_with_handover_note
test_context_limit_restarts_mate
test_mid_request_is_not_restarted
test_unread_work_and_busy_agent_defer
test_child_landed_requests
test_no_record_corr_and_failed_relaunch
test_no_request_where_not_applicable
test_each_landing_requests_once
test_watcher_poll_applies_request
test_background_work_dialog_is_dismissed
test_finished_work_persists_first
test_context_limit_persists_first
test_answering_mate_restarts_after_request

echo "# all fm-secondmate-fresh-session tests passed"
