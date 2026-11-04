#!/usr/bin/env bash
# fm-decision-sweep.sh - after a decision replaces another, list the work tied to the old one (applypass fork).
#
# Usage: fm-decision-sweep.sh <new-key> [--dry-run]
#
# <new-key> is a data/decided.md entry whose text ends in a supersede suffix
# written by `bin/fm-decide.sh record ... --supersedes <ref>`:
#   - [<new-key>] YYYY-MM-DD <text> (supersedes: <ref>, <ref>) (shortcut: ...)
# A ref is a decided key, a story (sc-N), or a PR (<repo>#<N>, repo = GitHub repo
# name under applypass). fm-decide runs this in the foreground right after the
# append, so the re-check items exist when `record` returns; run it by hand to
# repeat the sweep (it opens nothing twice).
#
# Each ref expands to stories: a key gives the story in its Shortcut stamp (posted
# or pending) plus
# the stories named by its backlog item (the item whose id is the key, the key
# without its `plan-` prefix, or the key without a trailing -N); a PR gives the
# stories its title, body and branch name carry. Then it lists
#   - backlog items (any state) naming a story as a whole token, or a key;
#   - PRs naming a story the way bin/fm-shortcut-release-lib.sh finds one (a
#     whole-token sc-N in title, body or branch; Shortcut external links are not
#     read), plus PRs a ref names directly and PRs a found item links as pr=
#     (bodies read in full), that are open, merged to dev in the last
#     FM_SWEEP_DAYS days (default 30), or carried by an open dev-to-main release
#     PR; a PR a ref names directly skips that window. The repos are the origins of
#     the clones of data/projects.md plus applypass/apply_pass_backend and
#     applypass/apply_pass_frontend. A PR a ref names directly is added when
#     open or merged even if no searched list holds it.
# For every PR it opens one backlog item, kind recheck:
#   id    recheck-<new-key>-<repo>-<pr-number>
#   body  lines pr=<full PR URL>, old=<ref>, new=<new-key> (and release=<url>)
# Open = not done. A release holds until each is closed with
#   bin/fm-tasks-axi.sh done <id> --note "<evidence>"
# (the PR matches the new decision, or a fix PR is linked). Re-checks have no
# Shortcut story of their own. Once per run it comments on each story that got a
# new re-check (best-effort; a repeat run with nothing new comments nowhere).
# Output ends with one line: rechecks opened=<n> existing=<n>. Exit 1 when a
# repo, a release PR's commits, or the backlog could not be read; the re-checks it could open are open.
#
# Overrides (tests): FM_SWEEP_GH (gh), FM_SWEEP_TASKS (fm-tasks-axi.sh),
# FM_SWEEP_TICKET (fm-shortcut-ticket.sh), FM_SWEEP_SINCE (YYYY-MM-DD cutoff).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DECIDED="$DATA/decided.md"
GH="${FM_SWEEP_GH:-gh}"
TASKS="${FM_SWEEP_TASKS:-$SCRIPT_DIR/fm-tasks-axi.sh}"
TICKET="${FM_SWEEP_TICKET:-$SCRIPT_DIR/fm-shortcut-ticket.sh}"
OWNER=applypass
FIXED_REPOS="$OWNER/apply_pass_backend $OWNER/apply_pass_frontend"
DRY=0
STATUS=0

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { printf 'fm-decision-sweep: %s\n' "$*" >&2; exit 1; }
warn() { printf 'fm-decision-sweep: warning: %s\n' "$*" >&2; STATUS=1; }

KEY=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$KEY" ] || { usage >&2; exit 2; }; KEY=$1 ;;
  esac
  shift
