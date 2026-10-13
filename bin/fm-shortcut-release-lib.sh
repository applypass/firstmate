#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153
# fm-shortcut-release-lib.sh - release-done and the retry record for
# bin/fm-shortcut-ticket.sh (applypass fork only; sourced, never run).
#
# Release-done: when a release PR (base `release_base`, default main) merges and
# production runs its merge commit, every Shortcut story linked to a PR the
# release carries moves to Done with an evidence comment, and the firstmate
# backlog item that owns the story closes in the same call. Only the home's
# owner_id stories, or unassigned stories carrying a firstmate marker, are ever
# touched; anyone else's story is skipped untouched. A story with open
# work (another open PR, or no firstmate ownership marker because it is an
# umbrella or shared story) stays where it is and gets a comment instead.
#   release-hook <pr-url>  run by bin/fm-pr-merge.sh after a verified merge: for
#                          a repo in `vercel_repos`, finish the release once a
#                          READY production deployment covers the merge commit
#                          (else keep a pending record); for any other repo,
#                          print the release-done command to run after the
#                          prod deploy is confirmed.
#   release-done <pr-url>  the same finish, run by firstmate once it has
#                          confirmed the deploy; takes --evidence <text>.
#   pending                replay every pending record and list what remains.
#
# Retry record: a call that fails on the token or the Shortcut API leaves
# $STATE/shortcut-pending/<key>.args (the call) and <key>.meta (reason, the
# status file to tell). The first failure of a call appends a keyed `blocked`
# line to that status file, so it reaches firstmate; the next run of any
# fm-shortcut-ticket.sh operation replays the record, and a success clears it
# and appends the matching `resolved` line. A merge whose production deploy is
# not up yet keeps a record without the status line: that wait is expected.

PENDING_DIR="$STATE/shortcut-pending"
PENDING_FAILED=0
PENDING_NOTE=''

pending_key() { printf '%s\0' "$@" | cksum | cut -d' ' -f1; }

pending_status() {  # <verb> <key> <text>; appends to the call's status file
  local f=${STATUS_FILE:-}
  [ -n "$f" ] && [ -f "$f" ] || return 0
  printf '%s [at=%s] [key=%s]: %s\n' "$1" "$(date +%s)" "$2" "$3" >>"$f" 2>/dev/null || true
}

pending_record() {  # <quiet:0|1> <reason> <arg>...; returns 0 when the record is new
  local quiet=$1 reason=$2 key f new=0
  shift 2
  key=sc-$(pending_key "$@")
  f="$PENDING_DIR/$key"
  [ -f "$f.args" ] || new=1
  mkdir -p "$PENDING_DIR" || return 1
  printf '%s\0' "$@" >"$f.args.tmp" && mv "$f.args.tmp" "$f.args"
  printf 'reason=%s\nstatus=%s\n' "$reason" "${STATUS_FILE:-}" >"$f.meta"
  PENDING_FAILED=1
  if [ "$new" = 1 ] && [ "$quiet" = 0 ]; then
    pending_status blocked "shortcut-sync-$key" "Shortcut did not update ($reason); queued, retried on the next fm-shortcut-ticket.sh run or by: fm-shortcut-ticket.sh pending"
  fi
  return $((1 - new))
}

pending_on_failure() {  # <message>; called by die_retry, never during a replay
  [ "${FM_SHORTCUT_REPLAY:-}" != 1 ] || { PENDING_FAILED=1; return 0; }
  case "$OP" in state | review | comment | outcome | park | done | release-done | release-hook) ;; *) return 0 ;; esac
  [ "${#CALL_ARGS[@]}" -gt 0 ] || return 0
  pending_record 0 "$1" "${CALL_ARGS[@]}" || true
  PENDING_NOTE=" (queued for retry: $PENDING_DIR)"
}

pending_clear_on_success() {  # <exit-code>; the EXIT trap of the call
  local key f status
  [ "$1" = 0 ] && [ "$PENDING_FAILED" = 0 ] && [ "${#CALL_ARGS[@]}" -gt 0 ] || return 0
  key=sc-$(pending_key "${CALL_ARGS[@]}")
  f="$PENDING_DIR/$key"
  [ -f "$f.args" ] || return 0
  status=$(sed -n 's/^status=//p' "$f.meta" 2>/dev/null | head -1)
  rm -f "$f.args" "$f.meta"
  STATUS_FILE=$status pending_status resolved "shortcut-sync-$key" "Shortcut update went through on retry"
}

