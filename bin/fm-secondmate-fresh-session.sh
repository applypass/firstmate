#!/usr/bin/env bash
# Fork-only (applypass): fm-secondmate-fresh-session.sh - restart a second mate
# with a short handover note once it finishes a piece of work.
#
# WHY. A second mate keeps one conversation for weeks. Every later turn re-reads
# all of it, so one overnight window spent hundreds of thousands of tokens per
# bookkeeping call. Its records are durable on disk, so the conversation can be
# dropped at each completed piece of work without losing anything.
#
# Usage:
#   fm-secondmate-fresh-session.sh request --source <report|child|context> --verb <done|ready|failed|handover> [--corr <id>] [note...]
#   fm-secondmate-fresh-session.sh apply <secondmate-id>
#   fm-secondmate-fresh-session.sh sweep
#
# request - run inside the second mate's home (FM_HOME is that home). Called by
#   bin/fm-secondmate-report.sh after a done/ready/failed report with --item, and
#   after a child's work landed by bin/fm-merge-outcome-lib.sh (a merged PR) and
#   bin/fm-merge-local.sh (a local-only fast-forward). A child's done ledger line
#   is its PR-ready report, not a landing, and asks for nothing. It writes two
#   durable files and nothing else: the handover note, data/fresh-session-handover.md
#   (under 40 lines: what finished, the child tasks still in flight, the unread
#   instruction count, where the open work lives), and the request marker,
#   state/fresh-session.request. It never touches the running agent. A remote
#   route and a main home are ignored: a remote mate's restart is not covered.
# apply - run in the parent home (FM_HOME is the parent). Restarts one mate with
#   bin/fm-control.sh <id> relaunch, the same path /updatefirstmate uses, only
#   when every check below passes; otherwise it prints "deferred" and leaves the
#   marker for a later pass. After the relaunch it drops a fire-and-forget
#   steer that points the fresh agent at the handover note; the fresh agent then
#   runs bin/fm-session-start.sh and reconciles from durable records like on any
#   restart. The model and effort pin are untouched: relaunch re-resolves them.
# sweep - run in the parent home on every watcher poll. Applies every mate whose
#   home holds a marker. It scans for markers before loading any library, so a
#   poll with nothing pending costs a few stat calls.
#   Before it applies, it runs the context check below, so a mate whose
#   conversation grew past the limit is queued like one that finished work.
#
# Context limit. A mate that keeps taking wakes without ever finishing a piece
# of work never asks for a restart, so every call re-reads an ever longer
# conversation (measured 2026-10-26: 517 calls at about 218k tokens each).
# The sweep therefore reads the size of each local Claude mate's current
# session from its transcript (input + cache read + cache creation tokens of the
# last assistant turn). Past FM_SECONDMATE_CONTEXT_LIMIT (default 100000) it
# files the same request as a finished piece of work (--source context --verb
# handover), and apply restarts it under the same guards below. The check is
# rate limited by FM_SECONDMATE_CONTEXT_CHECK_SECS (default 60) and ignores a
# transcript last written before the mate's previous restart, so the old
# session cannot trigger a second restart. Set the limit to 0 to turn it off.
#
# A restart happens only when ALL of these hold, so it never cuts a request or
# an unread message short:
#   - the marker's own correlated request, if any, is resolved;
#   - no other reply-bearing request to that mate is still open
#     (state/pending-replies/, any phase other than resolved);
#   - no steering message to that mate is unread (state/<id>.inbox/*.msg);
#   - the mate's own wake queue (state/.wake-queue) holds no row, so no wake
#     is left unacknowledged;
#   - its agent is idle: the backend says idle, or its rendered tail shows no
#     busy signature and the marker is older than the pending-reply grace
#     window (fm_pending_reply_backend_observation; second mates carry no
#     semantic busy-state hooks);
#   - the runtime can prove a restart (fm_secondmate_restart_capable).
# Child crew work in flight is fine: it runs in its own endpoints and the fresh
# mate reconciles it from the home's records.
# A failed relaunch moves the marker to state/fresh-session.request.failed so a
# broken restart is not retried on every poll, and sweep appends the failure
# with fm-control's error text to the parent's state/fresh-session.log. If the
# failure left Claude's "Background work is running" exit dialog open, apply
# closes it with Esc so the mate keeps taking input.
#
# FM_SECONDMATE_FRESH_SESSION=off disables request and sweep.
#
# Exit status: 0 restarted, deferred, or nothing to do; 1 a relaunch failed; 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_NAME='fresh-session.request'
NOTE_REL=data/fresh-session-handover.md

