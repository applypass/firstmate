#!/usr/bin/env bash
# shellcheck disable=SC2016
# Fork-only (applypass): behavior tests for the one-task-per-second-mate guard.
#
# bin/fm-new-task-guard.sh owns the refusal. fm-send.sh --new-task and the main
# session's PreToolUse hook both call it. These tests run the real guard and the
# real bin/fm-tasks-axi.sh against scratch homes; only `tasks-axi` is a stub that
# reads the home's markdown backlog, so no real backlog is touched. Ids are
# neutral fixtures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-new-task-guard)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
GUARD="$ROOT/bin/fm-new-task-guard.sh"
SEND="$ROOT/bin/fm-send.sh"

# A stub tasks-axi: `list --state in_flight` over $TASKS_AXI_FILE (the markdown
# backlog fm-tasks-axi.sh pins). A missing file exits 1, like an unreadable home.
make_tasks_stub() { # <fakebin>
  cat > "$1/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ -f "${TASKS_AXI_FILE:-}" ] || { echo "no backlog: ${TASKS_AXI_FILE:-unset}" >&2; exit 1; }
[ "${1:-}" = list ] || exit 0
rows=$(awk '/^## /{s=($0=="## In flight")} s && /^- \[ \] /{print}' "$TASKS_AXI_FILE")
n=0; [ -z "$rows" ] || n=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
printf 'count: %s\ntasks[%s]{id,state,kind,repo,title}:\n' "$n" "$n"
printf '%s\n' "$rows" | sed -n 's/^- \[ \] \([^ ]*\) - \(.*\)$/  \1,in_flight,ship,r,"\2"/p'
SH
  chmod +x "$1/tasks-axi"
}

# new_world <name> -> sets W (main home), FB (fakebin). Main home is a plain git
# checkout with AGENTS.md so the hook scope treats it as the primary.
new_world() {
  W="$TMP_ROOT/$1"; mkdir -p "$W/data" "$W/config" "$W/state" "$W/bin"
  git init -q "$W"; git -C "$W" commit -q --allow-empty -m init
  : > "$W/AGENTS.md"
  FB=$(fm_fakebin "$W/fb"); make_tasks_stub "$FB"
  printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$W/data/backlog.md"
  : > "$W/data/secondmates.md"
}

# add_mate <id> <inflight-count>: registers the mate and writes its home backlog.
add_mate() {
  local id=$1 n=$2 h="$W/mates/$1" i
  mkdir -p "$h/data" "$h/state"
  { printf '# Backlog\n\n## In flight\n'
    for ((i = 1; i <= n; i++)); do printf -- '- [ ] %s-item%s - work (repo: r)\n' "$id" "$i"; done
    printf '## Queued\n## Done\n'; } > "$h/data/backlog.md"
  printf '%s\n' "$id" > "$h/.fm-secondmate-home"
  printf -- '- %s - fixture mate (home: %s; scope: fixture; projects: none; added 2026-11-09)\n' "$id" "$h" >> "$W/data/secondmates.md"
}

main_inflight() { # <n>: main's own in-flight items
  local i
  { printf '# Backlog\n\n## In flight\n'
    for ((i = 1; i <= $1; i++)); do printf -- '- [ ] main-item%s - work (repo: r)\n' "$i"; done
    printf '## Queued\n## Done\n'; } > "$W/data/backlog.md"
}

run_guard() { # <args...> -> OUT, RC
  OUT=$(env PATH="$FB:$PATH" FM_HOME="$W" FM_ROOT_OVERRIDE="$W" "$GUARD" "$@" 2>&1); RC=$?
}

test_new_task_refuses_busy_mate() {
  new_world busy; add_mate mate-a 1
  run_guard check mate-a
  expect_code 1 "$RC" "busy mate must refuse --new-task"
  case "$OUT" in *"mate-a"*"fm-brief.sh"*"fm-home-seed.sh"*"fm-spawn.sh"*"--secondmate"*) : ;; *) fail "refusal must print the per-task-mate commands: $OUT" ;; esac
  pass "guard: --new-task to a mate with an In flight item refuses and prints the remedy"
}

