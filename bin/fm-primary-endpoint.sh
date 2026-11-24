#!/usr/bin/env bash
# Fork-only (applypass): record the pane that runs main's own chat.
# Usage: fm-primary-endpoint.sh record [<fm-home>]
# Run by bin/fm-session-start.sh in the locked block, so it inherits the primary session's pane
# environment ($TMUX_PANE, herdr, Rex, T3). Writes $FM_HOME/state/.primary-endpoint:
#   backend=<tmux|herdr|...>, target=<pane>, harness=<claude|...>
# bin/fm-usage-limit-tick.sh reads it to resume main's chat after a usage limit resets.
# When no pane is discoverable (a bare terminal), the record is removed rather than left pointing at
# an old pane, and nothing is written. A secondmate home records nothing: its parent home already
# resumes that pane as a mate. Always exits 0: session start must never fail on this.
# Contract: docs/usage-limit-resume.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

[ "${1:-}" = record ] || { echo "usage: fm-primary-endpoint.sh record [<fm-home>]" >&2; exit 2; }
FM_HOME=${2:-${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
FILE="$STATE/.primary-endpoint"
[ -d "$STATE" ] || exit 0
fm_root_is_secondmate_home "$FM_HOME" && { rm -f "$FILE"; exit 0; }

if ! target=$(discover_supervisor_target 2>/dev/null) || [ -z "$target" ]; then
  rm -f "$FILE"
  exit 0
fi
backend=$(discover_supervisor_backend 2>/dev/null) || backend=tmux

harness=${FM_SUPERVISION_PRIMARY_HARNESS:-}
if [ -z "$harness" ] && [ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]; then harness=claude; fi

tmp=$(mktemp "$FILE.XXXXXX") || exit 0
if printf 'backend=%s\ntarget=%s\nharness=%s\n' "$backend" "$target" "$harness" >"$tmp"; then
  mv "$tmp" "$FILE" || rm -f "$tmp"
else
  rm -f "$tmp"
fi
exit 0
