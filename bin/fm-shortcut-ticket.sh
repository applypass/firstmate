#!/usr/bin/env bash
# fm-shortcut-ticket.sh - keep a backlog item's Shortcut story in sync (applypass fork).
#
# Usage: fm-shortcut-ticket.sh <item-id>                     create the story, in Backlog
#        fm-shortcut-ticket.sh link <item> sc-NNNN           make an existing, unowned story the item's own
#        fm-shortcut-ticket.sh state <item> progress|review  move the story
#        fm-shortcut-ticket.sh review <item> [--pr <url>] [--report <file>]
#                                                            In Review, plus PR link and report upload
#        fm-shortcut-ticket.sh comment <item> <text> | --file <file>
#        fm-shortcut-ticket.sh attach <item> <file>...       upload files (screenshots, reports)
#        fm-shortcut-ticket.sh outcome <item>                comment the task's final status line
#        fm-shortcut-ticket.sh park <item> --reason <text>   back to Backlog with the reason (work abandoned)
#        fm-shortcut-ticket.sh done <item> --evidence <text> move to Done (the captain's word)
#        fm-shortcut-ticket.sh chore <title> [<text>]        file an Engineering/Backlog chore story, print "sc-NNNN <url>"
#                                                            (a decision with no story; bin/fm-decide.sh calls it)
#        fm-shortcut-ticket.sh release-done <release-pr-url> [--evidence <text>] [--task <id>]
#                                                            stories of a merged, deployed release PR to Done
#        fm-shortcut-ticket.sh release-hook <pr-url> [--task <id>]
#                                                            the merge-path form: finish, or say what to run next
#        fm-shortcut-ticket.sh pending                       replay and list calls that failed earlier
#        fm-shortcut-ticket.sh --check <item>                exit 0 if the item has its own, existing story (or is exempt)
#        fm-shortcut-ticket.sh --linked <item>               print the linked sc-NNNN, if any
#        fm-shortcut-ticket.sh --enabled                     exit 0 if the feature is on
# Uploads (attach, review --report) of a .md file also upload <name>.html, a styled
# self-contained render (bin/fm-md-to-html.py, needs python3 with markdown-it-py), because
# Shortcut serves .md attachments as text/html and the browser collapses them; if the
# render fails the .md still uploads, with a warning.
# `comment ... --print-url` also prints the new comment's URL. Any operation accepts --best-effort: a missing sc id or an API failure then
# warns and exits 0, which is how the lifecycle hooks call it. The story
# operations also take the story id (sc-NNNN) in place of the item, for an
# item that no longer exists.
#
# Hooks: bin/fm-tasks-axi.sh add creates the story; bin/fm-spawn.sh refuses a
# ship or scout whose item has no verified story of its own (--check) and moves the story to In Progress on
# dispatch; bin/fm-pr-check.sh moves it to In Review and links the PR;
# bin/fm-captain-hold.sh answer (and keyed answers) comments the recorded decision;
# a landed ship goes to In Review at teardown even without a PR;
# bin/fm-teardown.sh comments the outcome (a scout also goes to In Review with
# its report.md uploaded; a forced teardown moves the story back to Backlog);
# bin/fm-tasks-axi.sh rm or hold --kind parked moves it back to Backlog with
# the reason. Merge and teardown never move a story to Done on their own:
# bin/fm-pr-merge.sh runs release-hook after a verified merge, and release-hook
# or release-done (bin/fm-shortcut-release-lib.sh owns both, and the retry
# record below) moves the stories a release carries to Done once production
# runs it. `done` stays for the captain's word. A call that fails on the token
# or the API leaves a pending record and a `blocked` status line, and the next
# run replays it, so a signed-out 1Password no longer stops stories quietly.
#
# Create: POST /api/v3/stories with name = item title, description = item body
# (or a Problem/Fix stub when empty) plus the ownership marker line
# `firstmate-item: <home-name>/<item-id>` (home-name = basename of FM_HOME),
# team/state/owner from the settings. The `Shortcut: sc-NNNN <url>` line is
# appended to the item body through tasks-axi.
# The item's own story is the one a body line `Shortcut: sc-NNNN` names, and it
# counts only while its description carries a marker for this item id and no
# other: --check and create GET it and refuse otherwise (an umbrella or a story
# another item owns). `link` is the only way to adopt an existing story: it
# refuses one that carries another item's marker, else writes this item's marker
# and records the body line. An `sc-NNNN` in the title is
# a parent (umbrella) reference: create makes the item its own story and links
# it to the parent with a "relates to" story link, never reusing the parent.
# Any other `sc-NNNN` in the body is only a reference: it is never moved,
# commented on, or uploaded to, and the item still gets its own story. `tasks-axi mv` moves the whole item, so a secondmate handoff
# carries the id. Skipped kinds: secondmate and captain (decision-only rows).
#
# Settings: key=value lines from defaults/shortcut-tickets in the code root, then
# config/shortcut-tickets in the home (later wins); an absent defaults file means
# off. FM_SHORTCUT_TICKETS=on|off overrides `enabled`. Keys: enabled, team_id,
# state_backlog, state_progress, state_review, state_done, owner_id, story_type,
# token_ref, op_timeout, api_base. owner_id (the member the home's stories are
# assigned to) and token_ref are per-home: the shipped defaults set neither, and
# --check and create refuse with the line to add to config/shortcut-tickets
# when owner_id is missing, or token_ref is missing while SHORTCUT_API_TOKEN is
# unset.
#
# The API token comes from SHORTCUT_API_TOKEN, else from `op read <token_ref>`
# bounded to op_timeout seconds (default 10), read once per call. Fork-only: op
# runs only with OP_SERVICE_ACCOUNT_TOKEN from the environment, the home .env, or a
# parent home .env up the secondmate chain; without one it is never called. It is held in
# memory only, reaches curl on stdin, never the command line or a child's
# environment, and is never printed or stored. A missing `op`, a failed read, or a read
# that does not answer in time is a concrete refusal (a best-effort caller only
# warns).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TASKS="$SCRIPT_DIR/fm-tasks-axi.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
BEST_EFFORT=0
PRINT_URL=0
CALL_ARGS=()
STATUS_FILE=${FM_SHORTCUT_STATUS_FILE:-}
# shellcheck source=bin/fm-shortcut-release-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-shortcut-release-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_retry() {  # a failure worth retrying: the token or the API
  pending_on_failure "$*"
  die "$@"
}

