#!/usr/bin/env bash
# Fork-only: fm-reply-first.sh - answer first, then dig (applypass fork).
#
# The latency report (2026-10-30) found the main firstmate ran more than three
# commands before replying on 55% of captain messages, and those replies were
# 85% of all waiting time. This hook counts the tool calls an agent makes after
# a message that expects an answer and, on the call after the third, refuses it
# once with "answer now with what you have, hand the rest off".
#
# usage:
#   <PreToolUse JSON on stdin> | fm-reply-first.sh pretool [--claude]
#   fm-reply-first.sh arm <captain-direct|firstmate> [--transcript <path>]
#   fm-reply-first.sh enabled
#
# arm      opens a reply window: the message arrived, no command has run, no
#          reply was seen. bin/fm-captain-direct.sh calls it for a message the
#          captain typed into the pane and for Firstmate traffic (the steering
#          doorbell or a [fm-from-firstmate] message). A new message replaces
#          the old window.
# pretool  runs on every tool call. While a window is open and unanswered it
#          counts the call. The call after the limit (default 3,
#          FM_REPLY_FIRST_LIMIT) is refused once (exit 2, the reason on
#          stderr) and the window closes, so later calls run normally.
# A reply closes the window early. Either of these counts:
#   - a Bash call that runs bin/fm-secondmate-report.sh (a status append to the
#     parent channel);
#   - assistant text of FM_REPLY_FIRST_MIN_CHARS (default 200, about a short
#     paragraph, so a line of narration such as "let me check" is not an answer) or more since the
#     window opened, read from the transcript the harness names in the payload.
# Only a call after a message that opened a window is ever refused, and the
# parent report call is never counted or refused.
#
# SWITCH. config/reply-first: "on" enables the hook in every home, "off"
# disables it everywhere, and absent (or "mates") enables it only in a secondmate
# home (a home with a .fm-secondmate-home marker). A main home stays off until
# its operator writes "on"; nothing else is needed to adopt it there.
#
# FILES. state/.reply-first holds the window as key=value lines (epoch, source,
# count, replied, fired, transcript, base); state/.reply-first.lock is a mkdir
# lock around each read-modify-write. The hook is silent and allows the call
# when anything is unreadable or not in scope: a broken hook never blocks work.
#
# Callers: bin/fm-mate-hooks-install.sh registers pretool in a secondmate's
# untracked .claude/settings.local.json; bin/fm-captain-direct.sh calls arm.
# docs/captain-direct-mate-access.md owns the operator view.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${CLAUDE_PROJECT_DIR:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
WINDOW="$STATE/.reply-first"
LOCK="$STATE/.reply-first.lock"
LIMIT=${FM_REPLY_FIRST_LIMIT:-3}
MIN_CHARS=${FM_REPLY_FIRST_MIN_CHARS:-200}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=3 ;; esac
case "$MIN_CHARS" in ''|*[!0-9]*) MIN_CHARS=200 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# 0 when the hook is on for this home.
enabled() {
  local mode=
  [ -d "$STATE" ] || return 1
  [ ! -f "$CONFIG/reply-first" ] || read -r mode < "$CONFIG/reply-first" 2>/dev/null || true
  case "$mode" in
    on) return 0 ;;
    off) return 1 ;;
  esac
  fm_root_is_secondmate_home "$FM_HOME"
}

