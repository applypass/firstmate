#!/usr/bin/env bash
# fm-decide.sh - the only writer of data/decided.md; every decision lands on a Shortcut story (applypass fork).
#
# Usage: fm-decide.sh record <key> <text> [--story sc-NNNN] [--item <task-id>] [--best-effort]
#        fm-decide.sh record <key> --file <file> [...]
#        fm-decide.sh audit                       list entries with no Shortcut stamp
#        fm-decide.sh guard-hook                  PreToolUse hook: block direct writes to data/decided.md
#        fm-decide.sh guard-line                  print the settings.local.json hook that installs the guard
#
# record resolves the story, comments the decision on it, and only then appends
#   - [<key>] YYYY-MM-DD <text> (shortcut: sc-NNNN <url>)
# to $FM_HOME/data/decided.md (temp file plus rename, under a lock). The story is
# --story, else the story --item's backlog body names, else a new Engineering/
# Backlog chore story filed through bin/fm-shortcut-ticket.sh (its settings, token
# path, and API base; nothing is duplicated here). A story the item does not own
# is only commented on, never moved or edited. If the comment fails nothing is
# recorded; a decision is never recorded without a story. Recording the same key
# and exact text again is a no-op; other text under a recorded key is refused.
# --best-effort turns a refusal into a warning, which is how
# bin/fm-captain-hold.sh answer calls it, keyed <task-id>-<answer occurrence>.
#
# Guard: add the line `guard-line` prints to the home's untracked
# .claude/settings.local.json (never the shared .claude/settings.json); record
# warns with that instruction while it is missing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DECIDED="$DATA/decided.md"
TICKET="$SCRIPT_DIR/fm-shortcut-ticket.sh"
BEST_EFFORT=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  if [ "$BEST_EFFORT" = 1 ]; then
    printf 'fm-decide: warning: %s\n' "$*" >&2
    exit 0
  fi
  printf 'fm-decide: %s\n' "$*" >&2
  exit 1
}

ticket() {  # passes the home through to the Shortcut script
  FM_HOME=$FM_HOME FM_DATA_OVERRIDE=$DATA "$TICKET" "$@"
}

guard_command() { printf "'%s' guard-hook" "$SCRIPT_DIR/fm-decide.sh"; }

guard_line() {
  jq -n --arg c "$(guard_command)" \
    '{hooks: {PreToolUse: [{matcher: "Write|Edit|MultiEdit|NotebookEdit|Bash", hooks: [{type: "command", command: $c}]}]}}'
}

guard_installed() {
  local f="$FM_HOME/.claude/settings.local.json"
  [ -f "$f" ] && jq -e --arg c "fm-decide.sh' guard-hook" \
    '[.hooks.PreToolUse[]?.hooks[]?.command // empty | contains($c)] | any' "$f" >/dev/null 2>&1
}

command_audit() {
  [ -f "$DECIDED" ] || { echo "no $DECIDED"; return 0; }
  local out
  out=$(grep -E '^- \[' "$DECIDED" | grep -Ev '\(shortcut: sc-[0-9]+' || true)
  [ -z "$out" ] || printf '%s\n' "$out"
  [ -z "$out" ]
}

guard_segments() {  # one shell segment per line; quoted words dropped from fm-decide.sh calls
  FM_CMD=$1 awk 'BEGIN {
    s = ENVIRON["FM_CMD"] "\n"; q = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q != "") {
        if (c == q) q = ""
        else if (c == "\\" && q == "\"") { raw = raw c; c = substr(s, ++i, 1) }
        raw = raw c; continue
      }
      if (c == "\\") { c = c substr(s, ++i, 1); raw = raw c; bare = bare c; continue }
      if (c == "\"" || c == "\047") { q = c; raw = raw c; continue }
      if (c ~ /[;|&\n]/) {
        n = split(raw, w, /[[:space:]]+/); k = 1
        while (k <= n && (w[k] == "" || w[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) k++
        f = w[k]; gsub(/["\047]/, "", f)
        print (f ~ /fm-decide\.sh$/ ? bare : raw)
        raw = ""; bare = ""; continue
      }
      raw = raw c; bare = bare c
    }
  }'
}

command_guard_hook() {
  local input path cmd
  input=$(cat)
  path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  case "$path" in
    */data/decided.md | data/decided.md) block=1 ;;
    *) block=0 ;;
  esac
  if [ "$block" = 0 ] && [ -n "$cmd" ]; then
    guard_segments "$cmd" | grep -Eq '>[[:space:]]*[^[:space:]|;&]*decided\.md|(^|[[:space:];|&(])(tee|mv|cp|rm|truncate|(sed|perl)[[:space:]]+-i[^[:space:]]*)[[:space:]][^|;&]*decided\.md' && block=1
  fi
  [ "$block" = 0 ] && exit 0
  printf 'data/decided.md is written only by bin/fm-decide.sh record <key> <text> [--story sc-NNNN], which also posts the decision to Shortcut.\n' >&2
  exit 2
}