die() {
  PENDING_FAILED=1
  if [ "$BEST_EFFORT" = 1 ]; then
    printf 'fm-shortcut-ticket: warning: %s%s\n' "$*" "$PENDING_NOTE" >&2
    exit 0
  fi
  printf 'fm-shortcut-ticket: %s%s\n' "$*" "$PENDING_NOTE" >&2
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
  case "$arg" in
    --best-effort) BEST_EFFORT=1 ;;
    --print-url) PRINT_URL=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
# shellcheck disable=SC2034
CALL_ARGS=(${ARGS[@]+"${ARGS[@]}"})

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  --enabled) enabled; exit $? ;;
esac

OP=create
case "${1:-}" in
  --check) OP=check; shift ;;
  --linked) OP=linked; shift ;;
  link | chore | state | review | comment | attach | outcome | park | done | release-done | release-hook | pending) OP=$1; shift ;;
esac
ID=${1:-}
[ -n "$ID" ] || [ "$OP" = pending ] || die "usage: fm-shortcut-ticket.sh [<op>] <item-id> ... (see --help)"
shift

enabled || exit 0
# shellcheck disable=SC2034
case "$ID" in https://*/*) ;; *) [ ! -f "$STATE/$ID.status" ] || STATUS_FILE=$STATE/$ID.status ;; esac

KIND='' TITLE='' BODY='' SC='' PARENT=''
case "$OP" in
  create | check | linked | link | chore) ;;
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

