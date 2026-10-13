#!/usr/bin/env bash
# Behavior tests for release-done, the release-hook, and the retry record of
# bin/fm-shortcut-ticket.sh (applypass fork). The Shortcut API (curl) and the
# forge (gh) are stubbed on PATH; no test reaches Shortcut, Vercel, or GitHub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-shortcut-release)
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE \
  FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_SHORTCUT_TICKETS FM_SHORTCUT_STATUS_FILE FM_SHORTCUT_REPLAY
TOKEN=tok-release-123
OWNER=11111111-2222-4333-8444-555555555555
DONE_STATE=500000010
REVIEW_STATE=500000009
RELEASE=https://github.com/applypass/apply_pass_frontend/pull/200
BACKEND_RELEASE=https://github.com/applypass/apply_pass_backend/pull/300

# The fake Shortcut API keeps stories in $D/stories/<id>.json, the PR-link index
# in $D/extlinks.tsv (url<TAB>id), and logs every call to $D/curl.log, comments
# to $D/comments/<id>. FAKE_CURL_FAIL=1 answers 500 to everything.
fake_curl() {  # <fakebin>
  mkdir -p "$1"
  cat > "$1/curl" <<'SH'
#!/usr/bin/env bash
out= method=GET data= url=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -o) out=${args[$((i + 1))]} ;;
    -X) method=${args[$((i + 1))]} ;;
    --data-binary) data=${args[$((i + 1))]#@} ;;
  esac
  url=${args[$i]}
done
cat >/dev/null
D=$FAKE_SC_DIR
mkdir -p "$D/comments"
{ printf '%s %s\n' "$method" "$url"; [ -z "$data" ] || printf 'BODY %s\n' "$(jq -c . "$data")"; } >> "$D/curl.log"
if [ "${FAKE_CURL_FAIL:-}" = 1 ]; then printf '{}' > "$out"; printf 500; exit 0; fi
id=${url##*/}
case "$method $url" in
  "GET "*/api/v3/external-link/stories\?external_link=*)
    link=$(jq -rn --arg u "${url#*external_link=}" '$u|@uri|.' >/dev/null; printf '%s' "${url#*external_link=}" | jq -Rr '@urid')
    awk -F'\t' -v l="$link" '$1 == l {print $2}' "$D/extlinks.tsv" | jq -Rn '[inputs | tonumber | {id: .}]' > "$out"
    printf 200 ;;
  "GET "*/api/v3/stories/*)
    if [ -f "$D/comments/$id" ]; then
      jq --rawfile c "$D/comments/$id" '.comments = [$c | split("\n")[] | select(. != "") | {text: .}]' "$D/stories/$id.json" > "$out"
    else
      cp "$D/stories/$id.json" "$out"
    fi
    printf 200 ;;
  "PUT "*/api/v3/stories/*)
    jq -s '.[0] * .[1]' "$D/stories/$id.json" "$data" > "$D/stories/$id.json.new" && mv "$D/stories/$id.json.new" "$D/stories/$id.json"
    printf '{}' > "$out"; printf 200 ;;
  "POST "*/api/v3/stories/*/comments)
    n=${url%/comments}; n=${n##*/}
    jq -r .text "$data" >> "$D/comments/$n"; printf '{}' > "$out"; printf 200 ;;
  *) printf '{}' > "$out"; printf 404 ;;
esac
SH
  chmod +x "$1/curl"
}

