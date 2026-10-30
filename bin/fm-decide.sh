#!/usr/bin/env bash
# fm-decide.sh - the only writer of data/decided.md; every decision lands on a Shortcut story (applypass fork).
#
# Usage: fm-decide.sh record <key> <text> [--story sc-NNNN] [--item <task-id>] [--best-effort]
#        fm-decide.sh record <key> --file <file> [...]
#        fm-decide.sh sync [<key>]                post entries still waiting for Shortcut, now
#        fm-decide.sh audit                       list entries with no Shortcut stamp
#        fm-decide.sh guard-hook                  PreToolUse hook: block direct writes to data/decided.md
#        fm-decide.sh guard-line                  print the settings.local.json hook that installs the guard
#
# record first appends the entry to $FM_HOME/data/decided.md (temp file plus
# rename, under a lock) and returns; a detached job then resolves the story,
# comments the decision on it, and rewrites the entry's stamp
#   - [<key>] YYYY-MM-DD <text> (shortcut: pending)            written at once
#   - [<key>] YYYY-MM-DD <text> (shortcut: pending sc-NNNN)    story known, comment not yet posted
#   - [<key>] YYYY-MM-DD <text> (shortcut: sc-NNNN <url>)      posted
# The job retries a failed call FM_DECIDE_SYNC_ATTEMPTS times (default 4) with
# FM_DECIDE_SYNC_DELAY seconds (default 10) tripled between tries. After the last
# failure it queues one note for the primary (bin/fm-inbox.sh, request id
# fm-decide-sync-<key>), presented at its next drain; `sync` then retries by hand.
# `audit` lists pending entries too. Only one run posts a key at a time: a run
# that finds the key's sync lock held by a live process skips that key. The
# story is --story, else the story --item's backlog body names,
# else a new Engineering/Backlog chore story filed through bin/fm-shortcut-ticket.sh (its settings, token
# path, and API base; nothing is duplicated here). A story the item does not own
# is only commented on, never moved or edited. Recording the same key and exact
# text again is a no-op (pending or posted); other text under a recorded key is
# refused.
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

guard_segments() {  # one shell segment per line; quoted arguments dropped from fm-decide.sh calls
  FM_CMD=$1 awk 'BEGIN {
    s = ENVIRON["FM_CMD"] "\n"; q = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q != "") {
        if (c == q) q = ""
        else if (c == "\\" && q == "\"") { raw = raw c; c = substr(s, ++i, 1) }
        raw = raw c; if (keep) bare = bare c
        continue
      }
      if (c == "\\") { c = c substr(s, ++i, 1); raw = raw c; bare = bare c; continue }
      if (c == "\"" || c == "\047") { q = c; keep = bare ~ />[[:space:]]*$/; raw = raw c; if (keep) bare = bare c; continue }
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
SYNCLOCK=''
TMPENTRY=''
cleanup() {
  [ -z "$LOCKDIR" ] || rmdir "$LOCKDIR" 2>/dev/null
  [ -z "$SYNCLOCK" ] || rm -rf "$SYNCLOCK"
  [ -z "$TMPENTRY" ] || rm -f "$TMPENTRY"
}
trap cleanup EXIT

take_lock() {
  local i=0
  mkdir -p "$DATA" || die "cannot create $DATA"
  LOCKDIR="$DATA/.decided.lock"
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -le 2400 ] || die "another fm-decide has held $LOCKDIR for 2 minutes"
    sleep 0.05
  done
}

release_lock() {
  [ -z "$LOCKDIR" ] || rmdir "$LOCKDIR" 2>/dev/null
  LOCKDIR=''
}

# pending_entry <key>: the entry's line when it still waits for Shortcut.
pending_entry() {
  [ -f "$DECIDED" ] || return 0
  FM_KEY=$1 awk '
    BEGIN { p = "- [" ENVIRON["FM_KEY"] "] " }
    index($0, p) == 1 && $0 ~ / \(shortcut: pending( sc-[0-9]+)?\)$/ { print; exit }
  ' "$DECIDED"
}