RELEASE=0
case "$OP" in release-done | release-hook | pending) RELEASE=1 ;; esac
case "$OP" in release-done | release-hook) release_parse_args "$ID" "$@" ;; esac
if [ -z "$SC" ] && [ "$RELEASE" = 0 ] && [ "$OP" != chore ]; then
  SHOW=$("$TASKS" show "$ID" --full 2>&1) || die "cannot read backlog item $ID: $(printf '%s' "$SHOW" | head -1)"
  KIND=$(field kind)
  TITLE=$(field title)
  BODY=$(field body)
  SC=$(printf '%s\n' "$BODY" | grep -Ei '^[[:space:]]*Shortcut:[[:space:]]*sc-[0-9]+' | head -1 | grep -Eoi 'sc-[0-9]+' | head -1) || true
  SC=$(printf '%s' "$SC" | tr '[:upper:]' '[:lower:]')
  PARENT=$(printf '%s\n' "$TITLE" | grep -Eoi '\bsc-[0-9]+\b' | head -1 | tr '[:upper:]' '[:lower:]') || true
fi

if [ "$OP" = linked ]; then
  [ -z "$SC" ] || printf '%s\n' "$SC"
  exit 0
fi

require_home_settings() {
  [ -n "$(setting owner_id)" ] ||
    die "no owner_id is configured for this home; add this line to $CONFIG/shortcut-tickets: owner_id=<Shortcut member UUID>"
  [ -n "${SHORTCUT_API_TOKEN:-}" ] || [ -n "$(setting token_ref)" ] ||
    die "SHORTCUT_API_TOKEN is not set and no token_ref is configured; add this line to $CONFIG/shortcut-tickets: token_ref=op://<vault>/<item>/<field>"
}

if [ "$OP" = check ]; then
  case "$KIND" in secondmate | captain) exit 0 ;; esac
  require_home_settings
  [ -n "$SC" ] || die "backlog item $ID has no Shortcut story of its own (a title sc-NNNN is only a parent reference); create one with: bin/fm-shortcut-ticket.sh $ID"
elif [ "$OP" = create ]; then
  case "$KIND" in secondmate | captain) exit 0 ;; esac
  require_home_settings
elif [ "$OP" = link ]; then
  TARGET=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "${TARGET#sc-}" in "$TARGET" | '' | *[!0-9]*) die "usage: link <item> sc-NNNN" ;; esac
  [ -z "$SC" ] || [ "$SC" = "$TARGET" ] || die "backlog item $ID already names $SC as its own story"
  [ "$TARGET" != "$PARENT" ] || die "$TARGET is the parent (umbrella) story in $ID's title, never its own; create its own with: bin/fm-shortcut-ticket.sh $ID"
  SC=$TARGET
elif [ "$OP" = chore ]; then
  require_home_settings
elif [ "$RELEASE" = 0 ] && [ -z "$SC" ]; then
  # A review with no story line cannot link its PR, so release-done will not find it by link.
  [ "$OP" != review ] || ! printf '%s\n' "$@" | grep -Fxq -- --pr || { printf 'fm-shortcut-ticket: warning: backlog item %s has no Shortcut story line (Shortcut: sc-NNNN); its PR is not linked to a story\n' "$ID" >&2; exit 0; }
  [ "$BEST_EFFORT" = 1 ] && exit 0
  die "backlog item $ID names no Shortcut ticket (sc-NNNN)"
fi