# The fake forge reads fixtures from $FAKE_GH_DIR: pr/<n>.tsv (base, state, merge
# sha), pr/<n>.state, commits/<n> (one subject per line), deployments (id sha),
# dstatus/<id>, durl/<id>, compare (status word).
fake_gh() {  # <fakebin>
  mkdir -p "$1"
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
G=$FAKE_GH_DIR
echo "gh $*" >> "$G/gh.log"
case "$*" in
  "pr view "*baseRefName*) cat "$G/pr/${3##*/}.tsv" ;;
  "pr view "*"--json state"*) cat "$G/pr/${3##*/}.state" ;;
  "api repos/"*/commits*) n=${2#*/pulls/}; n=${n%%/*}; cat "$G/commits/$n" 2>/dev/null ;;
  "api repos/"*/deployments\?*) cat "$G/deployments" 2>/dev/null ;;
  "api repos/"*/statuses*environment_url*) id=${2#*/deployments/}; cat "$G/durl/${id%%/*}" ;;
  "api repos/"*/statuses*) id=${2#*/deployments/}; cat "$G/dstatus/${id%%/*}" ;;
  "api repos/"*/compare/*) cat "$G/compare" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/gh"
}

fake_op() {  # <fakebin>: 1Password signed out unless FAKE_OP_TOKEN is set
  mkdir -p "$1"
  cat > "$1/op" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_OP_TOKEN:-}" ] || { echo "op: not signed in" >&2; exit 1; }
printf '%s\n' "$FAKE_OP_TOKEN"
SH
  chmod +x "$1/op"
}

make_case() {  # <name>: a code root, a home, and fake Shortcut and forge fixtures
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/defaults" "$dir/home/data" "$dir/home/state" "$dir/home/config" \
    "$dir/sc/stories" "$dir/gh/pr" "$dir/gh/commits" "$dir/gh/dstatus" "$dir/gh/durl" "$dir/fakebin"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
  cp "$ROOT/defaults/shortcut-tickets" "$dir/code/defaults/shortcut-tickets"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
  printf 'owner_id=%s\ntoken_ref=op://v/i/f\n' "$OWNER" > "$dir/home/config/shortcut-tickets"
  touch "$dir/sc/extlinks.tsv" "$dir/sc/curl.log" "$dir/gh/gh.log"
  fake_curl "$dir/fakebin"
  fake_gh "$dir/fakebin"
  fake_op "$dir/fakebin"
  printf '%s\n' "$dir"
}

story() {  # <case> <id> <state> <description> <linked-pr-url>...
  local dir=$1 id=$2 state=$3 desc=$4 links='[]' url owners=${STORY_OWNERS:-[\"$OWNER\"]}
  shift 4
  for url in "$@"; do
    printf '%s\t%s\n' "$url" "$id" >> "$dir/sc/extlinks.tsv"
  done
  links=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  jq -n --argjson id "$id" --argjson s "$state" --arg d "$desc" --argjson l "$links" --argjson o "$owners" \
    '{id: $id, workflow_state_id: $s, owner_ids: $o, description: $d, external_links: $l, app_url: ("https://app.shortcut.com/applypass/story/" + ($id | tostring))}' \
    > "$dir/sc/stories/$id.json"
}

pr_info() {  # <case> <number> <base> <state> <sha> [commit subject...]
  local dir=$1 n=$2
  printf '%s\t%s\t%s\n' "$3" "$4" "$5" > "$dir/gh/pr/$n.tsv"
  shift 5
  printf '%s\n' "$@" > "$dir/gh/commits/$n"
}

deploy() {  # <case> <id> <sha> <state>: one production deployment
  printf '%s %s\n' "$2" "$3" >> "$1/gh/deployments"
  printf '%s\n' "$4" > "$1/gh/dstatus/$2"
  printf 'https://frontend-%s.vercel.app\n' "$2" > "$1/gh/durl/$2"
  printf 'ahead\n' > "$1/gh/compare"
}

ticket() {  # <case> <args...>; token from the environment unless NO_TOKEN=1
  local dir=$1 token=$TOKEN
  shift
  [ -z "${NO_TOKEN:-}" ] || token=''
  (cd "$dir/code" && env -u SHORTCUT_API_TOKEN ${token:+SHORTCUT_API_TOKEN="$token"} FM_HOME="$dir/home" \
    FM_ROOT_OVERRIDE="$dir/code" FAKE_SC_DIR="$dir/sc" FAKE_GH_DIR="$dir/gh" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-shortcut-ticket.sh" "$@" 2>&1)
}

state_of() { jq -r .workflow_state_id "$1/sc/stories/$2.json"; }

OWNED='firstmate-item: home/'

# A release PR #200 that carries #101 (owned, finished), #102 (owned, but a
# second PR of it is still open), #103 (no ownership marker: an umbrella), and a
# story that is already Done.
seed_release() {  # <case>
  local dir=$1 head=abc1234abc1234abc1234abc1234abc1234abc12
  pr_info "$dir" 200 main MERGED "$head" "Fix widget (#101)" "Fix gadget (#102)" "Umbrella bit (#103)" "Old (#104)" "Merge pull request #105 from x/y" "Theirs (#106)" "Ours unassigned (#107)" "Stray (#108)"
  printf 'OPEN\n' > "$dir/gh/pr/150.state"
  tasks_add "$dir" st-101 "Widget"
  story "$dir" 11 "$REVIEW_STATE" "Widget
${OWNED}st-101" https://github.com/applypass/apply_pass_frontend/pull/101
  story "$dir" 12 "$REVIEW_STATE" "Gadget
${OWNED}st-102" https://github.com/applypass/apply_pass_frontend/pull/102 https://github.com/applypass/apply_pass_frontend/pull/150
  story "$dir" 13 "$REVIEW_STATE" "Umbrella story" https://github.com/applypass/apply_pass_frontend/pull/103
  STORY_OWNERS='["99999999-8888-4777-8666-555555555555"]' story "$dir" 15 "$REVIEW_STATE" "Someone else's
${OWNED}st-106" https://github.com/applypass/apply_pass_frontend/pull/106
  STORY_OWNERS='[]' story "$dir" 16 "$REVIEW_STATE" "Unassigned, firstmate's
${OWNED}st-107" https://github.com/applypass/apply_pass_frontend/pull/107
  STORY_OWNERS='[]' story "$dir" 17 "$REVIEW_STATE" "Unassigned, not firstmate's" https://github.com/applypass/apply_pass_frontend/pull/108
  story "$dir" 14 "$DONE_STATE" "Old
${OWNED}st-104" https://github.com/applypass/apply_pass_frontend/pull/104
}

tasks_add() {  # <case> <id> <title>
  (cd "$1/code" && FM_SHORTCUT_TICKETS=off FM_HOME="$1/home" FM_ROOT_OVERRIDE="$1/code" \
    "$ROOT/bin/fm-tasks-axi.sh" add "$2" "$3" --kind ship >/dev/null 2>&1 &&
    FM_SHORTCUT_TICKETS=off FM_HOME="$1/home" FM_ROOT_OVERRIDE="$1/code" "$ROOT/bin/fm-tasks-axi.sh" start "$2" >/dev/null 2>&1) ||
    fail "could not seed backlog item $2"
}

item_state() {  # <case> <id>
  (cd "$1/code" && FM_SHORTCUT_TICKETS=off FM_HOME="$1/home" FM_ROOT_OVERRIDE="$1/code" \
    "$ROOT/bin/fm-tasks-axi.sh" show "$2" 2>&1 | sed -n 's/^  state: *//p')
}

