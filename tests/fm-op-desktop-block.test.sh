#!/usr/bin/env bash
# shellcheck disable=SC2016
# Fork-only: agents can never reach the captain's 1Password desktop session
# (bin/fm-op-desktop-block.sh, applypass fork).
#
# The op PreToolUse hook (bin/fm-op-pretool-check.sh) sees only the command line
# an agent types, so an `op` call inside a script it runs slips past it. The
# block therefore lives in the environment every agent starts with:
# OP_BIOMETRIC_UNLOCK_ENABLED=false turns off op's 1Password app integration for
# every child process, whatever runs op and however.
#
# No real op, desktop app, or agent runs. The suite drives the real spawn against
# a fake pane, then EXECUTES the launch the pane received with the harness
# replaced by a probe that runs a script calling `op`, the way a worker runs
# `bash retag.sh check`. A fake op on PATH records the environment it got and
# reports DESKTOP-SESSION-REACHED when op would have fallen back to the app.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-op-desktop-block)
BLOCK="$ROOT/bin/fm-op-desktop-block.sh"

# make_case <name> <harness> <id>: echoes "<case>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# install_fake_op <dir>: an `op` that records what it saw and stands in for
# 1Password's own rule - no service account token and the app integration on
# means the desktop app answers.
install_fake_op() {
  cat > "$1/op" <<SH
#!/bin/sh
printf 'biometric=%s token=%s\n' "\${OP_BIOMETRIC_UNLOCK_ENABLED-unset}" "\${OP_SERVICE_ACCOUNT_TOKEN:+set}" >> '$1/op.log'
if [ -z "\${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ "\${OP_BIOMETRIC_UNLOCK_ENABLED:-true}" != false ]; then
  echo DESKTOP-SESSION-REACHED
  exit 0
fi
echo '[ERROR] account is not signed in' >&2
exit 1
SH
  chmod +x "$1/op"
}

# install_script_probe <fakebin> <harness>: the harness runs a script that calls
# op, so the op call is a grandchild the PreToolUse hook never sees.
install_script_probe() {
  local fakebin=$1 harness=$2
  install_fake_op "$fakebin"
  printf '#!/bin/sh\nop read op://vault/item/field\n' > "$fakebin/retag.sh"
  cat > "$fakebin/$harness" <<SH
#!/bin/sh
bash '$fakebin/retag.sh' check 2>/dev/null || echo op-refused
SH
  chmod +x "$fakebin/$harness"
}

# run_launch <with-pane-exports 0|1>: run the emitted launch in a synthetic pane
# that carries the contrary value, so a launch that only forwarded the ambient
# environment fails here.
run_launch() {
  local preamble=''
  [ "$1" = 0 ] || preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane OP_BIOMETRIC_UNLOCK_ENABLED=true \
    /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

assert_blocked() {  # <seen> <label>
  assert_not_contains "$1" DESKTOP-SESSION-REACHED "$2: op inside a script reached the 1Password desktop session"
  assert_equals op-refused "$1" "$2: op inside a script should be refused"
  grep -qx 'biometric=false token=' "$FAKEBIN_DIR/op.log" \
    || fail "$2: op should have started with OP_BIOMETRIC_UNLOCK_ENABLED=false, saw: $(cat "$FAKEBIN_DIR/op.log")"
}

# The gap this fixes: the hook allows a command that only runs a script.
test_hook_cannot_see_inside_a_script() {
  local out
  out=$(env -u OP_SERVICE_ACCOUNT_TOKEN "$ROOT/bin/fm-op-pretool-check.sh" --command 'bash retag.sh check' --claude 2>&1)
  expect_code 0 $? "the op hook allows a script run: $out"
  pass "the op PreToolUse hook cannot see op inside a script, so the launch environment must block it"
}

test_ship_and_scout_launches() {
  local harness setting rec out status seen
  for harness in claude codex; do
    for setting in absent enabled; do
      rec=$(make_case "ship-$harness-$setting" "$harness" "ship-$harness-$setting-a1")
      read_case "$rec"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      out=$(run_case_spawn "ship-$harness-$setting-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
      status=$?
      expect_code 0 "$status" "$harness ship spawn with allowlist=$setting should succeed: $out"
      install_script_probe "$FAKEBIN_DIR" "$harness"
      seen=$(run_launch 1) || fail "$harness ship, allowlist=$setting: the emitted launch failed to run"
      assert_blocked "$seen" "$harness ship, allowlist=$setting"
      : > "$FAKEBIN_DIR/op.log"
      seen=$(run_launch 0) || fail "$harness ship, allowlist=$setting: the launch alone failed to run"
      assert_blocked "$seen" "$harness ship launch alone, allowlist=$setting"
    done
  done
  rec=$(make_case scout codex scout-a1)
  read_case "$rec"
  out=$(run_case_spawn scout-a1 "$PROJ_DIR" --scout)
  expect_code 0 $? "scout spawn should succeed: $out"
  install_script_probe "$FAKEBIN_DIR" codex
  seen=$(run_launch 1) || fail "scout: the emitted launch failed to run"
  assert_blocked "$seen" "scout"
  pass "claude and codex ships and a scout cannot reach the desktop session from a script, with or without the allowlist"
}

test_secondmate_launch() {
  local rec sm out seen
  rec=$(make_case secondmate codex sm-a1)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' sm-a1 > "$sm/.fm-secondmate-home"
  printf 'charter for sm-a1\n' > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(run_case_spawn sm-a1 "$sm" --secondmate)
  expect_code 0 $? "secondmate spawn should succeed: $out"
  install_script_probe "$FAKEBIN_DIR" codex
  seen=$(run_launch 1) || fail "secondmate: the emitted launch failed to run"
  assert_blocked "$seen" "secondmate"
  pass "a secondmate cannot reach the desktop session from a script"
}

# A raw compound launch only covers its first command with a prefix assignment.
test_raw_compound_launch() {
  local rec out seen probe_dir
  rec=$(make_case raw-compound codex raw-a1)
  read_case "$rec"
  probe_dir="$CASE_DIR/agent-cwd"
  mkdir -p "$probe_dir"
  install_script_probe "$FAKEBIN_DIR" probe-harness
  mv "$FAKEBIN_DIR/probe-harness" "$probe_dir/probe"
  out=$(run_case_spawn raw-a1 "$PROJ_DIR" --mode no-mistakes --yolo off "cd $probe_dir && ./probe")
  expect_code 0 $? "raw compound launch spawn should succeed: $out"
  seen=$(run_launch 0) || fail "raw compound: the emitted launch failed to run"
  assert_blocked "$seen" "raw compound launch"
  pass "a raw compound launch command still blocks the desktop session after cd"
}

test_install_merges_claude_settings_env() {
  local dir="$TMP_ROOT/install" file
  mkdir -p "$dir/.claude"
  file="$dir/.claude/settings.local.json"
  printf '{"hooks":{"Stop":[]},"env":{"A":"1"}}\n' > "$file"
  "$BLOCK" install "$dir" || fail "install failed"
  "$BLOCK" install "$dir" || fail "second install failed"
  jq -e '.env.A == "1" and .env.OP_BIOMETRIC_UNLOCK_ENABLED == "false" and (.hooks.Stop | length == 0)' "$file" >/dev/null \
    || fail "install should add the block and keep other settings: $(cat "$file")"
  mkdir -p "$TMP_ROOT/fresh"
  "$BLOCK" install "$TMP_ROOT/fresh" || fail "fresh install failed"
  jq -e '.env.OP_BIOMETRIC_UNLOCK_ENABLED == "false"' "$TMP_ROOT/fresh/.claude/settings.local.json" >/dev/null \
    || fail "fresh install wrote no block"
  pass "install merges the block into a directory's untracked Claude settings, idempotently"
}

test_check_reports_the_gap() {
  local out
  out=$(OP_BIOMETRIC_UNLOCK_ENABLED=false "$BLOCK" check 2>&1)
  expect_code 0 $? "check with the block in place: $out"
  [ -z "$out" ] || fail "check should be silent with the block in place, got: $out"
  out=$(env -u OP_BIOMETRIC_UNLOCK_ENABLED "$BLOCK" check 2>&1)
  expect_code 1 $? "check without the block"
  assert_contains "$out" "OP_BIOMETRIC_UNLOCK_ENABLED=false" "the gap report names the fix"
  assert_contains "$out" "1Password desktop" "the gap report names the risk"
  out=$(OP_BIOMETRIC_UNLOCK_ENABLED=true "$BLOCK" check 2>&1)
  expect_code 1 $? "check with the app integration explicitly on: $out"
  pass "check is silent with the block and reports the gap without it"
}

test_lint_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$BLOCK" 2>&1) || fail "bin/fm-op-desktop-block.sh is not lint-clean: $out"
  pass "bin/fm-op-desktop-block.sh is lint-clean"
}

test_hook_cannot_see_inside_a_script
test_ship_and_scout_launches
test_secondmate_launch
test_raw_compound_launch
test_install_merges_claude_settings_env
test_check_reports_the_gap
test_lint_clean
