#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for the read-only side session (bin/fm-ask.sh,
# bin/fm-ask-pretool-check.sh, bin/fm-ask-command-policy.mjs, bin/fm-ask-order.sh).
#
# The guard is driven with real PreToolUse payloads and must refuse every
# mutation and allow reads. The launcher is driven with a fake claude that
# records its arguments, environment, and working directory, so the suite
# proves what the real session would be started with: no session lock, no
# session-start, an empty scratch directory, the read-only tool set, and the
# marker the hook honors. The queued-order path is driven with a stub send.
# A live run against the real claude is recorded in the PR proof.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "ok - node not installed, skipping"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-ask)
CHECK="$ROOT/bin/fm-ask-pretool-check.sh"
ASK="$ROOT/bin/fm-ask.sh"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
printf 'queued: audit\n' > "$HOME_DIR/data/backlog.md"
printf 'KEY=secret\n' > "$HOME_DIR/.env"

# guard <tool> <json input> [env assignments...]: exit code in RC, stderr in ERR.
guard() {
  local tool=$1 input=$2
  shift 2
  ERR=$(jq -cn --arg t "$tool" --argjson i "$input" '{tool_name:$t,tool_input:$i}' \
    | env FM_ASK_READONLY=1 FM_ASK_HOME="$HOME_DIR" "$@" "$CHECK" 2>&1 >/dev/null)
  RC=$?
}
bash_cmd() { guard Bash "$(jq -cn --arg c "$1" '{command:$c}')" "${@:2}"; }

assert_refused() {  # <command> <code>
  bash_cmd "$1"
  expect_code 2 "$RC" "refused: $1"
  assert_contains "$ERR" '"permissionDecision":"deny"' "deny object for: $1"
  assert_contains "$ERR" "[$2]" "reason code $2 for: $1"
  assert_contains "$ERR" "real firstmate" "reason hands the order off for: $1"
}
assert_allowed() {
  bash_cmd "$1" "${@:2}"
  expect_code 0 "$RC" "allowed: $1 ($ERR)"
}

test_every_named_mutation_is_refused() {
  local c
  for c in 'bin/fm-send.sh mate-a do it' '/abs/bin/fm-spawn.sh x' 'bin/fm-pr-merge.sh 12' 'bin/fm-wake-drain.sh' \
    'bin/fm-wake-drain.sh --ack-through 5' 'bin/fm-captain-hold.sh hold x --reason r' 'bin/fm-decide.sh x' \
    'bin/fm-teardown.sh x' 'bin/fm-control.sh x interrupt' 'bin/fm-secondmate-report.sh done abc x' \
    'ls && bin/fm-send.sh a b' 'echo $(bin/fm-send.sh a b)' 'cat x | bin/fm-send.sh a b'; do
    assert_refused "$c" ask-mutation
  done
  assert_refused 'bin/fm-tasks-axi.sh add x "y"' ask-mutation
  assert_refused 'bin/fm-tasks-axi.sh done x' ask-mutation
  assert_refused 'bin/fm-ask-order.sh do the thing' ask-mutation
  pass "send, spawn, merge, drain (with ack), hold, decide, teardown, control, report, backlog writes, and an order with no mate are refused"
}

test_writes_and_shell_escapes_are_refused() {
  local c
  for c in 'echo x > f' 'echo x >> f' 'cat a > b' 'ls 2> err.txt' 'tee f' 'rm -rf x' 'mv a b' 'cp a b' 'touch f' \
    'git commit -m x' 'git add .' 'git push' 'find . -delete' 'find . -exec rm {} ;' 'sort -o f g' 'git diff --output=f' \
    'bash -c ls' 'sh -c "rm x"' 'eval ls' 'xargs rm' 'env ls' 'sudo ls' 'python3 -c 1' 'node -e 1' 'sed -i s/a/b/ f' \
    'FM_HOME=/x ls' 'x=$(rm -rf y)' 'ls; $CMD' 'rg --pre cat x' 'tmux kill-server' 'curl http://x' 'exec ls' 'nohup ls'; do
    bash_cmd "$c"
    expect_code 2 "$RC" "refused: $c"
  done
  pass "file writes, shell re-entry, program runners, and unclassifiable commands are refused"
}

