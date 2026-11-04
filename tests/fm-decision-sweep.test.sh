#!/usr/bin/env bash
# Behavior tests for bin/fm-decision-sweep.sh (applypass fork): when a decision
# replaces another, list the backlog items and PRs tied to the old one and open
# one re-check item per PR. gh and the Shortcut script are stubs (FM_SWEEP_GH,
# FM_SWEEP_TICKET); the backlog is a real tasks-axi file in a temp home, so no
# test reaches GitHub, Shortcut or a real home.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-decision-sweep)
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE \
  FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_SHORTCUT_TICKETS

BACKEND=applypass/apply_pass_backend
FRONTEND=applypass/apply_pass_frontend
BURL="https://github.com/$BACKEND/pull"
FURL="https://github.com/$FRONTEND/pull"
DECISIONS=decided.md

tasks() {  # <case-dir> <tasks-axi args...>
  local dir=$1
  shift
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" FM_SHORTCUT_TICKETS=off \
    "$ROOT/bin/fm-tasks-axi.sh" "$@" 2>&1)
}

make_case() {  # <name>
  local dir="$TMP_ROOT/$1" fx
  fx="$dir/fx"
  mkdir -p "$dir/code/defaults" "$dir/home/data" "$dir/home/state" "$dir/home/config" "$dir/home/projects" "$dir/fakebin" "$fx"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
  cp "$ROOT/defaults/shortcut-tickets" "$dir/code/defaults/shortcut-tickets"
  printf '## In flight\n\n## Queued\n\n## Done\n' >"$dir/home/data/backlog.md"
  {
    printf -- '- [plan-multi] 2026-10-31 approved: several alternate languages (shortcut: sc-9018 https://app.shortcut.com/applypass/story/9018)\n'
    printf -- '- [dropdown-again] 2026-11-03 back to one dropdown (supersedes: plan-multi, sc-8740, apply_pass_frontend#443) (shortcut: pending)\n'
  } >"$dir/home/data/$DECISIONS"

  # gh stub: lists and views come from fixture files, every call is logged.
  cat >"$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FX/gh.log"
case "$1 $2" in
  "pr list")
    repo= state=
    while [ "$#" -gt 0 ]; do case "$1" in --repo) repo=$2 ;; --state) state=$2 ;; esac; shift; done
    f="$FX/$(printf '%s' "$repo" | tr / _).$state.json"
    if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi ;;
  "pr view")
    n=${3##*/}
    if [ -f "$FX/view.$n.json" ]; then cat "$FX/view.$n.json"; else exit 1; fi ;;
  "api repos"*)
    [ ! -e "$FX/api.fail" ] || { echo "HTTP 403: rate limit" >&2; exit 1; }
    f="$FX/commits.$(printf '%s' "$2" | tr / _).txt"
    [ ! -f "$f" ] || cat "$f" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
  cat >"$dir/fakebin/ticket" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FX/ticket.log"
SH
  chmod +x "$dir/fakebin/ticket"

  # Backend: open release PR 826 carries 823 and 91; both are on dev.
  cat >"$fx/applypass_apply_pass_backend.open.json" <<JSON
[{"number":826,"title":"Release 1103","body":"| 823 | sc-9018 |","headRefName":"dev","baseRefName":"main","url":"$BURL/826"},
 {"number":500,"title":"Unrelated sc-1111","body":"see https://app.shortcut.com/applypass/story/9018","headRefName":"fm/other","baseRefName":"dev","url":"$BURL/500"},
 {"number":501,"title":"Near miss sc-90180","body":"","headRefName":"fm/near","baseRefName":"dev","url":"$BURL/501"}]
JSON
  cat >"$fx/applypass_apply_pass_backend.merged.json" <<JSON
[{"number":823,"title":"Store several languages (sc-9018, sc-8740)","body":"","headRefName":"fm/multi","baseRefName":"dev","url":"$BURL/823","mergedAt":"2026-11-01T10:00:00Z"},
 {"number":91,"title":"Earlier sc-9018 work","body":"","headRefName":"fm/earlier","baseRefName":"dev","url":"$BURL/91","mergedAt":"2026-08-02T10:00:00Z"},
 {"number":90,"title":"Old sc-9018 work","body":"","headRefName":"fm/old","baseRefName":"dev","url":"$BURL/90","mergedAt":"2026-08-01T10:00:00Z"}]
