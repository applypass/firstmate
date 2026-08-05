#!/usr/bin/env bash
# Search and record questions the captain has already answered.
#
# WHY: the captain gets asked things they have already settled. The answers were on
# disk - one was a numbered decision in a project decision log, from nine days
# earlier - and nothing made firstmate read them before escalating again.
#
# WHY A SEARCH AND NOT A PRELOADED LIST: a list of every answered decision does
# not scale, is mostly irrelevant to any one session, never shrinks, and competes
# with the wake queue and real blockers for the same first-thing-read slot, which
# is exactly how the wall of text that hid these answers got built. What is needed
# is a lookup at the MOMENT OF ASKING. So session start carries one line - how
# many answers exist and the instruction to search - and this script makes the
# lookup a single cheap command.
#
# WHAT IT SEARCHES: data/decided.md, the index this script appends to, plus every
# other decision log already in this home's data/ directory. Existing logs are
# searchable as they are, with no migration: the index adds answers that have no
# other home, it does not replace the logs. data/NEED_DECISION.md is deliberately
# excluded - that is the OPEN view, and mixing unanswered items into an
# already-answered search is how a pending question gets treated as settled.
#
# STABLE TOPIC KEYS: every indexed answer carries a kebab-case key so the same
# question is findable by the same word later, whatever wording the asker used.
#
# HARD LINE CAP: output is bounded, and when it truncates it says how many
# matches it dropped. A silently truncated answer list reads as "no other answer
# exists", which is the failure this script exists to prevent.
#
# Usage:
#   fm-decided.sh search <term> [more terms...]
#       Print answered decisions whose line matches every term, case-insensitive.
#   fm-decided.sh record --key <slug> --answer "<one line>"
#                        [--source <path>] [--date <YYYY-MM-DD>] [--supersede]
#       Append an answer to data/decided.md. Refuses a key that already exists
#       unless --supersede, which replaces that key's line in place.
#   fm-decided.sh count
#       Print the one-line summary session start carries.
#   fm-decided.sh sources
#       List the files a search covers.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
INDEX="$DATA/decided.md"

MAX_LINES=${FM_DECIDED_MAX_LINES:-40}
case "$MAX_LINES" in ''|*[!0-9]*|0) MAX_LINES=40 ;; esac

usage() {
  sed -n '2,${/^set -u/q;p;}' "${BASH_SOURCE[0]}"
}

die() {
  printf 'fm-decided: %s\n' "$*" >&2
  exit 2
}

