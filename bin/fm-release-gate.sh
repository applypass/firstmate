#!/usr/bin/env bash
# fm-release-gate.sh - release gate for dev-to-main release PRs (applypass fork).
#
# Usage: fm-release-gate.sh table   <release-pr-url>
#        fm-release-gate.sh refresh <release-pr-url>
#        fm-release-gate.sh check   <release-pr-url>
#
# Before a main merge, every PR the release carries needs a row proving the
# decision it implements is recorded and still current, and a stored-data or
# API-field change needs a reader-and-writer audit.
#
# A release carries the PRs behind the commits of `compare main...dev`. Per PR:
#   story     sc-N tokens in its title, body, or branch name
#   decision  1. its backlog item (the item whose text names the PR url): decided.md
#                keys plan-<item> and <item>-*;
#             2. else the decided.md entries stamped with one of the PR's stories;
#             3. else none
#   current   yes unless a LATER decided.md entry's "(supersedes: ...)" suffix names
#             a listed decision key, one of the PR's stories (sc-N), or <repo>#<N>
#             (and that entry is not itself a listed decision), or an open re-check
#             item exists. A re-check item has id recheck-*, body line pr=<url>;
#             with re-check items, the PR is current only when every one is done.
#   data/API  the PR diff touches a glob from config/release-gate (see below)
#   audit     the PR body has a "## Reader and writer audit" heading, or
#             data/<item>/reader-writer-audit.md exists; needed only with a data/API change
# A row fails when the decision is none, it is not current, or a data/API change has
# no audit. A waiver passes a row: decided.md key
#   release-waiver-<repo>-<release-pr>-<pr>   with text starting "waived:"
# recorded with bin/fm-decide.sh. A general "ship as is" waives no row.
#
# table    print the rows as a markdown table.
# refresh  rewrite only the block between the fm-release-gate markers in the release
#          PR body (appended when absent); the rest of the body is untouched.
# check    exit 0 when every row passes; exit 1 listing every failing row and its
#          waiver command. A PR that is not dev into main, or in a repo not listed
#          in config/release-gate, passes with a note.
#
# config/release-gate (optional), one repo per line, "#" comments:
#   <owner>/<repo> [glob ...]
# A repo with no globs uses the default globs. Without the file the covered repos
# are applypass/apply_pass_backend and applypass/apply_pass_frontend. Default globs:
#   schema.sql scripts/*.sql migrations/** swagger.yml
# (a "*" matches across directories).
#
# Overrides (tests): FM_RELEASE_GATE_GH (the gh command), FM_DATA_OVERRIDE,
# FM_BACKLOG_OVERRIDE, FM_RELEASE_GATE_CONFIG.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DECIDED="$DATA/decided.md"
BACKLOG="${FM_BACKLOG_OVERRIDE:-$DATA/backlog.md}"
ARCHIVE="${FM_BACKLOG_ARCHIVE_OVERRIDE:-$DATA/done-archive.md}"
CONFIG="${FM_RELEASE_GATE_CONFIG:-$FM_HOME/config/release-gate}"
GH="${FM_RELEASE_GATE_GH:-gh}"
DEFAULT_REPOS="applypass/apply_pass_backend applypass/apply_pass_frontend"
DEFAULT_GLOBS="schema.sql scripts/*.sql migrations/** swagger.yml"
MARK_START='<!-- fm-release-gate:start -->'
MARK_END='<!-- fm-release-gate:end -->'

usage() {
  echo "usage: fm-release-gate.sh table|refresh|check <release-pr-url>" >&2
  exit 2
}

die() {
  echo "fm-release-gate: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required"
[ "$#" -eq 2 ] || usage
SUB=$1
URL=$2
case "$SUB" in table | refresh | check) ;; *) usage ;; esac