test_new_task_sends_to_idle_mate() {
  new_world idle; add_mate mate-a 0
  run_guard check mate-a
  expect_code 0 "$RC" "idle mate must accept --new-task: $OUT"
  pass "guard: --new-task to a mate with no In flight item passes"
}

test_worker_target_out_of_scope() {
  new_world worker; add_mate mate-a 1
  run_guard check ordinary-worker
  expect_code 0 "$RC" "a non-secondmate target is out of scope: $OUT"
  pass "guard: an ordinary worker target is never refused"
}

test_unreadable_backlog_refuses() {
  new_world unread; add_mate mate-a 0; rm -f "$W/mates/mate-a/data/backlog.md"
  run_guard check mate-a
  expect_code 1 "$RC" "unreadable mate backlog must refuse"
  case "$OUT" in *"mate-a"*"backlog"*) : ;; *) fail "refusal must name what could not be read: $OUT" ;; esac
  pass "guard: an unreadable mate backlog refuses and names it"
}

test_unreadable_other_mate_counts_as_active() {
  new_world unreadother; add_mate mate-a 0; add_mate mate-gone 0
  rm -rf "$W/mates/mate-gone"
  run_guard check mate-a
  expect_code 0 "$RC" "an unreadable other mate below the cap must not refuse: $OUT"
  case "$OUT" in *"mate-gone"*"unreadable - counted as active"*) : ;; *) fail "the note must name the unreadable mate: $OUT" ;; esac
  new_world unreadcap; local i
  for i in 1 2 3 4 5 6; do add_mate "mate-$i" 1; done
  add_mate mate-gone 0; rm -rf "$W/mates/mate-gone"
  add_mate mate-idle 0; main_inflight 1
  run_guard check mate-idle
  expect_code 1 "$RC" "an unreadable mate must count toward the cap: $OUT"
  case "$OUT" in *"refused"*"mate-gone"*"unreadable - counted as active"*) : ;; *) fail "the cap refusal must list the unreadable mate as active: $OUT" ;; esac
  pass "guard: another mate's unreadable backlog counts as active and is named, not refused"
}

test_fleet_cap_refuses_and_names_entries() {
  new_world cap; local i
  for i in 1 2 3 4 5 6 7; do add_mate "mate-$i" 1; done
  add_mate mate-idle 0
  main_inflight 1
  run_guard check mate-idle
  expect_code 1 "$RC" "8 active entries must refuse even for an idle target"
  case "$OUT" in *"mate-1"*"in flight"*) : ;; *) fail "cap refusal must list counted entries with state: $OUT" ;; esac
  case "$OUT" in *"main-item1"*) : ;; *) fail "cap refusal must list main's own in-flight work: $OUT" ;; esac
  case "$OUT" in *"mate-idle"*"idle - retire first"*) : ;; *) fail "cap refusal must flag the idle mate: $OUT" ;; esac
  pass "guard: at the fleet cap --new-task refuses and names busy and idle entries"
}

test_below_cap_passes_and_cap_is_configurable() {
  new_world below; local i
  for i in 1 2 3 4 5 6; do add_mate "mate-$i" 1; done
  add_mate mate-idle 0; main_inflight 1
  run_guard check mate-idle
  expect_code 0 "$RC" "7 active entries is below the default cap: $OUT"
  printf '7\n' > "$W/config/fleet-wip-cap"
  run_guard check mate-idle
  expect_code 1 "$RC" "a configured cap of 7 must refuse at 7 active: $OUT"
  pass "guard: below the cap passes and the cap is read from config/fleet-wip-cap"
}

hook_payload() { # <command>
  jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
}

run_hook() { # <command> [root]
  OUT=$(hook_payload "$1" | env PATH="$FB:$PATH" FM_HOME="$W" FM_ROOT_OVERRIDE="${2:-$W}" "$GUARD" hook --claude 2>&1); RC=$?
}

