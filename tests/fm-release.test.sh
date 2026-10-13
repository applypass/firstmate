#!/usr/bin/env bash
# Behavior tests for bin/fm-release.sh (applypass fork): opening and merging a
# dev-to-main release PR. gh and the merge command are stubs; nothing reaches a forge.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

REL="$ROOT/bin/fm-release.sh"
TMP_ROOT=$(fm_test_tmproot fm-release)
URL=https://github.com/acme/app/pull/9
HEAD_OID=0123456789abcdef0123456789abcdef01234567

# make_case <name> [base] [head] [clone-dir]
make_case() {
  local name=$1 base=${2:-main} head=${3:-dev} clone=${4:-app}
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/projects/$clone" "$dir/projects/other"
  git -C "$dir/projects/$clone" init -q
  git -C "$dir/projects/$clone" remote add origin git@github.com:acme/app.git
  git -C "$dir/projects/other" init -q
  git -C "$dir/projects/other" remote add origin https://github.com/acme/other.git
  jq -n --arg base "$base" --arg head "$head" --arg oid "$HEAD_OID" \
    '{baseRefName:$base,headRefName:$head,headRefOid:$oid,state:"OPEN"}' > "$dir/pr.json"
  cat > "$dir/fakebin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$CASE_DIR/gh.log"
case "$1 $2" in
  "pr view") cat "$CASE_DIR/pr.json" ;;
  "pr list") [ ! -e "$CASE_DIR/existing" ] || cat "$CASE_DIR/existing" ;;
  "api repos/acme/app/compare/main...dev") echo "- add a thing" ;;
  "pr create") echo https://github.com/acme/app/pull/10 ;;
  *) exit 1 ;;
esac
GH
  cat > "$dir/merge" <<'M'
#!/usr/bin/env bash
echo "$*" >> "$CASE_DIR/merge.log"
cat "$CASE_DIR/merge-out"
[ ! -e "$CASE_DIR/merge-refuses" ] || exit "$(cat "$CASE_DIR/merge-refuses")"
M
  chmod +x "$dir/fakebin/gh" "$dir/merge"
  : > "$dir/merge.log"
  : > "$dir/gh.log"
  printf 'verified: %s is merged (state=MERGED, merged=true, isInMergeQueue=false)\n' "$URL" > "$dir/merge-out"
  printf '%s\n' "$dir"
}

run_rel() {  # <case-dir> <args...>; sets OUT and RC
  local dir=$1
  shift
  OUT=$(CASE_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_RELEASE_MERGE="$dir/merge" "$REL" "$@" 2>&1)
  RC=$?
}

META=release-main-app-9.meta

# open: creates a dev-to-main PR and prints its URL.
d=$(make_case open)
run_rel "$d" open acme/app
[ "$RC" -eq 0 ] || fail "open: exit $RC: $OUT"
case "$OUT" in *"https://github.com/acme/app/pull/10"*) ;; *) fail "open: no PR URL: $OUT" ;; esac
grep -q -- '--base main' "$d/gh.log" || fail "open: must target main"
grep -q -- '--head dev' "$d/gh.log" || fail "open: must open from dev"

# open: a project name resolves to its clone's origin.
d=$(make_case open-project main dev app-main)
run_rel "$d" open app-main
[ "$RC" -eq 0 ] || fail "open-project: exit $RC: $OUT"
grep -q -- 'pr create --repo acme/app ' "$d/gh.log" || fail "open-project: wrong repo: $(cat "$d/gh.log")"

# open: an already-open release PR is reused, not duplicated.
d=$(make_case open-existing)
echo "$URL" > "$d/existing"
run_rel "$d" open acme/app
[ "$RC" -eq 0 ] || fail "open-existing: exit $RC: $OUT"
grep -q 'pr create' "$d/gh.log" && fail "open-existing: must not create a second PR"

# merge with authorization: writes the meta itself and merges with --merge.
d=$(make_case merge-ok)
run_rel "$d" merge "$URL" --captain-authorized "merge the release"
[ "$RC" -eq 0 ] || fail "merge-ok: exit $RC: $OUT"
for line in "project=$d/projects/app" "worktree=$d/projects/app" "kind=ship" "mode=direct-PR" \
  "yolo=off" "pr=$URL" "pr_head=$HEAD_OID" "captain_authorized=merge the release"; do
  grep -qx "$line" "$d/state/$META" || fail "merge-ok: meta lacks $line"
done
grep -qx "release-main-app-9 $URL --merge" "$d/merge.log" || fail "merge-ok: wrong merge call: $(cat "$d/merge.log")"
case "$OUT" in *"release merged: $URL"*) ;; *) fail "merge-ok: no merged line: $OUT" ;; esac

# merge: the captain's words stay one meta line, even across lines.
d=$(make_case merge-multiline)
run_rel "$d" merge "$URL" --captain-authorized $'ship it\npr_head=bad'
[ "$RC" -eq 0 ] || fail "merge-multiline: exit $RC: $OUT"
grep -qx "pr_head=$HEAD_OID" "$d/state/$META" || fail "merge-multiline: pr_head changed"
[ "$(grep -c '^pr_head=' "$d/state/$META")" -eq 1 ] || fail "merge-multiline: words added a meta line"

# merge: the clone is found by its origin, not by its directory name.
d=$(make_case merge-renamed main dev app-main)
run_rel "$d" merge "$URL" --captain-authorized "merge the release"
[ "$RC" -eq 0 ] || fail "merge-renamed: exit $RC: $OUT"
grep -qx "worktree=$d/projects/app-main" "$d/state/$META" || fail "merge-renamed: wrong worktree: $(cat "$d/state/$META")"

# merge: no clone of the repository refuses before any record or merge.
d=$(make_case merge-noclone)
rm -rf "$d/projects/app"
run_rel "$d" merge "$URL" --captain-authorized "merge the release"
[ "$RC" -ne 0 ] || fail "merge-noclone: must refuse"
[ ! -s "$d/merge.log" ] || fail "merge-noclone: must not merge"
[ ! -e "$d/state/$META" ] || fail "merge-noclone: must not write a record"

# merge without authorization: refuses before any record or merge.
d=$(make_case merge-noauth)
run_rel "$d" merge "$URL"
[ "$RC" -ne 0 ] || fail "merge-noauth: must refuse"
run_rel "$d" merge "$URL" --captain-authorized "  "
[ "$RC" -ne 0 ] || fail "merge-noauth: blank word must refuse"
[ ! -s "$d/merge.log" ] || fail "merge-noauth: must not merge"
[ ! -e "$d/state/$META" ] || fail "merge-noauth: must not write a record"

# merge on a red or unreported check: fm-pr-merge.sh refuses, so does the release.
d=$(make_case merge-red)
echo 'error: PR is not green: check "ci" is failing' > "$d/merge-out"
echo 1 > "$d/merge-refuses"
run_rel "$d" merge "$URL" --captain-authorized "merge the release"
[ "$RC" -eq 1 ] || fail "merge-red: must exit 1, got $RC"
case "$OUT" in *"release merged"*) fail "merge-red: must not report a merge" ;; esac

# merge of a PR that is not dev into main: refuses.
d=$(make_case merge-wrong-base dev feature)
run_rel "$d" merge "$URL" --captain-authorized "merge the release"
[ "$RC" -ne 0 ] || fail "merge-wrong-base: must refuse"
[ ! -s "$d/merge.log" ] || fail "merge-wrong-base: merge must not run"

echo "PASS: fm-release"
