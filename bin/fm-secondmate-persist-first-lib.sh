# shellcheck shell=bash disable=SC2034
# Fork-only (applypass): fm-secondmate-persist-first-lib.sh - the persist-first
# request step for bin/fm-secondmate-fresh-session.sh. Source only.
#
# Ask one mate to write down its open work: arm the parent-owned reply
# expectation, then deliver FM_SECONDMATE_PERSIST_REQUEST (the same marked request
# bin/fm-secondmate-restart.sh sends) through fm-send. The caller owns the wait
# and the bound. Needs bin/fm-secondmate-restart-lib.sh and
# bin/fm-pending-reply-lib.sh sourced. Publishes, on success,
#   FM_SECONDMATE_PERSIST_CORR    the correlation id the mate's answer must carry
# and on failure sets FM_SECONDMATE_PERSIST_REASON to one operator-readable line.

_FM_SECONDMATE_PERSIST_FIRST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_SECONDMATE_PERSIST_CORR=""
FM_SECONDMATE_PERSIST_REASON=""
fm_secondmate_persist_send() {  # <parent-home> <state> <id>
  local home=$1 state=$2 id=$3 corr send_out detail
  FM_SECONDMATE_PERSIST_CORR=""
  FM_SECONDMATE_PERSIST_REASON=""
  if ! corr=$(fm_pending_reply_create "$home" "$state" "$id" \
    "$FM_SECONDMATE_PERSIST_REQUEST"); then
    FM_SECONDMATE_PERSIST_REASON="its answer about the open work cannot be tracked, so a clean reload could not be proven"
    return 1
  fi
  if ! send_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$_FM_SECONDMATE_PERSIST_FIRST_LIB_DIR/fm-send.sh" "$id" "$FM_SECONDMATE_PERSIST_REQUEST" 2>&1); then
    fm_pending_reply_discard_undelivered "$state" "$corr" >/dev/null 2>&1 || true
    detail=$(printf '%s\n' "$send_out" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}')
    FM_SECONDMATE_PERSIST_REASON="the request to write down its open work could not be delivered: $detail"
    return 1
  fi
  FM_SECONDMATE_PERSIST_CORR=$corr
}