pending_replay() {  # replays every record but the current call's own
  local f key cur args a
  [ "${FM_SHORTCUT_REPLAY:-}" != 1 ] && [ -d "$PENDING_DIR" ] || return 0
  cur=sc-$(pending_key "${CALL_ARGS[@]}")
  for f in "$PENDING_DIR"/sc-*.args; do
    [ -f "$f" ] || continue
    key=$(basename "$f" .args)
    [ "$key" != "$cur" ] || continue
    args=()
    while IFS= read -r -d '' a; do args+=("$a"); done <"$f"
    [ "${#args[@]}" -gt 0 ] || continue
    FM_SHORTCUT_REPLAY=1 "$0" "${args[@]}" >/dev/null 2>&1 || true
  done
}

pr_parts() {  # <pr-url> -> sets PR_OWNER PR_REPO PR_NUM; fails for a non-GitHub url
  local re='^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)/?$'
  [[ "$1" =~ $re ]] || return 1
  PR_OWNER=${BASH_REMATCH[1]} PR_REPO=${BASH_REMATCH[2]} PR_NUM=${BASH_REMATCH[3]}
}

carried_prs() {  # <release-pr-url>: the release itself plus every #N its commits name
  local url=$1 msg n
  printf '%s\n' "$url"
  pr_parts "$url" || return 0
  gh api "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUM/commits" --paginate --jq '.[].commit.message | split("\n")[0]' 2>/dev/null |
    while IFS= read -r msg; do
      for n in $(printf '%s\n' "$msg" | grep -Eo '(\(#[0-9]+\)|Merge pull request #[0-9]+)' | grep -Eo '[0-9]+'); do
        printf 'https://github.com/%s/%s/pull/%s\n' "$PR_OWNER" "$PR_REPO" "$n"
      done
    done | sort -u
}

production_evidence() {  # <owner> <repo> <sha>: prints the evidence when a READY production deployment covers sha
  local o=$1 r=$2 sha=$3 line id dsha state rel
  gh api "repos/$o/$r/deployments?environment=Production&per_page=20" --jq '.[] | "\(.id) \(.sha)"' 2>/dev/null |
    while read -r id dsha; do
      state=$(gh api "repos/$o/$r/deployments/$id/statuses" --jq '.[0].state' 2>/dev/null) || continue
      [ "$state" = success ] || continue
      if [ "$dsha" != "$sha" ]; then
        rel=$(gh api "repos/$o/$r/compare/$sha...$dsha" --jq .status 2>/dev/null) || continue
        case "$rel" in ahead | identical) ;; *) continue ;; esac
      fi
      line=$(gh api "repos/$o/$r/deployments/$id/statuses" --jq '.[0].environment_url // .[0].target_url // ""' 2>/dev/null)
      printf 'Vercel production deployment %s READY at %s (covers %s)\n' "$id" "${line:-no url}" "${sha:0:9}"
      return 0
    done
}

story_urls() {  # the story's linked PR urls from $WORK/resp
  jq -r '(.external_links // [])[] | select(test("/pull/[0-9]+"))' "$WORK/resp"
}

story_is_ours() {  # <marker-owners>; the story in $WORK/resp is the home owner's, or unassigned and firstmate's
  local assignees
  assignees=$(jq -r '(.owner_ids // [])[]' "$WORK/resp")
  [ "$assignees" = "$(setting owner_id)" ] && return 0
  [ -z "$assignees" ] && [ -n "$1" ]
}

release_done() {  # <release-pr-url> <evidence>
  local release=$1 evidence=$2 carried pr ids id owner prs p state held done_list='' held_list=''
  carried=$(carried_prs "$release") || true
  : >"$WORK/ids"
  for pr in $carried; do
    http GET "/api/v3/external-link/stories?external_link=$(jq -rn --arg u "$pr" '$u|@uri')"
    ok || die_retry "could not look up the Shortcut stories linked to $pr (HTTP $HTTP_CODE)"
    jq -r '.[].id' "$WORK/resp" >>"$WORK/ids"
  done
  ids=$(sort -un "$WORK/ids")
  for id in $ids; do
    SC=sc-$id
    http GET "/api/v3/stories/$id"
    ok || die_retry "$SC is not a readable Shortcut story (HTTP $HTTP_CODE)"
    [ "$(jq -r '.workflow_state_id // empty' "$WORK/resp")" != "$(setting state_done)" ] || continue
    owner=$(story_owners)
    story_is_ours "$owner" || continue
    prs=$(story_urls)
    held=''
    [ -n "$owner" ] || held="it carries no firstmate ownership marker (umbrella or shared story)"
    for p in $prs; do
      printf '%s\n' "$carried" | grep -Fxq "$p" && continue
      pr_parts "$p" || continue
      state=$(gh pr view "$p" --json state --jq .state 2>/dev/null) || { held="could not read $p"; break; }
      [ "$state" != OPEN ] || { held="$p is still open"; break; }
    done
    if [ -n "$held" ]; then
      post_comment "Release $release merged; $SC stays In Review because $held."
      held_list="$held_list $SC"
      continue
    fi
    put_state "done"
    post_comment "$(printf 'Done: merged to the release branch and running in production.\nPRs: %s\nRelease PR: %s\nDeploy evidence: %s' "$(printf '%s' "$prs" | tr '\n' ' ')" "$release" "$evidence")"
    done_list="$done_list $SC"
    close_backlog_item "$owner" "$prs"
  done
  printf 'fm-shortcut-ticket: release %s: Done:%s; left In Review:%s\n' "$release" "${done_list:- none}" "${held_list:- none}"
}

