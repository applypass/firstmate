#!/usr/bin/env bash
# fm-meeting-todos-sync.sh - push a meeting to-do record to Shortcut (applypass fork).
#
# Usage: fm-meeting-todos-sync.sh <record-file> [--dry-run]
#
# <record-file> is data/meeting-todos/<YYYY-MM-DD>.md (format: bin/fm-meeting-todos-lib.sh and
# docs/configuration.md "Meeting to-do record (fork)"). The file name is the meeting date. The
# script validates the record first and exits 2 with one "file:line: problem" per line when it is
# malformed, before any Shortcut call.
#
# Per row with status open or moved:
#   - Story cell empty: create the story (Engineering team, Backlog, the row's Deadline, labels
#     standup-<meeting date> and todo-today|todo-week; epic 6074 only when the Task ends in
#     "[agentic]", the tag is dropped from the story name) and write the new sc-NNNN into the
#     Story cell at once, so a re-run never creates it twice.
#   - Story cell set: read the story and write only what differs - a missing label, or the Deadline.
#     A Deadline that replaces a different one also comments "Deadline moved <old> -> <new>: <reason>"
#     (the reason is the trailing "(moved: <reason>)" of the Deadline cell). A story with no Deadline
#     yet gets one with no comment.
# Rows with status done or dropped never write to a story. Deadlines are stored as <date>T12:30:00Z,
# which is 18:00 IST.
#
# Per meeting: one Shortcut Doc titled 'Standup <Day D Mon> - agreed to-dos' (with ' (<meeting title>)'
# added when the file holds several meetings) holding the Krisp link, the two-line summary and a table
# of story link, task, owner, scope, deadline and status. The doc id and a hash of its content go in
# the section heading ('| doc <id> <hash>'); the doc is written only when the hash differs, so a
# re-run on an unchanged file makes no Shortcut writes. A section with a failed row writes no doc.
#
# --dry-run prints what would be written and changes nothing (reads still happen).
# Exit: 0 done (or nothing to do), 1 a Shortcut call failed or tickets are off, 2 bad usage or record.
#
# Shortcut is reached through bin/fm-shortcut-ticket.sh (`api` and `setting`), which owns the token
# and the settings. Test seam: FM_MEETING_TODOS_TICKET_CMD replaces that command.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICKET=${FM_MEETING_TODOS_TICKET_CMD:-$SCRIPT_DIR/fm-shortcut-ticket.sh}
# shellcheck source=bin/fm-meeting-todos-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-meeting-todos-lib.sh"

US=$'\x1f'
DEADLINE_TIME=12:30:00Z
ERRORS=0
DRY=0
FILE=''

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

for arg in "$@"; do
  case "$arg" in
    -h | --help) usage; exit 0 ;;
    --dry-run) DRY=1 ;;
    -*) printf 'fm-meeting-todos-sync: unknown option %s\nusage: fm-meeting-todos-sync.sh <record-file> [--dry-run]\n' "$arg" >&2; exit 2 ;;
    *) [ -z "$FILE" ] || { printf 'usage: fm-meeting-todos-sync.sh <record-file> [--dry-run]\n' >&2; exit 2; }; FILE=$arg ;;
  esac
