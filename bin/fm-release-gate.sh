#!/usr/bin/env bash
# fm-release-gate.sh - release gate for dev-to-main release PRs (applypass fork).
#
# Usage: fm-release-gate.sh table   <release-pr-url>
#        fm-release-gate.sh refresh <release-pr-url>
#        fm-release-gate.sh check   <release-pr-url>
#        fm-release-gate.sh row     <dev-pr-url>
#
# Before a main merge, every PR the release carries needs a row proving the
# decision it implements is recorded and still current, and a stored-data or
# API-field change needs a reader-and-writer audit.
#
# A dev-into-main release carries the PRs behind the commits of `compare main...dev`.
# Any other PR into main is a single-PR release: that PR is its only row.
# A carried commit with no PR into dev adds a row "commit <shortsha>: no PR". It fails
# only when the commit's diff touches a data/API glob, and then passes only with a
# waiver key release-waiver-<repo>-<release-pr>-<shortsha> whose words after
# "waived:" name the sha; otherwise it is a note row and passes. Per PR:
#   story     sc-N tokens in its title, body, or branch name
#   decision  1. its backlog item (the item whose text names the PR url, not followed
#                by a digit): decided.md
#                keys plan-<item> and <item>-*;
#             2. else the decided.md entries stamped with one of the PR's stories,
#                except an entry whose "(supersedes: ...)" suffix names one of the
#                PR's stories, <repo>#<N>, or another such entry (it stays a superseder);
#             3. else none
#   current   yes unless a LATER decided.md entry's "(supersedes: ...)" suffix names
#             a listed decision key, one of the PR's stories (sc-N), or <repo>#<N>
#             (and that entry is not itself a decision from the PR's backlog item),
#             or an open re-check
#             item exists. A re-check item has id recheck-*, body line pr=<url>
#             (not followed by a digit);
#             with re-check items, the PR is current only when every one is done.
#   data/API  the PR diff touches a glob from config/release-gate (see below)
#             The changed files come from the paginated pulls/<N>/files API.
#   audit     the PR body has a "## Reader and writer audit" heading, or
#             data/<item>/reader-writer-audit.md exists; needed only with a data/API change
# A row fails when the decision is none, it is not current, or a data/API change has
# no audit. A waiver passes a row: decided.md key
#   release-waiver-<repo>-<release-pr>-<pr>   with text starting "waived:"
# recorded with bin/fm-decide.sh, whose words after "waived:" name that PR as
# <repo>#<pr>, #<pr>, "PR <pr>" or the PR url. A general "ship as is" waives no row.
#
# table    print the rows as a markdown table.
# refresh  rewrite only the block between the fm-release-gate markers in the release
#          PR body (appended when absent); the rest of the body is untouched. When a row
#          fails it also appends one needs-decision line (key release-gate-<repo>-<pr>)
#          to state/release-main-<repo>-<pr>.status naming each failing PR and its fix
#          command, once per distinct failure set, so firstmate raises it at release
#          open (fm-release.sh open calls refresh). A clean release adds nothing.
# check    exit 0 when every row passes; exit 1 listing every failing row and its
#          waiver command. A PR whose base is not main, or in a repo not listed
#          in config/release-gate, passes with a note. A forge read that fails
#          exits 1, so an unreadable forge never passes the gate.
#
# config/release-gate (optional), one repo per line, "#" comments:
#   <owner>/<repo> [glob ...]
# A repo with no globs uses the default globs. Without the file the covered repos
# are applypass/apply_pass_backend and applypass/apply_pass_frontend. Default globs:
#   schema.sql scripts/*.sql migrations/** swagger.yml
# (a "*" matches across directories).
#
# row      the dev-merge guard (bin/fm-main-merge-guard.sh): evaluate the one PR at <dev-pr-url>
#          with the same per-PR code as check, and exit 1 with the failing fields, a
#          fix: line (the fm-decide.sh record command, or the audit to add) and the
#          waiver command when the row fails. Only a PR whose base is dev is checked;
#          any other base passes untouched. The waiver key is
#            dev-waiver-<repo>-<pr>   with text starting "waived:" naming that PR
#          recorded the same way as a release waiver. Covered repos are those in
#          config/release-gate; without the file the default for row is
#          apply_pass_backend, apply_pass_frontend and ai_backend (applypass).
#
# Overrides (tests): FM_RELEASE_GATE_GH (the gh command), FM_DATA_OVERRIDE,
# FM_BACKLOG_OVERRIDE, FM_RELEASE_GATE_CONFIG.
set -uf

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
DEFAULT_ROW_REPOS="applypass/apply_pass_backend applypass/apply_pass_frontend applypass/ai_backend"
DEFAULT_GLOBS="schema.sql scripts/*.sql migrations/** swagger.yml"
MARK_START='<!-- fm-release-gate:start -->'
MARK_END='<!-- fm-release-gate:end -->'