close_backlog_item() {  # <item-id> <pr-urls>; a firstmate record that cannot close is a warning
  local item=$1 pr show
  case "$item" in '' | *$'\n'*) return 0 ;; esac
  show=$("$TASKS" show "$item" 2>/dev/null) || return 0
  case "$(printf '%s\n' "$show" | sed -n 's/^  state: *//p' | head -1)" in done | '') return 0 ;; esac
  pr=$(printf '%s\n' "$2" | head -1)
  "$TASKS" "done" "$item" ${pr:+--pr "$pr"} >/dev/null ||
    printf 'fm-shortcut-ticket: warning: %s is Done in Shortcut but its backlog item did not close; run: bin/fm-tasks-axi.sh done %s\n' "$item" "$item" >&2
}

release_parse_args() {  # <url> [--task <id>] [--evidence <text>]; sets URL TASK EVIDENCE and the status file
  URL=$1 TASK='' EVIDENCE=''
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) TASK=${2:-}; shift ;;
      --evidence) EVIDENCE=${2:-}; shift ;;
      *) die "unknown $OP option: $1" ;;
    esac
    shift
  done
  [ -z "$TASK" ] || [ ! -f "$STATE/$TASK.status" ] || STATUS_FILE=$STATE/$TASK.status
  pr_parts "$URL" || die "usage: $OP <https://github.com/o/r/pull/N>"
}

release_probe() {  # <pr-url>: sets RELEASE_BASE RELEASE_SHA; fails (quietly) unless the PR merged into the release base
  local info state
  command -v gh >/dev/null 2>&1 || die_retry "gh is required to tell whether $1 is a release"
  info=$(gh pr view "$1" --json baseRefName,state,mergeCommit --jq '[.baseRefName, .state, (.mergeCommit.oid // "")] | @tsv' 2>/dev/null) ||
    die_retry "could not read $1 to decide whether it is a release"
  IFS=$'\t' read -r RELEASE_BASE state RELEASE_SHA <<<"$info"
  [ "$state" = MERGED ] && [ "$RELEASE_BASE" = "$(setting release_base main)" ]
}

release_hook() {  # <pr-url>, after release_probe
  local url=$1 sha=$RELEASE_SHA evidence
  case " $(setting vercel_repos) " in
    *" $PR_REPO "*)
      evidence=$(production_evidence "$PR_OWNER" "$PR_REPO" "$sha")
      if [ -n "$evidence" ]; then
        release_done "$url" "$evidence"
      else
        pending_record 1 "awaiting a READY production deployment of ${sha:0:9}" "${CALL_ARGS[@]}" || true
        printf 'fm-shortcut-ticket: %s merged to %s; stories move to Done once production runs %s (retried on the next run)\n' "$url" "$RELEASE_BASE" "${sha:0:9}"
      fi
      ;;
    *)
      printf 'fm-shortcut-ticket: %s merged to %s and deploys from the captain terminal. After confirming production runs %s, run: bin/fm-shortcut-ticket.sh release-done %s\n' \
        "$url" "$RELEASE_BASE" "${sha:0:9}" "$url"
      ;;
  esac
}

pending_report() {  # replay, then list what remains
  local f left=0
  pending_replay
  for f in "$PENDING_DIR"/sc-*.meta; do
    [ -f "$f" ] || continue
    left=$((left + 1))
    printf 'pending: %s\n' "$(sed -n 's/^reason=//p' "$f" | head -1)"
  done
  printf 'fm-shortcut-ticket: %s pending record(s) remain\n' "$left"
}