lock_take() {
  local tries=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    # A lock left by a killed hook is stale after a minute.
    [ -z "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ] || rmdir "$LOCK" 2>/dev/null || true
    tries=$((tries + 1))
    [ "$tries" -le 60 ] || return 1
    sleep 0.05
  done
}
lock_drop() { rmdir "$LOCK" 2>/dev/null || true; }

win_get() {  # <key>
  [ -f "$WINDOW" ] || return 0
  sed -n "s/^$1=//p" "$WINDOW" | head -n 1
}

# Write the window from the current shell variables, atomically.
win_write() {
  local tmp
  tmp=$(mktemp "$WINDOW.XXXXXX") || return 1
  if printf 'epoch=%s\nsource=%s\ncount=%s\nreplied=%s\nfired=%s\ntranscript=%s\nbase=%s\n' \
    "$w_epoch" "$w_source" "$w_count" "$w_replied" "$w_fired" "$w_transcript" "$w_base" > "$tmp"; then
    mv -f "$tmp" "$WINDOW"
  else
    rm -f "$tmp"
    return 1
  fi
}

cmd_arm() {
  local source=${1:-} transcript=
  case "$source" in captain-direct|firstmate) ;; *) usage >&2; exit 2 ;; esac
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --transcript) transcript=${2:-}; shift 2 || break ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  enabled || exit 0
  w_base=0
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    w_base=$(wc -l < "$transcript" 2>/dev/null | tr -d ' ')
    case "$w_base" in ''|*[!0-9]*) w_base=0 ;; esac
  fi
  w_epoch=$(date +%s) w_source=$source w_count=0 w_replied=0 w_fired=0 w_transcript=$transcript
  lock_take || exit 0
  win_write
  lock_drop
}

# 0 when the assistant wrote MIN_CHARS or more of text after the window opened.
transcript_replied() {  # <path> <base>
  local path=$1 base=$2 longest
  [ -n "$path" ] && [ -f "$path" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  longest=$(tail -n "+$((base + 1))" "$path" 2>/dev/null | jq -R -r '
      fromjson? | select(type == "object" and .type == "assistant")
      | [.message.content[]? | select(.type == "text") | .text | gsub("^\\s+|\\s+$"; "") | length] | max // 0' 2>/dev/null \
    | sort -n | tail -n 1)
  case "$longest" in ''|*[!0-9]*) return 1 ;; esac
  [ "$longest" -ge "$MIN_CHARS" ]
}

cmd_pretool() {
  local payload command transcript
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  enabled || exit 0
  [ -f "$WINDOW" ] || exit 0
  command=$(printf '%s' "$payload" | jq -r '(.tool_input.command // .toolInput.command // empty)' 2>/dev/null) || exit 0
  transcript=$(printf '%s' "$payload" | jq -r '(.transcript_path // empty)' 2>/dev/null) || transcript=
  lock_take || exit 0
  w_epoch=$(win_get epoch) w_source=$(win_get source) w_count=$(win_get count)
  w_replied=$(win_get replied) w_fired=$(win_get fired) w_transcript=$(win_get transcript) w_base=$(win_get base)
  case "$w_count" in ''|*[!0-9]*) lock_drop; exit 0 ;; esac
  case "$w_base" in ''|*[!0-9]*) w_base=0 ;; esac
  if [ "$w_replied" = 1 ] || [ "$w_fired" = 1 ]; then
    lock_drop
    exit 0
  fi
  case "$command" in
    *fm-secondmate-report.sh*)
      w_replied=1
      win_write
      lock_drop
      exit 0
      ;;
  esac
  [ -n "$transcript" ] || transcript=$w_transcript
  if transcript_replied "$transcript" "$w_base"; then
    w_replied=1
    win_write
    lock_drop
    exit 0
  fi
  if [ "$w_count" -lt "$LIMIT" ]; then
    w_count=$((w_count + 1))
    win_write
    lock_drop
    exit 0
  fi
  w_fired=1
  win_write
  lock_drop
  local who="the captain's message"
  [ "$w_source" = captain-direct ] || who="the message from firstmate"
  local reason="[reply-first] You have run $LIMIT commands since $who and have not answered yet. This call was not run. Answer now, in plain words, with what you have so far, and hand the rest off: name what is still open and who or what will do it (a status line to the parent with bin/fm-secondmate-report.sh, or a crewmate). Dig further only after the answer is out."
  local escaped
  escaped=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  exit 2
}

case "${1:-}" in
  pretool) shift; cmd_pretool "$@" ;;
  arm) shift; cmd_arm "$@" ;;
  enabled) enabled; exit $? ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
