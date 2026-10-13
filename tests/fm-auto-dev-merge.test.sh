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
READY="done [at=1]: PR $URL checks green"

# make_case <name> [base] [author] [status-line] [extra-label]
make_case() {
  local name=$1 base=${2:-dev} author=${3:-me}
  local status=${4:-$READY} label=${5:-bug}
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fakebin"
  fm_write_meta "$dir/state/t1.meta" "kind=ship" "mode=no-mistakes"
  printf '%s\n' "working [at=0]: go" "$status" > "$dir/state/t1.status"
  jq -n --arg base "$base" --arg author "$author" --arg label "$label" \
    '{baseRefName:$base,author:{login:$author},labels:[{name:$label}]}' > "$dir/pr.json"
  cat > "$dir/fakebin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") cat "$CASE_DIR/pr.json" ;;
  "api user") echo me ;;
  *) exit 1 ;;
esac
GH
  # The merge stub prints merge-out (default: a landed merge) and exits 1 when
  # merge-refuses exists.
  cat > "$dir/merge" <<'M'
#!/usr/bin/env bash
echo "$*" >> "$CASE_DIR/merge.log"
cat "$CASE_DIR/merge-out"
[ ! -e "$CASE_DIR/merge-refuses" ] || exit 1
M
  chmod +x "$dir/fakebin/gh" "$dir/merge"
  : > "$dir/merge.log"
  printf 'verified: %s is merged (state=MERGED, merged=true, isInMergeQueue=false)\n' "$URL" > "$dir/merge-out"
  printf '%s\n' "$dir"
}

run_auto() {  # <case-dir>; sets OUT and RC
  local dir=$1
  OUT=$(CASE_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" \
    FM_AUTO_DEV_MERGE_MERGE="$dir/merge" "$AUTO" t1 "$URL" 2>&1)
  RC=$?
}

last_status() { tail -1 "$1/state/t1.status"; }

expect_quiet_skip() {  # <name> <case-dir> <reason-fragment>
  [ "$RC" -eq 0 ] || fail "$1: skip must exit 0, got $RC"
  case "$OUT" in *"skipped"*"$3"*) ;; *) fail "$1: expected skip mentioning '$3', got: $OUT" ;; esac
  [ ! -s "$2/merge.log" ] || fail "$1: merge must not run"
  case "$(last_status "$2")" in paused*) fail "$1: a quiet skip must not append a status line" ;; esac
}

expect_paused() {  # <name> <case-dir> <reason-fragment>...
  local name=$1 dir=$2 line; shift 2
  [ "$RC" -eq 0 ] || fail "$name: skip must exit 0, got $RC"
  line=$(last_status "$dir")
  case "$line" in
    "paused [at="[0-9]*"]: auto-dev-merge skipped $URL: "*"; merge it with bin/fm-pr-merge.sh once green") ;;
    *) fail "$name: expected a paused status line, got: $line" ;;
  esac
  for frag in "$@"; do
    case "$line" in *"$frag"*) ;; *) fail "$name: status line lacks '$frag': $line" ;; esac
    case "$OUT" in *"skipped"*"$frag"*) ;; *) fail "$name: stderr lacks '$frag': $OUT" ;; esac
  done
  case "$OUT" in *"merged $URL"*) fail "$name: must not report a merge" ;; esac
}

test_merges_green_dev_pr() {
  local dir; dir=$(make_case merges)
  run_auto "$dir"
  [ "$RC" -eq 0 ] || fail "merges: exit $RC: $OUT"
  case "$OUT" in *"verified: $URL is merged"*) ;; *) fail "merges: merge output not passed through: $OUT" ;; esac
  [ "$(printf '%s\n' "$OUT" | tail -1)" = "auto-dev-merge: merged $URL to dev" ] || fail "merges: unexpected outcome: $OUT"
  [ "$(cat "$dir/merge.log")" = "t1 $URL" ] || fail "merges: merge args: $(cat "$dir/merge.log")"
  [ "$(last_status "$dir")" = "$READY" ] || fail "merges: status must be untouched"
}