test_reads_are_allowed() {
  local c
  for c in 'cat data/backlog.md' 'ls state | head -5' 'grep -r audit data' 'jq . data/x.json' 'tail -n 3 state/a.status' \
    'find data -name "*.md"' 'git log --oneline -3' 'git -C . status' 'bin/fm-crew-state.sh mate-a' 'bin/fm-fleet-view.sh --json' \
    'bin/fm-peek.sh mate-a 20' 'bin/fm-tasks-axi.sh list --state queued' 'bin/fm-tasks-axi.sh show x' 'echo hi 2>/dev/null' \
    'cat a 2>&1 | wc -l' 'for f in a b; do echo $f; done' 'date +%s' "cat $HOME_DIR/data/backlog.md" \
    "git -C $HOME_DIR log --oneline -3" 'git --no-pager show HEAD' "grep -rn audit $HOME_DIR/data" 'cut -d/ -f2 x' 'cat <<EOF
hi
EOF'; do
    assert_allowed "$c"
  done
  pass "read commands, pipelines, and fm read scripts run"
}

test_git_cannot_run_a_program_or_leave_the_home() {
  local c
  for c in "git -c core.fsmonitor='touch /tmp/pwned' status" 'git -ccore.pager=sh log' 'git --config-env=core.pager=X log' \
    'git --exec-path=/tmp status' 'git --git-dir=/etc/x log' 'git --work-tree=/ status' 'git -C /etc log' 'git -C ../.. log' \
    'git diff --ext-diff' 'git show --textconv HEAD' 'git cat-file --filters HEAD:x' 'git grep -Ovim x' \
    'git grep --open-files-in-pager=sh x' 'git diff --no-index /etc/hosts x'; do
    bash_cmd "$c"
    expect_code 2 "$RC" "refused: $c"
  done
  pass "git takes no -c, no repo or exec override, no program-running option, and no path outside the home"
}

test_bash_reads_outside_the_home_are_refused() {
  local c
  ln -sfn /etc "$HOME_DIR/link"
  for c in 'cat ~/.ssh/id_ed25519' 'cat /etc/hosts' 'grep -r token ~' "find / -name '*.age'" 'cat ../../etc/hosts' \
    'cat < /etc/hosts' 'grep --file=/etc/hosts x' 'grep -f/etc/hosts x' 'cat ~root/x' "cat $HOME_DIR/.env" \
    "cat $HOME_DIR/link/hosts" 'cat $HOME/.ssh/id_rsa' 'x=/etc/hosts; cat $x' 'cat $(echo /etc/hosts)' 'cat {/etc/hosts,x}' \
    'for f in /etc/hosts; do cat $f; done'; do
    bash_cmd "$c"
    expect_code 2 "$RC" "refused: $c"
  done
  pass "a Bash read outside the home, of a secret, or through a path the guard cannot see is refused"
}

test_the_queued_order_is_the_only_exception() {
  assert_allowed 'bin/fm-ask-order.sh do the invoice bug first' FM_ASK_ORDER_TARGET=mate-a
  bash_cmd 'FM_ASK_ORDER_HOME=/other bin/fm-ask-order.sh x' FM_ASK_ORDER_TARGET=mate-a
  expect_code 2 "$RC" "an order command cannot override its target through the environment"
  bash_cmd 'bin/fm-send.sh mate-a x' FM_ASK_ORDER_TARGET=mate-a
  expect_code 2 "$RC" "a direct send stays refused even when orders are allowed"
  pass "only bin/fm-ask-order.sh runs, only with a fixed owning mate"
}

test_other_tools_and_paths() {
  local tool
  for tool in Edit Write NotebookEdit Agent WebFetch mcp__x__y; do
    guard "$tool" '{"file_path":"x"}'
    expect_code 2 "$RC" "$tool is refused"
  done
  guard Read "{\"file_path\":\"$HOME_DIR/data/backlog.md\"}"; expect_code 0 "$RC" "Read inside the home: $ERR"
  guard Read '{"file_path":"/etc/hosts"}'; expect_code 2 "$RC" "Read outside the home is refused"
  guard Read "{\"file_path\":\"$HOME_DIR/.env\"}"; expect_code 2 "$RC" "Read of a .env file is refused"
  guard Read "{\"file_path\":\"$HOME_DIR/../escape\"}"; expect_code 2 "$RC" "a .. escape is refused"
  ln -sfn /etc "$HOME_DIR/link"
  guard Read "{\"file_path\":\"$HOME_DIR/link/hosts\"}"; expect_code 2 "$RC" "a symlink out of the home is refused"
  guard Grep "{\"pattern\":\"x\",\"path\":\"$HOME_DIR/data\"}"; expect_code 0 "$RC" "Grep in the home"
  guard Grep '{"pattern":"x","path":"/etc"}'; expect_code 2 "$RC" "Grep outside the home is refused"
  guard Glob "{\"pattern\":\"$HOME_DIR/data/*.md\"}"; expect_code 0 "$RC" "Glob in the home"
  guard Glob '{"pattern":"/etc/*"}'; expect_code 2 "$RC" "Glob outside the home is refused"
  pass "only Read, Grep, Glob, and Bash run, and only on the home"
}