test_release_done_finishes_only_complete_stories() {
  local dir out
  dir=$(make_case release-done)
  seed_release "$dir"
  out=$(ticket "$dir" release-done "$RELEASE" --evidence "prod runs abc1234") || fail "release-done failed: $out"
  assert_equals "$DONE_STATE" "$(state_of "$dir" 11)" "the finished story did not move to Done"
  assert_equals "$REVIEW_STATE" "$(state_of "$dir" 12)" "a story with another open PR moved to Done"
  assert_equals "$REVIEW_STATE" "$(state_of "$dir" 13)" "an umbrella story moved to Done"
  assert_grep "$RELEASE" "$dir/sc/comments/11" "the Done comment lacks the release PR"
  assert_grep "pull/101" "$dir/sc/comments/11" "the Done comment lacks the story's PR"
  assert_grep "prod runs abc1234" "$dir/sc/comments/11" "the Done comment lacks the deploy evidence"
  assert_grep "still open" "$dir/sc/comments/12" "the open-work story got no explanation"
  assert_grep "no firstmate ownership marker" "$dir/sc/comments/13" "the umbrella story got no explanation"
  [ ! -e "$dir/sc/comments/14" ] || fail "an already-Done story was commented on again"
  assert_equals "$DONE_STATE" "$(state_of "$dir" 16)" "an unassigned story firstmate worked on did not finish"
  assert_equals "$REVIEW_STATE" "$(state_of "$dir" 15)" "another person's story was moved"
  assert_equals "$REVIEW_STATE" "$(state_of "$dir" 17)" "an unassigned story without a firstmate marker was moved"
  [ ! -e "$dir/sc/comments/15" ] && [ ! -e "$dir/sc/comments/17" ] || fail "a skipped story was commented on"
  assert_no_grep "PUT https://api.app.shortcut.com/api/v3/stories/15" "$dir/sc/curl.log" "another person's story was written"
  assert_equals "done" "$(item_state "$dir" st-101)" "the firstmate backlog item did not close with its story"
  assert_not_contains "$out" "$TOKEN" "the token was printed"
  pass "release-done moves finished stories to Done with evidence, closes their backlog item, and leaves open-work stories in review, and never touches another person's story"
}