API=$(setting api_base "${SHORTCUT_API_BASE:-https://api.app.shortcut.com}")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-shortcut.XXXXXX") || die "cannot create a temp directory"
trap 'pending_clear_on_success $?; rm -rf "$WORK"' EXIT
[ "$OP" != release-hook ] || release_hook_start "$URL" || exit 0

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
RERUN=$(printf ' %q' "${CALL_ARGS[@]}")
TOKEN=${SHORTCUT_API_TOKEN:-}
if [ -z "$TOKEN" ]; then
  TOKEN_REF=$(setting token_ref)
  [ -n "$TOKEN_REF" ] || die "SHORTCUT_API_TOKEN is not set and no token_ref is configured; add this line to $CONFIG/shortcut-tickets: token_ref=op://<vault>/<item>/<field>"
  command -v op >/dev/null 2>&1 || die_retry "SHORTCUT_API_TOKEN is not set and the 1Password CLI (op) is not installed to read $TOKEN_REF; run: bin/fm-shortcut-ticket.sh$RERUN"
  # Fork-only: never reach op without the vault-scoped service account token, so it cannot fall back to the 1Password desktop session.
  # shellcheck source=bin/fm-op-service-account-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-op-service-account-lib.sh"
  OP_SA_TOKEN=$(fm_op_service_account_token "$FM_HOME") || die_retry "service account token missing: OP_SERVICE_ACCOUNT_TOKEN not found in $(fm_op_service_account_sources "$FM_HOME"); set SHORTCUT_API_TOKEN or add OP_SERVICE_ACCOUNT_TOKEN to the .env (the desktop 1Password session is never used); then run: bin/fm-shortcut-ticket.sh$RERUN"
  OP_TIMEOUT=$(setting op_timeout 10)
  case "$OP_TIMEOUT" in '' | 0* | *[!0-9]*) die "op_timeout must be a positive number of seconds (got '$OP_TIMEOUT')" ;; esac
  TOKEN=$(OP_SERVICE_ACCOUNT_TOKEN=$OP_SA_TOKEN fm_run_timed "$OP_TIMEOUT" op read "$TOKEN_REF" 2>/dev/null) || TOKEN=''
  [ -n "$TOKEN" ] || die_retry "SHORTCUT_API_TOKEN is not set and 'op read $TOKEN_REF' failed or did not answer within ${OP_TIMEOUT}s (check that OP_SERVICE_ACCOUNT_TOKEN can read it); then run: bin/fm-shortcut-ticket.sh$RERUN"
fi

HTTP_CODE=
http() {  # <method> <path> [curl args...]; response body lands in $WORK/resp
  local method=$1 path=$2
  shift 2
  HTTP_CODE=$(printf 'header = "Shortcut-Token: %s"\n' "$TOKEN" |
    curl -sS --max-time 30 -K - -o "$WORK/resp" -w '%{http_code}' -X "$method" "$@" "$API$path" 2>"$WORK/err") ||
    HTTP_CODE=000
}
http_json() {  # <method> <path> <json-file>
  http "$1" "$2" -H 'Content-Type: application/json' --data-binary "@$3"
}
ok() { case "$HTTP_CODE" in 200 | 201 | 204) return 0 ;; *) return 1 ;; esac; }

sc_num() { printf '%s' "${SC#sc-}"; }

MARKER="firstmate-item: $(basename "$FM_HOME")/$ID"
story_owners() {  # item ids the markers in the fetched story name, one per line
  jq -r '.description // ""' "$WORK/resp" |
    sed -n 's|^firstmate-item: [^/]*/\([^[:space:]]*\)[[:space:]]*$|\1|p' | sort -u
}
require_own_story() {  # GETs $SC and refuses unless its markers name only this item
  local owners
  http GET "/api/v3/stories/$(sc_num)"
  ok || die_retry "$SC named by $ID is not a readable Shortcut story (HTTP $HTTP_CODE); create one with: bin/fm-shortcut-ticket.sh $ID"
  owners=$(story_owners)
  [ "$owners" = "$ID" ] && return 0
  [ -n "$owners" ] &&
    die "$SC named by $ID belongs to another item ($(printf '%s' "$owners" | tr '\n' ' ')); remove the Shortcut line and create its own with: bin/fm-shortcut-ticket.sh $ID"
  die "$SC named by $ID carries no '$MARKER' marker. If $SC was created for this item (before ownership markers), mark it: bin/fm-shortcut-ticket.sh link $ID $SC. If it is a shared or umbrella story, remove the Shortcut line and create the item's own story: bin/fm-shortcut-ticket.sh $ID"
}

record_body_line() {  # <num> <url>
  {
    [ -z "$BODY" ] || printf '%s\n' "$BODY"
    printf 'Shortcut: sc-%s %s\n' "$1" "$2"
  } >"$WORK/body.md"
  "$TASKS" update "$ID" --body-file "$WORK/body.md" >/dev/null 2>"$WORK/err" ||
    die "sc-$1 is $ID's story but could not be recorded on it: $(head -1 "$WORK/err")"
}