re='^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)/?$'
[[ "$URL" =~ $re ]] || die "not a GitHub PR url: $URL"
OWNER=${BASH_REMATCH[1]} REPO=${BASH_REMATCH[2]} NUM=${BASH_REMATCH[3]}
SLUG="$OWNER/$REPO"
URL="https://github.com/$SLUG/pull/$NUM"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# covered_globs: prints the globs for SLUG and returns 0, or returns 1 when not covered.
covered_globs() {
  local want line repo rest
  want=$(lower "$SLUG")
  if [ -f "$CONFIG" ]; then
    while IFS= read -r line; do
      line=${line%%#*}
      [ -n "${line//[[:space:]]/}" ] || continue
      repo=${line%%[[:space:]]*}
      rest=${line#"$repo"}
      [ "$(lower "$repo")" = "$want" ] || continue
      rest=$(printf '%s' "$rest" | xargs 2>/dev/null || printf '%s' "$rest")
      printf '%s\n' "${rest:-$DEFAULT_GLOBS}"
      return 0
    done < "$CONFIG"
    return 1
  fi
  for repo in $DEFAULT_REPOS; do
    [ "$(lower "$repo")" = "$want" ] && { printf '%s\n' "$DEFAULT_GLOBS"; return 0; }
  done
  return 1
}

# ---- decided.md ------------------------------------------------------------
# entries: "<line-no>\t<key>\t<text>" per "- [key] ..." line
entries() {
  [ -f "$DECIDED" ] || return 0
  awk '/^- \[[^]]+\] / { k = $0; sub(/^- \[/, "", k); sub(/\].*/, "", k);
    t = $0; sub(/^- \[[^]]*\] /, "", t); sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2} /, "", t); printf "%d\t%s\t%s\n", NR, k, t }' "$DECIDED"
}

# ---- backlog ---------------------------------------------------------------
# items: "<id>\t<done 0|1>\t<text with newlines as \x1f>"
items() {
  local f
  for f in "$BACKLOG" "$ARCHIVE"; do
    [ -f "$f" ] || continue
    awk '
      function flush() { if (id != "") printf "%s\t%d\t%s\n", id, done, text; id = "" }
      /^- \[[ xX]\] / { flush(); done = ($0 ~ /^- \[[xX]\]/); id = $0; sub(/^- \[[ xX]\] /, "", id); sub(/[ ].*/, "", id); text = $0; next }
      /^  / && id != "" { text = text "\037" $0; next }
      { flush() }
      END { flush() }' "$f"
  done
}

gh_json() { "$GH" "$@" 2>/dev/null; }

# carried_prs: PR numbers (merged to dev) behind the commits main lacks.
carried_prs() {
  local sha
  gh_json api "repos/$SLUG/compare/main...dev" --paginate --jq '.commits[].sha' |
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      gh_json api "repos/$SLUG/commits/$sha/pulls" --jq '.[] | select(.base.ref == "dev") | .number'
    done | sort -n -u
}

