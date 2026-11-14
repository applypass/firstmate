# shellcheck shell=bash disable=SC2034
# Fork-only (applypass): plain-shell detection of an agent stopped by a dropped
# connection, the usual sign of a laptop sleep or a network drop. Sourced by
# bin/fm-usage-limit-tick.sh. No state is read or written here.
#
# fm_sleep_resume_detect <screen-text>
#   Sets FM_SR_STOPPED to 1 when the bottom of the screen shows a connection error
#   above an idle prompt, else 0, and FM_SR_SHAPE to the matched marker.
#
# A stop needs all three: a connection-error line in the last FM_SR_TAIL_LINES
# non-blank lines, an idle prompt after it, and no working indicator after it
# (a retry countdown, "esc to interrupt", or a spinner line). Lines with quotes
# or backticks never count (a double quote or backtick; the API's own message has
# an apostrophe), so a command or code that names a marker is ignored.

set -u

FM_SR_TAIL_LINES=${FM_SR_TAIL_LINES:-15}
FM_SR_MARKER_RE="Your computer went to sleep|Can't reach the API server|Unable to connect to API|check your internet or DNS|ENOTFOUND|ETIMEDOUT|ECONNRESET|ECONNREFUSED|EAI_AGAIN|Connection close|Request timed out"
FM_SR_WORKING_RE='Retrying in|esc to interrupt|[A-Za-z]+(…|\.\.\.) \('
FM_SR_PROMPT_RE='^[[:space:]]*(❯|›|>)([[:space:]]|$)'

fm_sleep_resume_detect() {
  local text=$1 line marker='' after=0 prompt=0 working=0
  FM_SR_STOPPED=0 FM_SR_SHAPE=""
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -qE "$FM_SR_MARKER_RE" \
      && ! printf '%s' "$line" | grep -q "[\"\`]"; then
      marker=$(printf '%s' "$line" | grep -oE "$FM_SR_MARKER_RE" | head -n 1)
      after=1 prompt=0 working=0
      continue
    fi
    [ "$after" = 1 ] || continue
    printf '%s' "$line" | grep -qE "$FM_SR_PROMPT_RE" && prompt=1
    printf '%s' "$line" | grep -qE "$FM_SR_WORKING_RE" && working=1
  done < <(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n "$FM_SR_TAIL_LINES")
  if [ -n "$marker" ] && [ "$prompt" = 1 ] && [ "$working" = 0 ]; then
    FM_SR_STOPPED=1 FM_SR_SHAPE=$marker
  fi
  return 0
}