# pending_keys: the key of every entry still waiting for Shortcut.
pending_keys() {
  [ -f "$DECIDED" ] || return 0
  awk '/^- \[[A-Za-z0-9._-]+\] .* \(shortcut: pending( sc-[0-9]+)?\)$/ { k = $0; sub(/^- \[/, "", k); sub(/\].*/, "", k); print k }' "$DECIDED"
}

# set_stamp <key> <stamp>: swap a pending entry's stamp, under the lock.
set_stamp() {
  take_lock
  TMPENTRY=$(mktemp "$DATA/.decided.XXXXXX") || die "cannot create a temp file in $DATA"
  FM_KEY=$1 FM_STAMP=$2 awk '
    BEGIN { p = "- [" ENVIRON["FM_KEY"] "] " }
    index($0, p) == 1 && $0 ~ / \(shortcut: pending( sc-[0-9]+)?\)$/ {
      sub(/ \(shortcut: pending( sc-[0-9]+)?\)$/, " (shortcut: " ENVIRON["FM_STAMP"] ")")
    }
    { print }
  ' "$DECIDED" >"$TMPENTRY"
  if ! mv "$TMPENTRY" "$DECIDED"; then
    rm -f "$TMPENTRY"
    TMPENTRY=''
    release_lock
    return 1
  fi
  TMPENTRY=''
  release_lock
}

