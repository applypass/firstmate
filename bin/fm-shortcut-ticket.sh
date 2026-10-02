#!/usr/bin/env bash
# fm-shortcut-ticket.sh - keep a backlog item's Shortcut story in sync (applypass fork).
#
# Usage: fm-shortcut-ticket.sh <item-id>                     create (or link) the story, in Backlog
#        fm-shortcut-ticket.sh state <item> progress|review  move the story
#        fm-shortcut-ticket.sh review <item> [--pr <url>] [--report <file>]
#                                                            In Review, plus PR link and report upload
#        fm-shortcut-ticket.sh comment <item> <text> | --file <file>
#        fm-shortcut-ticket.sh attach <item> <file>...       upload files (screenshots, reports)
#        fm-shortcut-ticket.sh outcome <item>                comment the task's final status line
#        fm-shortcut-ticket.sh park <item> --reason <text>   back to Backlog with the reason (work abandoned)
#        fm-shortcut-ticket.sh done <item> --evidence <text> move to Done (never automatic)
#        fm-shortcut-ticket.sh --check <item>                exit 0 if ticketed or exempt
#        fm-shortcut-ticket.sh --linked <item>               print the linked sc-NNNN, if any
#        fm-shortcut-ticket.sh --enabled                     exit 0 if the feature is on
# Any operation accepts --best-effort: a missing sc id or an API failure then
# warns and exits 0, which is how the lifecycle hooks call it. The story
# operations also take the story id (sc-NNNN) in place of the item, for an
# item that no longer exists.
#
# Hooks: bin/fm-tasks-axi.sh add creates the story; bin/fm-spawn.sh refuses a
# ship or scout with no sc id (--check) and moves the story to In Progress on
# dispatch; bin/fm-pr-check.sh moves it to In Review and links the PR;
# bin/fm-captain-hold.sh answer (and keyed answers) comments the recorded decision;
# a landed ship goes to In Review at teardown even without a PR;
# bin/fm-teardown.sh comments the outcome (a scout also goes to In Review with
# its report.md uploaded; a forced teardown, a cancelled (rm) or parked (hold)
# item moves the story back to Backlog with the reason). Merge and teardown never move a story to Done: firstmate
# runs `done` on the captain's word or verified production evidence.
#
# Create: POST /api/v3/stories with name = item title, description = item body
# (or a Problem/Fix stub when empty), team/state/owner from the settings. The
# `Shortcut: sc-NNNN <url>` line is appended to the item body through tasks-axi.
# The linked story is the one a body line `Shortcut: sc-NNNN` names, else an
# `sc-NNNN` in the title; that story is verified (GET) and nothing is created.
# Any other `sc-NNNN` in the body is only a reference: it is never moved,
# commented on, or uploaded to, and the item still gets its own story. `tasks-axi mv` moves the whole item, so a secondmate handoff
# carries the id. Skipped kinds: secondmate and captain (decision-only rows).
#
# Settings: key=value lines from defaults/shortcut-tickets in the code root, then
# config/shortcut-tickets in the home (later wins); an absent defaults file means
# off. FM_SHORTCUT_TICKETS=on|off overrides `enabled`. Keys: enabled, team_id,
# state_backlog, state_progress, state_review, state_done, owner_id, story_type,
# api_base.
#
# The API token comes from SHORTCUT_API_TOKEN only. It reaches curl on stdin,
# never the command line, and is never printed or stored.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TASKS="$SCRIPT_DIR/fm-tasks-axi.sh"
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
    printf 'fm-shortcut-ticket: warning: %s\n' "$*" >&2
    exit 0
  fi
  printf 'fm-shortcut-ticket: %s\n' "$*" >&2
  exit 1
}

setting() {  # <key> [default]
  local key=$1 value="${2:-}" file line
  for file in "$FM_ROOT/defaults/shortcut-tickets" "$CONFIG/shortcut-tickets"; do
    [ -f "$file" ] || continue
    line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -1) || true
    [ -n "$line" ] && value=$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  done
  printf '%s' "$value"
}

enabled() {
  local value
  if [ -n "${FM_SHORTCUT_TICKETS:-}" ]; then
    value=$FM_SHORTCUT_TICKETS
  elif [ -f "$FM_ROOT/defaults/shortcut-tickets" ] || [ -f "$CONFIG/shortcut-tickets" ]; then
    value=$(setting enabled off)
  else
    value=off
  fi
  case "$value" in on | true | 1 | yes) return 0 ;; *) return 1 ;; esac
}

ARGS=()
for arg in "$@"; do
  if [ "$arg" = --best-effort ]; then BEST_EFFORT=1; else ARGS+=("$arg"); fi
done
set -- ${ARGS[@]+"${ARGS[@]}"}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  --enabled) enabled; exit $? ;;
esac