test_queued_is_not_merged() {
  local dir; dir=$(make_case queued)
  printf 'verified: %s is queued (state=OPEN, merged=false, isInMergeQueue=true)\n' "$URL" > "$dir/merge-out"
  run_auto "$dir"
  [ "$RC" -eq 0 ] || fail "queued: exit $RC: $OUT"
  case "$OUT" in *"is queued"*) ;; *) fail "queued: merge output not passed through: $OUT" ;; esac
  case "$OUT" in *"merged $URL to dev"*) fail "queued: must not report a merge: $OUT" ;; esac
  case "$OUT" in *"has not landed"*) ;; *) fail "queued: expected a not-landed line: $OUT" ;; esac
}

test_actionable_line_kept() {
  local dir; dir=$(make_case actionable)
  printf '%s\n' "verified: $URL is merged (state=MERGED, merged=true, isInMergeQueue=false)" \
    "actionable: merged $URL but could not record the outcome for supervision" > "$dir/merge-out"
  run_auto "$dir"
  case "$OUT" in *"actionable: merged $URL"*) ;; *) fail "actionable: line lost: $OUT" ;; esac
  case "$OUT" in *"auto-dev-merge: merged $URL to dev"*) ;; *) fail "actionable: expected merged: $OUT" ;; esac
}

test_pauses_main_base() {
  local dir; dir=$(make_case main main)
  run_auto "$dir"; expect_paused main "$dir" "base is main, not dev"
  [ ! -s "$dir/merge.log" ] || fail "main: merge must not run"
}

test_pauses_release_base() {
  local dir; dir=$(make_case release release/1.2)
  run_auto "$dir"; expect_paused release "$dir" "base is release/1.2, not dev"
}

test_merge_refusal_pauses_with_every_reason() {
  local dir; dir=$(make_case refused)
  printf '%s\n' "error: refusing to merge $URL" "  - check 'preview' is not green" \
    "  - mergeable is \"UNKNOWN\", not MERGEABLE" "error: these checks are not green: preview" > "$dir/merge-out"
  : > "$dir/merge-refuses"
  run_auto "$dir"
  expect_paused refused "$dir" "merge refused: error: refusing to merge $URL" \
    "- check 'preview' is not green" "not MERGEABLE" "these checks are not green: preview" \
    "gates on every check, required or not"
}

test_quiet_skip_foreign_pr() {
  local dir; dir=$(make_case foreign main someone-else)
  run_auto "$dir"; expect_quiet_skip foreign "$dir" "not opened by me"
}

test_quiet_skip_flagged_pr() {
  local dir; dir=$(make_case flagged dev me "$READY" "Security")
  run_auto "$dir"; expect_quiet_skip flagged "$dir" "label"
}

test_quiet_skip_before_checks_green() {
  local dir; dir=$(make_case validating dev me "done [at=1]: PR $URL ready for final validation")
  run_auto "$dir"; expect_quiet_skip validating "$dir" "checks green"
}

test_quiet_skip_not_a_ship() {
  local dir; dir=$(make_case scout)
  fm_write_meta "$dir/state/t1.meta" "kind=scout" "mode=no-mistakes"
  run_auto "$dir"; expect_quiet_skip scout "$dir" "not a ship"
}

test_off_switch() {
  local dir; dir=$(make_case off)
  OUT=$(CASE_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_AUTO_DEV_MERGE=off \
    FM_AUTO_DEV_MERGE_MERGE="$dir/merge" "$AUTO" t1 "$URL" 2>&1)
  [ -z "$OUT" ] && [ ! -s "$dir/merge.log" ] || fail "off: expected silence and no merge, got: $OUT"
  [ "$(last_status "$dir")" = "$READY" ] || fail "off: status must be untouched"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$t"
done
echo "PASS: fm-auto-dev-merge"
