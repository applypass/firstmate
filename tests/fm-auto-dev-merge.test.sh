#!/usr/bin/env bash
# Behavior tests for bin/fm-auto-dev-merge.sh (applypass fork): the standing
# dev-merge authority applied when a ship's green ready report is recorded.
# gh and the merge command are stubs on PATH; nothing reaches a forge.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

AUTO="$ROOT/bin/fm-auto-dev-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-auto-dev-merge)
URL=https://github.com/acme/app/pull/7
CHECK_OK='[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'

# make_case <name> [base] [author] [checks-json] [status-line] [extra-label]
make_case() {
  local name=$1 base=${2:-dev} author=${3:-me} checks=${4:-$CHECK_OK}
  local status=${5:-"done [at=1]: PR $URL checks green"} label=${6:-bug}
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fakebin"
  fm_write_meta "$dir/state/t1.meta" "kind=ship" "mode=no-mistakes"
  printf '%s\n' "working [at=0]: go" "$status" > "$dir/state/t1.status"
  jq -n --arg base "$base" --arg author "$author" --arg label "$label" --argjson checks "$checks" \
    '{state:"OPEN",isDraft:false,baseRefName:$base,author:{login:$author},labels:[{name:$label}],statusCheckRollup:$checks}' \
    > "$dir/pr.json"
  cat > "$dir/fakebin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") cat "$CASE_DIR/pr.json" ;;
  "api user") echo me ;;
  *) exit 1 ;;
esac
GH
  cat > "$dir/merge" <<'M'
#!/usr/bin/env bash
echo "$*" >> "$CASE_DIR/merge.log"
[ ! -e "$CASE_DIR/merge-refuses" ] || { echo "error: refused by merge gate" >&2; exit 1; }
M
  chmod +x "$dir/fakebin/gh" "$dir/merge"
  : > "$dir/merge.log"
  printf '%s\n' "$dir"
}

run_auto() {  # <case-dir>; sets OUT and RC
  local dir=$1
  OUT=$(CASE_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" \
    FM_AUTO_DEV_MERGE_MERGE="$dir/merge" "$AUTO" t1 "$URL" 2>&1)
  RC=$?
}

expect_skip() {  # <name> <case-dir> <reason-fragment>
  [ "$RC" -eq 0 ] || fail "$1: skip must exit 0, got $RC"
  case "$OUT" in *"skipped"*"$3"*) ;; *) fail "$1: expected skip mentioning '$3', got: $OUT" ;; esac
  [ ! -s "$2/merge.log" ] || fail "$1: merge must not run"
}

test_merges_green_dev_pr() {
  local dir; dir=$(make_case merges)
  run_auto "$dir"
  [ "$RC" -eq 0 ] || fail "merges: exit $RC: $OUT"
  [ "$OUT" = "auto-dev-merge: merged $URL to dev" ] || fail "merges: unexpected outcome: $OUT"
  [ "$(cat "$dir/merge.log")" = "t1 $URL" ] || fail "merges: merge args: $(cat "$dir/merge.log")"
}

test_refuses_main_base() {
  local dir; dir=$(make_case main main)
  run_auto "$dir"; expect_skip main "$dir" "not dev"
}

test_refuses_release_base() {
  local dir; dir=$(make_case release release/1.2)
  run_auto "$dir"; expect_skip release "$dir" "not dev"
}

test_refuses_red_checks() {
  local dir; dir=$(make_case red dev me '[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]')
  run_auto "$dir"; expect_skip red "$dir" "not all green"
}

test_refuses_pending_checks() {
  local dir; dir=$(make_case pending dev me '[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]')
  run_auto "$dir"; expect_skip pending "$dir" "not all green"
}

test_refuses_no_checks() {
  local dir; dir=$(make_case nochecks dev me '[]')
  run_auto "$dir"; expect_skip nochecks "$dir" "not all green"
}

test_refuses_foreign_pr() {
  local dir; dir=$(make_case foreign dev someone-else)
  run_auto "$dir"; expect_skip foreign "$dir" "not opened by me"
}

test_refuses_flagged_pr() {
  local dir; dir=$(make_case flagged dev me "$CHECK_OK" "done [at=1]: PR $URL checks green" "Security")
  run_auto "$dir"; expect_skip flagged "$dir" "label"
}

test_refuses_before_checks_green() {
  local dir; dir=$(make_case validating dev me "$CHECK_OK" "done [at=1]: PR $URL ready for final validation")
  run_auto "$dir"; expect_skip validating "$dir" "checks green"
}

test_refuses_draft() {
  local dir; dir=$(make_case draft)
  jq '.isDraft = true' "$dir/pr.json" > "$dir/pr.tmp" && mv "$dir/pr.tmp" "$dir/pr.json"
  run_auto "$dir"; expect_skip draft "$dir" "draft"
}

test_merge_refusal_is_a_skip() {
  local dir; dir=$(make_case refused)
  : > "$dir/merge-refuses"
  run_auto "$dir"
  [ "$RC" -eq 0 ] || fail "refused: exit $RC"
  case "$OUT" in *"merge refused"*) ;; *) fail "refused: expected merge refusal, got: $OUT" ;; esac
  case "$OUT" in *"merged $URL"*) fail "refused: must not report a merge" ;; esac
}

test_off_switch() {
  local dir; dir=$(make_case off)
  OUT=$(CASE_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_AUTO_DEV_MERGE=off \
    FM_AUTO_DEV_MERGE_MERGE="$dir/merge" "$AUTO" t1 "$URL" 2>&1)
  [ -z "$OUT" ] && [ ! -s "$dir/merge.log" ] || fail "off: expected silence and no merge, got: $OUT"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$t"
done
echo "PASS: fm-auto-dev-merge"
