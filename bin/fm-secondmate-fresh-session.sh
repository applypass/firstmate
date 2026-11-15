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
#   fm-secondmate-fresh-session.sh request --source <report|child|context|new-task> --verb <done|ready|failed|handover> [--corr <id>] [note...]
#   fm-secondmate-fresh-session.sh hold [--queued] <secondmate-id> <text>
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
# hold - run in the parent home by bin/fm-new-task-guard.sh fresh-context, for a
#   --new-task send to an idle mate. It stores the text under the parent's
#   state/<id>.fresh-held/, where the mate does not read, and files a request
#   (--source new-task) unless one is pending. While held text waits, hold (and
#   fm-send.sh's hold --queued for any later text to the mate) adds the text to
#   the same queue, so it reaches the inbox after the held text, in send order.
#   Exit 0 means held; any other exit means the caller delivers the text itself:
#   --queued found nothing waiting, the switch is off, or the mate is not a local
#   mate whose restart the runtime can prove.
# apply - run in the parent home (FM_HOME is the parent). Restarts one mate with
#   bin/fm-control.sh <id> relaunch, the same path /updatefirstmate uses, only
#   when every check below passes; otherwise it prints "deferred" and leaves the
#   marker for a later pass. After the relaunch it drops a fire-and-forget
#   steer that points the fresh agent at the handover note; the fresh agent then
#   runs bin/fm-session-start.sh and reconciles from durable records like on any
#   restart. The model and effort pin are untouched: relaunch re-resolves them.
#   Held text then goes to the mate through fm-send.sh --same-task
#   (FM_SEND_HELD_RELEASE=1, so it is not held again), oldest first, so it
#   always arrives after the restart. With no restart to come (no
#   marker, the switch off, a runtime that cannot prove a restart, a persist
#   timeout, a failed relaunch, or a deferral older than the persist wait) apply
#   delivers the held work at once and drops a new-task marker. While held work
#   waits, the persist request and the pointer steer say the restart is for new
#   work.
# sweep - run in the parent home on every watcher poll. Applies every mate whose
#   home holds a marker or whose held new work waits. It scans for markers before loading any library, so a
#   poll with nothing pending costs a few stat calls.
#   Before it applies, it runs the context check below, so a mate whose
#   conversation grew past the limit is queued like one that finished work.
#
# Context limit. A mate that keeps taking wakes without ever finishing a piece
# of work never asks for a restart, so every call re-reads an ever longer
# conversation (measured 2026-10-26: 517 calls at about 218k tokens each).
# The sweep therefore reads the size of each local Claude mate's current
# session from its transcript (input + cache read + cache creation tokens of the
# last assistant turn). Past FM_SECONDMATE_CONTEXT_LIMIT (default 150000) it
# files the same request as a finished piece of work (--source context --verb
# handover), and apply restarts it under the same guards below. The check is
# rate limited by FM_SECONDMATE_CONTEXT_CHECK_SECS (default 60) and ignores a
# transcript last written before the mate's previous restart, so the old
# session cannot trigger a second restart. Set the limit to 0 to turn it off.
#
# Persist first. Before the relaunch, apply asks the mate to write down the open
# work it holds only in its conversation, with the persist step /updatefirstmate
# runs, worded for a fresh session (fm_secondmate_persist_send in
# bin/fm-secondmate-persist-first-lib.sh). Like bin/fm-secondmate-restart.sh, one
# apply call sends the request and then polls for that request's correlated
# answer every FM_SECONDMATE_PERSIST_POLL seconds (default 5), up to
# FM_SECONDMATE_PERSIST_WAIT seconds (default 900); the watcher runs the sweep
# detached, so the wait never stalls a poll. Every attempt asks afresh; no
# answer is carried to a later sweep. Once the answer is in, apply waits within
# the same bound for the checks below to pass, and defers if they do not. The
# per-mate liveness lock in the parent's state, held for the whole call, makes a
# concurrent sweep skip that mate instead of sending a second request. A mate
# that does not answer in time is not relaunched and gets no nudge ("timed out
# ... did not confirm"): apply closes that request's pending-reply record and
# withdraws its own unread steering message so neither can block the next attempt,
# clears the marker, and logs the timeout to the parent's state/fresh-session.log. The next trigger files a new request.
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
# FM_SECONDMATE_FRESH_SESSION=off disables request, hold and restarts; the sweep
# then only delivers held work.
#
# Exit status: 0 restarted, deferred, held, or nothing to do; 1 a relaunch failed
# or nothing was held; 2 usage.
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
  case "$source" in report | child | context | new-task) ;; *) usage >&2; return 2 ;; esac
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

  if [ "$source" = new-task ]; then
    just="Nothing finished. New work arrived, so your conversation was replaced; the work reaches your inbox right after this restart."
  elif [ "$source" = context ]; then
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

# --- hold ------------------------------------------------------------------

has_held() {  # <held-dir>
  compgen -G "$1/*.msg" >/dev/null
}

