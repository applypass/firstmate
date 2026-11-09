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
  run_guard check mate-a --new-task
  expect_code 1 "$RC" "busy mate must refuse --new-task"
  case "$OUT" in *"mate-a"*"fm-brief.sh"*"fm-home-seed.sh"*"fm-spawn.sh"*"--secondmate"*) : ;; *) fail "refusal must print the per-task-mate commands: $OUT" ;; esac
  pass "guard: --new-task to a mate with an In flight item refuses and prints the remedy"
}

test_new_task_sends_to_idle_mate() {
  new_world idle; add_mate mate-a 0
  run_guard check mate-a --new-task
  expect_code 0 "$RC" "idle mate must accept --new-task: $OUT"
  pass "guard: --new-task to a mate with no In flight item passes"
}

test_same_task_always_passes() {
  new_world same; add_mate mate-a 3
  run_guard check mate-a --same-task
  expect_code 0 "$RC" "--same-task must never refuse: $OUT"
  pass "guard: --same-task passes even for a busy mate"
}

test_worker_target_out_of_scope() {
  new_world worker; add_mate mate-a 1
  run_guard check ordinary-worker --new-task
  expect_code 0 "$RC" "a non-secondmate target is out of scope: $OUT"
  pass "guard: an ordinary worker target is never refused"
}

test_unreadable_backlog_refuses() {
  new_world unread; add_mate mate-a 0; rm -f "$W/mates/mate-a/data/backlog.md"
  run_guard check mate-a --new-task
  expect_code 1 "$RC" "unreadable mate backlog must refuse"
  case "$OUT" in *"mate-a"*"backlog"*) : ;; *) fail "refusal must name what could not be read: $OUT" ;; esac
  pass "guard: an unreadable mate backlog refuses and names it"
}

test_fleet_cap_refuses_and_names_entries() {
  new_world cap; local i
  for i in 1 2 3 4 5 6 7; do add_mate "mate-$i" 1; done
  add_mate mate-idle 0
  main_inflight 1
  run_guard check mate-idle --new-task
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
  run_guard check mate-idle --new-task
  expect_code 0 "$RC" "7 active entries is below the default cap: $OUT"
  printf '7\n' > "$W/config/fleet-wip-cap"
  run_guard check mate-idle --new-task
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
  OUT=$(env PATH="$FB:$PATH" FM_HOME="$W" FM_ROOT_OVERRIDE="$W" FM_SEND_SETTLE=0 "$SEND" mate-a --new-task "do new thing" 2>&1); RC=$?
  expect_code 0 "$RC" "fm-send --new-task to an idle mate must send: $OUT"
  [ -e "$W/state/mate-a.inbox/001.msg" ] || fail "idle --new-task must enqueue"
  pass "fm-send: --new-task refuses a busy mate with nothing enqueued, sends to an idle one"
}

fm_test_run \
  test_new_task_refuses_busy_mate \
  test_new_task_sends_to_idle_mate \
  test_same_task_always_passes \
  test_worker_target_out_of_scope \
  test_unreadable_backlog_refuses \
  test_fleet_cap_refuses_and_names_entries \
  test_below_cap_passes_and_cap_is_configurable \
  test_hook_refuses_captain_text_to_busy_mate \
  test_hook_inert_in_secondmate_home \
  test_send_new_task_refusal_enqueues_nothing
