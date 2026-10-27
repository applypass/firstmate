#!/usr/bin/env bash
# shellcheck disable=SC2016
# Fork-only: behavior tests for the hourly /stow then /clear reminder
# (bin/fm-clear-reminder.sh), driven through the tracked Claude prompt-submit
# registration of bin/fm-host-mirror.sh exactly as a primary's own hook runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
unset FM_CLEAR_REMINDER FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR

MIRROR="$ROOT/bin/fm-host-mirror.sh"
REMINDER="$ROOT/bin/fm-clear-reminder.sh"
TMP_ROOT=$(fm_test_tmproot fm-clear-reminder)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
trap fm_test_cleanup EXIT

PRIMARY_ROOT="$TMP_ROOT/primary"
mkdir -p "$PRIMARY_ROOT"
git init -q "$PRIMARY_ROOT"
: > "$PRIMARY_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY_ROOT/bin"

make_home() {  # <name>
  mkdir -p "$TMP_ROOT/$1/state" "$TMP_ROOT/$1/config"
  printf '%s\n' "$TMP_ROOT/$1"
}

# Submit one captain prompt as the lock-owning primary session of <home> at clock <now>.
prompt() {  # <home> <now> <text>
  jq -cn --arg t "$3" '{hook_event_name: "UserPromptSubmit", prompt_id: "p", prompt: $t}' |
    FM_HOME="$1" FM_NOW="$2" FM_ROOT_OVERRIDE="$PRIMARY_ROOT" MIRROR="$MIRROR" "$FAKEBIN/claude" -c \
      'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; FM_CLEAR_REMINDER_NOW=$FM_NOW "$MIRROR" hook claude'
}

test_two_prompts_inside_an_hour_print_one_line() {
  local home out
  home=$(make_home hourly)
  : > "$home/config/supervision-host"
  out=$(prompt "$home" 1000000 hello; prompt "$home" 1003599 again)
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "two prompts inside an hour must print one line"
  case "$(printf '%s' "$out" | jq -r .systemMessage)" in
    */stow*/clear*) ;;
    *) fail "the reminder must suggest /stow then /clear: $out" ;;
  esac
  out=$(prompt "$home" 1003600 later)
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "a prompt an hour later must remind again"
  pass "reminder: two prompts inside an hour print one line, and the next hour reminds again"
}

test_restart_keeps_the_hourly_limit() {
  local home out
  home=$(make_home restart)
  : > "$home/config/supervision-host"
  prompt "$home" 2000000 first >/dev/null
  [ "$(cat "$home/state/.clear-reminder-epoch")" = 2000000 ] || fail "the reminder time must live in the home state"
  out=$(prompt "$home" 2000100 "after restart")
  assert_equals "" "$out" "a restart must not reset the hourly limit"
  pass "reminder: the hourly limit survives a restart"
}

test_non_primary_contexts_print_nothing() {
  local home out worker
  home=$(make_home worker-home)
  : > "$home/config/supervision-host"
  # A linked task worktree is never primary.
  worker="$TMP_ROOT/worker-wt"
  git -C "$PRIMARY_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$PRIMARY_ROOT" worktree add -q "$worker" -b worker-branch
  ln -s "$ROOT/bin" "$worker/bin"
  : > "$worker/AGENTS.md"
  out=$(jq -cn '{hook_event_name: "UserPromptSubmit", prompt: "hi"}' |
    FM_HOME="$home" FM_ROOT_OVERRIDE="$worker" "$FAKEBIN/claude" -c \
      'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; FM_CLEAR_REMINDER_NOW=1000000 "'"$MIRROR"'" hook claude')
  assert_equals "" "$out" "a worker worktree must print nothing"
  # A second session that does not own the lock.
  out=$(jq -cn '{hook_event_name: "UserPromptSubmit", prompt: "hi"}' |
    FM_HOME="$home" FM_ROOT_OVERRIDE="$PRIMARY_ROOT" FM_CLEAR_REMINDER_NOW=1000000 "$MIRROR" hook claude)
  assert_equals "" "$out" "a session without the fleet lock must print nothing"
  # A secondmate-style home with the host off.
  home=$(make_home host-off)
  : > "$home/config/supervision-host-off"
  out=$(prompt "$home" 1000000 hi)
  assert_equals "" "$out" "a home that opted out of the host must print nothing"
  [ ! -e "$home/state/.clear-reminder-epoch" ] || fail "a silent context must not record a reminder"
  pass "reminder: a worker, a lockless session, and an opted-out home print nothing"
}

test_machine_prompts_do_not_use_the_hour() {
  local home out
  home=$(make_home machine)
  : > "$home/config/supervision-host"
  out=$(prompt "$home" 1000000 '<task-notification>done</task-notification>')
  assert_equals "" "$out" "a rewake prompt must not remind"
  [ ! -e "$home/state/.clear-reminder-epoch" ] || fail "a rewake prompt must not spend the hour"
  pass "reminder: a Stop-hook rewake does not print or spend the hour"
}

test_off_switch() {
  local home
  home=$(make_home off)
  assert_equals "" "$(FM_CLEAR_REMINDER=off "$REMINDER" --state "$home/state")" "FM_CLEAR_REMINDER=off must print nothing"
  pass "reminder: FM_CLEAR_REMINDER=off disables it"
}

test_two_prompts_inside_an_hour_print_one_line
test_restart_keeps_the_hourly_limit
test_non_primary_contexts_print_nothing
test_machine_prompts_do_not_use_the_hour
test_off_switch