test_hook_refuses_captain_text_to_busy_mate() {
  new_world hook; add_mate mate-a 1
  run_hook 'bin/fm-send.sh mate-a "From firstmate (captain said): please do X"'
  expect_code 2 "$RC" "captain-prefixed main send to a busy mate must be denied"
  case "$OUT" in *"fm-spawn.sh"*) : ;; *) fail "hook denial must carry the remedy: $OUT" ;; esac
  run_hook 'bin/fm-send.sh mate-a --same-task "From firstmate (captain said): please do X"'
  expect_code 0 "$RC" "--same-task must pass the hook: $OUT"
  run_hook 'bin/fm-send.sh mate-a "ordinary steer"'
  expect_code 0 "$RC" "text without the captain prefix must pass the hook: $OUT"
  new_world hook2; add_mate mate-a 0
  run_hook 'bin/fm-send.sh mate-a "From firstmate (captain said): please do X"'
  expect_code 0 "$RC" "an idle mate must pass the hook: $OUT"
  pass "hook: refuses a captain-prefixed send to a busy mate unless --same-task"
}

test_hook_inert_in_secondmate_home() {
  new_world hookmate; add_mate mate-a 1
  printf 'mate-self\n' > "$W/.fm-secondmate-home"
  run_hook 'bin/fm-send.sh mate-a "From firstmate (captain said): please do X"'
  expect_code 0 "$RC" "the hook must be inert in a secondmate home: $OUT"
  pass "hook: inert in a secondmate home"
}

# Fresh context for an idle mate: --new-task to an idle local mate holds the text,
# and the watcher's fresh-session sweep saves and restarts the mate before the
# text reaches its inbox. FM_FRESH_CONTEXT_CREW_STATE stands in for the crew-state
# read, so a test picks the state the guard sees.
make_crew_state_stub() { # <world> <crew-state>
  cat > "$1/crew-state-stub" <<SH
#!/usr/bin/env bash
echo "state: $2 · source: status-log · fixture"
SH
  chmod +x "$1/crew-state-stub"
}

# fm-send integration: a refused --new-task enqueues nothing.
make_send_stubs() { # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done; printf 'fakepane\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf '%s\n' fm-mate-a ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/sleep"
  chmod +x "$1/tmux" "$1/sleep"
}

test_installer_registers_hook_once() {
  new_world install
  "$ROOT/bin/fm-op-guard-install.sh" "$W" >/dev/null 2>&1 || fail "installer failed"
  "$ROOT/bin/fm-op-guard-install.sh" "$W" >/dev/null 2>&1 || fail "installer rerun failed"
  [ "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(contains("fm-new-task-guard.sh"))] | length' "$W/.claude/settings.local.json")" = 1 ] \
    || fail "the hook must be registered exactly once"
  pass "installer: registers the new-task hook once, idempotently"
}

test_send_new_task_refusal_enqueues_nothing() {
  new_world send; add_mate mate-a 1; make_send_stubs "$FB"
  fm_write_secondmate_meta "$W/state/mate-a.meta" "$W/mates/mate-a" "sess:fm-mate-a"
  OUT=$(env PATH="$FB:$PATH" FM_HOME="$W" FM_ROOT_OVERRIDE="$W" FM_SEND_SETTLE=0 "$SEND" mate-a --new-task "do new thing" 2>&1); RC=$?
  expect_code 1 "$RC" "fm-send --new-task to a busy mate must refuse: $OUT"
  [ ! -e "$W/state/mate-a.inbox/001.msg" ] || fail "a refused send must enqueue nothing"
  OUT=$(env PATH="$FB:$PATH" FM_HOME="$W" FM_ROOT_OVERRIDE="$W" FM_SEND_SETTLE=0 "$SEND" mate-a --same-task "keep going" 2>&1); RC=$?
  expect_code 0 "$RC" "fm-send --same-task must send: $OUT"
  [ -e "$W/state/mate-a.inbox/001.msg" ] || fail "--same-task must enqueue"
  new_world send2; add_mate mate-a 0; make_send_stubs "$FB"
  fm_write_secondmate_meta "$W/state/mate-a.meta" "$W/mates/mate-a" "sess:fm-mate-a"
  make_crew_state_stub "$W" working
  OUT=$(env PATH="$FB:$PATH" FM_HOME="$W" FM_ROOT_OVERRIDE="$W" FM_SEND_SETTLE=0 \
    FM_FRESH_CONTEXT_CREW_STATE="$W/crew-state-stub" "$SEND" mate-a --new-task "do new thing" 2>&1); RC=$?
  expect_code 0 "$RC" "fm-send --new-task to an idle mate must send: $OUT"
  [ -e "$W/state/mate-a.inbox/001.msg" ] || fail "idle --new-task must enqueue"
  pass "fm-send: --new-task refuses a busy mate with nothing enqueued, sends to an idle one"
}

