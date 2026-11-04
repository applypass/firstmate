#!/usr/bin/env bash
# Fork-only: meeting-to-ticket gate for the primary firstmate session (applypass fork).
#
# usage:
#   fm-meeting-ticket-gate.sh mark            PostToolUse hook: read the payload on stdin
#   fm-meeting-ticket-gate.sh check           Stop check: exit 2 + stderr message while a marker is unmet
#   fm-meeting-ticket-gate.sh install <dir>   register the PostToolUse hook in <dir>/.claude/settings.local.json
#
# Why: reading a meeting transcript must end in tickets before the session moves on.
#
# mark: when the tool named in the payload is on the configured meeting-tool list and its
# result holds a transcript, write state/meeting-pending/<meeting-id> (id, date, tool).
# The list is $FM_HOME/config/meeting-transcript-tools, falling back to the tracked
# default bin/fm-meeting-transcript-tools.default: one shell glob per line, '#' comments.
# A bare meeting listing (no transcript text) writes nothing. No-op for any other tool,
# in a child task worktree, and in a secondmate home.
#
# check: for each marker, pass when data/meeting-<date>-<id>.md or data/standup-<date>.md exists,
# names the meeting id, has at least one table task row, and every task row carries evidence in
# a cell after the Task cell (Owner, Where; the Due cell does not count): an sc-NNNN story id, a whole 'not ours' or 'done'
# cell, or a PR reference (PR 826, BE 825, FE 445 with 3+ digits, or a /pull/N url). A row with
# 'id pending', 'TBD', or none of those fails. A passing marker is deleted; a failing one blocks the turn
# end, and the message names the file checked and each failing row.
#
# Due column: the table header is '| # | Task | Owner | Due | Where |' (or '| P | Task | Owner | Due | Story |').
# The Due column is found by its header name. Each task row's Due cell holds a date as YYYY-MM-DD,
# or exactly 'no deadline - ask at standup' (case-insensitive, surrounding spaces ignored), so a
# to-do with no timeline is visible and raised at the next standup. A row whose evidence cell is a
# whole 'not ours' or 'done' needs no due date. A table with task rows but no Due column fails.
# The main home's data/todos.md register uses the header '| Task | Owner | Due | Story |' with the same
# Due cell: YYYY-MM-DD or exactly 'no deadline - ask at standup'. This gate does not check data/todos.md.
#
# Delete a marker by hand to waive a meeting.
#
# Test seams: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_DATA_OVERRIDE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MARKERS="$STATE/meeting-pending"
DEFAULT_LIST="$SCRIPT_DIR/fm-meeting-transcript-tools.default"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

in_primary_home() {
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 1
  fm_root_is_secondmate_home "$FM_ROOT" && return 1
  return 0
}