done
[ -n "$FILE" ] || { printf 'usage: fm-meeting-todos-sync.sh <record-file> [--dry-run]\n' >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { printf 'fm-meeting-todos-sync: jq is required\n' >&2; exit 1; }
fm_mt_validate "$FILE" || exit 2
FDATE=$(fm_mt_file_date "$FILE")

if [ -z "${FM_MEETING_TODOS_TICKET_CMD:-}" ] && ! "$TICKET" --enabled; then
  printf 'fm-meeting-todos-sync: Shortcut tickets are off (see bin/fm-shortcut-ticket.sh --enabled); nothing was synced\n' >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-meeting-todos.XXXXXX") || { printf 'fm-meeting-todos-sync: cannot create a temp directory\n' >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

api() {  # <method> <path> [json-file]; the body lands in $WORK/out, a failure's message in $WORK/err
  "$TICKET" api "$@" > "$WORK/out" 2> "$WORK/err" < /dev/null
}

note_error() {  # <context>
  printf 'fm-meeting-todos-sync: %s: %s\n' "$1" "$(head -1 "$WORK/err" 2>/dev/null)" >&2
  ERRORS=1
  SEC_ERR=1
}

TEAM=$("$TICKET" setting team_id)
STORY_TYPE=$("$TICKET" setting story_type feature)
STATE_BACKLOG=$("$TICKET" setting state_backlog)
AGENTIC_EPIC=$("$TICKET" setting meeting_todo_agentic_epic 6074)

LABELS=''
LABELS_LOADED=0
ensure_label() {  # <name>
  local name=$1
  if [ "$LABELS_LOADED" = 0 ]; then
    if api GET /api/v3/labels; then
      LABELS=$(jq -r '.[].name' "$WORK/out" 2>/dev/null)
    else
      note_error "cannot list labels"
    fi
    LABELS_LOADED=1
  fi
  printf '%s\n' "$LABELS" | grep -Fxq -- "$name" && return 0
  LABELS=$(printf '%s\n%s' "$LABELS" "$name")
  if [ "$DRY" = 1 ]; then
    printf 'would create label %s\n' "$name"
    return 0
  fi
  jq -n --arg n "$name" '{name: $n}' > "$WORK/label.json"
  if api POST /api/v3/labels "$WORK/label.json"; then
    printf 'created label %s\n' "$name"
  else
    note_error "cannot create label $name"
  fi
}

SEC_ERR=0 SEC_PLANNED=0
SEC_TITLE='' SEC_ID='' SEC_LINK='' SEC_DOC='' SEC_HASH='' SUM1='' SUM2='' SEC_LINE=0
TABLE="$WORK/table"
NSEC=$(fm_mt_records "$FILE" | grep -c "^S") || true

content_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-10
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-10
  else
    cksum | awk '{ printf "%010x\n", $1 }' | cut -c1-10
  fi
}