test_the_guard_fails_closed_and_is_inert_elsewhere() {
  local out
  out=$(printf '' | env FM_ASK_READONLY=1 FM_ASK_HOME="$HOME_DIR" "$CHECK" 2>&1); expect_code 2 $? "empty payload is refused: $out"
  out=$(printf 'not json' | env FM_ASK_READONLY=1 FM_ASK_HOME="$HOME_DIR" "$CHECK" 2>&1); expect_code 2 $? "malformed payload is refused: $out"
  out=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | env FM_ASK_READONLY=1 "$CHECK" 2>&1); expect_code 2 $? "no home is refused: $out"
  out=$(printf '{"tool_name":"Write","tool_input":{}}' | env -u FM_ASK_READONLY "$CHECK" 2>&1); expect_code 0 $? "a normal session is not touched: $out"
  [ -z "$out" ] || fail "inert guard printed: $out"
  pass "inside a side session an unreadable call is refused, outside one the guard is silent"
}

# A fake claude that records how it was started.
make_fake_claude() {
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake-$1")
  cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
{
  printf 'cwd=%s\n' "$(pwd -P)"
  for a in "$@"; do printf 'arg=%s\n' "$a"; done
  for v in FM_HOME FM_ASK_READONLY FM_ASK_HOME FM_ASK_ORDER_HOME FM_ASK_ORDER_TARGET GIT_OPTIONAL_LOCKS; do printf 'env %s=%s\n' "$v" "${!v-<unset>}"; done
} > "$FM_FAKE_CLAUDE_OUT"
SH
  chmod +x "$FAKEBIN/claude"
  FM_FAKE_CLAUDE_OUT="$TMP_ROOT/fake-$1/out"
  export FM_FAKE_CLAUDE_OUT
}

ask() {  # <args...>; the fake claude's record lands in $FM_FAKE_CLAUDE_OUT
  ASK_OUT=$(PATH="$FAKEBIN:$PATH" FM_ASK_SCRATCH="$TMP_ROOT/scratch" FM_HOME="$CALLER" "$ASK" "$@" 2>&1)
  ASK_RC=$?
}

test_launch_shape() {
  make_fake_claude launch
  CALLER="$TMP_ROOT/caller"
  mkdir -p "$CALLER/state" "$CALLER/data"
  rm -rf "$HOME_DIR/link"
  ask "$HOME_DIR"
  expect_code 0 "$ASK_RC" "launch succeeds: $ASK_OUT"
  local rec
  rec=$(cat "$FM_FAKE_CLAUDE_OUT")
  assert_contains "$rec" "cwd=$(cd "$TMP_ROOT/scratch" && pwd -P)" "starts in the empty scratch directory, not the home"
  assert_contains "$rec" "arg=--setting-sources" "project settings are not loaded"
  assert_contains "$rec" "arg=user" "only user settings"
  assert_contains "$rec" "arg=Read,Grep,Glob,Bash" "built-in tools are limited to the read set"
  assert_contains "$rec" "arg=dontAsk" "unlisted tools are refused"
  assert_contains "$rec" "arg=$(cd "$HOME_DIR" && pwd -P)" "the home is added for reading"
  assert_contains "$rec" "env FM_ASK_READONLY=1" "the read-only marker is set"
  assert_contains "$rec" "env FM_HOME=$(cd "$HOME_DIR" && pwd -P)" "FM_HOME names the home"
  assert_contains "$rec" "env GIT_OPTIONAL_LOCKS=0" "git status takes no lock"
  assert_contains "$rec" "env FM_ASK_ORDER_TARGET=<unset>" "a main-style home has no order target"
  assert_contains "$rec" "READ-ONLY side session" "the prompt says it is read-only"
  assert_contains "$rec" "hand it to the real firstmate" "the prompt hands orders off"
  assert_contains "$rec" "fm-ask-pretool-check.sh" "the guard hook is registered"
  [ ! -e "$HOME_DIR/state/.lock" ] && [ ! -e "$HOME_DIR/state/.lock-session" ] || fail "the session lock was taken"
  [ -z "$(find "$HOME_DIR/state" -type f 2>/dev/null)" ] || fail "the home's state changed: $(find "$HOME_DIR/state" -type f)"
  pass "the session starts read-only: scratch cwd, limited tools, marker set, no lock, home untouched"
}