do_hold() {
  local queued=0 id text meta home held file created=0 seq=0 n f
  [ "${1:-}" != --queued ] || { queued=1; shift; }
  id=${1:-} text=${2:-}
  case "$id" in '' | *[!A-Za-z0-9._-]*) usage >&2; return 2 ;; esac
  [ "$#" -eq 2 ] && [ -n "$text" ] || { usage >&2; return 2; }
  [ -n "${FM_HOME:-}" ] || return 1
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  held="$STATE/$id.fresh-held"
  if ! has_held "$held"; then
    [ "$queued" = 0 ] || return 1
    fresh_session_off && return 1
    meta="$STATE/$id.meta"
    # shellcheck source=bin/fm-secondmate-restart-lib.sh
    . "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
    fm_secondmate_restart_capable "$meta" && [ "$FM_SECONDMATE_RESTART_PLACEMENT" = local ] || return 1
    home=$(fm_meta_get "$meta" home)
    [ -n "$home" ] && [ -d "$home/state" ] || return 1
    if [ ! -f "$home/state/$MARKER_NAME" ]; then
      FM_HOME="$home" FM_STATE_OVERRIDE='' "$0" request --source new-task --verb handover \
        "new work is waiting" >/dev/null 2>&1 </dev/null || true
      [ -f "$home/state/$MARKER_NAME" ] || return 1
      created=1
    fi
  fi
  for f in "$held"/*.msg; do
    [ -f "$f" ] || continue
    n=${f##*/} n=${n#*-} n=${n%%-*}
    case "$n" in '' | *[!0-9]*) continue ;; esac
    [ $((10#$n)) -lt "$seq" ] || seq=$((10#$n + 1))
  done
  file="$held/$(date +%s)-$(printf '%06d' "$seq")-$$.msg"
  if ! publish_file "$file" "$text"; then
    [ "$created" = 0 ] || rm -f "$home/state/$MARKER_NAME"
    return 1
  fi
  if [ "$seq" = 0 ]; then
    printf 'fm-send: %s is idle, so the new work is held at %s; the watcher restarts it on a fresh context, then delivers the work to its inbox\n' "$id" "$file"
  else
    printf 'fm-send: %s is waiting for a fresh start, so this message is held at %s and reaches its inbox after the work held before it\n' "$id" "$file"
  fi
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

# Run the persist-first step. Returns 0 once the mate's correlated answer is in
# and every restart check passes; otherwise prints a deferral or a timeout and
# returns 1.
persist_gate() {  # <id> <meta> <home> <marker> [why]
  local id=$1 meta=$2 home=$3 marker=$4 why=${5:-} wait poll deadline corr reason resolved=0 now line
  wait=${FM_SECONDMATE_PERSIST_WAIT:-900}
  case "$wait" in '' | *[!0-9]*) wait=900 ;; esac
  poll=${FM_SECONDMATE_PERSIST_POLL:-5}
  case "$poll" in '' | *[!0-9]* | 0) poll=5 ;; esac
  if ! reason=$(blocked_reason "$id" "$meta" "$home" "$marker"); then
    defer "$id" "$reason"
    return 1
  fi
  if ! fm_secondmate_persist_send "$FM_HOME" "$STATE" "$id" "$why"; then
    defer "$id" "$FM_SECONDMATE_PERSIST_REASON"
    return 1
  fi
  corr=$FM_SECONDMATE_PERSIST_CORR
  deadline=$(($(date +%s) + wait))
  while :; do
    [ "$resolved" = 1 ] || ! fm_pending_reply_try_resolve "$STATE" "$corr" || resolved=1
    if [ "$resolved" = 1 ] && reason=$(blocked_reason "$id" "$meta" "$home" "$marker"); then
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      if [ "$resolved" = 1 ]; then
        defer "$id" "$reason"
        return 1
      fi
      fm_pending_reply_resolve_operator "$STATE" "$corr" "$id" fresh-session-persist-timeout >/dev/null 2>&1 || true
      # Withdraw this attempt's own unread request so it cannot block the next trigger.
      grep -l "corr=$corr" "$STATE/$id.inbox"/*.msg 2>/dev/null | while IFS= read -r msg; do rm -f "$msg"; done
      rm -f "$marker"
      line="timed out $id: it did not confirm within ${wait}s that its open work is written down ($corr), so it was not restarted"
      printf '%s\n' "$line"
      printf '%s %s\n' "$now" "$line" >> "$STATE/fresh-session.log"
      return 1
    fi
    [ $((deadline - now)) -ge "$poll" ] || poll=$((deadline - now))
    sleep "$poll"
  done
}

# Deliver held text through fm-send, oldest first. A send that fails keeps
# its file for the next sweep.
release_held() {  # <id> <held-dir>
  local f n=0
  for f in "$2"/*.msg; do
    [ -f "$f" ] || continue
    if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_HELD_RELEASE=1 \
      "$SCRIPT_DIR/fm-send.sh" "$1" --same-task "$(cat "$f")" >/dev/null 2>&1 </dev/null; then
      printf 'held %s: %s could not be delivered yet; the next sweep retries\n' "$1" "$f"
      return 0
    fi
    rm -f "$f"
    n=$((n + 1))
  done
  [ "$n" -eq 0 ] || printf 'released %s: %s held message(s) delivered to its inbox\n' "$1" "$n"
}

skip_fresh_start() {  # <id> <marker> <held-dir>
  [ ! -f "$2" ] || [ "$(marker_get "$2" source)" != new-task ] || rm -f "$2"
  release_held "$1" "$3"
}

held_expired() {  # <held-dir>
  local f oldest wait
  wait=${FM_SECONDMATE_PERSIST_WAIT:-900}
  case "$wait" in '' | *[!0-9]*) wait=900 ;; esac
  for f in "$1"/*.msg; do
    [ -f "$f" ] || continue
    oldest=${f##*/}
    oldest=${oldest%%-*}
    case "$oldest" in '' | *[!0-9]*) return 0 ;; esac
    [ $(($(date +%s) - oldest)) -ge "$wait" ]
    return
  done
  return 1
}