test_release_done_is_idempotent() {
  local dir
  dir=$(make_case release-idempotent)
  seed_release "$dir"
  ticket "$dir" release-done "$RELEASE" >/dev/null || fail "first release-done failed"
  : > "$dir/sc/curl.log"
  ticket "$dir" release-done "$RELEASE" >/dev/null || fail "second release-done failed"
  assert_no_grep "PUT " "$dir/sc/curl.log" "a repeat release-done moved a story again"
  assert_equals 1 "$(grep -c '^Done:' "$dir/sc/comments/11")" "a repeat release-done commented Done twice"
  assert_equals 1 "$(grep -c 'stays In Review' "$dir/sc/comments/12")" "a repeat release-done explained a held story twice"
  pass "a repeated release-done changes nothing"
}

test_failure_is_loud_and_retried() {
  local dir out key
  dir=$(make_case retry)
  seed_release "$dir"
  printf 'working [at=1]: start\n' > "$dir/home/state/st-101.status"
  out=$(NO_TOKEN=1 ticket "$dir" release-done "$RELEASE" --task st-101) && fail "release-done succeeded with 1Password signed out"
  assert_contains "$out" "queued for retry" "the failure did not say it was queued"
  assert_equals "$REVIEW_STATE" "$(state_of "$dir" 11)" "a story moved without a token"
  ls "$dir"/home/state/shortcut-pending/sc-*.args >/dev/null 2>&1 || fail "no pending record was left"
  assert_equals 1 "$(grep -c '^blocked \[at=[0-9]*\] \[key=shortcut-sync-' "$dir/home/state/st-101.status")" \
    "the failure did not append one keyed blocked line to the task status"
  key=$(sed -n 's/.*\[key=\(shortcut-sync-[^]]*\)\].*/\1/p' "$dir/home/state/st-101.status" | head -1)
  NO_TOKEN=1 ticket "$dir" release-done "$RELEASE" --task st-101 >/dev/null || true
  assert_equals 1 "$(grep -c '^blocked' "$dir/home/state/st-101.status")" "a repeated failure appended a second blocked line"
  out=$(ticket "$dir" pending) || fail "pending failed: $out"
  assert_equals "$DONE_STATE" "$(state_of "$dir" 11)" "the retry did not finish the story"
  assert_contains "$out" "0 pending record(s) remain" "the record survived a successful retry"
  assert_grep "resolved [at=" "$dir/home/state/st-101.status" "the retry did not append a resolved line"
  assert_grep "[key=$key]" "$dir/home/state/st-101.status" "the resolved line does not carry the blocked key"
  pass "a token failure leaves a pending record and one keyed blocked line, and the next run finishes and resolves it"
}