glob_hit() {  # <file> <globs>: prints the file when it matches a glob
  local f=$1 g
  # shellcheck disable=SC2086
  for g in $2; do
    # shellcheck disable=SC2053
    [[ "$f" == $g ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

ENTRIES=$(entries)
ITEMS=$(items)
GLOBS=''
COVERED=0
if GLOBS=$(covered_globs); then COVERED=1; fi

# header cells: PR | Story | Decision | Current | Data/API | Audit | Status
ROWS=''      # table lines
FAILS=''     # failing row lines (with waiver command)
build_rows() {
  local n json title body branch stories hit item decs k text line later sup ref id d f why
  local current cur_note data audit status rc_open rc_total rc_done wkey waived row url dn
  local superseded sc
  for n in $(carried_prs); do
    url="https://github.com/$SLUG/pull/$n"
    json=$(gh_json pr view "$n" --repo "$SLUG" --json title,body,headRefName,files) || json='{}'
    title=$(jq -r '.title // ""' <<<"$json")
    body=$(jq -r '.body // ""' <<<"$json")
    branch=$(jq -r '.headRefName // ""' <<<"$json")
    stories=$(
      { printf '%s\n' "$title" "$body" | sed -E 's#https?://[^[:space:])>]*##g'; printf '%s\n' "$branch"; } |
        tr -c 'A-Za-z0-9_\n-' ' ' | tr ' ' '\n' | sed -nE 's/^[sS][cC]-([0-9]+)(-.*)?$/sc-\1/p' | sort -u
    )
    # the PR's backlog item: the one whose text names the PR url
    item=''
    while IFS=$'\t' read -r id _ text; do
      [ -n "$id" ] || continue
      case "$id" in recheck-*) continue ;; esac
      if [[ "$(lower "$text")" == *"$(lower "$url")"* ]]; then
        item=$id
        break
      fi
    done <<<"$ITEMS"
    # decisions
    decs=''
    if [ -n "$item" ]; then
      while IFS=$'\t' read -r line k text; do
        [ -n "$k" ] || continue
        case "$k" in "plan-$item" | "$item"-*) decs="$decs $k" ;; esac
      done <<<"$ENTRIES"
    fi
    if [ -z "$decs" ] && [ -n "$stories" ]; then
      while IFS=$'\t' read -r line k text; do
        [ -n "$k" ] || continue
        case "$k" in release-waiver-*) continue ;; esac
        for sc in $stories; do
          if [[ "$text" =~ \(shortcut:\ (pending\ )?$sc([^0-9]|\)|$) ]]; then
            decs="$decs $k"
            break
          fi
        done
      done <<<"$ENTRIES"
    fi
    decs=${decs# }
    # superseded by a later entry
    superseded=''
    if [ -n "$decs" ]; then
      while IFS=$'\t' read -r line k text; do
        [ -n "$k" ] || continue
        if [[ "$text" =~ \(supersedes:\ ([^\)]*)\) ]]; then
          sup=${BASH_REMATCH[1]}
        else
          continue
        fi
        case " $decs " in *" $k "*) continue ;; esac
        for ref in ${sup//,/ }; do
          ref=$(lower "$ref")
          hit=0
          for d in $decs; do
            [ "$ref" = "$(lower "$d")" ] && [ "$line" -gt "$(decision_line "$d")" ] && hit=1
          done
          for sc in $stories; do [ "$ref" = "$sc" ] && hit=1; done
          [ "$ref" = "$(lower "$REPO")#$n" ] && hit=1
          [ "$hit" = 1 ] || continue
          # only a later entry than a listed decision supersedes it
          later=0
          for d in $decs; do [ "$line" -gt "$(decision_line "$d")" ] && later=1; done
          if [ "$later" = 1 ]; then
            superseded="superseded by $k (supersedes: $ref)"
            break 2
          fi
        done
      done <<<"$ENTRIES"
    fi
    # re-check items
    rc_total=0 rc_done=0 rc_open=''
    while IFS=$'\t' read -r id dn text; do
      case "$id" in recheck-*) ;; *) continue ;; esac
      [[ "$(lower "$text")" == *"pr=$(lower "$url")"* ]] || continue
      rc_total=$((rc_total + 1))
      if [ "$dn" = 1 ]; then rc_done=$((rc_done + 1)); else rc_open="$rc_open $id"; fi
    done <<<"$ITEMS"
    if [ "$rc_total" -gt 0 ]; then
      if [ "$rc_done" -eq "$rc_total" ]; then current=yes cur_note=''
      else current=no cur_note="open re-check${rc_open}"; fi
    elif [ -n "$superseded" ]; then
      current=no cur_note="$superseded"
    else
      current=yes cur_note=''
    fi
    # data or API change
    hit=''
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      hit=$(glob_hit "$f" "$GLOBS") && break
      hit=''
    done < <(jq -r '(.files // [])[] | .path' <<<"$json")
    if [ -n "$hit" ]; then data="yes ($hit)"; else data=no; fi
    # audit
    audit=no
    if grep -qiE '^#{1,6}[[:space:]]+Reader and writer audit[[:space:]]*$' <<<"$body"; then
      audit=yes
    elif [ -n "$item" ] && [ -f "$DATA/$item/reader-writer-audit.md" ]; then
      audit="yes (data/$item/reader-writer-audit.md)"
    fi
    [ -n "$hit" ] || audit="n/a"
    # status
    status=ok
    why=''
    [ -n "$decs" ] || { status=FAIL; why="no decision recorded"; }
    [ "$current" = yes ] || { status=FAIL; why="${why:+$why; }NOT CURRENT: $cur_note"; }
    if [ -n "$hit" ] && [ "$audit" = no ]; then status=FAIL; why="${why:+$why; }data/API change ($hit) without a reader and writer audit"; fi
    wkey="release-waiver-$REPO-$NUM-$n"
    waived=0
    while IFS=$'\t' read -r line k text; do
      [ "$(lower "$k")" = "$(lower "$wkey")" ] && [[ "$text" == waived:* ]] && waived=1
    done <<<"$ENTRIES"
    if [ "$status" = FAIL ] && [ "$waived" = 1 ]; then status="waived"; fi
    row="| [#$n]($url) | ${stories//$'\n'/ } | ${decs:-none} | ${current}${cur_note:+ ($cur_note)} | $data | $audit | $status |"
    ROWS="$ROWS$row"$'\n'
    if [ "$status" = FAIL ]; then
      FAILS="$FAILS#$n ${stories//$'\n'/ } ${decs:-none} - $why"$'\n'
      FAILS="$FAILS  waive: bin/fm-decide.sh record $wkey \"waived: Captain <date>: <words naming $REPO#$n>\""$'\n'
    fi
  done
}

