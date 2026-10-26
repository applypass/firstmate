#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Fork-only: behavior tests for the op guard (bin/fm-op-pretool-check.sh).
#
# The guard refuses a Bash command that runs the 1Password `op` CLI unless
# OP_SERVICE_ACCOUNT_TOKEN is set. Commands are only classified, never run, so
# no real op, codex, or claude is launched. The suite proves the refused
# matrix, the allowed matrix (token supplied, non-op words), that a token value
# is never echoed, the Claude payload shape, fail-open transport, and the
# installer that registers the hook in a directory's untracked Claude settings.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-op-pretool-check)
CHECK="$ROOT/bin/fm-op-pretool-check.sh"

# No test may write the real ~/.claude or ~/.claude-work. Capture the real HOME
# before any override, run the installer with HOME pointed at a scratch dir (the
# classifier keeps the real HOME so the asdf node shim still resolves), and fail
# at once if that HOME or any directory the installer is aimed at resolves
# inside the real HOME.
REAL_HOME=$(CDPATH='' cd -- "${HOME:?HOME must be set}" 2>/dev/null && pwd -P) || fail "cannot resolve the real HOME"
assert_outside_real_home() {  # <path>
  local resolved
  resolved=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || fail "cannot resolve '$1'"
  case "$resolved/" in
    "$REAL_HOME"/*) fail "'$1' resolves inside the real HOME ($REAL_HOME); tests must never write there" ;;
  esac
}
assert_outside_real_home "$TMP_ROOT"
SCRATCH_HOME="$TMP_ROOT/home"
mkdir -p "$SCRATCH_HOME"
assert_outside_real_home "$SCRATCH_HOME"

# run_check <command> [env assignments...]: prints "<exit>" and leaves the
# output in CHECK_OUT, with OP_SERVICE_ACCOUNT_TOKEN unset unless supplied.
run_check() {
  local cmd=$1
  shift
  CHECK_OUT=$(env -u OP_SERVICE_ACCOUNT_TOKEN "$@" "$CHECK" --command "$cmd" --claude 2>&1)
  CHECK_RC=$?
}

assert_refused() {
  run_check "$1"
  expect_code 2 "$CHECK_RC" "refused: $1"
  assert_contains "$CHECK_OUT" '"permissionDecision":"deny"' "deny object for: $1"
  assert_contains "$CHECK_OUT" "OP_SERVICE_ACCOUNT_TOKEN" "reason names the fix for: $1"
  assert_contains "$CHECK_OUT" "fm-op-service-account-token.sh" "reason names the loader for: $1"
}

assert_allowed() {
  run_check "$1"
  expect_code 0 "$CHECK_RC" "allowed: $1"
  [ -z "$CHECK_OUT" ] || fail "allowed command produced output: $1: $CHECK_OUT"
}

test_refused_cases() {
  local c
  for c in \
    'op read op://vault/item/field' \
    'ls && op whoami' \
    'ls; op whoami' \
    'ls || op whoami' \
    'cat f | op inject' \
    'echo $(op item list)' \
    'echo `op item list`' \
    'echo ok; (op whoami)' \
    '{ op whoami; }' \
    'env X=1 op read y' \
    'env -i HOME=/x op read y' \
    'X=1 op read y' \
    '/opt/homebrew/bin/op read y' \
    '/usr/local/bin/op whoami' \
    'sudo op signin' \
    'command op read y' \
    'time op read y' \
    'xargs op read' \
    'bash -c "op read z"' \
    "sh -c 'ls && op read z'" \
    'bash -c "op read $ITEM"' \
    'bash -c "ls; op read $X"' \
    'eval "op read z"' \
    'eval "ls; op read $X"' \
    'nice -n 10 op read x' \
    'xargs -n 1 op read' \
    'xargs -I {} op read {}' \
    'for f in a b; do op read "op://v/$f"; done' \
    'if op read x; then echo ok; fi' \
    'if true; then op read x; fi' \
    'if false; then echo no; else op read x; fi' \
    'while true; do op read x; done' \
    'until false; do op read x; done' \
    '! op read x' \
    'then sudo op read x' \
    'OP_SERVICE_ACCOUNT_TOKEN= op read y' \
    'env -u OP_SERVICE_ACCOUNT_TOKEN op read y' \
    'echo hi
op whoami'; do
    assert_refused "$c"
  done
  pass "bare op calls are refused in every command position"
}

test_allowed_cases() {
  local c
  for c in \
    'open foo' \
    'opt/bin/run' \
    'cat opt.txt' \
    'ls /op/bar' \
    'cat /op/notes.md' \
    'echo --op' \
    'git commit -m "use op read for secrets"' \
    "git commit -m 'op whoami fixed'" \
    'echo "op"' \
    'grep -r op src' \
    'command -v op' \
    'which op' \
    'type op' \
    'git log --oneline' \
    'echo shop; stop; loop' ; do
    assert_allowed "$c"
  done
  pass "non-op words and quoted op text are allowed"
}

test_token_supplied_cases() {
  local c
  for c in \
    'OP_SERVICE_ACCOUNT_TOKEN=abc op read x' \
    'env OP_SERVICE_ACCOUNT_TOKEN=abc op read x' \
    'env -i OP_SERVICE_ACCOUNT_TOKEN=abc op read x' \
    'export OP_SERVICE_ACCOUNT_TOKEN=abc && op read x' \
    'export OP_SERVICE_ACCOUNT_TOKEN="$(cat tok)"; op read x' \
    'export A=1 OP_SERVICE_ACCOUNT_TOKEN=abc; ls | op inject' \
    'export OP_SERVICE_ACCOUNT_TOKEN=abc && echo $(op read x)' \
    'export OP_SERVICE_ACCOUNT_TOKEN=abc && bash -c "op read x"' \
    'declare -x OP_SERVICE_ACCOUNT_TOKEN=abc; op read x' \
    'OP_SERVICE_ACCOUNT_TOKEN=abc bash -c "op read x"' \
    'OP_SERVICE_ACCOUNT_TOKEN=abc; export OP_SERVICE_ACCOUNT_TOKEN; op read x' \
    'OP_SERVICE_ACCOUNT_TOKEN=abc; declare -x OP_SERVICE_ACCOUNT_TOKEN; op read x' \
    'export OP_SERVICE_ACCOUNT_TOKEN=abc; bash -c "op read $ITEM"' \
    'export OP_SERVICE_ACCOUNT_TOKEN=abc; for f in a b; do op read "op://v/$f"; done' \
    'export OP_SERVICE_ACCOUNT_TOKEN=abc; nice -n 10 op read x'; do
    assert_allowed "$c"
  done
  # An export that comes after the call does not cover it.
  assert_refused 'op read x && export OP_SERVICE_ACCOUNT_TOKEN=abc'
  # A name-only export loads nothing the line did not assign, and an unexport
  # or an empty reassignment unloads it.
  for c in \
    'export OP_SERVICE_ACCOUNT_TOKEN; op read x' \
    'export -n OP_SERVICE_ACCOUNT_TOKEN; op read x' \
    'declare -x OP_SERVICE_ACCOUNT_TOKEN; op read x' \
    'OP_SERVICE_ACCOUNT_TOKEN=abc; export -n OP_SERVICE_ACCOUNT_TOKEN; op read x' \
    'OP_SERVICE_ACCOUNT_TOKEN=abc; declare +x OP_SERVICE_ACCOUNT_TOKEN; op read x' \
    'OP_SERVICE_ACCOUNT_TOKEN=; export OP_SERVICE_ACCOUNT_TOKEN; op read x' \
    'export OP_SERVICE_ACCOUNT_TOKEN=abc; OP_SERVICE_ACCOUNT_TOKEN=; op read x'; do
    assert_refused "$c"
  done
  # A token in the hook's own environment covers every call.
  run_check 'op read x' OP_SERVICE_ACCOUNT_TOKEN=abc
  expect_code 0 "$CHECK_RC" "token in the environment allows op"
  [ -z "$CHECK_OUT" ] || fail "environment-token allow produced output: $CHECK_OUT"
  pass "a token in the command or environment allows op"
}

# The deny reason's example must itself pass the guard, run op only once a
# token is loaded, and stop before op when no token can be found.
test_deny_reason_remedy() {
  local example home bin marker rc
  run_check 'op read x'
  expect_code 2 "$CHECK_RC" "bare op is refused before reading its remedy"
  example=$(printf '%s' "$CHECK_OUT" | jq -r '.systemMessage' | sed -n 's/.*for example: \(.*&& op \.\.\.\).*/\1/p')
  [ -n "$example" ] || fail "deny reason carries no example command: $CHECK_OUT"
  example="${example% ...} read x"
  assert_allowed "$example"

  home="$TMP_ROOT/remedy-home"
  bin="$TMP_ROOT/remedy-bin"
  marker="$TMP_ROOT/remedy-op-ran"
  mkdir -p "$home" "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s" "${OP_SERVICE_ACCOUNT_TOKEN:-}" > %s\n' "$marker" > "$bin/op"
  chmod +x "$bin/op"

  # Claude Code's Bash tool runs the user's $SHELL, so the remedy must work
  # under zsh as well as bash (sourcing the bash library from zsh used to fail).
  local shells=(bash)
  command -v zsh >/dev/null 2>&1 && shells+=(zsh)
  local shell
  for shell in "${shells[@]}"; do
    rm -f "$marker" "$home/.env"
    env -u OP_SERVICE_ACCOUNT_TOKEN FM_HOME="$home" PATH="$bin:$PATH" "$shell" -c "$example" >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || fail "remedy under $shell succeeded with no token to load"
    [ ! -e "$marker" ] || fail "remedy under $shell ran op with no token loaded"

    printf 'OP_SERVICE_ACCOUNT_TOKEN=abc123\n' > "$home/.env"
    env -u OP_SERVICE_ACCOUNT_TOKEN FM_HOME="$home" PATH="$bin:$PATH" "$shell" -c "$example" >/dev/null 2>&1
    rc=$?
    expect_code 0 "$rc" "remedy under $shell runs op once the home .env supplies a token"
    [ -e "$marker" ] || fail "remedy under $shell did not run op after loading the token"
    [ "$(cat "$marker")" = "abc123" ] || fail "op under $shell did not receive the loaded token"
  done
  pass "the deny reason's remedy loads the token or stops before op (${shells[*]})"
}