usage() {
  echo "usage: fm-release-gate.sh table|refresh|check <release-pr-url> | row <dev-pr-url>" >&2
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
case "$SUB" in table | refresh | check | row) ;; *) usage ;; esac

re='^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)/?$'
[[ "$URL" =~ $re ]] || die "not a GitHub PR url: $URL"
OWNER=${BASH_REMATCH[1]} REPO=${BASH_REMATCH[2]} NUM=${BASH_REMATCH[3]}
SLUG="$OWNER/$REPO"
URL="https://github.com/$SLUG/pull/$NUM"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# covered_globs: prints the globs for SLUG and returns 0, or returns 1 when not covered.
covered_globs() {
  local want line repo rest repos
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
  repos=$DEFAULT_REPOS
  [ "$SUB" != row ] || repos=$DEFAULT_ROW_REPOS
  for repo in $repos; do
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

# names_url <text> <prefix><url>: true when text holds it not followed by a digit,
# so .../pull/82 does not match .../pull/823.
names_url() {
  [[ "$(lower "$1")" =~ "$(lower "$2")"([^0-9]|$) ]]
}

# carried_prs: PR numbers (merged to dev) behind the commits main lacks, then
# "c:<sha>" for each such commit with no PR into dev; returns 1 when any forge read fails.
carried_prs() {
  local shas sha pulls out='' lone=''
  shas=$("$GH" api "repos/$SLUG/compare/main...dev" --paginate --jq '.commits[].sha') || return 1
  for sha in $shas; do
    pulls=$("$GH" api "repos/$SLUG/commits/$sha/pulls" --jq '.[] | select(.base.ref == "dev") | .number') || return 1
    if [ -n "$pulls" ]; then out="$out$pulls"$'\n'; else lone="${lone}c:$sha"$'\n'; fi
  done
  printf '%s' "$out" | sed '/^$/d' | sort -n -u
  printf '%s' "$lone"
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
  local superseded sc prs files after short fixkey fixsc
  if [ "$SUB" = row ]; then
    prs=$NUM
  elif [ "$HEAD_REF" = dev ]; then
    prs=$(carried_prs) || die "could not read the PRs $URL carries"
  else
    prs=$NUM
  fi
  for n in $prs; do
    case "$n" in
      c:*)
        n=${n#c:}
        short=$(lower "${n:0:7}")
        files=$("$GH" api "repos/$SLUG/commits/$n" --paginate --jq '.files[].filename') || die "could not read the files of commit $n"
        hit=''
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          hit=$(glob_hit "$f" "$GLOBS") && break
          hit=''
        done <<<"$files"
        status=note data=no
        if [ -n "$hit" ]; then
          status=FAIL data="yes ($hit)"
          wkey="release-waiver-$REPO-$NUM-$short"
          while IFS=$'\t' read -r line k text; do
            [ "$(lower "$k")" = "$(lower "$wkey")" ] && [[ "$text" == waived:* ]] || continue
            [[ "$(lower "${text#waived:}")" == *"$short"* ]] && status=waived
          done <<<"$ENTRIES"
        fi
        ROWS="$ROWS| commit $short: no PR | | | | $data | | $status |"$'\n'
        if [ "$status" = FAIL ]; then
          FAILS="${FAILS}commit $short: no PR - data/API change ($hit) with no PR, decision or audit"$'\n'
          FAILS="$FAILS  waive: bin/fm-decide.sh record $wkey \"waived: Captain <date>: <words naming commit $short>\""$'\n'
        fi
        continue
        ;;
    esac
    url="https://github.com/$SLUG/pull/$n"
    json=$("$GH" pr view "$n" --repo "$SLUG" --json title,body,headRefName) || die "could not read $url"
    files=$("$GH" api "repos/$SLUG/pulls/$n/files" --paginate --jq '.[].filename') || die "could not read the files of $url"
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
      if names_url "$text" "$url"; then
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
      after=''
      while IFS=$'\t' read -r line k text; do
        case " $decs " in *" $k "*) ;; *) continue ;; esac
        if [[ "$text" =~ \(supersedes:\ ([^\)]*)\) ]]; then
          hit=0
          for ref in ${BASH_REMATCH[1]//,/ }; do
            ref=$(lower "$ref")
            for sc in $stories; do [ "$ref" = "$sc" ] && hit=1; done
            for d in $decs; do [ "$d" != "$k" ] && [ "$ref" = "$(lower "$d")" ] && hit=1; done
            [ "$ref" = "$(lower "$REPO")#$n" ] && hit=1
          done
          [ "$hit" = 1 ] && continue
        fi
        after="$after $k"
      done <<<"$ENTRIES"
      decs=$after
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
      names_url "$text" "pr=$url" || continue
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
    done <<<"$files"
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
    [ "$SUB" != row ] || wkey="dev-waiver-$REPO-$n"
    waived=0
    while IFS=$'\t' read -r line k text; do
      [ "$(lower "$k")" = "$(lower "$wkey")" ] && [[ "$text" == waived:* ]] || continue
      after=$(lower "${text#waived:}")
      if [[ "$after" =~ (\#|(^|[^a-z0-9_])pr\ )$n([^0-9]|$) ]] || names_url "$after" "$url"; then waived=1; fi
    done <<<"$ENTRIES"
    if [ "$status" = FAIL ] && [ "$waived" = 1 ]; then status="waived"; fi
    row="| [#$n]($url) | ${stories//$'\n'/ } | ${decs:-none} | ${current}${cur_note:+ ($cur_note)} | $data | $audit | $status |"
    ROWS="$ROWS$row"$'\n'
    if [ "$status" = FAIL ]; then
      FAILS="$FAILS#$n ${stories//$'\n'/ } ${decs:-none} - $why"$'\n'
      fixkey="plan-${item:-$REPO-$n}"
      fixsc=${stories%%$'\n'*}
      if [ -z "$decs" ]; then
        FAILS="$FAILS  fix: bin/fm-decide.sh record $fixkey \"<the decision this PR implements>\" --story ${fixsc:-sc-NNNN}"$'\n'
      elif [ "$current" != yes ]; then
        FAILS="$FAILS  fix: record the decision this PR now implements: bin/fm-decide.sh record $fixkey \"<current decision>\" --story ${fixsc:-sc-NNNN}, or close the re-check item"$'\n'
      fi
      if [ -n "$hit" ] && [ "$audit" = no ]; then
        FAILS="$FAILS  fix: add a '## Reader and writer audit' section to the PR body, or create data/${item:-<item>}/reader-writer-audit.md"$'\n'
      fi
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


if [ "$COVERED" = 0 ]; then
  echo "fm-release-gate: $SLUG is not covered by the release gate (config/release-gate); nothing to check" >&2
  case "$SUB" in table) echo "Release gate: $SLUG is not covered." ;; esac
  exit 0
fi
# Only a PR into main is gated; its head picks the rows (see the header).
pr=$("$GH" pr view "$URL" --json baseRefName,headRefName) || die "could not read $URL"
BASE_REF=$(jq -r '.baseRefName // ""' <<<"$pr")
HEAD_REF=$(jq -r '.headRefName // ""' <<<"$pr")
[ -n "$BASE_REF" ] && [ -n "$HEAD_REF" ] || die "could not read the base and head of $URL"
if [ "$SUB" = row ]; then
  if [ "$BASE_REF" != dev ]; then
    echo "fm-release-gate: $URL targets $BASE_REF, not dev; no dev row to check" >&2
    exit 0
  fi
elif [ "$BASE_REF" != main ]; then
  echo "fm-release-gate: $URL targets $BASE_REF, not main; nothing to check" >&2
  exit 0
fi

build_rows

case "$SUB" in
  row)
    if [ -n "$FAILS" ]; then
      echo "dev merge guard: $URL has no passing release row, so it cannot merge to dev:" >&2
      printf '%s' "$FAILS" >&2
      echo "Fix the row, then merge again. Only the captain waives it, by recording the dev-waiver key naming this PR." >&2
      exit 1
    fi
    echo "dev merge guard: the row for $URL passes"
    ;;
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
    # Fork-only: raise failing rows to the supervisor as soon as the release PR is opened or
    # refreshed (fm-release.sh open calls refresh), not at the merge word.
    if [ -n "$FAILS" ]; then
      sf="${FM_STATE_OVERRIDE:-$FM_HOME/state}/release-main-$REPO-$NUM.status"
      msg="release $URL carries PRs failing the release gate: $(printf '%s' "$FAILS" | sed -e 's/^[[:space:]]*//' | paste -sd ';' - | sed 's/;/; /g')"
      if [ "$(tail -n 1 "$sf" 2>/dev/null | sed -E 's/^[^:]*: //')" != "$msg" ]; then
        mkdir -p "$(dirname "$sf")" &&
          printf 'needs-decision [at=%s] [key=release-gate-%s-%s]: %s\n' "$(date +%s)" "$REPO" "$NUM" "$msg" >> "$sf" ||
          echo "warning: could not record the failing rows in $sf" >&2
      fi
    fi
    ;;
esac
