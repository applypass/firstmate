#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
# Only a done, ready, needs-decision, blocked, or failed <verb> closes the
# request; working or paused only acknowledges it and keeps it open.
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through fm_parent_channel_destination
# (bin/fm-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the secondmate home with FM_HOME
# set to that home.
#
# Fork-only (applypass): while Shortcut ticket sync is on, a done or ready
# report (including --doc) needs --item <id> naming the backlog item of the
# investigation, and refuses to publish unless
# `bin/fm-shortcut-ticket.sh --check <id>` passes in this home.
#
# Usage:
#   fm-secondmate-report.sh [--item <id>] <verb> <corr_id> <note...>
#   fm-secondmate-report.sh [--item <id>] --doc <verb> <corr_id> <doc-path> <note...>
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --item audit-1 --doc done abcdef0123456789 data/x/report.md "see report"
set -eu

CALLER_FM_HOME=${FM_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh [--item <id>] <verb> <corr_id> <note...>
  fm-secondmate-report.sh [--item <id>] --doc <verb> <corr_id> <doc-path> <note...>
EOF
  exit 2
}

DOC_MODE=0
ITEM=
while :; do
  case "${1:-}" in
    --doc) DOC_MODE=1; shift ;;
    --item) [ -n "${2:-}" ] || usage; ITEM=$2; shift 2 ;;
    *) break ;;
  esac
done

[ $# -ge 2 ] || usage
VERB=$1
CORR=$2
shift 2
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  [ $# -ge 1 ] && [ -n "$*" ] || usage
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

HOME_DIR=$CALLER_FM_HOME
case "$HOME_DIR" in
  '')
    echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

DESTINATION=
DEST_RC=0
DESTINATION=$(fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
case "$VERB" in
  done | ready)
    if FM_HOME="$HOME_DIR" "$SCRIPT_DIR/fm-shortcut-ticket.sh" --enabled; then
      if [ -z "$ITEM" ]; then
        echo "error: a $VERB report needs --item <id> naming the investigation's backlog item, whose own Shortcut story must pass bin/fm-shortcut-ticket.sh --check <id>" >&2
        exit 1
      fi
      if ! FM_HOME="$HOME_DIR" "$SCRIPT_DIR/fm-shortcut-ticket.sh" --check "$ITEM"; then
        echo "error: refusing to publish $VERB for $ITEM: it has no verified Shortcut story of its own (reason above)" >&2
        exit 1
      fi
    fi
    ;;
esac
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

token=$(fm_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf -v line '%s [%s]: %s (%s via-helper)' "$VERB" "$token" "$NOTE" "$DOC_PATH"
  else
    printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$DOC_PATH"
  fi
else
  NOTE=$*
  printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$NOTE"
fi
printf '%s\n' "$(status_stamp_line "$line")" >> "$DESTINATION"
