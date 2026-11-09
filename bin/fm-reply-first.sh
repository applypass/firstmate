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
#   <UserPromptSubmit JSON on stdin> | fm-reply-first.sh prompt [--claude]
#   fm-reply-first.sh arm [--transcript <path>]
#   fm-reply-first.sh clear
#   fm-reply-first.sh enabled
#
# prompt   the main home's prompt hook: opens a window for a message the
#          captain typed and closes any window for every other prompt (a Stop
#          hook wake, a task notification, the steering or operational-input
#          doorbell, an away-supervisor injection). A second mate home gets the
#          same decision from bin/fm-captain-direct.sh instead.
# arm      opens a reply window: the message arrived, no command has run, no
#          reply was seen. bin/fm-captain-direct.sh calls it for a message the
#          captain typed into the pane. A new message replaces the old window.
# clear    closes the window. bin/fm-captain-direct.sh calls it for every
#          other prompt (Firstmate traffic, operational input, a harness
#          notification): each new prompt ends the turn that answered the
#          captain, and routed work is not a question to answer first.
# pretool  runs on every tool call. While a window is open and unanswered it
#          counts the call. The call after the limit (default 3,
#          FM_REPLY_FIRST_LIMIT) is refused once (exit 2, the reason on
#          stderr) and the window closes, so later calls run normally.
# A reply closes the window early. Either of these counts:
#   - a Bash call that runs bin/fm-secondmate-report.sh (a status append to the
#     parent channel);
#   - assistant text since the window opened, read from the transcript the
#     harness names in the payload, that is FM_REPLY_FIRST_MIN_CHARS (default
#     200, about a short paragraph) or longer, or that addresses the captain:
#     "captain" (any case) as a word of its own, not part of a name or path
#     such as fm-captain-hold.sh, set off by a comma before it or by , . ! ? : ;
#     or the end of the text after it. So "Captain, shipshape." and "Aye,
#     captain - done." count, and "let me see what the captain asked" does not.
# Only a call after a message that opened a window is ever refused, and the
# parent report call is never counted or refused. Neither is a command that
# hands work off (fm-send.sh, fm-spawn.sh, fm-dispatch-resolve.sh, fm-brief.sh):
# the answer-now message asks for exactly those.
#
# SCOPE. A secondmate home (a .fm-secondmate-home marker) and the primary
# firstmate home. A main home closes its window on the Stop hook too, so a wake
# turn that follows a captain turn is never counted against it. A home turns it
# off with the word "off" in config/reply-first.
#
# FILES. state/.reply-first holds the window as key=value lines (epoch, count,
# replied, fired, transcript, base); state/.reply-first.lock is a mkdir
# lock around each read-modify-write. The hook is silent and allows the call
# when anything is unreadable or not in scope: a broken hook never blocks work.
#
# Callers: bin/fm-mate-hooks-install.sh registers pretool in a secondmate's
# untracked .claude/settings.local.json (and, with --main, prompt, pretool, and a
# Stop clear in the primary home's, which bin/fm-session-start.sh runs);
# bin/fm-captain-direct.sh calls arm and clear for a mate.
# docs/captain-direct-mate-access.md owns the operator view.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${CLAUDE_PROJECT_DIR:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
WINDOW="$STATE/.reply-first"
SEEN="$STATE/.reply-first-seen"
LOCK="$STATE/.reply-first.lock"
LIMIT=${FM_REPLY_FIRST_LIMIT:-3}
MIN_CHARS=${FM_REPLY_FIRST_MIN_CHARS:-200}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=3 ;; esac
case "$MIN_CHARS" in ''|*[!0-9]*) MIN_CHARS=200 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# 0 when the hook is on for this home.
enabled() {
  [ -d "$STATE" ] || return 1
  [ -f "$CONFIG/reply-first" ] && [ "$(tr -d '[:space:]' < "$CONFIG/reply-first")" = off ] && return 1
  fm_root_is_secondmate_home "$FM_HOME" || fm_primary_root_matches "$FM_HOME"
}