put_state() {  # <state-key>
  local state
  state=$(setting "state_$1")
  [ -n "$state" ] || die "no state_$1 in the Shortcut settings"
  jq -n --argjson s "$state" '{workflow_state_id: $s}' >"$WORK/state.json"
  http_json PUT "/api/v3/stories/$(sc_num)" "$WORK/state.json"
  ok || die_retry "could not move $SC to $1 (HTTP $HTTP_CODE)"
}

story_is_done() {
  http GET "/api/v3/stories/$(sc_num)"
  ok || die_retry "$SC is not a readable Shortcut story (HTTP $HTTP_CODE)"
  [ "$(jq -r '.workflow_state_id // empty' "$WORK/resp")" = "$(setting state_done)" ]
}

post_comment() {  # <text>
  jq -n --arg t "$1" '{text: $t}' >"$WORK/comment.json"
  http_json POST "/api/v3/stories/$(sc_num)/comments" "$WORK/comment.json"
  ok || die_retry "could not comment on $SC (HTTP $HTTP_CODE)"
}

upload_one() {  # <file>
  http POST /api/v3/files -F "file0=@$1" -F "story_id=$(sc_num)"
  ok || die_retry "could not upload $1 to $SC (HTTP $HTTP_CODE)"
}

html_copy() {  # <md-file>; prints the rendered copy's path, nothing when the render fails
  local md=$1 out py
  out="$WORK/html/$(basename "${md%.*}").html"
  py=$(command -v python3) || { printf 'fm-shortcut-ticket: warning: python3 not found, %s uploads without an HTML copy\n' "$md" >&2; return 0; }
  mkdir -p "$WORK/html"
  if "$py" "$SCRIPT_DIR/fm-md-to-html.py" "$md" "$out" 2>"$WORK/render.err"; then
    printf '%s' "$out"
  else
    printf 'fm-shortcut-ticket: warning: could not render %s to HTML (%s); uploading the .md only\n' "$md" "$(head -1 "$WORK/render.err")" >&2
  fi
}

upload() {  # <file>...
  local f copy
  for f in "$@"; do
    [ -f "$f" ] || die "no such file to attach: $f"
    upload_one "$f"
    # Fork-only: Shortcut serves an uploaded .md as text/html and the browser collapses it, so a .md also goes up as a styled .html.
    case "$f" in
      *.md | *.MD)
        copy=$(html_copy "$f")
        [ -z "$copy" ] || upload_one "$copy"
        ;;
    esac
  done
}

link_pr() {  # <url>
  http GET "/api/v3/stories/$(sc_num)"
  ok || die_retry "$SC is not a readable Shortcut story (HTTP $HTTP_CODE)"
  jq --arg u "$1" '{external_links: ((.external_links // []) + [$u] | unique)}' "$WORK/resp" >"$WORK/links.json"
  http_json PUT "/api/v3/stories/$(sc_num)" "$WORK/links.json"
  ok || die_retry "could not link $1 to $SC (HTTP $HTTP_CODE)"
}

if [ "$OP" = check ]; then
  require_own_story
  exit 0
fi

if [ "$OP" = link ]; then
  http GET "/api/v3/stories/$(sc_num)"
  ok || die_retry "$SC is not a readable Shortcut story (HTTP $HTTP_CODE)"
  OWNERS=$(story_owners)
  URL=$(jq -r '.app_url // empty' "$WORK/resp")
  if [ -z "$OWNERS" ]; then
    jq --arg m "$MARKER" '{description: (if (.description // "") == "" then $m else .description + "\n\n" + $m end)}' \
      "$WORK/resp" >"$WORK/desc.json"
    http_json PUT "/api/v3/stories/$(sc_num)" "$WORK/desc.json"
    ok || die_retry "could not mark $SC as $ID's own story (HTTP $HTTP_CODE)"
  elif [ "$OWNERS" != "$ID" ]; then
    die "$SC already belongs to another item ($(printf '%s' "$OWNERS" | tr '\n' ' ')); give $ID its own story with: bin/fm-shortcut-ticket.sh $ID"
  fi
  printf '%s\n' "$BODY" | grep -Eiq '^[[:space:]]*Shortcut:[[:space:]]*sc-[0-9]+' || record_body_line "$(sc_num)" "$URL"
  printf 'fm-shortcut-ticket: %s -> %s %s\n' "$ID" "$SC" "$URL"
  exit 0