test_token_never_echoed() {
  local secret='ops_SECRETVALUE123456' out
  # Refused call that carries a (later) token in the command line.
  run_check "op read x && export OP_SERVICE_ACCOUNT_TOKEN=$secret"
  expect_code 2 "$CHECK_RC" "refused with a token later in the line"
  assert_not_contains "$CHECK_OUT" "$secret" "deny output must not echo the command's token"
  # Refused call while a different token sits in the hook environment is allowed,
  # and in neither mode does the token reach the output.
  out=$(OP_SERVICE_ACCOUNT_TOKEN=$secret "$CHECK" --command 'op read x' 2>&1)
  assert_not_contains "$out" "$secret" "allow output must not echo the environment token"
  # Stdin payload: the deny must not carry the command text at all.
  out=$(printf '{"tool_input":{"command":"OP_X=%s op read x"}}' "$secret" | env -u OP_SERVICE_ACCOUNT_TOKEN "$CHECK" --claude 2>&1)
  expect_code 2 $? "stdin payload refused"
  assert_not_contains "$out" "$secret" "deny output must not echo any part of the command"
  pass "no token value is ever echoed"
}

test_harness_payloads() {
  local out err rc
  out=$(printf '{"tool_input":{"command":"op whoami"}}' | env -u OP_SERVICE_ACCOUNT_TOKEN "$CHECK" --claude 2>"$TMP_ROOT/claude.err")
  rc=$?
  expect_code 2 "$rc" "Claude payload refused"
  [ -z "$out" ] || fail "Claude deny must leave stdout empty, got: $out"
  err=$(cat "$TMP_ROOT/claude.err")
  assert_contains "$err" '"permissionDecision":"deny"' "Claude deny object on stderr"
  out=$(printf '{"tool_input":{"command":"ls"}}' | env -u OP_SERVICE_ACCOUNT_TOKEN "$CHECK" --claude 2>&1)
  expect_code 0 $? "non-op payload allowed"
  pass "the Claude stdin payload renders the deny"
}