rel_path() {
  case "$1" in
    "$FM_HOME"/*) printf '%s\n' "${1#"$FM_HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# search_files: the index first, then every other decision log in this home.
# Name matching is case-insensitive so DECISIONS.md and decisions.md both count.
search_files() {
  local f base lower
  [ -f "$INDEX" ] && printf '%s\n' "$INDEX"
  for f in "$DATA"/*.md; do
    [ -f "$f" ] || continue
    [ "$f" = "$INDEX" ] && continue
    base=$(basename "$f")
    lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      need_decision.md) continue ;;
      *decision*|*decided*) printf '%s\n' "$f" ;;
    esac
  done
}

cmd_sources() {
  local found=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    found=1
    printf '%s\n' "$(rel_path "$f")"
  done <<EOF
$(search_files)
EOF
  [ "$found" -eq 1 ] || printf '(no decision records in %s yet)\n' "$(rel_path "$DATA")"
}

cmd_count() {
  local indexed=0 logs=0 f
  # `grep -c` PRINTS 0 and then exits 1 on no match, so a `|| printf '0'`
  # fallback would append a second zero and put a stray bare 0 above the one
  # startup line the searchable-decision design rests on.
  [ -f "$INDEX" ] && indexed=$(grep -c '^- \[' "$INDEX" 2>/dev/null || true)
  case "$indexed" in ''|*[!0-9]*) indexed=0 ;; esac
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$INDEX" ] && continue
    logs=$((logs + 1))
  done <<EOF
$(search_files)
EOF
  printf '%s answered decision(s) indexed in %s, plus %s decision log(s) in %s.\n' \
    "$indexed" "$(rel_path "$INDEX")" "$logs" "$(rel_path "$DATA")"
  printf 'Search before escalating anything: bin/fm-decided.sh search <terms>\n'
}

cmd_search() {
  [ "$#" -gt 0 ] || die 'search needs at least one term'
  local files hits total shown f
  files=$(search_files)
  # Exit status is the contract: 0 means "an answer exists", non-zero means
  # "nothing answered this", so no-records-at-all must not read as a settled no.
  if [ -z "$files" ]; then
    printf 'no decision records to search in %s yet\n' "$(rel_path "$DATA")"
    return 1
  fi
  # AND across terms by chaining case-insensitive greps, keeping file:line
  # provenance from the first grep so every hit stays checkable at its source.
  hits=$(
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -in -- "$1" "$f" 2>/dev/null | sed "s|^|$(rel_path "$f"):|"
    done <<EOF
$files
EOF
  )
  shift
  while [ "$#" -gt 0 ] && [ -n "$hits" ]; do
    hits=$(printf '%s\n' "$hits" | grep -i -- "$1" || true)
    shift
  done
  if [ -z "$hits" ]; then
    printf 'no answered decision matches. It may genuinely be unanswered - or recorded in a project record outside %s.\n' "$(rel_path "$DATA")"
    return 1
  fi
  total=$(printf '%s\n' "$hits" | grep -c . || printf '0')
  shown=$total
  [ "$shown" -gt "$MAX_LINES" ] && shown=$MAX_LINES
  printf '%s\n' "$hits" | head -n "$shown"
  if [ "$total" -gt "$shown" ]; then
    printf -- '--- %s more match(es) omitted by the %s-line cap; narrow the terms or raise FM_DECIDED_MAX_LINES ---\n' \
      "$((total - shown))" "$MAX_LINES"
  fi
  return 0
}

cmd_record() {
  local key='' answer='' source='' date='' supersede=0 line existing
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key) shift; key=${1:-} ;;
      --answer) shift; answer=${1:-} ;;
      --source) shift; source=${1:-} ;;
      --date) shift; date=${1:-} ;;
      --supersede) supersede=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$key" ] || die 'record needs --key <slug>, the stable word this answer is findable by'
  [ -n "$answer" ] || die 'record needs --answer "<one line>"'
  case "$key" in
    *[!a-z0-9-]*) die "key '$key' must be kebab-case: lowercase letters, digits, and dashes" ;;
  esac
  [ -n "$date" ] || date=$(date '+%Y-%m-%d')
  case "$date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) die "date '$date' must be YYYY-MM-DD" ;;
  esac
  [ -d "$DATA" ] || die "no data directory at $DATA"

  if [ ! -f "$INDEX" ]; then
    {
      printf '# Answered decisions\n\n'
      printf 'One line per settled question, newest last.\n'
      printf 'Search it with: bin/fm-decided.sh search <terms>\n'
      printf 'The source named on a line is authoritative when the line itself is too\n'
      printf 'short to act on.\n\n'
    } > "$INDEX" || die "cannot create $(rel_path "$INDEX")"
  fi

  existing=$(grep -n "^- \[$key\] " "$INDEX" 2>/dev/null | head -1 || true)
  if [ -n "$existing" ] && [ "$supersede" -eq 0 ]; then
    printf 'fm-decided: key %s is already answered:\n' "$key" >&2
    printf '  %s\n' "${existing#*:}" >&2
    printf 'Use a new key for a different question, or --supersede to replace this answer.\n' >&2
    exit 1
  fi

  line="- [$key] $date $answer"
  if [ -n "$source" ]; then
    local src_abs
    case "$source" in
      /*) src_abs=$source ;;
      *) src_abs="$FM_HOME/$source" ;;
    esac
    line="$line (source: $(rel_path "$src_abs"))"
  fi

  if [ -n "$existing" ]; then
    # The index is LOCAL and gitignored, so a truncated rewrite loses answers
    # with no backup. Every step is checked and the replacement is installed only
    # when the whole file was rebuilt: grep exits 1 when it matched nothing, which
    # is a legitimate empty result, but anything above that is a read or write
    # failure and must leave the record alone.
    local tmp grep_status
    tmp="$INDEX.tmp.$$"
    grep -v "^- \[$key\] " "$INDEX" > "$tmp" 2>/dev/null
    grep_status=$?
    if [ "$grep_status" -gt 1 ]; then
      rm -f "$tmp" 2>/dev/null
      die "cannot rewrite $(rel_path "$INDEX") (reading it failed with status $grep_status); the record is unchanged"
    fi
    if ! printf '%s\n' "$line" >> "$tmp"; then
      rm -f "$tmp" 2>/dev/null
      die "cannot write the replacement index at $(rel_path "$tmp"); $(rel_path "$INDEX") is unchanged"
    fi
    if ! mv -f "$tmp" "$INDEX"; then
      rm -f "$tmp" 2>/dev/null
      die "cannot install the rewritten $(rel_path "$INDEX"); the record is unchanged"
    fi
    printf 'superseded: %s\n' "$line"
  else
    printf '%s\n' "$line" >> "$INDEX" || die "cannot append to $(rel_path "$INDEX")"
    printf 'recorded: %s\n' "$line"
  fi
}

case "${1:-}" in
  search) shift; cmd_search "$@" ;;
  record) shift; cmd_record "$@" ;;
  count) cmd_count ;;
  sources) cmd_sources ;;
  -h|--help|'') usage ;;
  *) die "unknown command '$1'" ;;
esac