fi

pending_replay
case "$OP" in
  pending)
    pending_report
    exit 0
    ;;
  release-hook | release-done)
    if [ "$OP" = release-hook ]; then
      release_hook "$URL"
    else
      release_done "$URL" "${EVIDENCE:-confirmed by firstmate that production runs the merged release}"
    fi
    exit 0
    ;;
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
    [ "$PRINT_URL" = 0 ] || jq -r '.app_url // empty' "$WORK/resp"
    exit 0
    ;;
  chore)
    jq -n --arg name "$ID" --arg desc "${1:-}" \
      --arg team "$(setting team_id)" --arg state "$(setting state_backlog)" --arg owner "$(setting owner_id)" '
      {name: $name, description: $desc, story_type: "chore"}
      + (if $team != "" then {group_id: $team} else {} end)
      + (if $state != "" then {workflow_state_id: ($state | tonumber)} else {} end)
      + (if $owner != "" then {owner_ids: [$owner]} else {} end)' >"$WORK/req.json" ||
      die "cannot build the chore request (check state_backlog in the settings)"
    http_json POST /api/v3/stories "$WORK/req.json"
    ok || die "Shortcut chore creation failed (HTTP $HTTP_CODE)"
    NUM=$(jq -r '.id // empty' "$WORK/resp" 2>/dev/null)
    case "$NUM" in '' | *[!0-9]*) die "Shortcut returned no story id for the chore" ;; esac
    printf 'sc-%s %s\n' "$NUM" "$(jq -r '.app_url // empty' "$WORK/resp")"
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
  require_own_story
  exit 0
fi

DESC=$BODY
[ -n "$DESC" ] || DESC=$(printf -- '- Problem: %s\n- Fix: tracked by firstmate backlog item %s' "$TITLE" "$ID")
DESC=$(printf '%s\n\n%s' "$DESC" "$MARKER")
jq -n --arg name "$TITLE" --arg desc "$DESC" \
  --arg team "$(setting team_id)" --arg state "$(setting state_backlog)" \
  --arg owner "$(setting owner_id)" --arg type "$(setting story_type feature)" '
  {name: $name, description: $desc, story_type: $type}
  + (if $team != "" then {group_id: $team} else {} end)
  + (if $state != "" then {workflow_state_id: ($state | tonumber)} else {} end)
  + (if $owner != "" then {owner_ids: [$owner]} else {} end)' >"$WORK/req.json" ||
  die "cannot build the story request (check state_backlog in the settings)"

http_json POST /api/v3/stories "$WORK/req.json"
ok || die_retry "Shortcut story creation failed for $ID (HTTP $HTTP_CODE)"
NUM=$(jq -r '.id // empty' "$WORK/resp" 2>/dev/null)
URL=$(jq -r '.app_url // empty' "$WORK/resp" 2>/dev/null)
case "$NUM" in '' | *[!0-9]*) die "Shortcut returned no story id for $ID" ;; esac

record_body_line "$NUM" "$URL"
if [ -n "$PARENT" ]; then
  jq -n --argjson s "$NUM" --argjson o "${PARENT#sc-}" '{subject_id: $s, object_id: $o, verb: "relates to"}' >"$WORK/link.json"
  http_json POST /api/v3/story-links "$WORK/link.json"
  ok || printf 'fm-shortcut-ticket: warning: sc-%s was created but could not be linked to parent %s (HTTP %s)\n' "$NUM" "$PARENT" "$HTTP_CODE" >&2
fi
printf 'fm-shortcut-ticket: %s -> sc-%s %s\n' "$ID" "$NUM" "$URL"