# sync_once <key>: one try at posting a pending entry. 0 when it is posted (or
# was never pending), 1 when a Shortcut call failed.
sync_once() {
  local key=$1 entry story text url created comment_url
  entry=$(pending_entry "$key")
  [ -n "$entry" ] || return 0
  story=$(printf '%s' "$entry" | sed -n 's/.* (shortcut: pending \(sc-[0-9]*\))$/\1/p')
  text=${entry#"- [$key] "}
  text=${text:11}
  text=${text% (shortcut: pending*}
  url=''
  if [ -z "$story" ]; then
    created=$(ticket chore "Decision: $key" "Captain decision $key: $text") || return 1
    story=${created%% *}
    url=${created#* }
    set_stamp "$key" "pending $story" || return 1
  fi
  comment_url=$(ticket comment "$story" "Captain decision [$key]: $text" --print-url) || return 1
  [ -n "$url" ] || url="https://app.shortcut.com/applypass/story/${story#sc-}"
  [ -z "$comment_url" ] || url=$comment_url
  set_stamp "$key" "$story $url"
}

# take_sync_lock <key>: the key's sync lock, so one run posts it at a time. A
# lock whose holder is gone is taken over. Nonzero while a live run holds it.
take_sync_lock() {
  local lock="$DATA/.decided-sync.$1.lock" pid
  if ! mkdir "$lock" 2>/dev/null; then
    pid=$(cat "$lock/pid" 2>/dev/null)
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    ! kill -0 "$pid" 2>/dev/null || return 1
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || return 1
  fi
  SYNCLOCK=$lock
  printf '%s\n' "$$" >"$lock/pid"
}

release_sync_lock() {
  [ -z "$SYNCLOCK" ] || rm -rf "$SYNCLOCK"
  SYNCLOCK=''
}

# sync_key <key>: sync_once under the key's sync lock, with bounded retries; one
# note for the primary when the last try fails.
sync_key() {
  local key=$1 attempts=${FM_DECIDE_SYNC_ATTEMPTS:-4} delay=${FM_DECIDE_SYNC_DELAY:-10} i=1 rc
  while :; do
    if ! take_sync_lock "$key"; then
      printf 'fm-decide: another run is posting %s; skipped\n' "$key"
      return 0
    fi
    sync_once "$key"
    rc=$?
    release_sync_lock
    [ "$rc" != 0 ] || break
    if [ "$i" -ge "$attempts" ]; then
      FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-inbox.sh" note --request-id "fm-decide-sync-$key" -- \
        "Decision $key is in data/decided.md but is not on Shortcut after $attempts tries. Run: '$SCRIPT_DIR/fm-decide.sh' sync $key" >/dev/null 2>&1 || true
      printf 'fm-decide: decision %s is recorded locally but could not be posted to Shortcut after %s tries\n' "$key" "$attempts" >&2
      return 1
    fi
    sleep "$delay"
    delay=$((delay * 3))
    i=$((i + 1))
  done
  printf 'fm-decide: posted %s\n' "$key"
}

command_sync() {  # [<key>]
  local key rc=0
  if [ -n "${1:-}" ]; then
    sync_key "$1" || rc=1
  else
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      sync_key "$key" || rc=1
    done <<KEYS
$(pending_keys)
KEYS
  fi
  return "$rc"
}

# Detached: the caller never waits for the network, and a caller that captures
# our output does not wait on the job's pipe either.
launch_sync() {  # <key>
  FM_HOME=$FM_HOME FM_DATA_OVERRIDE=$DATA nohup "$SCRIPT_DIR/fm-decide.sh" sync "$1" \
    >>"$DATA/.decided-sync.log" 2>&1 </dev/null &
  disown 2>/dev/null || true
}

# append_entry <line>: add one entry (the lock is held), temp file plus rename.
append_entry() {
  TMPENTRY=$(mktemp "$DATA/.decided.XXXXXX") || return 1
  { [ ! -f "$DECIDED" ] || cat "$DECIDED"; printf '%s\n' "$1"; } >"$TMPENTRY"
  mv "$TMPENTRY" "$DECIDED" || { rm -f "$TMPENTRY"; TMPENTRY=''; return 1; }
  TMPENTRY=''
}

guard_warning() {
  guard_installed || printf 'fm-decide: warning: direct writes to data/decided.md are not blocked here; add this to %s/.claude/settings.local.json (merge into its "hooks"):\n%s\n' "$FM_HOME" "$(guard_line)" >&2
}

command_record() {
  local key=${1:-} text='' story='' item='' file='' stamp=pending
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
      BEGIN { p = "- [" ENVIRON["FM_KEY"] "] "; t = ENVIRON["FM_TEXT"] " (shortcut: sc-"; q = ENVIRON["FM_TEXT"] " (shortcut: pending" }
      index($0, p) == 1 {
        seen = 1; r = substr($0, length(p) + 12)
        if (index(r, t) == 1 && substr(r, length(t) + 1) ~ /^[0-9]+ [^ ]*\)$/) same = 1
        if (index(r, q) == 1 && substr(r, length(q) + 1) ~ /^( sc-[0-9]+)?\)$/) same = 1
      }
      END { print same ? "same" : seen ? "other" : "" }' "$DECIDED") in
      same) return 0 ;;
      other) die "a decision with key '$key' is already recorded with different text; use a new key" ;;
    esac
  fi

  if [ -z "$story" ] && [ -n "$item" ]; then
    story=$(ticket --linked "$item" 2>/dev/null || true)
  fi
  [ -z "$story" ] || stamp="pending $story"
  append_entry "- [$key] ${FM_DECIDE_DATE:-$(date +%F)} $text (shortcut: $stamp)" || die "cannot write $DECIDED"
  release_lock
  launch_sync "$key"
  printf 'fm-decide: recorded %s locally; posting to Shortcut in the background\n' "$key"
  guard_warning
}

ARGS=()
for arg in "$@"; do
  case "$arg" in
    --best-effort) BEST_EFFORT=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

case "${1:-}" in
  record) shift; command_record "$@" ;;
  sync) shift; command_sync "$@" ;;
  audit) command_audit ;;
  guard-hook) command_guard_hook ;;
  guard-line) guard_line ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