# 0 when the prompt text came from a person at the keyboard.
text_is_captain() {  # <trimmed prompt text>
  local text=$1
  [ -n "$text" ] || return 1
  case "$text" in
    /*) return 1 ;;
    '<task-notification>'*|'<system-reminder>'*|'Stop hook feedback'*|'firstmate watcher '*) return 1 ;;
    ': Firstmate instruction waiting:'*|'[fm-from-firstmate]'*|*$'\xE2\x81\xA3''[fm-from-firstmate]'*) return 1 ;;
  esac
  printf '%s' "$text" | "$SCRIPT_DIR/fm-operational-input.sh" classify >/dev/null 2>&1 && return 1
  printf '%s' "$text" | FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-operational-input.sh" doorbell-kind >/dev/null 2>&1 && return 1
  return 0
}

# 0 when a segment of the shell command runs one of the named scripts: its
# first word, unquoted, after any VAR=value assignments and a bash, sh, env, or
# timeout N wrapper, split at ; & | and newlines.
command_runs() {  # <command> <script name>...
  local cmd=$1 seg word name words skip
  shift
  cmd=${cmd//[;&|]/$'\n'}
  while IFS= read -r seg; do
    read -r -a words <<< "$seg" || true
    skip=0
    for word in "${words[@]+"${words[@]}"}"; do
      [ "$skip" = 1 ] && { skip=0; continue; }
      word=${word#[\"\']}
      word=${word%[\"\']}
      case "$word" in
        [A-Za-z_]*=*|bash|sh|env) continue ;;
        timeout) skip=1; continue ;;
      esac
      for name in "$@"; do
        [ "${word##*/}" = "$name" ] && return 0
      done
      break
    done
  done <<< "$cmd"
  return 1
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

cmd_clear() {
  enabled || exit 0
  lock_take || exit 0
  rm -f "$WINDOW"
  lock_drop
}

win_get() {  # <key>
  [ -f "$WINDOW" ] || return 0
  sed -n "s/^$1=//p" "$WINDOW" | head -n 1
}

# Write the window from the current shell variables, atomically.
win_write() {
  local tmp
  tmp=$(mktemp "$WINDOW.XXXXXX") || return 1
  if printf 'epoch=%s\ncount=%s\nreplied=%s\nfired=%s\ntranscript=%s\nbase=%s\nlookups=%s\noverride=%s\n' \
    "$w_epoch" "$w_count" "$w_replied" "$w_fired" "$w_transcript" "$w_base" "${w_lookups:-0}" "${w_override:-0}" > "$tmp"; then
    mv -f "$tmp" "$WINDOW"
  else
    rm -f "$tmp"
    return 1
  fi
}

cmd_arm() {
  local transcript='' text=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --transcript) transcript=${2:-}; shift 2 || break ;;
      --text) text=${2:-}; shift 2 || break ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  enabled || exit 0
  w_base=0
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    w_base=$(wc -l < "$transcript" 2>/dev/null | tr -d ' ')
    case "$w_base" in ''|*[!0-9]*) w_base=0 ;; esac
  fi
  w_epoch=$(date +%s) w_count=0 w_replied=0 w_fired=0 w_transcript=$transcript
  w_lookups=0 w_override=0
  text_overrides "$text" && w_override=1
  lock_take || exit 0
  win_write
  [ -z "$transcript" ] || seen_write "$transcript" "$w_base"
  lock_drop
}

# 0 when a captain message asks main to dig itself (the fixed phrase set in the
# header). bin/fm-main-orchestration-guard.sh reads the flag this sets.
text_overrides() {  # <text>
  local lower
  lower=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *"look yourself"*|*"look it up yourself"*|*"look at it yourself"*|*"check yourself"*|*"check it yourself"*|*"dig yourself"*|*"dig in yourself"*) return 0 ;;
  esac
  return 1
}

seen_write() {  # <transcript> <line>
  if printf 'transcript=%s\nline=%s\n' "$1" "$2" > "$SEEN.tmp.$$"; then
    mv -f "$SEEN.tmp.$$" "$SEEN"
  else
    rm -f "$SEEN.tmp.$$"
  fi
}

