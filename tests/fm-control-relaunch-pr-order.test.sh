#!/usr/bin/env bash
# Fork-only: a relaunch keeps pr= and pr_head= last in the task record.
#
# bin/fm-final-run-handover.sh hands a ship's final run to a fresh worker
# through `fm-control.sh <id> relaunch`, which reruns bin/fm-spawn.sh.
# fm_pr_metadata_identity_parse (bin/fm-pr-lib.sh) rejects any key after pr=
# other than pr_head= and the x_* relay keys, and the watcher then drops the
# task's merge poll. control_relaunch_tx= must therefore land before pr=.
#
# Hermetic: a stubbed tmux models only the relaunch path (exit, launch brief,
# empty composer), the same way tests/fm-control-relaunch.test.sh does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

CONTROL="$ROOT/bin/fm-control.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch-pr-order)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && fm_test_remove_tree "$d"
  done
  fm_test_cleanup
}
trap relaunch_cleanup EXIT

# The harness's exit command stops the agent, and a launch-brief literal starts
# the harness named in `becomes`.
make_tmux_stub() {  # <dir>
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
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      [ "$payload" != C-u ] || : > "$D/composer"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
}

# new_case <name> <id> -> echoes a case dir with a live claude pane.
new_case() {
  local id=$2 dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> <harness>
add_ship_task() {
  local dir=$1 id=$2 harness=$3
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude relaunch pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

# A relaunch must leave pr= and its allowed followers (pr_head=) last in the
# record: fm_pr_metadata_identity_parse rejects any other key after pr=, and the
# watcher then drops the task's merge poll. control_relaunch_tx= is such a key.
test_relaunch_keeps_the_pr_identity_block_last_and_the_merge_poll_valid() {
  local dir out rc id=rl50 url=https://github.com/example/repo/pull/50
  local head=0123456789abcdef0123456789abcdef01234567 state template
  dir=$(new_case prlast "$id")
  add_ship_task "$dir" "$id" claude
  state="$dir/home/state"
  template="$ROOT/bin/fm-pr-poll.sh"
  printf 'pr=%s\npr_head=%s\n' "$url" "$head" >> "$state/$id.meta"
  fm_pr_poll_prepare "$state" "$id" github "$url" github.com example/repo 50 "$template" \
    || fail "could not prepare the PR poll fixture"
  fm_pr_poll_publish_prepared || fail "could not publish the PR poll fixture"
  fm_pr_poll_snapshot_capture "$state" "$id" "$template" \
    || fail "the PR poll fixture did not validate before the relaunch"

  out=$(run_control "$dir" "$id" relaunch --note "fresh worker for the final run"); rc=$?

  expect_code 0 "$rc" "a relaunch of a task with an armed PR poll should succeed"$'\n'"$out"
  [ -n "$(fm_meta_get "$state/$id.meta" control_relaunch_tx)" ] \
    || fail "control_relaunch_tx must stay readable after the relaunch"
  fm_pr_metadata_identity_parse "$state/$id.meta" \
    || fail "a relaunch left a key after pr=, so the identity parse rejects the record: $(tail -n 4 "$state/$id.meta" | tr '\n' ' ')"
  fm_pr_poll_snapshot_capture "$state" "$id" "$template" \
    || fail "a relaunch broke the merge poll: the watcher's snapshot no longer validates"
  [ "$(tail -n 1 "$state/$id.meta")" = "pr_head=$head" ] \
    || fail "pr_head= must stay the last line of the record"
  pass "fm-control relaunch: control_relaunch_tx is written before pr=, so the merge poll still validates"
}

test_relaunch_keeps_the_pr_identity_block_last_and_the_merge_poll_valid