# A tmux stub that models the mate's agent for the real fm-control relaunch: /exit
# stops it (and logs whether the new work had reached the inbox by then), the
# launch line brings back what $D/becomes names, and when $D/answer exists every
# doorbell makes the mate answer the save request on its parent channel.
make_mate_stubs() { # <fakebin> <world>
  local D="$2/fake"
  mkdir -p "$D"
  printf 'claude' > "$D/command"
  printf 'claude' > "$D/becomes"
  printf '%s' "$H" > "$D/cwd"
  : > "$D/literal"
  cat > "$1/tmux" <<SH
#!/usr/bin/env bash
D=$(printf '%q' "$D")
INBOX=$(printf '%q' "$2/state/mate-a.inbox")
STATUS=$(printf '%q' "$2/state/mate-a.status")
SH
  cat >> "$1/tmux" <<'SH'
case "${1:-}" in
  send-keys)
    shift; literal=0; target=
    while [ $# -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; -l) literal=1; shift ;; *) break ;; esac
    done
    payload=${1:-}
    [ "$literal" = 1 ] || exit 0
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    printf '%s\n' "$payload" >> "$D/literal"
    case "$payload" in
      /exit|/quit)
        printf 'exit new-work-in-inbox=%s\n' "$(grep -rl 'do new thing' "$INBOX" 2>/dev/null | grep -c .)" >> "$D/events"
        printf 'zsh' > "$D/command.$target" ;;
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) cat "$D/becomes" > "$D/command.$target" ;;
      ': Firstmate instruction waiting: list '*)
        [ -f "$D/answer" ] || exit 0
        for m in "$INBOX"/*.msg; do
          [ -f "$m" ] && grep -q 'I am about to restart your agent' "$m" || continue
          corr=$(grep -oE 'corr=[0-9a-f]{16}' "$m" | head -1)
          printf 'done [%s]: open records written down\n' "$corr" >> "$STATUS"
          mkdir -p "$INBOX/handled"; mv "$m" "$INBOX/handled/"
        done ;;
    esac ;;
  display-message)
    target=; prev=
    for a in "$@"; do
      [ "$prev" != -t ] || target=$a
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) if [ -f "$D/command.$target" ]; then cat "$D/command.$target"; else cat "$D/command"; fi; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
      prev=$a
    done
    printf 'fakepane\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) [ -f "$D/no-window" ] || printf '%s\n' fm-mate-a ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/sleep"
  chmod +x "$1/tmux" "$1/sleep"
}

# mate_world <name> <crew-state|real>: a parent home with one idle local Claude
# mate (a git worktree home bound to this parent) that the real fm-control can
# relaunch. "real" leaves the crew-state read to bin/fm-crew-state.sh.
mate_world() {
  new_world "$1"
  local h="$TMP_ROOT/$1-mate-a"
  H=$h
  fm_git_worktree "$TMP_ROOT/$1-mate-a-repo" "$h" sm-mate-a
  mkdir -p "$h/bin" "$h/data" "$h/state" "$W/data/mate-a"
  printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$h/data/backlog.md"
  printf 'mate-a\n' > "$h/.fm-secondmate-home"
  printf -- '- mate-a - fixture mate (home: %s; scope: fixture; projects: none; added 2026-11-09)\n' "$h" >> "$W/data/secondmates.md"
  printf '# agents\n' > "$h/AGENTS.md"
  printf '# charter\n' > "$W/data/mate-a/brief.md"
  printf 'claude\n' > "$W/config/secondmate-harness"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$W" > "$h/.fm-secondmate-parent"
  fm_write_secondmate_meta "$W/state/mate-a.meta" "$h" "fmses:fm-mate-a" alpha claude
  printf 'model=default\neffort=default\n' >> "$W/state/mate-a.meta"
  make_mate_stubs "$FB" "$W"
  CREW=
  if [ "$2" != real ]; then make_crew_state_stub "$W" "$2"; CREW="$W/crew-state-stub"; fi
}

# The save answer may take FM_SECONDMATE_PERSIST_WAIT; a send that waited for it
# would take ten minutes here.
mate_send() { # <flag> -> OUT, RC, TOOK (seconds)
  local t0=$SECONDS
  OUT=$(env PATH="$FB:$PATH" FM_HOME="$W" FM_ROOT_OVERRIDE="$W" FM_SEND_SETTLE=0 \
    FM_SECONDMATE_PERSIST_WAIT=600 ${CREW:+FM_FRESH_CONTEXT_CREW_STATE="$CREW"} \
    "$SEND" mate-a "$1" "do new thing" 2>&1 </dev/null); RC=$?
  TOOK=$((SECONDS - t0))
}

watcher_step() { # [persist-wait] -> OUT (one fresh-session sweep, as the watcher runs it)
  OUT=$(env PATH="$FB:$PATH" FM_HOME="$W" FM_SEND_SETTLE=0 \
    FM_PENDING_REPLY_GRACE_SECS=0 FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 \
    FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_SECONDMATE_PERSIST_WAIT="${1:-30}" FM_SECONDMATE_PERSIST_POLL=1 \
    "$ROOT/bin/fm-secondmate-fresh-session.sh" sweep 2>&1 </dev/null)
}

inbox_has_new_work() {
  grep -l 'do new thing' "$W/state/mate-a.inbox"/*.msg >/dev/null 2>&1
}

assert_no_update_claim() {
  ! grep -rqi 'firstmate was updated\|updatefirstmate' "$W/state/mate-a.inbox" "$W/state/pending-replies" 2>/dev/null \
    || fail "no message to the mate may claim firstmate was updated: $(grep -rli 'updated' "$W/state/mate-a.inbox" 2>&1)"
}

test_send_new_task_idle_mate_is_held_then_restarted_first() {
  mate_world fresh-idle 'done'
  mate_send --new-task
  expect_code 0 "$RC" "idle --new-task must send: $OUT"
  [ "$TOOK" -lt 60 ] || fail "the send must not wait for the save answer, took ${TOOK}s"
  ! inbox_has_new_work || fail "the new work must not reach the inbox before the fresh start"
  grep -rq 'do new thing' "$W/state/mate-a.fresh-held" || fail "the new work must be held durably: $OUT"
  grep -qx 'source=new-task' "$H/state/fresh-session.request" || fail "the fresh start must be recorded"
  [ ! -e "$W/fake/events" ] || fail "the send itself must not restart the mate"
  : > "$W/fake/answer"
  watcher_step
  case "$OUT" in *"restarted mate-a"*"released mate-a"*) : ;; *) fail "the watcher step must restart, then release: $OUT" ;; esac
  [ "$(cat "$W/fake/events")" = 'exit new-work-in-inbox=0' ] \
    || fail "the mate must restart once, before the new work reaches its inbox: $(cat "$W/fake/events")"
  inbox_has_new_work || fail "the new work must reach the inbox after the restart"
  ! grep -rq 'do new thing' "$W/state/mate-a.fresh-held" 2>/dev/null || fail "the held copy must be gone once delivered"
  [ ! -e "$H/state/fresh-session.request" ] || fail "the fresh start must be consumed"
  grep -rq 'because new work is arriving for you' "$W/state/mate-a.inbox/handled" \
    || fail "the save request must say the restart is for new work"
  assert_no_update_claim
  pass "fm-send: --new-task to an idle mate is held; the watcher restarts it, then delivers"
}

test_send_new_task_unreachable_mate_delivers_at_once() {
  mate_world fresh-unreachable real
  : > "$W/fake/no-window"
  mate_send --new-task
  expect_code 0 "$RC" "an unreachable mate still receives the message: $OUT"
  [ "$TOOK" -lt 60 ] || fail "the send must not wait for the save answer, took ${TOOK}s"
  inbox_has_new_work || fail "the message must be in the inbox at once: $OUT"
  [ ! -e "$W/state/mate-a.fresh-held" ] || fail "an unreachable mate must not get a held message"
  [ ! -e "$H/state/fresh-session.request" ] || fail "an unreachable mate must not get a fresh start"
  pass "fm-send: --new-task to an unreachable mate delivers at once with no fresh start"
}

test_send_save_answer_deadline_releases_without_restart() {
  mate_world fresh-deadline 'done'
  mate_send --new-task
  expect_code 0 "$RC" "idle --new-task must send: $OUT"
  watcher_step 1
  case "$OUT" in *"timed out mate-a"*"released mate-a"*) : ;; *) fail "a missed save answer must release the held work: $OUT" ;; esac
  [ ! -e "$W/fake/events" ] || fail "a mate that missed the save deadline must not be restarted"
  inbox_has_new_work || fail "the held work must reach the inbox"
  [ ! -e "$H/state/fresh-session.request" ] || fail "the skipped fresh start must be cleared"
  assert_no_update_claim
  pass "fm-send: a missed save deadline releases the held work with no restart"
}

test_send_relaunch_failure_releases_the_held_work() {
  mate_world fresh-fail 'done'
  printf 'zsh' > "$W/fake/becomes"
  mate_send --new-task
  expect_code 0 "$RC" "idle --new-task must send: $OUT"
  : > "$W/fake/answer"
  watcher_step
  case "$OUT" in *"failed mate-a"*"released mate-a"*) : ;; *) fail "a failed relaunch must release the held work: $OUT" ;; esac
  inbox_has_new_work || fail "the held work must reach the inbox after a failed relaunch"
  assert_no_update_claim
  pass "fm-send: a failed relaunch still delivers the held work"
}

test_send_new_task_working_mate_is_untouched() {
  local st
  for st in working parked unknown; do
    mate_world "fresh-$st" "$st"
    mate_send --new-task
    expect_code 0 "$RC" "a $st mate still receives the message: $OUT"
    inbox_has_new_work || fail "a $st mate must get the message at once"
    [ ! -e "$W/state/mate-a.fresh-held" ] || fail "a $st mate must never get a held message"
  done
  pass "fm-send: --new-task to a working, parked or unknown mate delivers at once"
}

test_send_same_task_never_holds() {
  mate_world fresh-same 'done'
  mate_send --same-task
  expect_code 0 "$RC" "--same-task must send: $OUT"
  inbox_has_new_work || fail "--same-task must deliver at once"
  [ ! -e "$W/state/mate-a.fresh-held" ] || fail "--same-task continues work and must never be held"
  pass "fm-send: --same-task never holds or restarts"
}

fm_test_run \
  test_new_task_refuses_busy_mate \
  test_new_task_sends_to_idle_mate \
  test_worker_target_out_of_scope \
  test_unreadable_backlog_refuses \
  test_unreadable_other_mate_counts_as_active \
  test_fleet_cap_refuses_and_names_entries \
  test_below_cap_passes_and_cap_is_configurable \
  test_hook_refuses_captain_text_to_busy_mate \
  test_hook_inert_in_secondmate_home \
  test_installer_registers_hook_once \
  test_send_new_task_refusal_enqueues_nothing \
  test_send_new_task_idle_mate_is_held_then_restarted_first \
  test_send_new_task_unreachable_mate_delivers_at_once \
  test_send_save_answer_deadline_releases_without_restart \
  test_send_relaunch_failure_releases_the_held_work \
  test_send_new_task_working_mate_is_untouched \
  test_send_same_task_never_holds