JSON
  printf 'Merge pull request #823 from x\nEarlier work (#91)\n' >"$fx/commits.repos_applypass_apply_pass_backend_pulls_826_commits.txt"
  # Frontend: PR 443 by direct ref and by sc-8740, PR 448 by sc-8740 only.
  cat >"$fx/applypass_apply_pass_frontend.merged.json" <<JSON
[{"number":443,"title":"Pills for sc-8740","body":"","headRefName":"fm/pills","baseRefName":"dev","url":"$FURL/443","mergedAt":"2026-11-01T11:00:00Z"},
 {"number":448,"title":"More sc-8740 polish","body":"","headRefName":"fm/polish","baseRefName":"dev","url":"$FURL/448","mergedAt":"2026-11-02T11:00:00Z"}]
JSON
  printf '{"title":"Pills for sc-8740","body":"","headRefName":"fm/pills"}\n' >"$fx/view.443.json"
  printf '[]\n' >"$fx/applypass_apply_pass_frontend.open.json"

  tasks "$dir" add multi "Multi-select languages" --kind ship --body "sc-9018 storage. pr=$BURL/823" >/dev/null || fail "fixture add failed"
  printf '%s\n' "$dir"
}

sweep() {  # <case-dir> <args...>
  local dir=$1
  shift
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" FX="$dir/fx" FM_SHORTCUT_TICKETS=off \
    FM_SWEEP_GH="$dir/fakebin/gh" FM_SWEEP_TICKET="$dir/fakebin/ticket" FM_SWEEP_SINCE=2026-10-05 \
    PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-decision-sweep.sh" "$@" 2>&1)
}

test_refs_find_items_and_prs_and_open_rechecks() {
  local dir out body
  dir=$(make_case find)
  out=$(sweep "$dir" dropdown-again) || fail "sweep failed: $out"
  assert_contains "$out" "multi (" "the backlog item naming the old story was not listed"
  assert_contains "$out" "$BURL/823 (merged 2026-11-01, in release $BURL/826)" "PR 823 was not reported with its open release"
  assert_contains "$out" "$FURL/443" "the directly named PR 443 was not found"
  assert_contains "$out" "$FURL/448" "a PR naming the story sc-8740 in its title was not found"
  assert_contains "$out" "$BURL/91 (merged 2026-08-02, in release $BURL/826)" "an old PR inside an open release was dropped"
  assert_not_contains "$out" "$BURL/90" "a PR older than the window and in no release was reported"
  assert_not_contains "$out" "$BURL/500" "a PR whose body only holds a story URL was reported"
  assert_not_contains "$out" "$BURL/501" "sc-90180 was matched as sc-9018"
  assert_not_contains "$out" "$BURL/826 (" "the release PR itself was reported as work"
  assert_contains "$out" "rechecks opened=4 existing=0" "the summary line is wrong"
  body=$(tasks "$dir" show recheck-dropdown-again-apply_pass_backend-823 --full) || fail "no re-check item for PR 823: $body"
  assert_contains "$body" "pr=$BURL/823" "the re-check lacks the PR URL"
  assert_contains "$body" "old=plan-multi" "the re-check lacks the old decision (found through the key's story)"
  assert_contains "$body" "new=dropdown-again" "the re-check lacks the new key"
  assert_contains "$body" "release=$BURL/826" "the re-check lacks the carrying release"
  assert_contains "$body" "kind: recheck" "the re-check is not kind recheck"
  body=$(tasks "$dir" show recheck-dropdown-again-apply_pass_frontend-443 --full) || fail "no re-check item for PR 443: $body"
  assert_contains "$body" "old=apply_pass_frontend#443" "the re-check lacks the PR ref as old"
  assert_contains "$body" "old=sc-8740" "the re-check lacks the story ref as old"
  assert_grep 'comment sc-9018 ' "$dir/fx/ticket.log" "sc-9018 was not commented on"
  assert_grep 'comment sc-8740 ' "$dir/fx/ticket.log" "sc-8740 was not commented on"
  assert_equals 2 "$(grep -c '^comment ' "$dir/fx/ticket.log")" "a story was commented on more than once"
  pass "key, story and PR refs find the item and the PRs, and each PR gets one re-check item"
}

test_second_run_opens_no_duplicates() {
  local dir out
  dir=$(make_case twice)
  sweep "$dir" dropdown-again >/dev/null || fail "first sweep failed"
  out=$(sweep "$dir" dropdown-again) || fail "second sweep failed: $out"
  assert_contains "$out" "rechecks opened=0 existing=4" "the second run did not see the open re-checks"
  assert_equals 2 "$(grep -c '^comment ' "$dir/fx/ticket.log")" "the second run commented again"
  assert_equals 4 "$(tasks "$dir" list | grep -c '^  recheck-')" "re-check items were duplicated"
  pass "running the sweep again opens and comments nothing new"
}