test_print_model_and_mate_resolution() {
  make_fake_claude print
  CALLER="$TMP_ROOT/caller2"
  local mate="$TMP_ROOT/mate-home"
  mkdir -p "$CALLER/state" "$CALLER/data" "$mate/state" "$mate/data"
  printf 'mate-a\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$CALLER" > "$mate/.fm-secondmate-parent"
  printf -- '- mate-a - owns the audit (home: %s; scope: audits; projects: p; added 2026-10-01)\n' "$mate" > "$CALLER/data/secondmates.md"
  printf -- '- mate-r - remote one (host: h; root: /r; home: /rh; scope: s; projects: p; added 2026-10-01)\n' >> "$CALLER/data/secondmates.md"
  ask --model sonnet --effort low -p "what is queued?" mate-a
  expect_code 0 "$ASK_RC" "id resolves through the registry: $ASK_OUT"
  local rec
  rec=$(cat "$FM_FAKE_CLAUDE_OUT")
  assert_contains "$rec" "env FM_HOME=$(cd "$mate" && pwd -P)" "the mate's own home is read"
  assert_contains "$rec" "arg=-p" "print mode"
  assert_contains "$rec" "arg=what is queued?" "the question is passed"
  assert_contains "$rec" "arg=sonnet" "model passes through"
  assert_contains "$rec" "env FM_ASK_ORDER_TARGET=mate-a" "orders queue to the owning mate"
  assert_contains "$rec" "env FM_ASK_ORDER_HOME=$(cd "$CALLER" && pwd -P)" "through the parent home"
  assert_contains "$rec" "bin/fm-ask-order.sh" "the prompt names the one exception"
  ask mate-r
  expect_code 1 "$ASK_RC" "a remote mate is refused"
  assert_contains "$ASK_OUT" "remote" "says why"
  ask mate-zzz
  expect_code 1 "$ASK_RC" "an unknown mate is refused"
  ask /nonexistent/home
  expect_code 1 "$ASK_RC" "a missing home is refused"
  ask "$TMP_ROOT"
  expect_code 1 "$ASK_RC" "a directory that is not a home is refused"
  pass "a mate id resolves to its home, orders target that mate, bad targets are refused"
}

test_order_queues_through_send_to_a_fixed_target() {
  local dir="$TMP_ROOT/order" out rc
  mkdir -p "$dir/bin" "$dir/parent/state"
  cp "$ROOT/bin/fm-ask-order.sh" "$dir/bin/"
  cat > "$dir/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf 'FM_HOME=%s target=%s message=%s\n' "$FM_HOME" "$1" "$2" > "$SEND_LOG"
SH
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
echo "working phase=audit"
SH
  chmod +x "$dir/bin/"*.sh
  printf 'working [at=1]: auditing batch 3\n' > "$dir/parent/state/mate-a.status"
  out=$(FM_ASK_READONLY=1 FM_ASK_ORDER_HOME="$dir/parent" FM_ASK_ORDER_TARGET=mate-a SEND_LOG="$dir/send.log" "$dir/bin/fm-ask-order.sh" "do the invoice bug first" 2>&1)
  rc=$?
  expect_code 0 "$rc" "order queued: $out"
  assert_contains "$(cat "$dir/send.log")" "FM_HOME=$dir/parent target=mate-a" "sent to the fixed mate through the parent home"
  assert_contains "$(cat "$dir/send.log")" "do the invoice bug first" "the order text is carried"
  assert_contains "$(cat "$dir/send.log")" "captain gave this order" "the mate is told where it came from"
  assert_contains "$out" "queued-to: mate-a" "prints the queued confirmation"
  assert_contains "$out" "mate-state: working phase=audit" "prints the mate's current state"
  assert_contains "$out" "latest-status: working [at=1]: auditing batch 3" "prints the mate's newest status line"
  out=$(FM_ASK_READONLY=1 "$dir/bin/fm-ask-order.sh" "x" 2>&1); expect_code 1 $? "refuses with no fixed target: $out"
  out=$(FM_ASK_ORDER_HOME="$dir/parent" FM_ASK_ORDER_TARGET=mate-a "$dir/bin/fm-ask-order.sh" "x" 2>&1); expect_code 1 $? "refuses outside a side session: $out"
  pass "an order is sent through fm-send to the fixed mate and reports its state"
}

test_scripts_are_shellcheck_clean() {
  local f
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  for f in fm-ask.sh fm-ask-pretool-check.sh fm-ask-order.sh; do
    "$ROOT/bin/fm-lint.sh" "$ROOT/bin/$f" >/dev/null 2>&1 || fail "bin/$f is not lint-clean"
  done
  pass "ask scripts are clean under bin/fm-lint.sh"
}

test_every_named_mutation_is_refused
test_writes_and_shell_escapes_are_refused
test_reads_are_allowed
test_git_cannot_run_a_program_or_leave_the_home
test_bash_reads_outside_the_home_are_refused
test_the_queued_order_is_the_only_exception
test_other_tools_and_paths
test_the_guard_fails_closed_and_is_inert_elsewhere
test_launch_shape
test_print_model_and_mate_resolution
test_order_queues_through_send_to_a_fixed_target
test_scripts_are_shellcheck_clean
