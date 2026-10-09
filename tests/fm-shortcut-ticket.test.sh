#!/usr/bin/env bash
# Behavior tests for the Shortcut ticket-on-add feature (applypass fork):
# bin/fm-shortcut-ticket.sh, its hook in bin/fm-tasks-axi.sh add, and the
# secondmate handoff. Shortcut is stubbed with a fake curl on PATH; no test
# reaches the real API. The spawn refusal cases live in
# tests/fm-backlog-atomicity.test.sh beside the spawn fixtures.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-shortcut-ticket)
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE \
  FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
TOKEN=tok-secret-123
OWNER=11111111-2222-4333-8444-555555555555
TOKEN_REF='op://home-vault/Shortcut API key/password'


# A code root (tracked .tasks.toml, shipped defaults) beside a separate home.
make_case() {  # <name> [on|off|nodefaults]
  local dir="$TMP_ROOT/$1" mode=${2:-on}
  mkdir -p "$dir/code/defaults" "$dir/home/data" "$dir/home/state" "$dir/home/config"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
  if [ "$mode" != nodefaults ]; then
    cp "$ROOT/defaults/shortcut-tickets" "$dir/code/defaults/shortcut-tickets"
  fi
  printf 'owner_id=%s\ntoken_ref=%s\n' "$OWNER" "$TOKEN_REF" > "$dir/home/config/shortcut-tickets"
  [ "$mode" != off ] || printf 'enabled=off\n' >> "$dir/home/config/shortcut-tickets"
  fm_fake_shortcut_curl "$dir/fakebin"
  fm_fake_op "$dir/fakebin"
  : > "$dir/curl.log"
  printf '%s\n' "$dir"
}

