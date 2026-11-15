#!/usr/bin/env bash
# Fork-only: tests/fm-control-own-doorbell-live-e2e.test.sh - the live guard for
# bin/fm-control-doorbell-lib.sh (live-harness-optin family, applypass fork).
#
# The portable regression in tests/fm-control-relaunch.test.sh pins the logic
# against a tmux stub. What it cannot prove is the vendor behavior the clear
# depends on: that Ctrl-U empties a wrapped, unsent doorbell in a real Claude
# composer, and that the same helper leaves any other draft alone. This guard
# launches the real claude in an isolated tmux server on a narrow pane (so the
# doorbell wraps over several rows, as in a real worker pane), types the doorbell
# without submitting it, and asserts the helper both clears it and refuses a draft.
# A second pane, wide but only 7 rows tall, clips the wrapped doorbell to its
# first row; the guard asserts the clipped view is cleared too.
# It submits no prompt, so it spends no model tokens.
#
# Run explicitly with FM_CONTROL_DOORBELL_LIVE=1 after a Claude upgrade, and
# record the dated result in docs/verification/runtime-backends.md ("Claude
# own-doorbell clear"). A missing claude fails when the guard is forced on.
#
# Folder trust: claude launches with the repo root as cwd, which the operator's
# machine has normally already trusted; a trust dialog is a real unready state
# and fails the check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_CONTROL_DOORBELL_LIVE tmux claude

unset NO_MISTAKES_GATE

SOCKET="fm-doorbell-clear-$$"
SESSION="dbclear"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-doorbell-clear.XXXXXX")
LAB=$(cd "$LAB" && pwd)

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR" "$LAB/state"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"

# shellcheck source=bin/fm-control-doorbell-lib.sh
. "$ROOT/bin/fm-control-doorbell-lib.sh"

version=$(claude --version 2>/dev/null | head -1 || printf 'version-unknown')

# 60 columns wraps the 160-odd character doorbell over several rows.
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 60 -y 40 -c "$ROOT" \
  "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions"
STATE="$LAB/state"
ID=live-doorbell
BACKEND=tmux
T="$SESSION:0"
LABEL=''
HARNESS=claude
POLL=0.5

composer() { fm_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null || printf unknown; }

# Claude redraws asynchronously, so a typed line can read empty for a moment.
wait_pending() {
  local n=0
  while [ "$n" -lt 20 ] && [ "$(composer)" != pending ]; do
    sleep 0.5
    n=$((n + 1))
  done
}

i=0
while [ "$i" -lt 90 ] && [ "$(composer)" != empty ]; do
  sleep 1
  i=$((i + 1))
done
[ "$(composer)" = empty ] || {
  tmux -L "$SOCKET" capture-pane -p -t "$T" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "claude ($version) never showed an empty composer; the pane is not usable"
}

line=$(fm_task_inbox_doorbell_line "$(fm_task_inbox_dir "$STATE" "$ID")/x.msg") \
  || fail "could not build the doorbell line"

tmux -L "$SOCKET" send-keys -t "$T" -l "$line"
wait_pending
[ "$(composer)" = pending ] \
  || fail "claude ($version): the typed doorbell should classify as pending, got $(composer)"
fm_control_clear_own_doorbell \
  || fail "claude ($version): the own-doorbell clear did not empty the wrapped composer"
[ "$(composer)" = empty ] || fail "claude ($version): composer not empty after the clear"
pass "claude ($version): an unsent wrapped doorbell is cleared and the composer proves empty"

tmux -L "$SOCKET" send-keys -t "$T" -l "my own draft"
sleep 1
if fm_control_clear_own_doorbell; then
  fail "claude ($version): the helper cleared a draft that is not the doorbell"
fi
tmux -L "$SOCKET" capture-pane -p -t "$T" | grep -q "my own draft" \
  || fail "claude ($version): the draft must survive a refused clear"
pass "claude ($version): a draft that is not the doorbell is left untouched"

# A pane too short for the wrapped doorbell shows only its first rows.
tmux -L "$SOCKET" kill-session -t "$SESSION"
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 152 -y 7 -c "$ROOT" \
  "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions"
i=0
while [ "$i" -lt 90 ] && [ "$(composer)" != empty ]; do
  sleep 1
  i=$((i + 1))
done
[ "$(composer)" = empty ] || fail "claude ($version) never showed an empty composer in the short pane"
tmux -L "$SOCKET" send-keys -t "$T" -l "$line"
wait_pending
[ "$(composer)" = pending ] \
  || fail "claude ($version): the clipped doorbell should classify as pending, got $(composer)"
fm_control_clear_own_doorbell \
  || fail "claude ($version): the own-doorbell clear did not empty the clipped composer"
[ "$(composer)" = empty ] || fail "claude ($version): composer not empty after the clipped clear"
pass "claude ($version): a doorbell clipped by a short pane is cleared and the composer proves empty"
