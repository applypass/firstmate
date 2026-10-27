#!/usr/bin/env bash
# tests/fm-claude-lean-mcp.test.sh - bin/fm-claude-lean-mcp.sh gives a task
# worker an empty MCP tool set by default and lets a task or home widen it.
# Each case runs the real script and reads the flags it prints.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEAN="$ROOT/bin/fm-claude-lean-mcp.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-lean-mcp)

# run_lean <case> [VAR=value...]: sets CFG, ST, OUT and RC.
run_lean() {
  local name=$1
  shift
  CFG="$TMP_ROOT/$name/config"
  ST="$TMP_ROOT/$name/state"
  mkdir -p "$CFG"
  OUT=$(env -u FM_WORKER_MCP "$@" "$LEAN" "$CFG" "$ST" 2>&1)
  RC=$?
}

test_default_is_strict_and_empty() {
  run_lean default
  assert_equals 0 "$RC" "default must succeed: $OUT"
  assert_equals "--strict-mcp-config --mcp-config '$ST/claude-worker-mcp-none.json' " "$OUT" "default flags"
  assert_equals '{"mcpServers":{}}' "$(tr -d '[:space:]' <"$ST/claude-worker-mcp-none.json")" "default config must hold no servers"
  pass "default launch carries a strict, empty MCP config"
}

test_home_allowlist_replaces_the_empty_set() {
  run_lean home
  printf '{"mcpServers":{"shortcut":{"command":"x"}}}\n' >"$CFG/claude-worker-mcp.json"
  OUT=$(env -u FM_WORKER_MCP "$LEAN" "$CFG" "$ST" 2>&1)
  assert_equals "--strict-mcp-config --mcp-config '$CFG/claude-worker-mcp.json' " "$OUT" "home allowlist flags"
  pass "config/claude-worker-mcp.json widens the default"
}

test_task_override_wins_over_home() {
  run_lean task
  printf '{}\n' >"$CFG/claude-worker-mcp.json"
  printf '{"mcpServers":{}}\n' >"$TMP_ROOT/task/one-task.json"
  OUT=$(FM_WORKER_MCP="$TMP_ROOT/task/one-task.json" "$LEAN" "$CFG" "$ST" 2>&1)
  assert_equals "--strict-mcp-config --mcp-config '$TMP_ROOT/task/one-task.json' " "$OUT" "task override flags"
  pass "FM_WORKER_MCP=<file> beats the home allowlist"
}

test_all_inherits_everything() {
  run_lean all
  OUT=$(FM_WORKER_MCP=all "$LEAN" "$CFG" "$ST" 2>&1)
  assert_equals "" "$OUT" "FM_WORKER_MCP=all must print no flags"
  pass "FM_WORKER_MCP=all keeps the full inherited MCP set"
}

test_missing_named_file_refuses() {
  run_lean missing
  OUT=$(FM_WORKER_MCP="$TMP_ROOT/missing/nope.json" "$LEAN" "$CFG" "$ST" 2>&1)
  RC=$?
  assert_equals 1 "$RC" "a missing named file must refuse"
  assert_contains "$OUT" "not a readable file" "refusal reason"
  pass "a missing MCP config refuses instead of falling back"
}

test_default_is_strict_and_empty
test_home_allowlist_replaces_the_empty_set
test_task_override_wins_over_home
test_all_inherits_everything
test_missing_named_file_refuses

echo "# all fm-claude-lean-mcp tests passed"