test_registered_project_repo_is_searched() {
  local dir out
  dir=$(make_case project)
  printf -- '- extra [no-mistakes] - a project (added 2026-11-01)\n' >"$dir/home/data/projects.md"
  git init -q "$dir/home/projects/extra"
  git -C "$dir/home/projects/extra" remote add origin https://github.com/applypass/extra.git
  out=$(sweep "$dir" dropdown-again) || fail "sweep failed: $out"
  assert_grep 'pr list --repo applypass/extra --state open' "$dir/fx/gh.log" "the registered project's repo was not searched"
  assert_grep 'pr list --repo applypass/apply_pass_backend --state merged --base dev' "$dir/fx/gh.log" "the backend repo was not searched on dev"
  pass "repos of registered projects are searched next to the backend and web app"
}

test_missing_suffix_and_unreadable_repo() {
  local dir out
  dir=$(make_case failures)
  printf -- '- [plain] 2026-11-03 no suffix (shortcut: pending)\n' >>"$dir/home/data/$DECISIONS"
  out=$(sweep "$dir" plain) && fail "a decision with no supersede suffix swept"
  assert_contains "$out" "no (supersedes: ...) suffix" "the refusal does not say what is missing"
  out=$(sweep "$dir" nosuchkey) && fail "an unknown key swept"
  assert_contains "$out" "no decision [nosuchkey]" "the unknown key was not named"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$dir/fakebin/gh"
  out=$(sweep "$dir" dropdown-again) && fail "a sweep that could not list PRs exited 0"
  assert_contains "$out" "could not list PRs of $BACKEND" "the unreadable repo was not named"
  pass "a missing suffix, an unknown key and an unreadable repo are reported, not swept silently"
}

test_pending_story_stamp_counts() {
  local dir out
  dir=$(make_case pending)
  {
    printf -- '- [pills] 2026-10-30 several language pills (shortcut: pending sc-8740)\n'
    printf -- '- [one-dropdown] 2026-11-03 one dropdown (supersedes: pills) (shortcut: pending)\n'
  } >>"$dir/home/data/$DECISIONS"
  out=$(sweep "$dir" one-dropdown) || fail "sweep failed: $out"
  assert_contains "$out" "$FURL/443" "PR 443 on the pending story sc-8740 was missed"
  assert_contains "$out" "$FURL/448" "PR 448 on the pending story sc-8740 was missed"
  pass "an old decision whose story post is still pending gives its story to the sweep"
}

test_unreadable_release_commits_fail_the_sweep() {
  local dir out
  dir=$(make_case release-fail)
  : >"$dir/fx/api.fail"
  out=$(sweep "$dir" dropdown-again) && fail "a sweep that could not read the release's commits exited 0: $out"
  assert_contains "$out" "could not read the commits of release $BURL/826" "the unreadable release was not named"
  assert_not_contains "$out" "$BURL/91 (" "an old PR was reported as carried with no commit list"
  pass "a release PR whose commits cannot be read fails the sweep instead of dropping its PRs"
}

test_named_pr_outside_the_lists_gets_a_recheck() {
  local dir out body url=https://github.com/applypass/firstmate/pull/81
  dir=$(make_case named)
  printf -- '- [gate-again] 2026-11-04 new gate (supersedes: firstmate#81) (shortcut: pending)\n' >>"$dir/home/data/$DECISIONS"
  printf '{"title":"Old gate","body":"","headRefName":"fm/gate","state":"MERGED","mergedAt":"2026-11-02T09:00:00Z"}\n' >"$dir/fx/view.81.json"
  out=$(sweep "$dir" gate-again) || fail "sweep failed: $out"
  assert_contains "$out" "$url (merged 2026-11-02)" "the named PR in an unsearched repo was not listed"
  assert_contains "$out" "rechecks opened=1 existing=0" "the named PR got no re-check"
  body=$(tasks "$dir" show recheck-gate-again-firstmate-81 --full) || fail "no re-check item for firstmate#81: $body"
  assert_contains "$body" "pr=$url" "the re-check lacks the PR URL"
  assert_contains "$body" "old=firstmate#81" "the re-check lacks the PR ref as old"
  pass "a PR named as a ref gets a re-check even when no searched PR list holds it"
}