done
[ -n "$KEY" ] || { usage >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is required"
[ -f "$DECIDED" ] || die "no $DECIDED"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-decision-sweep.XXXXXX") || die "cannot create a temp directory"
trap 'rm -rf "$WORK"' EXIT
: >"$WORK/stories" # <story number> TAB <ref>
: >"$WORK/keys"    # <decided key>
: >"$WORK/direct"  # <pr url> TAB <ref>
: >"$WORK/items"   # <item id> TAB <why>
: >"$WORK/named"   # <pr url> TAB <repo> TAB <pr view json>, for PRs named as refs
: >"$WORK/refurls" # <pr url>, for PRs named as refs

entry_for() {  # <key>: its decided.md line
  FM_KEY=$1 awk 'BEGIN { p = "- [" ENVIRON["FM_KEY"] "] " } index($0, p) == 1 { print; exit }' "$DECIDED"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Backlog rows, one per task, literal \n turned into a space so tokens stay whole.
ROWS="$WORK/rows"
"$TASKS" list --fields body >"$WORK/tasks.out" 2>"$WORK/tasks.err" || die "cannot read the backlog: $(cat "$WORK/tasks.err")"
sed -n 's/^  \([^ ,][^,]*,.*\)$/  \1/p' "$WORK/tasks.out" | sed 's/\\n/ /g' >"$WORK/rows.list"
while IFS= read -r row; do
  case "$row" in
    *'(truncated, '*' chars total - use show '*)
      id=${row#  }; id=${id%%,*}
      if full=$("$TASKS" show "$id" --full 2>"$WORK/show.err"); then
        printf '  %s,%s\n' "$id" "$(printf '%s\n' "$full" | sed 's/\\n/ /g' | tr '\n' ' ')"
      else
        warn "could not read the full body of $id: $(head -n 1 "$WORK/show.err")"
        printf '%s\n' "$row"
      fi ;;
    *) printf '%s\n' "$row" ;;
  esac
done <"$WORK/rows.list" >"$ROWS"

row_story_tokens() {  # <row>: story numbers named as whole sc-N tokens
  printf '%s\n' "$1" | sed -E 's#https?://[^[:space:]")>,]*# #g' | tr -c 'A-Za-z0-9_\n-' ' ' | tr ' ' '\n' |
    sed -nE 's/^[sS][cC]-([0-9]+)(-.*)?$/\1/p'
}

row_for_item() { grep -E "^  $(printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g')," "$ROWS" | head -n 1; }

add_stories_of_pr() {  # <pr url> <repo> <ref>: the stories its title, body and branch name
  local url=$1 repo=$2 ref=$3 json n
  json=$("$GH" pr view "$url" --json title,body,headRefName,state,mergedAt 2>/dev/null) || { warn "could not read $url"; return 0; }
  printf '%s\t%s\t%s\n' "$url" "$repo" "$(jq -c . <<<"$json")" >>"$WORK/named"
  jq -r '([(.title // "") , (.body // "")] | map(gsub("https?://[^\\s)>]*"; "")) | join(" ")) + " " + (.headRefName // "")' <<<"$json" |
    tr -c 'A-Za-z0-9_\n-' ' ' | tr ' ' '\n' | sed -nE 's/^[sS][cC]-([0-9]+)(-.*)?$/\1/p' |
    while IFS= read -r n; do printf '%s\t%s\n' "$n" "$ref" >>"$WORK/stories"; done
}

# 1. The new entry and its refs.
ENTRY=$(entry_for "$KEY")
[ -n "$ENTRY" ] || die "no decision [$KEY] in $DECIDED"
REFS=$(printf '%s\n' "$ENTRY" | sed -n 's/.* (supersedes: \([^)]*\)).*/\1/p' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sed '/^$/d')
[ -n "$REFS" ] || die "decision [$KEY] has no (supersedes: ...) suffix; record it with --supersedes <ref>"

while IFS= read -r ref; do
  case "$(lower "$ref")" in
    sc-[0-9]*) n=${ref#*-}; printf '%s\t%s\n' "$n" "$ref" >>"$WORK/stories" ;;
    *#[0-9]*)
      repo=${ref%%#*}; num=${ref##*#}
      url="https://github.com/$OWNER/$repo/pull/$num"
      printf '%s\t%s\n' "$url" "$ref" >>"$WORK/direct"
      printf '%s\n' "$url" >>"$WORK/refurls"
      add_stories_of_pr "$url" "$OWNER/$repo" "$ref"
      ;;
    *)
      printf '%s\n' "$ref" >>"$WORK/keys"
      old=$(entry_for "$ref")
      if [ -z "$old" ]; then warn "no decision [$ref] in $DECIDED"; continue; fi
      printf '%s\n' "$old" | sed -n 's/.*(shortcut: \(pending \)\{0,1\}sc-\([0-9]*\).*/\2/p' | while IFS= read -r n; do printf '%s\t%s\n' "$n" "$ref" >>"$WORK/stories"; done
      for cand in "$ref" "${ref#plan-}" "$(printf '%s' "$ref" | sed -E 's/-[0-9]+$//')"; do
        row=$(row_for_item "$cand")
        [ -n "$row" ] || continue
        row_story_tokens "$row" | while IFS= read -r n; do printf '%s\t%s\n' "$n" "$ref" >>"$WORK/stories"; done
      done
      ;;
  esac
done <<REFS
$REFS
REFS
sort -u "$WORK/stories" -o "$WORK/stories"

# 2. Backlog items naming a story or a key (re-checks themselves never count).
while IFS= read -r row; do
  [ -n "$row" ] || continue
  id=${row#  }; id=${id%%,*}
  case "$id" in recheck-*) continue ;; esac
  why=''
  toks=$(row_story_tokens "$row")
  while IFS="$(printf '\t')" read -r n ref; do
    [ -n "$n" ] || continue
    printf '%s\n' "$toks" | grep -qx "$n" && why="$why sc-$n($ref)"
  done <"$WORK/stories"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    esc=$(printf '%s' "$k" | sed 's/[][\.*^$/]/\\&/g')
    printf '%s\n' "$row" | grep -Eiq "(^|[^A-Za-z0-9._-])$esc(\$|[^A-Za-z0-9._-])" && why="$why $k"
  done <"$WORK/keys"
  [ -n "$why" ] || continue
  printf '%s\t%s\n' "$id" "${why# }" >>"$WORK/items"
  printf '%s\n' "$row" | grep -Eo "https://github\.com/[^/ \"]+/[^/ \"]+/pull/[0-9]+" | sort -u | while IFS= read -r u; do
    printf '%s\t%s\n' "$u" "${why# }" >>"$WORK/direct"
  done
done <"$ROWS"

# 3. Repos to search.
REPOS="$FIXED_REPOS"
if [ -f "$DATA/projects.md" ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    slug=$(git -C "$FM_HOME/projects/$name" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
    case "$slug" in */*) ;; *) continue ;; esac
    case " $REPOS " in *" $slug "*) ;; *) REPOS="$REPOS $slug" ;; esac
  done <<NAMES
$(sed -n 's/^- //p' "$DATA/projects.md" | sed 's/ \[.*//; s/ - .*//')
NAMES
fi

if [ -n "${FM_SWEEP_SINCE:-}" ]; then
  SINCE=$FM_SWEEP_SINCE
else
  SINCE=$(date -u -v-"${FM_SWEEP_DAYS:-30}"d +%F 2>/dev/null || date -u -d "${FM_SWEEP_DAYS:-30} days ago" +%F)
fi
STORIES_JSON=$(cut -f1 "$WORK/stories" | sort -u | jq -R . | jq -s .)
DIRECT_JSON=$(cut -f1 "$WORK/direct" | sort -u | jq -R . | jq -s .)
NAMED_JSON=$(sort -u "$WORK/refurls" | jq -R . | jq -s .)

# 4. PRs per repo: open, merged to dev inside the window, or inside an open release.
: >"$WORK/found" # url TAB repo TAB num TAB state TAB stories TAB release
for repo in $REPOS; do
  fields=number,title,body,headRefName,baseRefName,url
  if ! "$GH" pr list --repo "$repo" --state open --limit 200 --json "$fields" >"$WORK/open.json" 2>"$WORK/gh.err" ||
    ! "$GH" pr list --repo "$repo" --state merged --base dev --limit 300 --json "$fields,mergedAt" >"$WORK/merged.json" 2>>"$WORK/gh.err"; then
    warn "could not list PRs of $repo: $(head -n 1 "$WORK/gh.err")"
    continue
  fi
  : >"$WORK/carried"
  jq -r '.[] | select(.headRefName == "dev" and .baseRefName == "main") | "\(.number)\t\(.url)"' "$WORK/open.json" >"$WORK/releases"
  while IFS="$(printf '\t')" read -r rnum rurl; do
    [ -n "$rnum" ] || continue
    if ! "$GH" api "repos/$repo/pulls/$rnum/commits" --paginate --jq '.[].commit.message | split("\n")[0]' >"$WORK/commits.txt" 2>"$WORK/api.err"; then
      warn "could not read the commits of release $rurl: $(head -n 1 "$WORK/api.err")"
      continue
    fi
    grep -Eo '(\(#[0-9]+\)|Merge pull request #[0-9]+)' "$WORK/commits.txt" | grep -Eo '[0-9]+' | sort -u |
      while IFS= read -r c; do printf '%s\t%s\n' "$c" "$rurl" >>"$WORK/carried"; done
  done <"$WORK/releases"
  CARRIED_JSON=$(jq -R 'split("\t") | {(.[0]): .[1]}' "$WORK/carried" | jq -s 'add // {}')
  jq -s -r --argjson stories "$STORIES_JSON" --argjson direct "$DIRECT_JSON" --argjson named "$NAMED_JSON" --argjson carried "$CARRIED_JSON" \
    --arg since "$SINCE" --arg repo "$repo" '
    def toks: [((.title // "") , (.body // "")) | gsub("https?://[^\\s)>]*"; "")] + [(.headRefName // "")]
      | join(" ") | [scan("(?i)(?<![A-Za-z0-9_-])sc-([0-9]+)(?![0-9A-Za-z_])") | .[0]];
    ((.[0] | map(. + {st: "open"})) + (.[1] | map(. + {st: "merged"})))
    | map(select((.headRefName == "dev" and .baseRefName == "main") | not))
    | map(. + {matched: (toks | map(select(. as $t | $stories | index($t))) | unique)})
    | map(select((.matched | length) > 0 or (.url as $u | $direct | index($u))))
    | map(select(.st == "open" or (.mergedAt // "")[0:10] >= $since or ($carried[(.number | tostring)] != null) or (.url as $u | $named | index($u))))
    | .[] | [.url, $repo, (.number | tostring), (if .st == "open" then "open" else "merged " + (.mergedAt // "")[0:10] end),
             (.matched | join(",")), ($carried[(.number | tostring)] // "")] | @tsv' \
    "$WORK/open.json" "$WORK/merged.json" >>"$WORK/found" 2>"$WORK/jq.err" || warn "could not read the PR list of $repo: $(head -n 1 "$WORK/jq.err")"
done
while IFS="$(printf '\t')" read -r url repo json; do
  [ -n "$url" ] || continue
  cut -f1 "$WORK/found" | grep -qxF "$url" && continue
  state=$(jq -r 'if .state == "OPEN" then "open" elif .state == "MERGED" then "merged " + ((.mergedAt // "")[0:10]) else "" end' <<<"$json")
  [ -n "$state" ] || continue
  printf '%s\t%s\t%s\t%s\t\t\n' "$url" "$repo" "${url##*/}" "$state" >>"$WORK/found"
done <"$WORK/named"
sort -u "$WORK/found" -o "$WORK/found"

# 5. Print and open re-checks.
TAB=$(printf '\t')
printf 'fm-decision-sweep: [%s] replaces %s\n' "$KEY" "$(printf '%s' "$REFS" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')"
printf 'backlog items tied to the old decision:\n'
if [ -s "$WORK/items" ]; then
  while IFS="$TAB" read -r id why; do printf '  %s (%s)\n' "$id" "$why"; done <"$WORK/items"
else
  printf '  none\n'
fi
printf 'PRs tied to the old decision:\n'
[ -s "$WORK/found" ] || printf '  none\n'

OPENED=0
EXISTING=0
: >"$WORK/commented" # story TAB line
while IFS="$TAB" read -r url repo num state matched release; do
  [ -n "$url" ] || continue
  rid="recheck-$KEY-${repo#*/}-$num"
  olds=''
  for n in $(printf '%s' "$matched" | tr ',' ' '); do
    olds="$olds $(awk -F'\t' -v n="$n" '$1 == n { print $2 }' "$WORK/stories")"
  done
  olds="$olds $(awk -F'\t' -v u="$url" '$1 == u { print $2 }' "$WORK/direct")"
  olds=$(printf '%s\n' "$olds" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
  [ -n "$olds" ] || olds=$KEY
  line="  $url ($state${release:+, in release $release})"
  if grep -q "^  $rid," "$ROWS" 2>/dev/null; then
    printf '%s -> %s already open\n' "$line" "$rid"
    EXISTING=$((EXISTING + 1))
    continue
  fi
  if [ "$DRY" = 1 ]; then
    printf '%s -> would open %s\n' "$line" "$rid"
    continue
  fi
  {
    printf 'Reversal re-check: this PR is tied to a decision that [%s] replaces. Confirm it matches the new decision, or link the fix PR, before it ships.\n' "$KEY"
    printf 'pr=%s\n' "$url"
    for o in $olds; do printf 'old=%s\n' "$o"; done
    printf 'new=%s\n' "$KEY"
    [ -z "$release" ] || printf 'release=%s\n' "$release"
    printf 'state=%s\n' "$state"
    printf 'Close with: bin/fm-tasks-axi.sh done %s --note "<evidence>"\n' "$rid"
  } >"$WORK/body.txt"
  if FM_SHORTCUT_TICKETS=off "$TASKS" add "$rid" "Re-check ${repo#*/}#$num against $KEY" --kind recheck --body-file "$WORK/body.txt" >"$WORK/add.out" 2>&1; then
    printf '%s -> opened %s\n' "$line" "$rid"
    OPENED=$((OPENED + 1))
    for n in $(printf '%s' "$matched" | tr ',' ' '); do
      printf '%s\t%s#%s%s\n' "$n" "${repo#*/}" "$num" "${release:+ (release $release)}" >>"$WORK/commented"
    done
  else
    warn "could not open $rid: $(head -n 1 "$WORK/add.out")"
  fi
done <"$WORK/found"

# 6. One comment per story that got a new re-check (best-effort).
if [ "$DRY" = 0 ] && [ -s "$WORK/commented" ]; then
  cut -f1 "$WORK/commented" | sort -u | while IFS= read -r n; do
    prs=$(awk -F'\t' -v n="$n" '$1 == n { print $2 }' "$WORK/commented" | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    "$TICKET" comment "sc-$n" "Decision [$KEY] replaces $(printf '%s' "$REFS" | tr '\n' ' ' | sed 's/ $//; s/ /, /g'). Re-check before release: $prs. Each has a backlog item recheck-$KEY-*; close it with evidence that the PR matches the new decision, or link the fix PR." --best-effort >/dev/null 2>&1 ||
      printf 'fm-decision-sweep: warning: could not comment on sc-%s\n' "$n" >&2
  done
fi

printf 'rechecks opened=%s existing=%s\n' "$OPENED" "$EXISTING"
exit "$STATUS"