# Text of one queued_command attachment line the captain sent mid-turn, empty
# for any other line. The prompt is a string, or a list of blocks whose text
# blocks are joined.
midturn_text() {  # <json line>
  printf '%s' "$1" | jq -r '
    select(type == "object" and .type == "attachment" and .attachment.type == "queued_command" and (.attachment.origin.kind // "") == "human")
    | .attachment.prompt
    | if type == "array" then [.[] | select(type == "object" and .type == "text") | .text] | join("\n") else tostring end' 2>/dev/null
}

# Scan the transcript lines written since the last scan. The newest queued_command
# the captain sent opens a fresh window exactly as arm does, based at that line.
# The first sight of a transcript only records its end. A message is scanned once,
# so it never re-arms. Callers: pretool (every call) and bin/fm-main-orchestration-guard.sh.
cmd_midturn() {
  local transcript=${1:-} total seen_path seen_line cand n json text last_n=0 last_text=
  enabled || return 0
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  lock_take || return 0
  total=$(wc -l < "$transcript" 2>/dev/null | tr -d ' ')
  case "$total" in ''|*[!0-9]*) lock_drop; return 0 ;; esac
  seen_path=$(sed -n 's/^transcript=//p' "$SEEN" 2>/dev/null | head -n 1)
  seen_line=$(sed -n 's/^line=//p' "$SEEN" 2>/dev/null | head -n 1)
  case "$seen_line" in ''|*[!0-9]*) seen_path= ;; esac
  if [ "$seen_path" != "$transcript" ] || [ "$total" -lt "$seen_line" ]; then
    seen_write "$transcript" "$total"
    lock_drop
    return 0
  fi
  if [ "$total" -eq "$seen_line" ]; then lock_drop; return 0; fi
  cand=$(sed -n "$((seen_line + 1)),${total}p" "$transcript" | grep -n -F '"queued_command"' | grep -F '"human"')
  while IFS= read -r cand_line; do
    [ -n "$cand_line" ] || continue
    n=${cand_line%%:*}
    json=${cand_line#*:}
    text=$(midturn_text "$json")
    text=${text#"${text%%[![:space:]]*}"}
    text=${text%"${text##*[![:space:]]}"}
    if text_is_captain "$text"; then last_n=$n last_text=$text; fi
  done <<< "$cand"
  seen_write "$transcript" "$total"
  if [ "$last_n" -gt 0 ]; then
    w_epoch=$(date +%s) w_count=0 w_replied=0 w_fired=0 w_transcript=$transcript w_base=$((seen_line + last_n))
    w_lookups=0 w_override=0
    text_overrides "$last_text" && w_override=1
    win_write
  fi
  lock_drop
}

# 0 when the assistant wrote MIN_CHARS or more of text after the window opened,
# or text that addresses the captain (see the header for the rule).
transcript_replied() {  # <path> <base>
  local path=$1 base=$2 longest
  [ -n "$path" ] && [ -f "$path" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  longest=$(tail -n "+$((base + 1))" "$path" 2>/dev/null | jq -R -r '
      fromjson? | select(type == "object" and .type == "assistant")
      | [.message.content[]? | select(.type == "text") | .text | gsub("^\\s+|\\s+$"; "") | if test("(^|[^\\w./-])captain(?![\\w/-]|\\.\\w)\\s*([,!?:;]|\\.(?!\\w)|$)|,\\s*captain(?![\\w/-]|\\.\\w)"; "i") then 1000000 + length else length end] | max // 0' 2>/dev/null \
    | sort -n | tail -n 1)
  case "$longest" in ''|*[!0-9]*) return 1 ;; esac
  [ "$longest" -ge "$MIN_CHARS" ] || [ "$longest" -ge 1000000 ]
}

cmd_prompt() {
  local payload parsed transcript text
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  fm_hook_payload_is_foreign_host "$payload" && exit 0
  enabled || exit 0
  parsed=$(printf '%s' "$payload" | jq -r '
    if type != "object" or ((.hook_event_name // "UserPromptSubmit") != "UserPromptSubmit") then empty
    else [((.transcript_path // "") | tostring), ((.prompt // "") | tostring)] | "\(.[0])\n\(.[1])" end' 2>/dev/null) || exit 0
  [ -n "$parsed" ] || exit 0
  transcript=$(printf '%s\n' "$parsed" | sed -n '1p')
  text=$(printf '%s\n' "$parsed" | sed '1d')
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  case "$text" in '<task-notification>'*) exit 0 ;; esac
  if text_is_captain "$text"; then
    if [ -n "$transcript" ]; then cmd_arm --transcript "$transcript" --text "$text"; else cmd_arm --text "$text"; fi
  else
    cmd_clear
  fi
  exit 0
}

# lookup [--peek]: the quick-lookup count and the override flag of the open
# window, printed as "<count> <override> <epoch>"; "0 0 -" with no window. Without
# --peek it counts one more lookup first. bin/fm-main-orchestration-guard.sh calls it.
cmd_lookup() {
  local peek=0
  [ "${1:-}" != --peek ] || peek=1
  if ! enabled || [ ! -f "$WINDOW" ]; then echo "0 0 -"; return 0; fi
  lock_take || { echo "0 0 -"; return 0; }
  if [ ! -f "$WINDOW" ]; then lock_drop; echo "0 0 -"; return 0; fi
  w_epoch=$(win_get epoch) w_count=$(win_get count)
  w_replied=$(win_get replied) w_fired=$(win_get fired) w_transcript=$(win_get transcript) w_base=$(win_get base)
  w_lookups=$(win_get lookups) w_override=$(win_get override)
  case "$w_lookups" in ''|*[!0-9]*) w_lookups=0 ;; esac
  case "$w_override" in 1) ;; *) w_override=0 ;; esac
  if [ "$peek" = 0 ]; then
    w_lookups=$((w_lookups + 1))
    win_write
  fi
  lock_drop
  echo "$w_lookups $w_override $w_epoch"
}

cmd_pretool() {
  local payload command transcript
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  enabled || exit 0
  command=$(printf '%s' "$payload" | jq -r '(.tool_input.command // .toolInput.command // empty)' 2>/dev/null) || exit 0
  transcript=$(printf '%s' "$payload" | jq -r '(.transcript_path // empty)' 2>/dev/null) || transcript=
  cmd_midturn "$transcript"
  [ -f "$WINDOW" ] || exit 0
  lock_take || exit 0
  w_epoch=$(win_get epoch) w_count=$(win_get count)
  w_replied=$(win_get replied) w_fired=$(win_get fired) w_transcript=$(win_get transcript) w_base=$(win_get base)
  w_lookups=$(win_get lookups) w_override=$(win_get override)
  case "$w_count" in ''|*[!0-9]*) lock_drop; exit 0 ;; esac
  case "$w_base" in ''|*[!0-9]*) w_base=0 ;; esac
  if [ "$w_replied" = 1 ] || [ "$w_fired" = 1 ]; then
    lock_drop
    exit 0
  fi
  if command_runs "$command" fm-send.sh fm-spawn.sh fm-dispatch-resolve.sh fm-brief.sh; then
    lock_drop
    exit 0
  fi
  if command_runs "$command" fm-secondmate-report.sh; then
    w_replied=1
    win_write
    lock_drop
    exit 0
  fi
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
  # The harness writes an assistant message to the transcript a moment after its
  # tool calls start, so text that came with this call may not be there yet. Look
  # again for up to two seconds before refusing; the refusal path is rare.
  lock_drop
  local waited=0 replied_late=0
  while [ "$waited" -lt 10 ]; do
    sleep 0.2
    waited=$((waited + 1))
    if transcript_replied "$transcript" "$w_base"; then replied_late=1; break; fi
  done
  lock_take || exit 0
  # A parallel call may have closed or fired the window while this one waited.
  if [ "$(win_get replied)" = 1 ] || [ "$(win_get fired)" = 1 ]; then
    lock_drop
    exit 0
  fi
  if [ "$replied_late" = 1 ]; then
    w_replied=1
    win_write
    lock_drop
    exit 0
  fi
  w_fired=1
  win_write
  lock_drop
  local handoff="a worker or second mate (bin/fm-spawn.sh or bin/fm-send.sh, run in the background)"
  fm_root_is_secondmate_home "$FM_HOME" && handoff="a status line to the parent with bin/fm-secondmate-report.sh, or a crewmate"
  local reason="[reply-first] You have run $LIMIT commands since the captain's message and have not answered yet. This call was not run. Answer now, in plain words, with what you have so far, and hand the rest off: name what is still open and who or what will do it ($handoff). Dig further only after the answer is out."
  local escaped
  escaped=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  exit 2
}

case "${1:-}" in
  pretool) shift; cmd_pretool "$@" ;;
  midturn) shift; cmd_midturn "$@"; exit 0 ;;
  lookup) shift; cmd_lookup "$@"; exit 0 ;;
  prompt) shift; cmd_prompt "$@" ;;
  arm) shift; cmd_arm "$@" ;;
  clear) cmd_clear ;;
  enabled) enabled; exit $? ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