test_pr_ref_alone_expands_to_its_stories() {
  local dir out
  dir=$(make_case pr-only)
  printf -- '- [by-pr] 2026-11-04 one dropdown (supersedes: apply_pass_backend#823) (shortcut: pending)\n' >>"$dir/home/data/$DECISIONS"
  printf '{"title":"Store several languages (sc-9018, sc-8740)","body":"","headRefName":"fm/multi","state":"MERGED","mergedAt":"2026-11-01T10:00:00Z"}\n' >"$dir/fx/view.823.json"
  out=$(sweep "$dir" by-pr) || fail "sweep failed: $out"
  assert_not_contains "$out" "jq: error" "reading the named PR's stories failed"
  assert_contains "$out" "$BURL/823 (" "the named PR was not listed"
  assert_contains "$out" "$FURL/443" "PR 443 on sc-8740, a story the named PR names, was missed"
  assert_contains "$out" "$FURL/448" "PR 448 on sc-8740, a story the named PR names, was missed"
  assert_contains "$out" "$BURL/91 (" "PR 91 on sc-9018, a story the named PR names, was missed"
  pass "a PR named as the only ref expands to the stories in its title, body and branch"
}

add_merged_pr() {  # <case-dir> <number> <title> <mergedAt>
  local f="$1/fx/applypass_apply_pass_backend.merged.json"
  jq --argjson n "$2" --arg t "$3" --arg m "$4" --arg u "$BURL/$2" \
    '. + [{number: $n, title: $t, body: "", headRefName: "fm/x\($n)", baseRefName: "dev", url: $u, mergedAt: $m}]' "$f" >"$f.new" && mv "$f.new" "$f"
}

test_long_item_bodies_are_read_in_full() {
  local dir out pad
  dir=$(make_case long-body)
  pad=$(printf 'x%.0s' $(seq 1 700))
  tasks "$dir" add longitem "Language notes" --kind ship --body "notes $pad end. pr=$BURL/777 Shortcut: sc-8740" >/dev/null || fail "fixture add failed"
  add_merged_pr "$dir" 777 "Language storage" 2026-11-02T10:00:00Z
  out=$(sweep "$dir" dropdown-again) || fail "sweep failed: $out"
  assert_contains "$out" "longitem (" "an item whose story sits past the list cut was not listed"
  assert_contains "$out" "$BURL/777 (merged 2026-11-02)" "a pr= link past the list cut was not followed"
  pass "an item's story and pr= link past the list's 500-char cut are found"
}

test_done_item_link_keeps_the_window() {
  local dir out
  dir=$(make_case done-link)
  tasks "$dir" add lang-v1 "First language picker" --kind ship --body "sc-9018 v1. pr=$BURL/700" >/dev/null || fail "fixture add failed"
  tasks "$dir" "done" lang-v1 --note "shipped" >/dev/null || fail "fixture done failed"
  add_merged_pr "$dir" 700 "Language picker v1" 2026-06-01T10:00:00Z
  out=$(sweep "$dir" dropdown-again) || fail "sweep failed: $out"
  assert_contains "$out" "lang-v1 (" "the done item tied to the old story was not listed"
  assert_not_contains "$out" "$BURL/700" "a PR merged before the window was reported through a done item's link"
  pass "a PR linked from a done item must be open, recent or in an open release"
}

test_dry_run_opens_nothing() {
  local dir out
  dir=$(make_case dry)
  out=$(sweep "$dir" dropdown-again --dry-run) || fail "dry run failed: $out"
  assert_contains "$out" "would open recheck-dropdown-again-apply_pass_backend-823" "the dry run did not name the re-check"
  [ ! -e "$dir/fx/ticket.log" ] || fail "the dry run commented on a story"
  tasks "$dir" show recheck-dropdown-again-apply_pass_backend-823 >/dev/null && fail "the dry run opened a re-check"
  pass "--dry-run lists and opens nothing"
}

test_refs_find_items_and_prs_and_open_rechecks
test_second_run_opens_no_duplicates
test_registered_project_repo_is_searched
test_missing_suffix_and_unreadable_repo
test_pending_story_stamp_counts
test_unreadable_release_commits_fail_the_sweep
test_named_pr_outside_the_lists_gets_a_recheck
test_pr_ref_alone_expands_to_its_stories
test_long_item_bodies_are_read_in_full
test_done_item_link_keeps_the_window
test_dry_run_opens_nothing