OP=create
case "${1:-}" in
  --check) OP=check; shift ;;
  --linked) OP=linked; shift ;;
  state | review | comment | attach | outcome | park | done) OP=$1; shift ;;
esac
ID=${1:-}
[ -n "$ID" ] || die "usage: fm-shortcut-ticket.sh [<op>] <item-id> ... (see --help)"
shift

enabled || exit 0

KIND='' TITLE='' BODY='' SC=''
case "$OP" in
  create | check | linked) ;;
  *) case "${ID#sc-}" in "$ID" | '' | *[!0-9]*) ;; *) SC=$ID ;; esac ;;
esac

field() {  # <name>; decodes a quoted value
  local raw
  raw=$(printf '%s\n' "$SHOW" | sed -n "s/^  $1: *//p" | head -1)
  case "$raw" in
    \"*) printf '%s' "$raw" | jq -Rr 'fromjson' 2>/dev/null || printf '%s' "$raw" ;;
    *) printf '%s' "$raw" ;;
  esac
}

if [ -z "$SC" ]; then
  SHOW=$("$TASKS" show "$ID" --full 2>&1) || die "cannot read backlog item $ID: $(printf '%s' "$SHOW" | head -1)"
  KIND=$(field kind)
  TITLE=$(field title)
  BODY=$(field body)
  SC=$(printf '%s\n' "$BODY" | grep -Ei '^[[:space:]]*Shortcut:[[:space:]]*sc-[0-9]+' | head -1 | grep -Eoi 'sc-[0-9]+' | head -1) || true
  [ -n "$SC" ] || SC=$(printf '%s\n' "$TITLE" | grep -Eoi '\bsc-[0-9]+\b' | head -1) || true
  SC=$(printf '%s' "$SC" | tr '[:upper:]' '[:lower:]')
fi

if [ "$OP" = linked ]; then
  [ -z "$SC" ] || printf '%s\n' "$SC"
  exit 0
fi

if [ "$OP" = check ]; then
  case "$KIND" in secondmate | captain) exit 0 ;; esac
  [ -n "$SC" ] && exit 0
  die "backlog item $ID has no Shortcut ticket (sc-NNNN); create one with: bin/fm-shortcut-ticket.sh $ID"
fi
if [ "$OP" = create ]; then
  case "$KIND" in secondmate | captain) exit 0 ;; esac
elif [ -z "$SC" ]; then
  [ "$BEST_EFFORT" = 1 ] && exit 0
  die "backlog item $ID names no Shortcut ticket (sc-NNNN)"
fi

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
[ -n "${SHORTCUT_API_TOKEN:-}" ] || die "SHORTCUT_API_TOKEN is not set; export it and run: bin/fm-shortcut-ticket.sh $ID"

API=$(setting api_base "${SHORTCUT_API_BASE:-https://api.app.shortcut.com}")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-shortcut.XXXXXX") || die "cannot create a temp directory"
trap 'rm -rf "$WORK"' EXIT

HTTP_CODE=
http() {  # <method> <path> [curl args...]; response body lands in $WORK/resp
  local method=$1 path=$2
  shift 2
  HTTP_CODE=$(printf 'header = "Shortcut-Token: %s"\n' "$SHORTCUT_API_TOKEN" |
    curl -sS --max-time 30 -K - -o "$WORK/resp" -w '%{http_code}' -X "$method" "$@" "$API$path" 2>"$WORK/err") ||
    HTTP_CODE=000
}
http_json() {  # <method> <path> <json-file>
  http "$1" "$2" -H 'Content-Type: application/json' --data-binary "@$3"
}
ok() { case "$HTTP_CODE" in 200 | 201 | 204) return 0 ;; *) return 1 ;; esac; }

sc_num() { printf '%s' "${SC#sc-}"; }

put_state() {  # <state-key>
  local state
  state=$(setting "state_$1")
  [ -n "$state" ] || die "no state_$1 in the Shortcut settings"
  jq -n --argjson s "$state" '{workflow_state_id: $s}' >"$WORK/state.json"
  http_json PUT "/api/v3/stories/$(sc_num)" "$WORK/state.json"
  ok || die "could not move $SC to $1 (HTTP $HTTP_CODE)"
}

story_is_done() {
  http GET "/api/v3/stories/$(sc_num)"
  ok || die "$SC is not a readable Shortcut story (HTTP $HTTP_CODE)"
  [ "$(jq -r '.workflow_state_id // empty' "$WORK/resp")" = "$(setting state_done)" ]
}

post_comment() {  # <text>
  jq -n --arg t "$1" '{text: $t}' >"$WORK/comment.json"
  http_json POST "/api/v3/stories/$(sc_num)/comments" "$WORK/comment.json"
  ok || die "could not comment on $SC (HTTP $HTTP_CODE)"
}