do_row() {  # <num> <line> <task> <owner> <story> <scope> <date> <reason> <status> <quote>
  local num=$1 line=$2 task=$3 owner=$4 story=$5 scope=$6 date=$7 reason=$8 status=$9 quote=${10}
  local name=$task agentic=0 want iso cur have id url ref missing upd moved label
  case "$task" in
    *"[agentic]") agentic=1; name=${task%"[agentic]"}; name=${name% } ;;
  esac
  iso="${date}T$DEADLINE_TIME"
  url=''
  ref=${story:--}

  case "$status" in
    done | dropped)
      if [ -n "$story" ]; then
        if api GET "/api/v3/stories/${story#sc-}"; then
          url=$(jq -r '.app_url // empty' "$WORK/out")
        else
          note_error "row $num: $story"
        fi
      fi
      ;;
    *)
      want="standup-$FDATE todo-$scope"
      for label in $want; do ensure_label "$label"; done
      if [ -z "$story" ]; then
        if [ "$DRY" = 1 ]; then
          printf 'would create a story for row %s: %s (deadline %s, %s)\n' "$num" "$name" "$date" "$want"
          SEC_PLANNED=1
          ref='(new)'
        else
          jq -n --arg name "$name" --arg owner "$owner" --arg scope "$scope" --arg date "$date" \
            --arg quote "$quote" --arg link "$SEC_LINK" --arg title "$SEC_TITLE" --arg mid "$SEC_ID" --arg num "$num" \
            --arg type "$STORY_TYPE" --arg team "$TEAM" --arg state "$STATE_BACKLOG" --arg iso "$iso" \
            --arg epic "$AGENTIC_EPIC" --argjson agentic "$agentic" --arg l1 "standup-$FDATE" --arg l2 "todo-$scope" '
            {name: $name,
             description: ("Agreed in \"" + $title + "\" (" + $link + ").\nOwner: " + $owner + ". Scope: " + $scope + ", due " + $date + ".\nQuote: " + $quote + "\n\nmeeting-todo: " + $mid + "/" + $num),
             story_type: $type, deadline: $iso, labels: [{name: $l1}, {name: $l2}]}
            + (if $team != "" then {group_id: $team} else {} end)
            + (if $state != "" then {workflow_state_id: ($state | tonumber)} else {} end)
            + (if $agentic == 1 and $epic != "" then {epic_id: ($epic | tonumber)} else {} end)' > "$WORK/story.json" || { ERRORS=1; SEC_ERR=1; return; }
          if api POST /api/v3/stories "$WORK/story.json"; then
            id=$(jq -r '.id // empty' "$WORK/out")
            url=$(jq -r '.app_url // empty' "$WORK/out")
            case "$id" in '' | *[!0-9]*) printf 'fm-meeting-todos-sync: row %s: Shortcut returned no story id\n' "$num" >&2; ERRORS=1; SEC_ERR=1; return ;; esac
            ref="sc-$id"
            if fm_mt_set_story "$FILE" "$line" "$ref"; then
              printf 'created %s: %s\n' "$ref" "$name"
            else
              printf 'fm-meeting-todos-sync: row %s: created %s but could not write it into %s; set that row'"'"'s Story cell by hand\n' "$num" "$ref" "$FILE" >&2
              ERRORS=1; SEC_ERR=1
            fi
          else
            note_error "row $num: cannot create the story"
            return
          fi
        fi
      else
        id=${story#sc-}
        if ! api GET "/api/v3/stories/$id"; then
          note_error "row $num: $story"
          return
        fi
        url=$(jq -r '.app_url // empty' "$WORK/out")
        cur=$(jq -r '(.deadline // "")[0:10]' "$WORK/out")
        have=$(jq -r '[.labels[]?.name] | .[]' "$WORK/out")
        missing=''
        for label in $want; do
          printf '%s\n' "$have" | grep -Fxq -- "$label" || missing="$missing $label"
        done
        upd=$(jq -n '{}')
        moved=0
        if [ "$cur" != "$date" ]; then
          upd=$(printf '%s' "$upd" | jq -c --arg d "$iso" '. + {deadline: $d}')
          [ -z "$cur" ] || moved=1
        fi
        if [ -n "$missing" ]; then
          upd=$(jq -c -n --argjson u "$upd" --slurpfile s "$WORK/out" --arg miss "$missing" '
            $u + {labels: ([($s[0].labels // [])[] | {name: .name}] + [$miss | split(" ")[] | select(. != "") | {name: .}])}')
        fi
        if [ "$upd" = '{}' ]; then
          printf 'row %s: %s unchanged\n' "$num" "$story"
        elif [ "$DRY" = 1 ]; then
          printf 'would update %s: %s\n' "$story" "$upd"
          [ "$moved" = 0 ] || printf 'would comment on %s: Deadline moved %s -> %s: %s\n' "$story" "$cur" "$date" "${reason:-no reason given}"
          SEC_PLANNED=1
        else
          printf '%s' "$upd" > "$WORK/upd.json"
          if api PUT "/api/v3/stories/$id" "$WORK/upd.json"; then
            printf 'updated %s: %s\n' "$story" "$upd"
            if [ "$moved" = 1 ]; then
              jq -n --arg t "Deadline moved $cur -> $date: ${reason:-no reason given}" '{text: $t}' > "$WORK/comment.json"
              if api POST "/api/v3/stories/$id/comments" "$WORK/comment.json"; then
                printf 'commented on %s: Deadline moved %s -> %s\n' "$story" "$cur" "$date"
              else
                note_error "row $num: $story moved but the comment failed"
              fi
            fi
          else
            note_error "row $num: cannot update $story"
          fi
        fi
      fi
      ;;
  esac
  if [ -n "$url" ] && [ "$ref" != '-' ]; then
    printf '| [%s](%s) | %s | %s | %s | %s | %s |\n' "$ref" "$url" "$name" "$owner" "$scope" "$date" "$status" >> "$TABLE"
  else
    printf '| %s | %s | %s | %s | %s | %s |\n' "$ref" "$name" "$owner" "$scope" "$date" "$status" >> "$TABLE"
  fi
}

finish_section() {
  local title content hash id
  [ -n "$SEC_ID" ] || return 0
  if [ "$SEC_ERR" = 1 ]; then
    printf 'fm-meeting-todos-sync: %s: a row failed, so its doc was not written; fix it and run again\n' "$SEC_TITLE" >&2
    return 0
  fi
  title=$(fm_mt_doc_title "$FDATE")
  [ "$NSEC" -le 1 ] || title="$title ($SEC_TITLE)"
  content=$(
    printf 'Krisp: %s\n\n' "$SEC_LINK"
    [ -z "$SUM1" ] || printf '%s\n' "$SUM1"
    [ -z "$SUM2" ] || printf '%s\n' "$SUM2"
    printf '\n| Story | Task | Owner | Scope | Deadline | Status |\n|---|---|---|---|---|---|\n'
    cat "$TABLE"
  )
  hash=$(printf '%s\n%s' "$title" "$content" | content_hash)
  if [ "$DRY" = 1 ]; then
    if [ -z "$SEC_DOC" ]; then
      printf 'would create the doc "%s"\n' "$title"
    elif [ "$SEC_PLANNED" = 1 ] || [ "$hash" != "$SEC_HASH" ]; then
      printf 'would update the doc "%s" (%s)\n' "$title" "$SEC_DOC"
    else
      printf 'doc "%s" unchanged\n' "$title"
    fi
    return 0
  fi
  if [ -n "$SEC_DOC" ] && [ "$hash" = "$SEC_HASH" ]; then
    printf 'doc "%s" unchanged\n' "$title"
    return 0
  fi
  jq -n --arg t "$title" --arg c "$content" '{title: $t, content: $c, content_format: "markdown"}' > "$WORK/doc.json"
  if [ -n "$SEC_DOC" ]; then
    if api PUT "/api/v3/documents/$SEC_DOC" "$WORK/doc.json"; then
      fm_mt_set_doc "$FILE" "$SEC_LINE" "$SEC_DOC" "$hash" || { ERRORS=1; printf 'fm-meeting-todos-sync: cannot record the doc hash in %s\n' "$FILE" >&2; }
      printf 'updated the doc "%s" (%s)\n' "$title" "$SEC_DOC"
    else
      note_error "cannot update doc $SEC_DOC"
    fi
  elif api POST /api/v3/documents "$WORK/doc.json"; then
    id=$(jq -r '.id // empty' "$WORK/out")
    if [ -z "$id" ]; then
      printf 'fm-meeting-todos-sync: Shortcut returned no doc id for "%s"\n' "$title" >&2
      ERRORS=1
    elif fm_mt_set_doc "$FILE" "$SEC_LINE" "$id" "$hash"; then
      printf 'created the doc "%s" (%s)\n' "$title" "$id"
    else
      printf 'fm-meeting-todos-sync: created doc %s but could not record it in %s; add "| doc %s %s" to the section heading\n' "$id" "$FILE" "$id" "$hash" >&2
      ERRORS=1
    fi
  else
    note_error "cannot create the doc"
  fi
}

fm_mt_records "$FILE" > "$WORK/records"
while IFS="$US" read -r -u 3 kind _ f2 f3 f4 f5 f6 f7 f8 f9 f10 f11; do
  case "$kind" in
    S)
      finish_section
      : > "$TABLE"
      SEC_ERR=0 SEC_PLANNED=0
      SEC_TITLE=$f2 SEC_ID=$f3 SEC_LINK=$f4 SEC_DOC=$f5 SEC_HASH=$f6 SUM1=$f7 SUM2=$f8 SEC_LINE=$f9
      ;;
    R)
      # f1 section, f2 line, f3 num, f4 task, f5 owner, f6 story, f7 scope, f8 date, f9 reason, f10 status, f11 quote
      do_row "$f3" "$f2" "$f4" "$f5" "$f6" "$f7" "$f8" "$f9" "$f10" "$f11"
      ;;
  esac
done 3< "$WORK/records"
finish_section

exit "$ERRORS"