tool_is_listed() {  # <tool-name>
  local tool=$1 list=$CONFIG/meeting-transcript-tools pattern
  [ -f "$list" ] || list=$DEFAULT_LIST
  [ -f "$list" ] || return 1
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    pattern=${pattern%%#*}
    pattern=${pattern//[[:space:]]/}
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2254 # the list entry is a glob on purpose
    case "$tool" in $pattern) return 0 ;; esac
  done < "$list"
  return 1
}

# Prints "<date>\t<id>" per meeting whose result holds a transcript. Strings that hold JSON
# are parsed, so MCP content blocks ([{type:text,text:"{...}"}]) are searched too. Each
# object that directly holds a transcript is one meeting, with its own id and date. When a
# transcript object has no id, every id named in the tool input not already matched is marked.
extract_meetings() {  # <payload>
  printf '%s' "$1" | jq -r --arg today "$(date +%F)" '
    def parsed: walk(if type == "string" and (test("^\\s*[\\[{]")) then (try fromjson catch .) else . end);
    def speaker_lines: [split("\n")[] | select(test("^\\s*(\\[?[0-9:.]+\\]?\\s*)?[A-Za-z][^:]{0,40}:\\s*\\S"))] | length;
    def is_transcript($k; $v):
      ($v | type) == "string"
      and (($k | test("transcript"; "i")) and ($v | length) >= 200
           or ($v | length) >= 1500 and ($v | speaker_lines) >= 5);
    def idkey: test("^(id|meeting_?id|document_?id|ids|meeting_?ids|document_?ids)$"; "i");
    def datekey: test("^(date|start(_?time|ed_?at)?|created_?at|meeting_?date|time)$"; "i");
    def ids: [to_entries[] | select(.key | idkey) | .value | if type == "array" then .[] else . end | select(type == "string" or type == "number") | tostring];
    def own_date: [to_entries[] | select(.key | datekey) | .value | select(type == "string") | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) | .[0:10]][0];
    (.tool_input // {} | parsed) as $in
    | ({r: (.tool_response // {} | parsed)} | [.. | objects | select(any(to_entries[]; is_transcript(.key; .value)))]) as $hits
    | ([$in | .. | objects | ids[]] | unique) as $input_ids
    | ([$in | .. | objects | own_date | select(.)][0]) as $input_date
    | [ $hits[] | {id: ids[0], date: (own_date // $input_date // $today)} ] as $found
    | ([$found[] | .id | select(.)]) as $known
    | ($found | map(select(.id == null)) | .[0].date) as $idless_date
    | [ ($found[] | select(.id)),
        (if $idless_date == null then empty
         elif ($input_ids - $known | length) > 0 then ($input_ids - $known)[] | {id: ., date: $idless_date}
         else {id: "", date: $idless_date} end) ]
    | unique_by(.id)[]
    | "\(.date)\t\(.id)"' 2>/dev/null
}

safe_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

cmd_mark() {
  local payload tool id date n=0 tuse
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  # Cheap exit before any jq: pull tool_name with sed and test it against the list.
  tool=$(printf '%s' "$payload" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$tool" ] || exit 0
  tool_is_listed "$tool" || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  in_primary_home || exit 0
  tuse=$(printf '%s' "$payload" | jq -r '.tool_use_id // empty' 2>/dev/null)
  while IFS=$'\t' read -r date id; do
    [ -n "${date:-}" ] || continue
    n=$((n + 1))
    [ -n "$id" ] || id="unknown-$(safe_id "${tuse:-$(date +%s)-$n}")"
    id=$(safe_id "$id")
    mkdir -p "$MARKERS" 2>/dev/null || exit 0
    printf 'id=%s\ndate=%s\ntool=%s\n' "$id" "$date" "$tool" > "$MARKERS/$id.tmp" \
      && mv "$MARKERS/$id.tmp" "$MARKERS/$id"
  done < <(extract_meetings "$payload")
  exit 0
}

# Prints failing-row descriptions for one mapping file; prints nothing when the file passes.
# Output lines: "TICKET<TAB>row<TAB>text" (no story/PR evidence), "DUE<TAB>row<TAB>text<TAB>cell"
# (Due cell is not a YYYY-MM-DD date or the no-deadline flag), "NODUE" (a table with task rows has no Due header),
# or "NOROWS" when no task row exists. Evidence is read from the cells after Task, skipping Due.
file_failures() {  # <file>
  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function whole(cells, nc,   i, cell) {
      for (i = 1; i <= nc; i++) {
        cell = tolower(trim(cells[i]))
        if (cell == "not ours" || cell == "done") return 1
      }
      return 0
    }
    function ok(owner_cells, cells, nc,   low) {
      low = tolower(owner_cells)
      if (low ~ /id pending|tbd/) return 0
      if (low ~ /(^|[^a-z0-9])sc-[0-9]+/) return 1
      if (whole(cells, nc)) return 1
      if (owner_cells ~ /(^|[^A-Za-z])(PR|BE|FE) [0-9][0-9][0-9]+/) return 1
      if (owner_cells ~ /\/pull\/[0-9]+/) return 1
      return 0
    }
    function due_ok(d) {
      d = tolower(trim(d))
      return (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ || d == "no deadline - ask at standup")
    }
    /^[ \t]*\|/ {
      line = $0
      if (line ~ /^[ \t]*\|[ \t:|-]+\|[ \t]*$/) { next }       # separator
      if (!in_table) {                                           # header row
        in_table = 1
        n = split(line, h, "|")
        due = 0
        for (i = 2; i < n; i++) if (tolower(trim(h[i])) == "due") { due = i; break }
        next
      }
      n = split(line, c, "|")                                    # c[1] empty, c[2..n-1] cells
      if (n < 5) next
      rows++
      if (!due) nodue = 1
      owner = ""
      nc = 0
      for (i = 4; i < n; i++) { if (i == due) continue; owner = owner " | " c[i]; oc[++nc] = c[i] }
      if (!ok(owner, oc, nc)) printf "TICKET\t%s\t%s\n", trim(c[2]), trim(c[3])
      if (due && !whole(oc, nc) && !due_ok(c[due])) printf "DUE\t%s\t%s\t%s\n", trim(c[2]), trim(c[3]), trim(c[due])
      next
    }
    { in_table = 0 }
    END {
      if (rows == 0) print "NOROWS"
      else if (nodue) print "NODUE"
    }
  ' "$1"
}

check_marker() {  # <marker-file>; sets REPORT, returns 0 pass / 1 fail
  local mf=$1 id='' date='' key val cand best='' failures names unknown=0
  while IFS='=' read -r key val; do
    case "$key" in id) id=$val ;; date) date=$val ;; esac
  done < "$mf"
  [ -n "$id" ] && [ -n "$date" ] || { rm -f "$mf"; return 0; }
  case "$id" in unknown-*) unknown=1 ;; esac
  names="data/meeting-$date-$id.md or data/standup-$date.md"
  REPORT=''
  for cand in "$DATA/meeting-$date-$id.md" "$DATA/standup-$date.md"; do
    [ -f "$cand" ] || continue
    [ -n "$best" ] || best=$cand
    if [ "$unknown" -eq 0 ] && ! grep -qF -- "$id" "$cand"; then
      [ "$best" = "$cand" ] && REPORT="$cand does not name meeting id $id (add a 'Source: ... meeting $id' line)."
      continue
    fi
    failures=$(file_failures "$cand")
    if [ -z "$failures" ]; then
      rm -f "$mf"
      return 0
    fi
    best=$cand
    if [ "$failures" = NOROWS ]; then
      REPORT="$cand has no task rows (a '| # | Task | Owner | Due | Where |' table with one row per agreed task)."
    else
      REPORT=''
      if printf '%s\n' "$failures" | grep -qx NODUE; then
        REPORT="$cand has no Due column (add 'Due' right after 'Owner': '| # | Task | Owner | Due | Where |')."
      fi
      if printf '%s\n' "$failures" | grep -q '^TICKET'; then
        REPORT="${REPORT:+$REPORT$'\n'}$cand has task rows with no ticket or owner:"
        while IFS=$'\t' read -r kind row text _; do
          [ "$kind" = TICKET ] && REPORT="$REPORT"$'\n'"  - row $row: $text"
        done <<< "$failures"
        REPORT="$REPORT"$'\n'"Each row needs an sc-NNNN story id, a 'not ours' owner, a PR reference, or a 'done' status."
      fi
      if printf '%s\n' "$failures" | grep -q '^DUE'; then
        REPORT="${REPORT:+$REPORT$'\n'}$cand has task rows with no valid due date:"
        while IFS=$'\t' read -r kind row text cell; do
          [ "$kind" = DUE ] && REPORT="$REPORT"$'\n'"  - row $row: $text (Due: '${cell:-empty}')"
        done <<< "$failures"
        REPORT="$REPORT"$'\n'"Each row's Due cell needs a date as YYYY-MM-DD, or exactly 'no deadline - ask at standup'."
      fi
    fi
    return 1
  done
  if [ -z "$best" ]; then
    REPORT="No mapping file for meeting $id ($date). Create $names, name the meeting id in it, and give every agreed task a row with an sc-NNNN story id (file the tickets) or an explicit 'not ours' owner."
  fi
  return 1
}

cmd_check() {
  local mf blocked=0 msg=''
  in_primary_home || exit 0
  [ -d "$MARKERS" ] || exit 0
  for mf in "$MARKERS"/*; do
    [ -f "$mf" ] || continue
    case "$mf" in *.tmp) continue ;; esac
    if ! check_marker "$mf"; then
      blocked=1
      msg="$msg"$'\n'"Meeting $(basename "$mf"): $REPORT"
    fi
  done
  [ "$blocked" -eq 1 ] || exit 0
  {
    printf 'MEETING TRANSCRIPT READ, TICKETS NOT FILED. File every agreed task before ending the turn.%s\n' "$msg"
    printf 'The check re-runs at turn end and clears the marker once the file passes (waive: delete state/meeting-pending/<id>).\n'
  } >&2
  exit 2
}

cmd_install() {  # <dir>
  local dir file tmp hook
  [ -d "${1:-}" ] || { echo "usage: fm-meeting-ticket-gate.sh install <dir>" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "fm-meeting-ticket-gate: jq is required" >&2; exit 1; }
  dir=$(CDPATH='' cd -- "$1" && pwd -P) || exit 1
  file="$dir/.claude/settings.local.json"
  hook="$(printf %q "$SCRIPT_DIR/fm-meeting-ticket-gate.sh") mark"
  mkdir -p "$dir/.claude" || exit 1
  [ -f "$file" ] || printf '{}\n' > "$file"
  tmp=$(mktemp "$file.XXXXXX") || exit 1
  if ! jq --arg cmd "$hook" '
    .hooks //= {}
    | .hooks.PostToolUse //= []
    | if any(.hooks.PostToolUse[]?.hooks[]?; (.command // "") | contains("fm-meeting-ticket-gate.sh"))
      then .
      else .hooks.PostToolUse += [{"matcher":".*","hooks":[{"type":"command","command":$cmd,"timeout":10}]}]
      end' "$file" > "$tmp"; then
    rm -f "$tmp"
    echo "fm-meeting-ticket-gate: could not merge into $file" >&2
    exit 1
  fi
  mv "$tmp" "$file"
}

case "${1:-}" in
  mark) cmd_mark ;;
  check) cmd_check ;;
  install) shift; cmd_install "${1:-}" ;;
  *) echo "usage: fm-meeting-ticket-gate.sh mark|check|install <dir>" >&2; exit 2 ;;
esac
