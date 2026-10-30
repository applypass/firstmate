#!/usr/bin/env bash
# Fork-only: fm-captain-direct.sh - the captain typing into a second mate's own pane (applypass fork).
#
# usage: <UserPromptSubmit JSON on stdin> | fm-captain-direct.sh [--claude]
#
# A second mate answers the parent firstmate, and nobody reads its chat. When
# the captain types into the mate's pane himself, two things must happen: the
# mate answers him there, in plain captain style, and the parent learns what he
# said at its next wake drain instead of at the next reconcile. This hook does
# both for every submitted prompt in a secondmate home:
#
#   Firstmate traffic - the steering doorbell (": Firstmate ..."), a
#   [fm-from-firstmate] message, any operational input (bin/fm-operational-input.sh),
#   or a harness <task-notification> - is not the captain. It adds nothing to the
#   conversation. A doorbell or from-firstmate message closes any open reply
#   window of bin/fm-reply-first.sh, because routed work is not a question to
#   answer first.
#
#   Anything else a human typed is captain-direct. The hook appends one line to
#   the mate's parent channel (the file bin/fm-secondmate-report.sh writes,
#   resolved by bin/fm-parent-channel-lib.sh):
#       captain-direct [at=<epoch>]: <his words, one line, at most 200 characters>
#   and injects a reminder to answer him in the pane. The line has no verb the
#   classifier knows, so bin/fm-classify-lib.sh surfaces it as an event of its own
#   (an unrecognized prefix is shown as itself), never as an open decision, and
#   never as the answer to a marked request: it carries no corr= token. The mate's
#   outcomes (ready, needs-decision, done) still travel by fm-secondmate-report.sh.
#
# Scope: only a secondmate home (a .fm-secondmate-home marker), and never the
# read-only side session (FM_ASK_READONLY, bin/fm-ask.sh). Anywhere else the hook
# is silent and exits 0. A hook that cannot do its work is also silent: it never
# blocks the prompt.
#
# Output (Claude UserPromptSubmit): one JSON object whose additionalContext is the
# reminder. The harness drops invisible characters from a typed prompt, so the
# U+2063 marker in a firstmate message cannot be relied on; the label and the
# doorbell text are.
# Callers: bin/fm-mate-hooks-install.sh registers it. docs/captain-direct-mate-access.md owns the operator view.
set -u

[ -z "${FM_ASK_READONLY:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${CLAUDE_PROJECT_DIR:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_root_is_secondmate_home "$FM_HOME" || exit 0
[ -d "$STATE" ] || exit 0

PARSED=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" or ((.hook_event_name // "UserPromptSubmit") != "UserPromptSubmit") then empty
  else [((.transcript_path // "") | tostring), ((.prompt // "") | tostring)] | "\(.[0])\n\(.[1])" end' 2>/dev/null) || exit 0
[ -n "$PARSED" ] || exit 0
TRANSCRIPT=$(printf '%s\n' "$PARSED" | sed -n '1p')
PROMPT=$(printf '%s\n' "$PARSED" | sed '1d')
# Trim leading and trailing whitespace.
TEXT=${PROMPT#"${PROMPT%%[![:space:]]*}"}
TEXT=${TEXT%"${TEXT##*[![:space:]]}"}
[ -n "$TEXT" ] || exit 0

arm() {
  local args=(captain-direct)
  [ -z "$TRANSCRIPT" ] || args+=(--transcript "$TRANSCRIPT")
  "$SCRIPT_DIR/fm-reply-first.sh" arm "${args[@]}" >/dev/null 2>&1 || true
}
disarm() { "$SCRIPT_DIR/fm-reply-first.sh" clear >/dev/null 2>&1 || true; }

# Firstmate's own traffic, never the captain.
case "$TEXT" in
  '<task-notification>'*) exit 0 ;;
  ': Firstmate instruction waiting:'*|'[fm-from-firstmate]'*|*$'\xE2\x81\xA3''[fm-from-firstmate]'*)
    disarm
    exit 0
    ;;
esac
kind=$(printf '%s' "$TEXT" | "$SCRIPT_DIR/fm-operational-input.sh" classify 2>/dev/null) && {
  [ "$kind" != from-firstmate ] || disarm
  exit 0
}
if printf '%s' "$TEXT" | FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-operational-input.sh" doorbell-kind >/dev/null 2>&1; then
  exit 0
fi

# The captain typed this. One bounded line for the parent.
SHORT=$(printf '%s' "$TEXT" | LC_ALL=C tr '\t\r\n' '   ' | tr -s ' ')
if [ "${#SHORT}" -gt 200 ]; then
  SHORT="$(printf '%s' "$SHORT" | cut -c1-197)..."
fi

REPORTED=yes
(
  # shellcheck source=bin/fm-parent-channel-lib.sh
  . "$SCRIPT_DIR/fm-parent-channel-lib.sh"
  fm_parent_channel_report "$FM_HOME" "$STATE" "captain-direct: $SHORT"
) >/dev/null 2>&1 || REPORTED=no
arm

NOTE="[captain-direct] The captain typed the message above straight into your pane. It is not a Firstmate message. Answer him here, now, in plain captain style: lead with the answer, short sentences, the outcome and what it means for him, no internal jargon."
if [ "$REPORTED" = yes ]; then
  NOTE="$NOTE The parent firstmate has already been told his words on the parent channel as a captain-direct line, so do not repeat them there. If his words change your routed work or priorities, do that and say so in the reply."
else
  NOTE="$NOTE The note to the parent firstmate could not be written, so say that to the captain and append one captain-direct line with his words yourself."
fi
NOTE="$NOTE Results of routed work (ready, needs-decision, done, blocked) still go to the parent through bin/fm-secondmate-report.sh, never only into this pane."
jq -cn --arg note "$NOTE" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $note}}'
exit 0