LOCKDIR=''
take_lock() {
  local i=0
  mkdir -p "$DATA" || die "cannot create $DATA"
  LOCKDIR="$DATA/.decided.lock"
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -le 2400 ] || die "another fm-decide has held $LOCKDIR for 2 minutes"
    sleep 0.05
  done
  trap 'rmdir "$LOCKDIR" 2>/dev/null; [ -z "${TMPENTRY:-}" ] || rm -f "$TMPENTRY"' EXIT
}

command_record() {
  local key=${1:-} text='' story='' item='' file='' url='' line=''
  [ -n "$key" ] || die "usage: record <key> <text> [--story sc-NNNN] [--item <task-id>]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --story) story=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]'); shift ;;
      --item) item=${2:-}; shift ;;
      --file) file=${2:-}; shift ;;
      *) text=$1 ;;
    esac
    shift
  done
  case "$key" in *[!A-Za-z0-9._-]*) die "key must be a slug (letters, digits, . _ -)" ;; esac
  if [ -n "$file" ]; then
    [ -f "$file" ] || die "no such decision file: $file"
    text=$(cat "$file")
  fi
  text=$(printf '%s' "$text" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
  [ -n "$text" ] || die "the decision text is empty"
  [ -z "$story" ] || case "${story#sc-}" in "$story" | '' | *[!0-9]*) die "--story takes sc-NNNN" ;; esac
  command -v jq >/dev/null 2>&1 || die "jq is required"
  "$TICKET" --enabled || die "Shortcut ticket sync is off in this home, so a decision cannot be given a story; turn it on (see docs/configuration.md)"

  take_lock
  if [ -f "$DECIDED" ]; then
    case $(FM_KEY=$key FM_TEXT=$text awk '
      BEGIN { p = "- [" ENVIRON["FM_KEY"] "] "; t = ENVIRON["FM_TEXT"] " (shortcut: sc-" }
      index($0, p) == 1 {
        seen = 1; r = substr($0, length(p) + 12)
        if (index(r, t) == 1 && substr(r, length(t) + 1) ~ /^[0-9]+ [^ ]*\)$/) same = 1
      }
      END { print same ? "same" : seen ? "other" : "" }' "$DECIDED") in
      same) return 0 ;;
      other) die "a decision with key '$key' is already recorded with different text; use a new key" ;;
    esac
  fi

  if [ -z "$story" ] && [ -n "$item" ]; then
    story=$(ticket --linked "$item" 2>/dev/null || true)
  fi
  if [ -z "$story" ]; then
    local created
    created=$(ticket chore "Decision: $key" "Captain decision $key: $text") || die "could not file a chore story for decision $key"
    story=${created%% *}
    url=${created#* }
  fi
  local comment_url
  comment_url=$(ticket comment "$story" "Captain decision [$key]: $text" --print-url) ||
    die "could not post decision $key to $story; nothing was recorded"
  [ -n "$url" ] || url="https://app.shortcut.com/applypass/story/${story#sc-}"
  [ -z "$comment_url" ] || url=$comment_url

  line="- [$key] ${FM_DECIDE_DATE:-$(date +%F)} $text (shortcut: $story $url)"
  TMPENTRY=$(mktemp "$DATA/.decided.XXXXXX") || die "cannot create a temp file in $DATA"
  { [ ! -f "$DECIDED" ] || cat "$DECIDED"; printf '%s\n' "$line"; } >"$TMPENTRY"
  mv "$TMPENTRY" "$DECIDED" || die "posted to $story but could not write $DECIDED; re-run to record it"
  TMPENTRY=''
  printf 'fm-decide: recorded %s on %s\n' "$key" "$story"
  guard_installed || printf 'fm-decide: warning: direct writes to data/decided.md are not blocked here; add this to %s/.claude/settings.local.json (merge into its "hooks"):\n%s\n' "$FM_HOME" "$(guard_line)" >&2
}

ARGS=()
for arg in "$@"; do
  if [ "$arg" = --best-effort ]; then BEST_EFFORT=1; else ARGS+=("$arg"); fi
done
set -- ${ARGS[@]+"${ARGS[@]}"}

case "${1:-}" in
  record) shift; command_record "$@" ;;
  audit) command_audit ;;
  guard-hook) command_guard_hook ;;
  guard-line) guard_line ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