test_fail_open() {
  local out
  out=$(printf '' | env -u OP_SERVICE_ACCOUNT_TOKEN "$CHECK" --claude 2>&1)
  expect_code 0 $? "empty stdin fails open"
  out=$(printf 'not json' | env -u OP_SERVICE_ACCOUNT_TOKEN "$CHECK" --claude 2>&1)
  expect_code 0 $? "unparseable stdin fails open"
  out=$(env -u OP_SERVICE_ACCOUNT_TOKEN "$CHECK" --command 'op "unterminated' --claude 2>&1)
  expect_code 0 $? "untokenizable command fails open"
  # No node on PATH: the transport cannot classify and allows.
  local bin="$TMP_ROOT/nonode"
  mkdir -p "$bin"
  for t in bash env sed tr cat jq dirname; do
    ln -sf "$(command -v "$t")" "$bin/$t" 2>/dev/null || true
  done
  out=$(PATH="$bin" env -u OP_SERVICE_ACCOUNT_TOKEN "$bin/env" PATH="$bin" "$bin/bash" "$CHECK" --command 'op read x' --claude 2>&1)
  expect_code 0 $? "missing node fails open: $out"
  pass "malformed input and a missing runtime fail open"
}

test_installer() {
  local dir="$TMP_ROOT/inst" file n
  mkdir -p "$dir/.claude"
  assert_outside_real_home "$dir"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch x"}]}]},"env":{"A":"1"}}\n' > "$dir/.claude/settings.local.json"
  HOME="$SCRATCH_HOME" "$ROOT/bin/fm-op-guard-install.sh" "$dir" || fail "installer failed"
  file="$dir/.claude/settings.local.json"
  jq -e '.env.A == "1" and (.hooks.Stop | length == 1)' "$file" >/dev/null || fail "installer dropped existing settings"
  jq -e --arg c "$(printf %q "$ROOT/bin/fm-op-pretool-check.sh") --claude" \
    '.hooks.PreToolUse[0].matcher == "Bash" and .hooks.PreToolUse[0].hooks[0].command == $c' "$file" >/dev/null \
    || fail "installer did not register the Bash PreToolUse hook"
  HOME="$SCRATCH_HOME" "$ROOT/bin/fm-op-guard-install.sh" "$dir" || fail "second install failed"
  n=$(jq '.hooks.PreToolUse | length' "$file")
  [ "$n" = 3 ] || fail "installer is not idempotent: $n hook entries"
  # The registered command, run as the harness would, refuses a bare op call.
  local cmd out
  cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$file")
  out=$(printf '{"tool_input":{"command":"op whoami"}}' | env -u OP_SERVICE_ACCOUNT_TOKEN bash -c "$cmd" 2>&1)
  expect_code 2 $? "registered hook refuses a bare op call"
  # A fresh directory with no settings file gets one.
  mkdir -p "$TMP_ROOT/fresh"
  assert_outside_real_home "$TMP_ROOT/fresh"
  HOME="$SCRATCH_HOME" "$ROOT/bin/fm-op-guard-install.sh" "$TMP_ROOT/fresh" || fail "fresh install failed"
  jq -e '.hooks.PreToolUse | length == 3' "$TMP_ROOT/fresh/.claude/settings.local.json" >/dev/null || fail "fresh install wrote no hook"
  # A checkout under a path with a space registers a hook that still launches.
  local spaced="$TMP_ROOT/with space/bin" target="$TMP_ROOT/spaced-target"
  mkdir -p "$spaced" "$target"
  assert_outside_real_home "$target"
  cp "$ROOT/bin/fm-op-guard-install.sh" "$ROOT/bin/fm-op-pretool-check.sh" \
    "$ROOT/bin/fm-op-command-policy.mjs" "$ROOT/bin/fm-arm-command-policy.mjs" "$ROOT/bin/fm-hook-host-lib.sh" "$spaced/"
  HOME="$SCRATCH_HOME" "$spaced/fm-op-guard-install.sh" "$target" || fail "spaced-path install failed"
  cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$target/.claude/settings.local.json")
  out=$(printf '{"tool_input":{"command":"op whoami"}}' | env -u OP_SERVICE_ACCOUNT_TOKEN bash -c "$cmd" 2>&1)
  expect_code 2 $? "hook registered from a path with a space refuses a bare op call: $out"
  assert_contains "$out" '"permissionDecision":"deny"' "spaced-path hook renders the deny"
  pass "installer merges, is idempotent, and registers a working hook"
}

test_scripts_are_shellcheck_clean() {
  local out f
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  for f in fm-op-pretool-check.sh fm-op-guard-install.sh fm-op-service-account-token.sh; do
    out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/$f" 2>&1) || fail "bin/$f is not lint-clean: $out"
  done
  pass "op guard scripts are clean under bin/fm-lint.sh"
}

test_refused_cases
test_allowed_cases
test_token_supplied_cases
test_deny_reason_remedy
test_token_never_echoed
test_harness_payloads
test_fail_open
test_installer
test_scripts_are_shellcheck_clean