decision_line() {  # <key>: line number of its entry
  local line k _t
  while IFS=$'\t' read -r line k _t; do
    [ "$k" = "$1" ] && { printf '%s' "$line"; return; }
  done <<<"$ENTRIES"
  printf '0'
}

render_table() {
  printf '| PR | Story | Decision it implements | Current? | Data or API change | Reader and writer audit | Status |\n'
  printf '|---|---|---|---|---|---|---|\n'
  printf '%s' "$ROWS"
}

# A release is dev into main; anything else is not gated.
release_shape_ok() {
  local pr
  pr=$(gh_json pr view "$URL" --json baseRefName,headRefName) || return 0
  [ "$(jq -r '.baseRefName // ""' <<<"$pr")" = main ] && [ "$(jq -r '.headRefName // ""' <<<"$pr")" = dev ]
}

if [ "$COVERED" = 0 ]; then
  echo "fm-release-gate: $SLUG is not covered by the release gate (config/release-gate); nothing to check" >&2
  case "$SUB" in table) echo "Release gate: $SLUG is not covered." ;; esac
  exit 0
fi
if ! release_shape_ok; then
  echo "fm-release-gate: $URL is not a dev-to-main release; nothing to check" >&2
  exit 0
fi

build_rows

case "$SUB" in
  table) render_table ;;
  check)
    if [ -n "$FAILS" ]; then
      echo "release gate: $URL carries PRs that fail the gate:" >&2
      printf '%s' "$FAILS" >&2
      echo "Fix each row, or the captain waives a row by naming that PR. A general ship-as-is waives none." >&2
      exit 1
    fi
    echo "release gate: every PR in $URL passes"
    ;;
  refresh)
    cur=$("$GH" pr view "$URL" --json body --jq '.body // ""') || die "could not read $URL"
    block="$MARK_START"$'\n'"## Release gate"$'\n\n'"$(render_table)"$'\n'"$MARK_END"
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    if [[ "$cur" == *"$MARK_START"* && "$cur" == *"$MARK_END"* ]]; then
      pre=${cur%%"$MARK_START"*}
      post=${cur#*"$MARK_END"}
      printf '%s%s%s\n' "$pre" "$block" "$post" > "$tmp"
    else
      printf '%s\n\n%s\n' "$cur" "$block" > "$tmp"
    fi
    "$GH" pr edit "$URL" --body-file "$tmp" >/dev/null || die "could not update the body of $URL"
    echo "release gate table refreshed: $URL"
    ;;
esac