run_tasks() {  # <case-dir> <wrapper args...>
  local dir=$1
  shift
  (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    SHORTCUT_API_TOKEN="${TOKEN_OVERRIDE-$TOKEN}" FAKE_CURL_LOG="$dir/curl.log" \
    PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-tasks-axi.sh" "$@" 2>&1)
}

check_item() {  # <case-dir> <id>
  local dir=$1
  (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    SHORTCUT_API_TOKEN="${TOKEN_OVERRIDE-$TOKEN}" FAKE_CURL_LOG="$dir/curl.log" \
    PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-shortcut-ticket.sh" --check "$2" 2>&1)
}

# Seed the fake Shortcut store with a story whose description is <text>.
seed_story() {  # <case-dir> <num> <text>
  mkdir -p "$1/fake-stories"
  printf '%s\n' "$3" > "$1/fake-stories/$2.desc"
}

show() {  # <case-dir> <id>
  (cd "$1/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$1/home" FM_ROOT_OVERRIDE="$1/code" "$ROOT/bin/fm-tasks-axi.sh" show "$2" --full 2>&1)
}

test_shipped_defaults_are_on_and_absent_means_off() {
  local dir
  dir=$(make_case defaults-on)
  (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    "$ROOT/bin/fm-shortcut-ticket.sh" --enabled) || fail "shipped defaults are not on"
  dir=$(make_case defaults-absent nodefaults)
  (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    "$ROOT/bin/fm-shortcut-ticket.sh" --enabled) && fail "an absent defaults file did not mean off"
  pass "the shipped defaults enable the feature and an absent file means off"
}

test_add_creates_story_and_records_id() {
  local dir out
  dir=$(make_case create)
  out=$(run_tasks "$dir" add st-1 "Fix the widget" --kind ship --body "- Problem: broken
- Fix: repair") || fail "add failed: $out"
  assert_contains "$(show "$dir" st-1)" "sc-7777 https://app.shortcut.com/applypass/story/7777" \
    "the story id and URL were not recorded on the item"
  assert_contains "$(show "$dir" st-1)" "Problem: broken" "the original body was lost"
  assert_grep "POST https://api.app.shortcut.com/api/v3/stories" "$dir/curl.log" "no story was created"
  assert_grep '"name":"Fix the widget"' "$dir/curl.log" "story name is not the item title"
  assert_grep "649562cb-7f18-471f-835f-7ed28a5abf0a" "$dir/curl.log" "team id missing from the request"
  assert_grep '"workflow_state_id":500000006' "$dir/curl.log" "story was not created in Backlog"
  assert_grep "$OWNER" "$dir/curl.log" "the home's owner missing from the request"
  assert_grep 'firstmate-item: home/st-1' "$dir/fake-stories/7777.desc" "create did not write the ownership marker"
  assert_grep 'Problem: broken' "$dir/fake-stories/7777.desc" "the marker replaced the description"
  assert_grep "TOKEN-ON-STDIN" "$dir/curl.log" "the token did not reach curl on stdin"
  assert_no_grep "TOKEN-IN-ARGV" "$dir/curl.log" "the token leaked into curl's argv"
  assert_not_contains "$out" "$TOKEN" "the token was printed"
  pass "add creates a Shortcut story and records its id and URL on the item"
}

test_existing_story_is_adopted_only_by_link() {
  local dir out
  dir=$(make_case link)
  seed_story "$dir" 4343 "Existing work"
  out=$(run_tasks "$dir" add st-3 "Other work" --kind ship --body "Shortcut: sc-4343 https://app.shortcut.com/applypass/story/4343") || fail "add failed: $out"
  assert_grep "GET https://api.app.shortcut.com/api/v3/stories/4343" "$dir/curl.log" "the body-named story was not read"
  assert_no_grep "POST" "$dir/curl.log" "a duplicate story was created for a body-named id"
  assert_contains "$out" "mark it: bin/fm-shortcut-ticket.sh link st-3 sc-4343" "the refusal did not name the link for a pre-marker own story"
  assert_contains "$out" "create the item's own story: bin/fm-shortcut-ticket.sh st-3" "the refusal did not name the create command for a shared story"
  check_item "$dir" st-3 >/dev/null && fail "--check passed an unowned body-named story"
  out=$(ticket "$dir" link st-3 sc-4343) || fail "link failed: $out"
  assert_grep 'firstmate-item: home/st-3' "$dir/fake-stories/4343.desc" "link did not write the marker"
  assert_grep 'Existing work' "$dir/fake-stories/4343.desc" "link lost the story description"
  check_item "$dir" st-3 >/dev/null || fail "--check refused a linked story"
  FAKE_CURL_FAIL=1 run_tasks "$dir" add st-13 "Unticketed" --kind ship >/dev/null
  seed_story "$dir" 4444 "Fresh"
  out=$(ticket "$dir" link st-13 sc-4444) || fail "link of an item with no body line failed: $out"
  assert_contains "$(show "$dir" st-13)" "Shortcut: sc-4444" "link did not record the body line"
  check_item "$dir" st-13 >/dev/null || fail "--check refused a story link recorded"
  pass "an existing story becomes an item's own only through link, which marks it and records the body line"
}

test_umbrella_or_shared_body_line_is_refused() {
  local dir out
  dir=$(make_case shared)
  seed_story "$dir" 6104 "Launch fixes umbrella"
  run_tasks "$dir" add sh-1 "Launch fix one" --kind ship --body "Shortcut: sc-6104" >/dev/null
  out=$(check_item "$dir" sh-1) && fail "--check passed an umbrella named as a body line"
  assert_contains "$out" "no 'firstmate-item: home/sh-1' marker" "the umbrella refusal did not name the missing marker"
  seed_story "$dir" 5555 "firstmate-item: home/sh-2"
  run_tasks "$dir" add sh-2 "Owner" --kind ship --body "Shortcut: sc-5555" >/dev/null
  run_tasks "$dir" add sh-3 "Sharer" --kind ship --body "Shortcut: sc-5555" >/dev/null
  check_item "$dir" sh-2 >/dev/null || fail "--check refused the story's own item"
  out=$(check_item "$dir" sh-3) && fail "--check passed a second item sharing a story"
  assert_contains "$out" "belongs to another item (sh-2" "the shared refusal did not name the owner"
  out=$(ticket "$dir" link sh-3 sc-5555) && fail "link adopted another item's story"
  assert_contains "$out" "already belongs to another item" "the link refusal did not say why"
  assert_no_grep 'sh-3' "$dir/fake-stories/5555.desc" "a refused link still marked the story"
  FAKE_CURL_FAIL=1 run_tasks "$dir" add sh-4 "Launch fix sc-6104 widget" --kind ship >/dev/null
  out=$(ticket "$dir" link sh-4 sc-6104) && fail "link adopted the title umbrella"
  assert_contains "$out" "parent (umbrella) story" "the umbrella link refusal did not say why"
  assert_contains "$out" "bin/fm-shortcut-ticket.sh sh-4" "the umbrella link refusal did not name the create command"
  assert_no_grep 'sh-4' "$dir/fake-stories/6104.desc" "a refused umbrella link still marked the story"
  pass "a body line naming an umbrella or another item's story fails the check, and link refuses it and the title umbrella"
}

test_title_id_is_a_parent_never_reused() {
  local dir out
  dir=$(make_case umbrella)
  out=$(run_tasks "$dir" add st-2 "Launch fix sc-4242 widget" --kind ship) || fail "add failed: $out"
  assert_grep "POST https://api.app.shortcut.com/api/v3/stories" "$dir/curl.log" "an umbrella title id stopped the item getting its own story"
  assert_grep "POST https://api.app.shortcut.com/api/v3/story-links" "$dir/curl.log" "the child story was not linked to the umbrella"
  assert_grep '"object_id":4242' "$dir/curl.log" "the link does not point at the umbrella story"
  assert_grep '"subject_id":7777' "$dir/curl.log" "the link does not start at the new story"
  assert_contains "$(show "$dir" st-2)" "Shortcut: sc-7777" "the item's own story was not recorded"
  : > "$dir/curl.log"
  out=$(ticket "$dir" state st-2 progress) || fail "state failed: $out"
  assert_grep "PUT https://api.app.shortcut.com/api/v3/stories/7777" "$dir/curl.log" "the state move missed the item's own story"
  assert_no_grep "4242" "$dir/curl.log" "a state move touched the umbrella story"
  pass "a title sc id is a parent: the item gets its own linked story and state moves never touch the parent"
}

test_check_needs_an_own_verified_story() {
  local dir out
  dir=$(make_case check-own)
  FAKE_CURL_FAIL=1 run_tasks "$dir" add ck-2 "Umbrella sc-4242" --kind ship >/dev/null
  out=$(check_item "$dir" ck-2) && fail "--check passed on a title-only id"
  assert_contains "$out" "no Shortcut story of its own" "the refusal did not explain the title id is only a parent"
  seed_story "$dir" 4343 "firstmate-item: home/ck-3"
  run_tasks "$dir" add ck-3 "Own story" --kind ship --body "Shortcut: sc-4343" >/dev/null
  check_item "$dir" ck-3 >/dev/null || fail "--check refused a verified body line"
  assert_grep "GET https://api.app.shortcut.com/api/v3/stories/4343" "$dir/curl.log" "--check did not confirm the story exists"
  run_tasks "$dir" add ck-4 "Ghost story" --kind ship --body "Shortcut: sc-9999" >/dev/null
  out=$(FAKE_CURL_MISSING=9999 check_item "$dir" ck-4) && fail "--check passed a story that does not exist"
  assert_contains "$out" "sc-9999" "the unreadable story was not named"
  pass "--check passes only on a body-line story that exists and is marked as the item's own"
}

test_check_and_create_need_the_home_settings() {
  local dir out
  dir=$(make_case settings)
  seed_story "$dir" 4343 "firstmate-item: home/hs-1"
  run_tasks "$dir" add hs-1 "Own story" --kind ship --body "Shortcut: sc-4343" >/dev/null
  printf 'token_ref=%s\n' "$TOKEN_REF" > "$dir/home/config/shortcut-tickets"
  out=$(check_item "$dir" hs-1) && fail "--check passed with no owner_id"
  assert_contains "$out" "add this line to $dir/home/config/shortcut-tickets: owner_id=<Shortcut member UUID>" "the refusal did not give the owner_id line"
  : > "$dir/curl.log"
  out=$(run_tasks "$dir" add hs-2 "No owner" --kind ship) || fail "a missing owner failed the add: $out"
  assert_contains "$out" "owner_id=<Shortcut member UUID>" "create did not refuse a missing owner_id"
  assert_no_grep "POST" "$dir/curl.log" "a story was created with no owner"
  printf 'owner_id=%s\n' "$OWNER" > "$dir/home/config/shortcut-tickets"
  out=$(TOKEN_OVERRIDE='' check_item "$dir" hs-1) && fail "--check passed with no token and no token_ref"
  assert_contains "$out" "token_ref=op://<vault>/<item>/<field>" "the refusal did not give the token_ref line"
  check_item "$dir" hs-1 >/dev/null || fail "an env token without token_ref was refused"
  pass "--check and create refuse with the config line to add when owner_id or token_ref is missing"
}

test_hung_op_read_is_bounded() {
  local dir out start elapsed
  dir=$(make_case op-hang)
  seed_story "$dir" 4343 "firstmate-item: home/oh-1"
  run_tasks "$dir" add oh-1 "Own story" --kind ship --body "Shortcut: sc-4343" >/dev/null
  printf 'op_timeout=1\n' >> "$dir/home/config/shortcut-tickets"
  start=$(date +%s)
  out=$(TOKEN_OVERRIDE='' FAKE_OP_HANG=1 FAKE_OP_TOKEN=tok-secret-123 check_item "$dir" oh-1) && fail "--check passed on a hung op read"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 10 ] || fail "a hung op read was not bounded (${elapsed}s)"
  assert_contains "$out" "did not answer within 1s" "the refusal did not name the timeout"
  : > "$dir/curl.log"
  out=$(TOKEN_OVERRIDE='' FAKE_OP_HANG=1 FAKE_OP_TOKEN=tok-secret-123 ticket "$dir" state oh-1 progress --best-effort) \
    || fail "a best-effort hook failed on a hung op read: $out"
  assert_contains "$out" "warning:" "the best-effort hook did not warn"
  [ ! -s "$dir/curl.log" ] || fail "a hook reached Shortcut without a token"
  pass "a hung op read is bounded by op_timeout: --check refuses and best-effort hooks only warn"
}

test_missing_token_refuses_the_check_and_op_supplies_it() {
  local dir out
  dir=$(make_case token)
  seed_story "$dir" 4343 "firstmate-item: home/tk-1"
  run_tasks "$dir" add tk-1 "Own story" --kind ship --body "Shortcut: sc-4343" >/dev/null
  out=$(TOKEN_OVERRIDE='' check_item "$dir" tk-1) && fail "--check passed with no token and no op"
  assert_contains "$out" "op read $TOKEN_REF" "the refusal did not name the failed 1Password read"
  : > "$dir/curl.log"
  out=$(TOKEN_OVERRIDE='' FAKE_OP_TOKEN=tok-secret-123 FAKE_OP_LOG="$dir/op.log" check_item "$dir" tk-1) || fail "op did not supply the token: $out"
  assert_grep "op read $TOKEN_REF" "$dir/op.log" "the token was not read from token_ref"
  assert_grep "TOKEN-ON-STDIN" "$dir/curl.log" "the op token did not reach curl on stdin"
  assert_no_grep "TOKEN-IN-ARGV" "$dir/curl.log" "the op token leaked into curl's argv"
  assert_no_grep "TOKEN-IN-CHILD-ENV" "$dir/curl.log" "the op token leaked into a child's environment"
  assert_not_contains "$out" "tok-secret-123" "the token was printed"
  pass "a missing token refuses the check; op read supplies it on stdin when configured"
}

test_secondmate_report_needs_the_items_own_story() {
  local dir mate parent_status corr=abcdef0123456789 out
  dir=$(make_case report)
  mate="$dir/home" parent_status="$dir/parent/state/mate.status"
  mkdir -p "$dir/parent/state"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" > "$mate/.fm-secondmate-parent"
  report() {
    (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$mate" FM_ROOT_OVERRIDE="$dir/code" \
      SHORTCUT_API_TOKEN="$TOKEN" FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$PATH" \
      "$ROOT/bin/fm-secondmate-report.sh" "$@" 2>&1)
  }
  out=$(report "done" "$corr" "audit clean") && fail "a done report published with no --item"
  assert_contains "$out" "--item <id>" "the refusal did not ask for the item"
  seed_story "$dir" 6104 "Launch fixes umbrella"
  run_tasks "$dir" add inv-1 "Umbrella only" --kind scout --body "Shortcut: sc-6104" >/dev/null
  out=$(report --item inv-1 --doc "done" "$corr" data/inv-1/report.md "see report") && fail "a --doc report published for an umbrella-only item"
  assert_contains "$out" "no 'firstmate-item: home/inv-1' marker" "the refusal did not give the check's reason"
  out=$(report --item inv-1 ready "$corr" "ready to ship") && fail "a ready report published for an umbrella-only item"
  [ ! -s "$parent_status" ] || fail "a refused report reached the parent channel: $(cat "$parent_status")"
  report working "$corr" "still digging" >/dev/null || fail "a working report needed a story"
  run_tasks "$dir" add inv-2 "Own investigation" --kind scout >/dev/null
  out=$(report --item inv-2 --doc "done" "$corr" data/inv-2/report.md "see report") || fail "an owned item's report was refused: $out"
  grep -q "^done .*corr=$corr.*data/inv-2/report.md" "$parent_status" || fail "the verified report did not reach the parent channel"
  out=$(cd "$dir/code" && FM_SHORTCUT_TICKETS=off FM_HOME="$mate" FM_ROOT_OVERRIDE="$dir/code" \
    "$ROOT/bin/fm-secondmate-report.sh" "done" "$corr" "feature off" 2>&1) || fail "the feature off still required --item: $out"
  pass "a second mate's done or ready report publishes only for an item whose own story --check verifies"
}

test_body_reference_is_not_the_linked_story() {
  local dir out
  dir=$(make_case body-ref)
  out=$(run_tasks "$dir" add st-11 "Harden the retry" --kind ship --body "Follow-up to sc-6092") \
    || fail "add failed: $out"
  assert_grep "POST https://api.app.shortcut.com/api/v3/stories" "$dir/curl.log" "a body reference stopped the item getting its own story"
  assert_no_grep "stories/6092" "$dir/curl.log" "the referenced story was touched on add"
  assert_grep "$OWNER" "$dir/curl.log" "the home's owner was not assigned"
  assert_contains "$(show "$dir" st-11)" "Follow-up to sc-6092" "the reference was lost from the body"
  : > "$dir/curl.log"
  out=$(ticket "$dir" state st-11 progress) || fail "state failed: $out"
  out=$(ticket "$dir" comment st-11 "a learning") || fail "comment failed: $out"
  printf 'a\n' > "$dir/a.png"
  out=$(ticket "$dir" attach st-11 "$dir/a.png") || fail "attach failed: $out"
  out=$(ticket "$dir" park st-11 --reason "not now") || fail "park failed: $out"
  assert_grep "PUT https://api.app.shortcut.com/api/v3/stories/7777" "$dir/curl.log" "the item's own story was not moved"
  assert_grep "FORM story_id=7777" "$dir/curl.log" "the upload did not go to the item's own story"
  assert_no_grep "6092" "$dir/curl.log" "a referenced story was moved, commented on, or uploaded to"
  dir=$(make_case body-ref-unticketed)
  FAKE_CURL_FAIL=1 run_tasks "$dir" add st-12 "Only a reference" --kind ship --body "Follow-up to sc-6092" >/dev/null
  check_item "$dir" st-12 >/dev/null && fail "--check took a body reference as the ticket"
  pass "a body reference such as 'Follow-up to sc-6092' is never the linked story"
}

test_named_story_that_does_not_exist_warns() {
  local dir out
  dir=$(make_case link-missing)
  out=$(FAKE_CURL_MISSING=9999 run_tasks "$dir" add st-4 "Bad ref" --body "Shortcut: sc-9999" --kind ship) \
    || fail "a bad reference failed the add: $out"
  assert_contains "$out" "sc-9999" "the unreadable story was not reported"
  assert_contains "$out" "bin/fm-shortcut-ticket.sh st-4" "the retry command was not named"
  pass "an unreadable named story warns and keeps the add"
}

test_non_work_kinds_are_skipped() {
  local dir out
  dir=$(make_case skip)
  out=$(run_tasks "$dir" add mate-1 "A secondmate" --kind secondmate) || fail "add failed: $out"
  out=$(run_tasks "$dir" add hold-1 "Captain call" --kind captain) || fail "add failed: $out"
  [ ! -s "$dir/curl.log" ] || fail "non-work kinds reached Shortcut: $(cat "$dir/curl.log")"
  check_item "$dir" hold-1 >/dev/null || fail "--check refused an exempt kind"
  pass "secondmate and captain-decision items get no story and pass the check"
}

test_api_failure_keeps_add_and_check_refuses() {
  local dir out check
  dir=$(make_case api-fail)
  out=$(FAKE_CURL_FAIL=1 run_tasks "$dir" add st-5 "Will not ticket" --kind ship) \
    || fail "an API failure failed the add: $out"
  assert_contains "$out" "bin/fm-shortcut-ticket.sh st-5" "the warning did not name the retry command"
  assert_contains "$(show "$dir" st-5)" "Will not ticket" "the item was not added"
  check=$(check_item "$dir" st-5) && fail "--check passed an unticketed item"
  assert_contains "$check" "bin/fm-shortcut-ticket.sh st-5" "the refusal did not name the retry"
  out=$(TOKEN_OVERRIDE='' run_tasks "$dir" add st-7 "No token" --kind ship) \
    || fail "a missing token failed the add: $out"
  assert_contains "$out" "SHORTCUT_API_TOKEN" "a missing token was not reported"
  pass "an API failure or missing token warns, keeps the add, and the check refuses"
}

test_retry_then_check_passes() {
  local dir out
  dir=$(make_case retry)
  FAKE_CURL_FAIL=1 run_tasks "$dir" add st-8 "Retry me" --kind ship >/dev/null
  out=$(cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" SHORTCUT_API_TOKEN="$TOKEN" \
    FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-shortcut-ticket.sh" st-8 2>&1) \
    || fail "retry failed: $out"
  check_item "$dir" st-8 >/dev/null || fail "--check refused after the id was recorded"
  pass "retrying records the id and the check then passes"
}

test_feature_off_makes_no_calls() {
  local dir out
  dir=$(make_case off off)
  out=$(run_tasks "$dir" add st-9 "Quiet" --kind ship) || fail "add failed: $out"
  [ ! -s "$dir/curl.log" ] || fail "a disabled feature called Shortcut"
  check_item "$dir" st-9 >/dev/null || fail "--check refused with the feature off"
  dir=$(make_case off-nodefaults nodefaults)
  out=$(run_tasks "$dir" add st-10 "Upstream" --kind ship) || fail "add failed: $out"
  [ ! -s "$dir/curl.log" ] || fail "an absent settings file called Shortcut"
  pass "feature off (config override or absent defaults) makes no calls and no refusal"
}

# A ticketed item for the lifecycle operations.
make_ticketed() {  # <name> [item-id]
  local dir id=${2:-lc-1}
  dir=$(make_case "$1")
  run_tasks "$dir" add "$id" "Lifecycle" --body "Shortcut: sc-5000" --kind ship >/dev/null || fail "setup add failed"
  : > "$dir/curl.log"
  printf '%s\n' "$dir"
}

ticket() {  # <case-dir> <args...>
  local dir=$1
  shift
  (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    SHORTCUT_API_TOKEN="${TOKEN_OVERRIDE-$TOKEN}" FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-shortcut-ticket.sh" "$@" 2>&1)
}

test_state_moves_the_story() {
  local dir out
  dir=$(make_ticketed state)
  out=$(ticket "$dir" state lc-1 progress) || fail "state progress failed: $out"
  assert_grep 'PUT https://api.app.shortcut.com/api/v3/stories/5000' "$dir/curl.log" "no state update sent"
  assert_grep '"workflow_state_id":500000008' "$dir/curl.log" "story was not moved to In Progress"
  out=$(ticket "$dir" state lc-1 "done") && fail "state accepted done"
  out=$(ticket "$dir" state lc-1 review) || fail "state review failed: $out"
  assert_grep '"workflow_state_id":500000009' "$dir/curl.log" "story was not moved to In Review"
  : > "$dir/curl.log"
  FAKE_CURL_STATE=500000010 ticket "$dir" state lc-1 progress >/dev/null || fail "state on a done story failed"
  assert_no_grep "PUT" "$dir/curl.log" "a Done story was moved back"
  pass "state moves the story to In Progress or In Review, refuses done, and leaves a Done story alone"
}

test_review_links_pr_and_uploads_report() {
  local dir out
  dir=$(make_ticketed review)
  printf 'findings\n' > "$dir/report.md"
  out=$(ticket "$dir" review lc-1 --pr https://github.com/o/r/pull/9 --report "$dir/report.md") \
    || fail "review failed: $out"
  assert_grep '"workflow_state_id":500000009' "$dir/curl.log" "story was not moved to In Review"
  assert_grep 'https://github.com/o/r/pull/9' "$dir/curl.log" "the PR was not linked"
  assert_grep 'POST https://api.app.shortcut.com/api/v3/files' "$dir/curl.log" "the report was not uploaded"
  assert_grep 'FORM story_id=5000' "$dir/curl.log" "the upload was not linked to the story"
  pass "review moves to In Review, links the PR, and uploads the report"
}

test_comment_attach_outcome() {
  local dir out
  dir=$(make_ticketed comment)
  out=$(ticket "$dir" comment lc-1 "Learned: retry on 429") || fail "comment failed: $out"
  assert_grep 'POST https://api.app.shortcut.com/api/v3/stories/5000/comments' "$dir/curl.log" "no comment posted"
  assert_grep 'Learned: retry on 429' "$dir/curl.log" "comment text missing"
  printf 'a\n' > "$dir/a.png"; printf 'b\n' > "$dir/b.png"
  out=$(ticket "$dir" attach lc-1 "$dir/a.png" "$dir/b.png") || fail "attach failed: $out"
  [ "$(grep -c '^POST https://api.app.shortcut.com/api/v3/files' "$dir/curl.log")" -eq 2 ] || fail "both files were not uploaded"
  printf 'done [at=1]: shipped the widget\n' > "$dir/home/state/lc-1.status"
  out=$(FM_STATE_OVERRIDE="$dir/home/state" ticket "$dir" outcome lc-1) || fail "outcome failed: $out"
  assert_grep 'Final outcome: done [at=1]: shipped the widget' "$dir/curl.log" "the outcome line was not posted"
  pass "comment, attach, and outcome post to the story"
}

test_done_needs_evidence_and_is_explicit() {
  local dir out
  dir=$(make_ticketed "done")
  out=$(ticket "$dir" "done" lc-1) && fail "done ran without evidence"
  [ ! -s "$dir/curl.log" ] || fail "done without evidence reached Shortcut"
  out=$(ticket "$dir" "done" lc-1 --evidence "verified in prod") || fail "done failed: $out"
  assert_grep '"workflow_state_id":500000010' "$dir/curl.log" "story was not moved to Done"
  assert_grep 'Done: verified in prod' "$dir/curl.log" "evidence was not commented"
  pass "done requires evidence and moves the story to Done"
}

test_park_returns_story_to_backlog() {
  local dir out
  dir=$(make_ticketed park)
  out=$(ticket "$dir" park lc-1 --reason "captain deprioritised") || fail "park failed: $out"
  assert_grep '"workflow_state_id":500000006' "$dir/curl.log" "story did not return to Backlog"
  assert_grep 'captain deprioritised' "$dir/curl.log" "reason was not commented"
  out=$(ticket "$dir" park lc-1) && fail "park accepted no reason"
  pass "park moves the story back to Backlog with the reason"
}

test_wrapper_rm_and_parked_hold_park_the_story() {
  local dir
  dir=$(make_ticketed wrapper-park lc-2)
  run_tasks "$dir" hold lc-2 --reason "start after launch" --kind future >/dev/null || fail "hold failed"
  [ ! -s "$dir/curl.log" ] || fail "a future hold moved the story"
  run_tasks "$dir" hold lc-2 --reason "not now" --kind parked >/dev/null || fail "parked hold failed"
  assert_grep '"workflow_state_id":500000006' "$dir/curl.log" "a parked hold did not return the story to Backlog"
  assert_grep 'parked: not now' "$dir/curl.log" "the parked reason was not commented"
  : > "$dir/curl.log"
  run_tasks "$dir" hold lc-2 --reason="again later" --kind=parked >/dev/null || fail "equals-form parked hold failed"
  assert_grep 'parked: again later' "$dir/curl.log" "an equals-form parked hold did not park the story"
  : > "$dir/curl.log"
  run_tasks "$dir" add lc-9 "Blocked on lc-2" --kind ship --blocked-by lc-2 >/dev/null || fail "blocked add failed"
  : > "$dir/curl.log"
  run_tasks "$dir" rm lc-2 >/dev/null && fail "rm of a blocking item succeeded"
  assert_no_grep 'cancelled' "$dir/curl.log" "a refused rm parked the story"
  run_tasks "$dir" rm lc-9 >/dev/null || fail "rm of the blocked item failed"
  : > "$dir/curl.log"
  run_tasks "$dir" rm --json lc-2 >/dev/null || fail "rm failed"
  assert_grep 'PUT https://api.app.shortcut.com/api/v3/stories/5000' "$dir/curl.log" "a removed item's story was not moved"
  assert_grep '"workflow_state_id":500000006' "$dir/curl.log" "a removed item's story did not return to Backlog"
  assert_grep 'cancelled' "$dir/curl.log" "a cancelled item did not post its reason"
  pass "a parked hold or a cancelled item sends its story back to Backlog, and a refused rm does not"
}

test_captain_answer_comments_the_decision() {
  local dir out
  dir=$(make_ticketed answer lc-3)
  printf 'Use option B.\n' > "$dir/decision.txt"
  fm_fake_exit0 "$dir/fakebin" tmux treehouse no-mistakes gh gh-axi
  hold() {
    (cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
      SHORTCUT_API_TOKEN="$TOKEN" FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$PATH" \
      "$ROOT/bin/fm-captain-hold.sh" "$@" 2>&1)
  }
  out=$(hold hold lc-3 --reason "captain must choose") || fail "hold failed: $out"
  [ ! -s "$dir/curl.log" ] || fail "holding a task touched Shortcut"
  out=$(hold answer lc-3 --decision-file "$dir/decision.txt") || fail "answer failed: $out"
  assert_grep 'Captain decision [lc-3]: Use option B.' "$dir/curl.log" "the recorded decision was not commented on the story"
  run_tasks "$dir" add lc-4 "Keyed" --body "Shortcut: sc-5001" --kind ship >/dev/null || fail "setup add failed"
  out=$(hold hold lc-4 --reason "captain go needed") || fail "hold failed: $out"
  : > "$dir/curl.log"
  out=$(printf 'lc-4\tgo\t\trelease\n' | hold answers --source "keyed fixture") || fail "keyed answers failed: $out"
  assert_contains "$out" "closed: lc-4" "the keyed release was not accepted"
  assert_grep 'POST https://api.app.shortcut.com/api/v3/stories/5001/comments' "$dir/curl.log" \
    "a keyed release decision was not commented on the story"
  pass "a captain answer, direct or keyed, comments the recorded decision on the story"
}

test_best_effort_is_silent_without_a_ticket_and_warns_on_failure() {
  local dir out
  dir=$(make_case best-effort)
  FAKE_CURL_FAIL=1 run_tasks "$dir" add be-1 "No ticket" --kind ship >/dev/null 2>&1
  : > "$dir/curl.log"
  out=$(ticket "$dir" state be-1 progress --best-effort) || fail "best-effort failed on an unticketed item: $out"
  [ -z "$out" ] || fail "best-effort printed for an unticketed item: $out"
  [ ! -s "$dir/curl.log" ] || fail "best-effort called Shortcut for an unticketed item"
  dir=$(make_ticketed best-effort-fail)
  out=$(TOKEN=bad ticket "$dir" comment lc-1 hi --best-effort) || fail "best-effort failed the caller: $out"
  pass "best-effort stays quiet without a ticket and never fails the caller"
}

test_handoff_carries_the_sc_id() {
  local dir="$TMP_ROOT/handoff" home sub out
  home="$dir/home" sub="$dir/sub"
  mkdir -p "$dir/code/defaults" "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
  cp "$ROOT/defaults/shortcut-tickets" "$dir/code/defaults/"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf 'owner_id=%s\n' "$OWNER" > "$home/config/shortcut-tickets"
  fm_fake_shortcut_curl "$dir/fakebin"
  : > "$dir/curl.log"
  mkdir -p "$sub/state" "$sub/data"
  seed_secondmate_home_marker "$sub" design
  local sub_abs
  sub_abs=$(cd "$sub" && pwd -P)
  printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' \
    "$sub_abs" > "$home/data/secondmates.md"
  printf 'window=firstmate:fm-design\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\nworktree=%s\n' \
    "$sub_abs" "$sub_abs" > "$home/state/design.meta"
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  # One item already ticketed, one not: the second is ticketed during handoff.
  (cd "$dir/code" && FM_SHORTCUT_TICKETS=off FM_HOME="$home" FM_ROOT_OVERRIDE="$dir/code" \
    "$ROOT/bin/fm-tasks-axi.sh" add h-1 "Has ticket" --body "Shortcut: sc-5151" --kind ship >/dev/null &&
    FM_SHORTCUT_TICKETS=off FM_HOME="$home" FM_ROOT_OVERRIDE="$dir/code" \
    "$ROOT/bin/fm-tasks-axi.sh" add h-2 "Needs ticket" --kind ship >/dev/null) || fail "setup add failed"
  local fakebin
  fakebin=$(make_fake_tmux "$dir/fake")
  out=$(cd "$dir/code" && env -u FM_SHORTCUT_TICKETS FM_HOME="$home" FM_ROOT_OVERRIDE="$dir/code" \
    SHORTCUT_API_TOKEN="$TOKEN" FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$fakebin:$PATH" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' FM_FAKE_TMUX_LOG="$dir/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$dir/fake/pane.txt" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 \
    "$ROOT/bin/fm-backlog-handoff.sh" design h-1 h-2 2>&1) || fail "handoff failed: $out"
  assert_grep "sc-5151" "$sub/data/backlog.md" "the linked sc id did not reach the secondmate backlog"
  assert_grep "sc-7777" "$sub/data/backlog.md" "the ticket created during handoff did not travel with the item"
  [ "$(grep -c '^POST' "$dir/curl.log")" -eq 1 ] || fail "the handoff created more than one story"
  pass "a handoff carries each item's sc id, ticketing an unticketed item first"
}

test_shipped_defaults_are_on_and_absent_means_off
test_add_creates_story_and_records_id
test_existing_story_is_adopted_only_by_link
test_umbrella_or_shared_body_line_is_refused
test_title_id_is_a_parent_never_reused
test_check_needs_an_own_verified_story
test_check_and_create_need_the_home_settings
test_hung_op_read_is_bounded
test_secondmate_report_needs_the_items_own_story
test_missing_token_refuses_the_check_and_op_supplies_it
test_body_reference_is_not_the_linked_story
test_named_story_that_does_not_exist_warns
test_non_work_kinds_are_skipped
test_api_failure_keeps_add_and_check_refuses
test_retry_then_check_passes
test_feature_off_makes_no_calls
test_handoff_carries_the_sc_id
test_state_moves_the_story
test_review_links_pr_and_uploads_report
test_comment_attach_outcome
test_done_needs_evidence_and_is_explicit
test_park_returns_story_to_backlog
test_wrapper_rm_and_parked_hold_park_the_story
test_best_effort_is_silent_without_a_ticket_and_warns_on_failure
test_captain_answer_comments_the_decision