do_apply() {
  local id=${1:-} meta home marker held why reason out rc delivery note_path
  case "$id" in '' | *[!A-Za-z0-9._-]*) usage >&2; return 2 ;; esac
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
  held="$STATE/$id.fresh-held"
  { [ -f "$marker" ] && [ ! -L "$marker" ]; } || has_held "$held" || return 0

  # shellcheck source=bin/fm-secondmate-restart-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
  # shellcheck source=bin/fm-secondmate-persist-first-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-persist-first-lib.sh"
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$SCRIPT_DIR/fm-pending-reply-lib.sh"
  # shellcheck source=bin/fm-secondmate-liveness-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

  fm_secondmate_liveness_lock "$id" || { defer "$id" "another restart or recovery is in progress"; return 0; }
  # shellcheck disable=SC2064
  trap "fm_secondmate_liveness_unlock '$id'" RETURN

  if fresh_session_off || [ ! -f "$marker" ] || [ -L "$marker" ]; then
    release_held "$id" "$held"
    return 0
  fi
  if ! fm_secondmate_restart_capable "$meta"; then
    defer "$id" "$FM_SECONDMATE_RESTART_REASON"
    skip_fresh_start "$id" "$marker" "$held"
    return 0
  fi
  why=''
  ! has_held "$held" || why='new work is arriving for you and you will start it on a fresh conversation'
  if ! persist_gate "$id" "$meta" "$home" "$marker" "$why"; then
    if [ ! -f "$marker" ] || held_expired "$held"; then
      skip_fresh_start "$id" "$marker" "$held"
    fi
    return 0
  fi

  note_path="$home/$NOTE_REL"
  msource=$(sed -n 's/^source=//p' "$marker" | head -1)
  if [ -n "$why" ]; then
    relaunch_note="Fresh session for new work. Handover note: $note_path"
    steer_why="your conversation was dropped on purpose so you start new work on a fresh context, and the new work follows in your inbox"
  elif [ "$msource" = context ]; then
    relaunch_note="Fresh session after the context limit. Handover note: $note_path"
    steer_why="your conversation grew past the context limit and was dropped on purpose"
  else
    relaunch_note="Fresh session after finished work. Handover note: $note_path"
    steer_why="your conversation was dropped after a finished piece of work, on purpose"
  fi
  rc=0
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-control.sh" "$id" relaunch \
    --note "$relaunch_note" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    dismiss_exit_dialog "$id" "$meta"
    mv -f "$marker" "$marker.failed" 2>/dev/null || true
    printf 'failed %s: %s\n' "$id" "$(one_line "$out" 300)"
    release_held "$id" "$held"
    return 1
  fi
  rm -f "$marker"
  date +%s > "$home/state/fresh-session.restarted" 2>/dev/null || true
  delivery=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "$id" --fire-and-forget "$delivery" \
    "You are a fresh session: $steer_why. Read the handover note at $note_path, run bin/fm-session-start.sh, and reconcile from durable records. This is not a request; do not reply." >/dev/null 2>&1; then
    printf 'restarted %s: handover note %s\n' "$id" "$note_path"
  else
    printf 'restarted %s: handover note %s (the pointer steer could not be delivered)\n' "$id" "$note_path"
  fi
  release_held "$id" "$held"
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
  limit=${FM_SECONDMATE_CONTEXT_LIMIT:-150000}
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
  [ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set" >&2; return 2; }
  state="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  fresh_session_off || do_context_check
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=${meta##*/}
    id=${id%.meta}
    home=$(sed -n 's/^home=//p' "$meta" | head -1)
    [ -n "$home" ] || continue
    if fresh_session_off || [ ! -f "$home/state/$MARKER_NAME" ]; then
      has_held "$state/$id.fresh-held" || continue
    fi
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
  hold) shift; do_hold "$@" ;;
  apply) shift; do_apply "$@" ;;
  sweep) do_sweep ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