test_best_effort_hook_failure_is_loud_and_replayed_by_any_run() {
  local dir out
  dir=$(make_case retry-hook)
  tasks_add "$dir" st-9 "Widget"
  (cd "$dir/code" && FM_SHORTCUT_TICKETS=off FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$ROOT/bin/fm-tasks-axi.sh" update st-9 --body "Shortcut: sc-21" >/dev/null 2>&1)
  story "$dir" 21 500000008 "x
${OWNED}st-9"
  printf 'working [at=1]: start\n' > "$dir/home/state/st-9.status"
  out=$(NO_TOKEN=1 ticket "$dir" review st-9 --pr https://github.com/applypass/apply_pass_frontend/pull/9 --best-effort) ||
    fail "a best-effort hook failed the caller: $out"
  assert_contains "$out" "queued for retry" "the best-effort warning did not say it was queued"
  assert_grep "[key=shortcut-sync-" "$dir/home/state/st-9.status" "the hook failure never reached the task status"
  ticket "$dir" comment st-9 "later call" >/dev/null || fail "a later call failed"
  assert_equals "$REVIEW_STATE" "$(state_of "$dir" 21)" "the queued review was not replayed by a later run"
  assert_grep "pull/9" "$dir/sc/stories/21.json" "the replay did not link the PR"
  ls "$dir"/home/state/shortcut-pending/sc-*.args >/dev/null 2>&1 && fail "the record outlived its replay"
  pass "a best-effort hook that fails is loud in the task status and replayed by the next run of any operation"
}

test_release_hook_on_a_vercel_repo_waits_for_production() {
  local dir out key sha=abc1234abc1234abc1234abc1234abc1234abc12
  dir=$(make_case hook-vercel)
  seed_release "$dir"
  printf 'working [at=1]: start\n' > "$dir/home/state/st-101.status"
  out=$(ticket "$dir" release-hook "$RELEASE" --task st-101 --best-effort) || fail "release-hook failed: $out"
  assert_equals "$REVIEW_STATE" "$(state_of "$dir" 11)" "a story moved before production ran the release"
  assert_contains "$out" "once production runs abc1234ab" "the hook did not say it is waiting for production"
  assert_contains "$out" "run: bin/fm-shortcut-ticket.sh release-done $RELEASE" "the hook did not name the release-done step"
  assert_equals 1 "$(grep -c "^blocked \[at=[0-9]*\] \[key=shortcut-sync-[^]]*\]: $RELEASE merged.*run: bin/fm-shortcut-ticket.sh release-done $RELEASE\$" "$dir/home/state/st-101.status")" \
    "waiting for the deploy did not append one keyed blocked line naming the release and the release-done step"
  key=$(sed -n 's/.*\[key=\(shortcut-sync-[^]]*\)\].*/\1/p' "$dir/home/state/st-101.status" | head -1)
  deploy "$dir" 55 "$sha" pending
  ticket "$dir" pending >/dev/null || fail "pending failed"
  assert_equals "$REVIEW_STATE" "$(state_of "$dir" 11)" "a deployment that is not READY finished the release"
  assert_equals 1 "$(grep -c '^blocked' "$dir/home/state/st-101.status")" "a replay that still waits appended another blocked line"
  : > "$dir/gh/deployments"
  deploy "$dir" 56 "$sha" success
  ticket "$dir" pending >/dev/null || fail "pending failed"
  assert_equals "$DONE_STATE" "$(state_of "$dir" 11)" "a READY production deployment did not finish the release"
  assert_grep "Vercel production deployment 56 READY" "$dir/sc/comments/11" "the Done comment lacks the deployment evidence"
  assert_grep "frontend-56.vercel.app" "$dir/sc/comments/11" "the Done comment lacks the deployment URL"
  assert_grep "resolved [at=" "$dir/home/state/st-101.status" "the finished release did not append a resolved line"
  assert_grep "[key=$key]" "$dir/home/state/st-101.status" "the resolved line does not carry the blocked key"
  pass "release-hook on a Vercel repo finishes the release only once a READY production deployment covers the merge commit"
}

test_release_hook_accepts_a_later_production_deployment() {
  local dir
  dir=$(make_case hook-later)
  seed_release "$dir"
  deploy "$dir" 60 ffffffffffffffffffffffffffffffffffffffff success
  ticket "$dir" release-hook "$RELEASE" >/dev/null || fail "release-hook failed"
  assert_equals "$DONE_STATE" "$(state_of "$dir" 11)" "a deployment of a later commit did not count"
  printf 'diverged\n' > "$dir/gh/compare"
  dir=$(make_case hook-diverged)
  seed_release "$dir"
  deploy "$dir" 61 ffffffffffffffffffffffffffffffffffffffff success
  printf 'behind\n' > "$dir/gh/compare"
  ticket "$dir" release-hook "$RELEASE" >/dev/null || fail "release-hook failed"
  assert_equals "$REVIEW_STATE" "$(state_of "$dir" 11)" "a deployment of an older commit counted"
  pass "a production deployment of a later commit confirms the release, an older one does not"
}

test_release_hook_on_a_backend_repo_prints_the_next_step() {
  local dir out
  dir=$(make_case hook-backend)
  pr_info "$dir" 300 main MERGED abc1234abc1234abc1234abc1234abc1234abc12
  out=$(ticket "$dir" release-hook "$BACKEND_RELEASE" --best-effort) || fail "release-hook failed: $out"
  assert_contains "$out" "bin/fm-shortcut-ticket.sh release-done $BACKEND_RELEASE" "the hook did not print the release-done command"
  assert_no_grep "api.app.shortcut.com" "$dir/sc/curl.log" "the backend hook reached Shortcut before the deploy was confirmed"
  pass "release-hook on a captain-deployed repo prints the release-done command and moves nothing"
}

test_release_hook_on_a_backend_repo_needs_no_token() {
  local dir out
  dir=$(make_case hook-backend-signed-out)
  pr_info "$dir" 300 main MERGED abc1234abc1234abc1234abc1234abc1234abc12
  printf 'working [at=1]: start\n' > "$dir/home/state/st-1.status"
  out=$(NO_TOKEN=1 ticket "$dir" release-hook "$BACKEND_RELEASE" --task st-1 --best-effort) || fail "release-hook failed: $out"
  assert_contains "$out" "bin/fm-shortcut-ticket.sh release-done $BACKEND_RELEASE" "a signed-out 1Password hid the release-done command"
  assert_not_contains "$out" "warning" "the backend hook read the token"
  ls "$dir"/home/state/shortcut-pending/sc-*.args >/dev/null 2>&1 && fail "the backend hook left a pending record"
  assert_no_grep "blocked" "$dir/home/state/st-1.status" "the backend hook raised a blocked line"
  pass "release-hook on a captain-deployed repo prints the release-done command with 1Password signed out"
}

test_a_replayed_backend_hook_reports_the_next_step() {
  local dir out key
  dir=$(make_case hook-backend-replay)
  printf 'working [at=1]: start\n' > "$dir/home/state/st-1.status"
  out=$(ticket "$dir" release-hook "$BACKEND_RELEASE" --task st-1 --best-effort) || fail "release-hook failed: $out"
  assert_grep "blocked [at=" "$dir/home/state/st-1.status" "a hook that could not read the release did not block"
  assert_no_grep "release-done" "$dir/home/state/st-1.status" "a hook that could not tell whether the PR is a release named the release-done step"
  key=$(sed -n 's/.*\[key=\(shortcut-sync-[^]]*\)\].*/\1/p' "$dir/home/state/st-1.status" | head -1)
  pr_info "$dir" 300 main MERGED abc1234abc1234abc1234abc1234abc1234abc12
  ticket "$dir" pending >/dev/null || fail "pending failed"
  assert_grep "resolved [at=" "$dir/home/state/st-1.status" "the replay did not resolve the record"
  assert_equals 1 "$(grep -c "^resolved .*\[key=$key\]: .*run: bin/fm-shortcut-ticket.sh release-done $BACKEND_RELEASE\$" "$dir/home/state/st-1.status")" \
    "the replayed hook lost the release-done step"
  assert_no_grep "went through" "$dir/home/state/st-1.status" "the replayed hook claimed Shortcut updated"
  pass "a replayed release-hook on a captain-deployed repo hands firstmate the release-done step"
}

test_a_signed_out_vercel_hook_names_the_release_step() {
  local dir sha=abc1234abc1234abc1234abc1234abc1234abc12
  dir=$(make_case hook-vercel-signed-out)
  seed_release "$dir"
  printf 'working [at=1]: start\n' > "$dir/home/state/st-101.status"
  NO_TOKEN=1 ticket "$dir" release-hook "$RELEASE" --task st-101 --best-effort >/dev/null || fail "release-hook failed"
  assert_equals 1 "$(grep -c "^blocked .*run: bin/fm-shortcut-ticket.sh release-done $RELEASE\$" "$dir/home/state/st-101.status")" \
    "the token failure did not name the release-done step"
  deploy "$dir" 55 "$sha" pending
  ticket "$dir" pending >/dev/null || fail "pending failed"
  assert_equals 1 "$(grep -c "^blocked .*: $RELEASE merged.*run: bin/fm-shortcut-ticket.sh release-done $RELEASE\$" "$dir/home/state/st-101.status")" \
    "a replay that now waits for production did not say so"
  ticket "$dir" pending >/dev/null || fail "pending failed"
  assert_equals 2 "$(grep -c '^blocked' "$dir/home/state/st-101.status")" "a replay that still waits repeated the blocked line"
  pass "a Vercel release-hook first blocked on the token names the release-done step, once per reason"
}

test_a_later_failure_keeps_the_pending_record() {
  local dir out
  dir=$(make_case retry-then-die)
  tasks_add "$dir" st-9 "Widget"
  (cd "$dir/code" && FM_SHORTCUT_TICKETS=off FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$ROOT/bin/fm-tasks-axi.sh" update st-9 --body "Shortcut: sc-21" >/dev/null 2>&1)
  story "$dir" 21 500000008 "x
${OWNED}st-9"
  printf 'working [at=1]: start\n' > "$dir/home/state/st-9.status"
  out=$(NO_TOKEN=1 ticket "$dir" comment st-9 --file "$dir/missing.md" --best-effort) || fail "a best-effort hook failed the caller: $out"
  assert_contains "$out" "run: bin/fm-shortcut-ticket.sh comment st-9 --file $dir/missing.md" "the token warning did not name the call to rerun"
  out=$(ticket "$dir" comment st-9 --file "$dir/missing.md" --best-effort) || fail "a best-effort hook failed the caller: $out"
  assert_contains "$out" "no such comment file" "the second call did not fail on the missing file"
  ls "$dir"/home/state/shortcut-pending/sc-*.args >/dev/null 2>&1 || fail "a failed best-effort call cleared the pending record"
  assert_no_grep "resolved" "$dir/home/state/st-9.status" "a failed best-effort call claimed the update went through"
  pass "a best-effort call that fails for another reason keeps its pending record and claims nothing"
}

test_release_hook_ignores_merges_to_other_bases() {
  local dir out
  dir=$(make_case hook-dev)
  pr_info "$dir" 400 dev MERGED abc1234abc1234abc1234abc1234abc1234abc12
  out=$(NO_TOKEN=1 ticket "$dir" release-hook https://github.com/applypass/apply_pass_frontend/pull/400 --best-effort) ||
    fail "release-hook failed: $out"
  assert_equals "" "$out" "a merge to dev produced output or a token failure"
  [ ! -s "$dir/sc/curl.log" ] || fail "a merge to dev called Shortcut"
  pass "release-hook is silent for a merge that is not into the release base"
}

test_feature_off_makes_no_release_calls() {
  local dir
  dir=$(make_case off)
  seed_release "$dir"
  (cd "$dir/code" && FM_SHORTCUT_TICKETS=off FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    FAKE_SC_DIR="$dir/sc" FAKE_GH_DIR="$dir/gh" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-shortcut-ticket.sh" release-done "$RELEASE") || fail "release-done with the feature off failed"
  [ ! -s "$dir/sc/curl.log" ] || fail "release-done called Shortcut with the feature off"
  pass "with the feature off release-done does nothing"
}

test_release_done_finishes_only_complete_stories
test_release_done_is_idempotent
test_failure_is_loud_and_retried
test_best_effort_hook_failure_is_loud_and_replayed_by_any_run
test_release_hook_on_a_vercel_repo_waits_for_production
test_release_hook_accepts_a_later_production_deployment
test_release_hook_on_a_backend_repo_prints_the_next_step
test_release_hook_on_a_backend_repo_needs_no_token
test_a_replayed_backend_hook_reports_the_next_step
test_a_signed_out_vercel_hook_names_the_release_step
test_a_later_failure_keeps_the_pending_record
test_release_hook_ignores_merges_to_other_bases
test_feature_off_makes_no_release_calls