upload() {  # <file>...
  local f
  for f in "$@"; do
    [ -f "$f" ] || die "no such file to attach: $f"
    http POST /api/v3/files -F "file0=@$f" -F "story_id=$(sc_num)"
    ok || die "could not upload $f to $SC (HTTP $HTTP_CODE)"
  done
}

link_pr() {  # <url>
  http GET "/api/v3/stories/$(sc_num)"
  ok || die "$SC is not a readable Shortcut story (HTTP $HTTP_CODE)"
  jq --arg u "$1" '{external_links: ((.external_links // []) + [$u] | unique)}' "$WORK/resp" >"$WORK/links.json"
  http_json PUT "/api/v3/stories/$(sc_num)" "$WORK/links.json"
  ok || die "could not link $1 to $SC (HTTP $HTTP_CODE)"
}

case "$OP" in
  state)
    case "${1:-}" in progress | review) ;; *) die "state takes progress or review; Done only via: done <item> --evidence <text>" ;; esac
    story_is_done && exit 0
    put_state "$1"
    exit 0
    ;;
  review)
    PR='' REPORT=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pr) PR=${2:-}; shift ;;
        --report) REPORT=${2:-}; shift ;;
        *) die "unknown review option: $1" ;;
      esac
      shift
    done
    story_is_done || put_state review
    [ -z "$PR" ] || link_pr "$PR"
    [ -z "$REPORT" ] || upload "$REPORT"
    exit 0
    ;;
  comment)
    if [ "${1:-}" = --file ]; then
      [ -f "${2:-}" ] || die "no such comment file: ${2:-}"
      TEXT=$(cat "$2")
    else
      TEXT=${1:-}
    fi
    [ -n "$TEXT" ] || die "usage: comment <item> <text> | --file <file>"
    post_comment "$TEXT"
    exit 0
    ;;
  attach)
    [ "$#" -gt 0 ] || die "usage: attach <item> <file>..."
    upload "$@"
    exit 0
    ;;
  outcome)
    LINE=
    if [ -f "$STATE/$ID.status" ]; then
      LINE=$(grep -E '^done' "$STATE/$ID.status" | tail -1)
      [ -n "$LINE" ] || LINE=$(tail -1 "$STATE/$ID.status")
    fi
    [ -n "$LINE" ] || exit 0
    post_comment "Final outcome: $LINE"
    exit 0
    ;;
  park)
    [ "${1:-}" = --reason ] && [ -n "${2:-}" ] || die "usage: park <item> --reason <text>"
    story_is_done && exit 0
    put_state backlog
    post_comment "Back to Backlog (work not continuing): $2"
    exit 0
    ;;
  done)
    [ "${1:-}" = --evidence ] && [ -n "${2:-}" ] || die "usage: done <item> --evidence <text> (the captain's word or verified production evidence)"
    put_state "done"
    post_comment "Done: $2"
    exit 0
    ;;
esac

# create
if [ -n "$SC" ]; then
  http GET "/api/v3/stories/$(sc_num)"
  ok || die "$SC named by $ID is not a readable Shortcut story (HTTP $HTTP_CODE)"
  exit 0
fi

DESC=$BODY
[ -n "$DESC" ] || DESC=$(printf -- '- Problem: %s\n- Fix: tracked by firstmate backlog item %s' "$TITLE" "$ID")
jq -n --arg name "$TITLE" --arg desc "$DESC" \
  --arg team "$(setting team_id)" --arg state "$(setting state_backlog)" \
  --arg owner "$(setting owner_id)" --arg type "$(setting story_type feature)" '
  {name: $name, description: $desc, story_type: $type}
  + (if $team != "" then {group_id: $team} else {} end)
  + (if $state != "" then {workflow_state_id: ($state | tonumber)} else {} end)
  + (if $owner != "" then {owner_ids: [$owner]} else {} end)' >"$WORK/req.json" ||
  die "cannot build the story request (check state_backlog in the settings)"

http_json POST /api/v3/stories "$WORK/req.json"
ok || die "Shortcut story creation failed for $ID (HTTP $HTTP_CODE)"
NUM=$(jq -r '.id // empty' "$WORK/resp" 2>/dev/null)
URL=$(jq -r '.app_url // empty' "$WORK/resp" 2>/dev/null)
case "$NUM" in '' | *[!0-9]*) die "Shortcut returned no story id for $ID" ;; esac

{
  [ -z "$BODY" ] || printf '%s\n' "$BODY"
  printf 'Shortcut: sc-%s %s\n' "$NUM" "$URL"
} >"$WORK/body.md"
"$TASKS" update "$ID" --body-file "$WORK/body.md" >/dev/null 2>"$WORK/err" ||
  die "created sc-$NUM but could not record it on $ID: $(head -1 "$WORK/err")"
printf 'fm-shortcut-ticket: %s -> sc-%s %s\n' "$ID" "$NUM" "$URL"