usage() {
  sed -n '3,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

fresh_session_off() {
  [ "${FM_SECONDMATE_FRESH_SESSION:-on}" = off ]
}

one_line() {  # <text> <max>
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-"$2"
}

# Write <content> to <path> atomically.
publish_file() {  # <path> <content>
  local path=$1 tmp
  mkdir -p "$(dirname "$path")" || return 1
  tmp="$path.tmp.$$"
  if ! { printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$path"; }; then
    rm -f "$tmp"
    return 1
  fi
}

marker_get() {  # <marker> <key>
  sed -n "s/^$2=//p" "$1" | head -1
}

# --- request ---------------------------------------------------------------

do_request() {
  local source='' verb='' corr='' just='' note home state parent_home id inbox_dir unread child cid last children body
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) source=${2:-}; shift 2 ;;
      --verb) verb=${2:-}; shift 2 ;;
      --corr) corr=${2:-}; shift 2 ;;
      *) break ;;
    esac
  done
  note=$*
  case "$source" in report | child | context) ;; *) usage >&2; return 2 ;; esac
  case "$verb" in done | ready | failed | handover) ;; *) usage >&2; return 2 ;; esac
  fresh_session_off && return 0
  home=${FM_HOME:-}
  [ -n "$home" ] || return 0
  state="${FM_STATE_OVERRIDE:-$home/state}"
  # shellcheck source=bin/fm-parent-channel-lib.sh
  . "$SCRIPT_DIR/fm-parent-channel-lib.sh"
  fm_parent_channel_destination "$home" "$state" >/dev/null || return 0
  [ "$FM_PARENT_CHANNEL_ROUTE" = local ] || return 0
  id=$FM_PARENT_CHANNEL_ID
  parent_home=$FM_SECONDMATE_PARENT_HOME

  children=''
  for child in "$state"/*.meta; do
    [ -e "$child" ] || continue
    cid=${child##*/}
    cid=${cid%.meta}
    [ "$(sed -n 's/^kind=//p' "$child" | head -1)" != secondmate ] || continue
    last=''
    [ ! -f "$state/$cid.status" ] || last=$(tail -n 1 "$state/$cid.status" 2>/dev/null || true)
    case "$last" in done* | failed*) continue ;; esac
    children="$children- $cid: $(one_line "${last:-no status line yet}" 140)"$'\n'
  done
  children=$(printf '%s' "$children" | head -n 10)
  unread=0
  inbox_dir="$parent_home/state/$id.inbox"
  if [ -d "$inbox_dir" ]; then
    unread=$(find "$inbox_dir" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
  fi

  if [ "$source" = context ]; then
    just="Nothing finished. Your conversation grew past the context limit, so it was replaced: $(one_line "${note:-no note}" 300)"
  else
    just="$verb ($source${corr:+, corr=$corr}): $(one_line "${note:-no note}" 300)"
  fi
  body="# Fresh session handover
Written $(date -u +%Y-%m-%dT%H:%M:%SZ) by the previous session of $id.
Your conversation was dropped on purpose to save tokens. Every record is on disk.

## Just finished
$just

## Still open
Unread steering messages for you: $unread (list $inbox_dir/*.msg, act in order, mv each into handled/)."
  if [ -n "$children" ]; then
    body="$body
Child tasks still in flight:
$children"
  else
    body="$body
Child tasks still in flight: none."
  fi
  body="$body

## First steps
1. Run bin/fm-session-start.sh and reconcile from its digest.
2. Open work lives in this home's backlog and state/*.status, not in this note.
3. Nothing here is a request. Do not reply to it; wait for routed work.
4. The digest lists open captain decisions and unread status; handle them before anything else."

  body=$(printf '%s\n' "$body" | head -n 40)
  publish_file "$home/$NOTE_REL" "$body" || return 0
  publish_file "$state/$MARKER_NAME" "source=$source
verb=$verb
corr=$corr
epoch=$(date +%s)
note=$NOTE_REL" || return 0
  return 0
}

# --- apply -----------------------------------------------------------------

defer() {  # <id> <reason>
  printf 'deferred %s: %s\n' "$1" "$2"
}

# 0 and prints nothing when every check passes, else prints the reason and returns 1.
blocked_reason() {  # <id> <meta> <home> <marker>
  local id=$1 meta=$2 home=$3 marker=$4 corr rec open verdict row epoch
  corr=$(marker_get "$marker" corr)
  case "$corr" in
    '') ;;
    *)
      # A corr with no pending-reply record (fire-and-forget or close-ack) has nothing to wait for.
      if [ -f "$(fm_pending_reply_path "$STATE" "$corr")" ] && ! fm_pending_reply_try_resolve "$STATE" "$corr"; then
        printf 'its correlated request %s is not resolved yet' "$corr"
        return 1
      fi
      ;;
  esac
  for rec in "$STATE"/pending-replies/*; do
    [ -f "$rec" ] || continue
    [ "$(fm_pending_reply_get "$rec" task_id)" = "$id" ] || continue
    [ "$(fm_pending_reply_get "$rec" phase)" != resolved ] || continue
    open=$(fm_pending_reply_get "$rec" corr_id)
    printf 'request %s is still open' "$open"
    return 1
  done
  if compgen -G "$STATE/$id.inbox/*.msg" >/dev/null; then
    printf 'a steering message to it is unread'
    return 1
  fi
  if [ -f "$home/state/.wake-queue" ]; then
    row=$(awk -F '\t' 'NF >= 5 && $1 ~ /^[0-9]+$/ { print "x"; exit }' "$home/state/.wake-queue" 2>/dev/null || true)
    if [ -n "$row" ]; then
      printf 'its wake queue holds an unacknowledged row'
      return 1
    fi
  fi
  # A second mate has no semantic busy-state hooks (fm-spawn arms them only for
  # task workers), so read the same backend observation the pending-reply
  # tracker uses. A rendered-tail idle counts only once the mate's report turn
  # has had the reply grace window to finish.
  verdict=$(fm_pending_reply_backend_observation "$(fm_backend_of_meta "$meta")" \
    "$(fm_backend_target_of_meta "$meta")" "fm-$id" "$(fm_meta_get "$meta" harness)")
  case "$verdict" in
    idle) ;;
    fallback-idle)
      epoch=$(marker_get "$marker" epoch)
      case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
      if [ $(($(date +%s) - epoch)) -lt "$(fm_pending_reply_grace_secs)" ]; then
        printf 'its agent is not provably idle (fallback-idle within the grace window)'
        return 1
      fi
      ;;
    *)
      printf 'its agent is not provably idle (%s)' "$verdict"
      return 1
      ;;
  esac
  return 0
}

# A Claude mate holding a background task answers /exit with a "Background
# work is running" dialog, so the relaunch fails and the dialog would hold the
# pane until someone presses Esc. Esc picks "Stay": the task keeps running and
# the mate takes input again.
dismiss_exit_dialog() {  # <id> <meta>
  local backend target screen
  backend=$(fm_backend_of_meta "$2")
  target=$(fm_backend_target_of_meta "$2")
  screen=$(fm_backend_visible_capture "$backend" "$target" "fm-$1" 2>/dev/null) || return 0
  printf '%s\n' "$screen" | grep -q 'Background work is running' || return 0
  fm_backend_send_key "$backend" "$target" Escape "fm-$1" >/dev/null 2>&1 || true
}

do_apply() {
  local id=${1:-} meta home marker reason out rc delivery note_path
  case "$id" in '' | *[!A-Za-z0-9._-]*) usage >&2; return 2 ;; esac
  fresh_session_off && return 0
  [ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set" >&2; return 2; }
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  export STATE
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 0
  [ "$(sed -n 's/^kind=//p' "$meta" | head -1)" = secondmate ] || return 0
  [ -z "$(sed -n 's/^remote_host=//p' "$meta" | head -1)" ] || return 0
  home=$(sed -n 's/^home=//p' "$meta" | head -1)
  [ -n "$home" ] || return 0
  marker="$home/state/$MARKER_NAME"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0

  # shellcheck source=bin/fm-secondmate-restart-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$SCRIPT_DIR/fm-pending-reply-lib.sh"
  # shellcheck source=bin/fm-secondmate-liveness-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

  fm_secondmate_liveness_lock "$id" || { defer "$id" "another restart or recovery is in progress"; return 0; }
  # shellcheck disable=SC2064
  trap "fm_secondmate_liveness_unlock '$id'" RETURN

  if ! fm_secondmate_restart_capable "$meta"; then
    defer "$id" "$FM_SECONDMATE_RESTART_REASON"
    return 0
  fi
  if ! reason=$(blocked_reason "$id" "$meta" "$home" "$marker"); then
    defer "$id" "$reason"
    return 0
  fi

  note_path="$home/$NOTE_REL"
  rc=0
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-control.sh" "$id" relaunch \
    --note "Fresh session after finished work. Handover note: $note_path" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    dismiss_exit_dialog "$id" "$meta"
    mv -f "$marker" "$marker.failed" 2>/dev/null || true
    printf 'failed %s: %s\n' "$id" "$(one_line "$out" 300)"
    return 1
  fi
  rm -f "$marker"
  date +%s > "$home/state/fresh-session.restarted" 2>/dev/null || true
  delivery=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "$id" --fire-and-forget "$delivery" \
    "You are a fresh session: your conversation was dropped after a finished piece of work, on purpose. Read the handover note at $note_path, run bin/fm-session-start.sh, and reconcile from durable records. This is not a request; do not reply." >/dev/null 2>&1; then
    printf 'restarted %s: handover note %s\n' "$id" "$note_path"
  else
    printf 'restarted %s: handover note %s (the pointer steer could not be delivered)\n' "$id" "$note_path"
  fi
  return 0
}

# --- context check ---------------------------------------------------------

# Context size of the newest Claude session transcript of <home>: input, cache
# read and cache creation tokens of its last assistant turn. Prints
# "<tokens> <transcript-mtime>" or nothing when there is no usable transcript.
context_tokens() {  # <home>
  local home=$1 enc root dir newest line mtime
  enc=$(printf '%s' "$home" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
  newest=''
  for root in "${FM_CLAUDE_PROJECTS_DIR:-}" "${CLAUDE_CONFIG_DIR:-}/projects" "$HOME/.claude-work/projects" "$HOME/.claude/projects"; do
    [ -n "$root" ] || continue
    dir="$root/$enc"
    [ -d "$dir" ] || continue
    # shellcheck disable=SC2012
    newest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
    [ -z "$newest" ] || break
  done
  [ -n "$newest" ] || return 0
  line=$(tail -c 600000 "$newest" 2>/dev/null | grep '"cache_read_input_tokens":' | tail -n 1)
  [ -n "$line" ] || return 0
  mtime=$(stat -f %m "$newest" 2>/dev/null || stat -c %Y "$newest" 2>/dev/null || echo 0)
  printf '%s\n' "$line" | awk -v mt="$mtime" '
    function num(key,   r) { if (match($0, "\"" key "\":[0-9]+")) { r = substr($0, RSTART, RLENGTH); sub(/.*:/, "", r); return r + 0 } return 0 }
    { printf "%d %s\n", num("input_tokens") + num("cache_read_input_tokens") + num("cache_creation_input_tokens"), mt }'
}

# File a context handover request for every local Claude mate over the limit.
do_context_check() {
  local state limit stamp now meta id home harness last out tokens mtime
  limit=${FM_SECONDMATE_CONTEXT_LIMIT:-100000}
  case "$limit" in '' | *[!0-9]*) return 0 ;; esac
  [ "$limit" -gt 0 ] || return 0
  state="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  stamp="$state/fresh-session.context-check"
  now=$(date +%s)
  if [ -f "$stamp" ]; then
    last=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null || echo 0)
    [ $((now - last)) -ge "${FM_SECONDMATE_CONTEXT_CHECK_SECS:-60}" ] || return 0
  fi
  : > "$stamp" 2>/dev/null || return 0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    [ -z "$(sed -n 's/^remote_host=//p' "$meta" | head -1)" ] || continue
    harness=$(sed -n 's/^harness=//p' "$meta" | head -1)
    [ "$harness" = claude ] || continue
    home=$(sed -n 's/^home=//p' "$meta" | head -1)
    [ -n "$home" ] && [ -d "$home/state" ] || continue
    [ ! -e "$home/state/$MARKER_NAME" ] && [ ! -e "$home/state/$MARKER_NAME.failed" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    out=$(context_tokens "$home")
    [ -n "$out" ] || continue
    tokens=${out%% *}
    mtime=${out##* }
    [ "$tokens" -ge "$limit" ] || continue
    if [ -f "$home/state/fresh-session.restarted" ]; then
      last=$(cat "$home/state/fresh-session.restarted" 2>/dev/null || echo 0)
      case "$last" in '' | *[!0-9]*) last=0 ;; esac
      [ "$mtime" -gt "$last" ] || continue
    fi
    FM_HOME="$home" FM_STATE_OVERRIDE='' "$0" request --source context --verb handover \
      "context was $tokens tokens (limit $limit)" >/dev/null 2>&1 || true
  done
}

# --- sweep -----------------------------------------------------------------

do_sweep() {
  local state meta id home out found='' rc=0
  fresh_session_off && return 0
  [ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set" >&2; return 2; }
  state="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  do_context_check
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    home=$(sed -n 's/^home=//p' "$meta" | head -1)
    [ -n "$home" ] && [ -f "$home/state/$MARKER_NAME" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    found="$found $id"
  done
  for id in $found; do
    if out=$(do_apply "$id"); then
      [ -z "$out" ] || printf '%s\n' "$out"
    else
      rc=1
      printf '%s\n' "$out"
      printf '%s %s\n' "$(date +%s)" "$out" >> "$state/fresh-session.log"
    fi
  done
  return "$rc"
}

case "${1:-}" in
  request) shift; do_request "$@" ;;
  apply) shift; do_apply "$@" ;;
  sweep) do_sweep ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
