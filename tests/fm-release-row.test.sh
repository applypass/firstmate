#!/usr/bin/env bash
# Behavior tests for the dev-merge row guard (applypass fork): `fm-release-gate.sh row`
# and its use in bin/fm-main-merge-guard.sh. gh is a stub; decisions and backlog are fixtures.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

GATE="$ROOT/bin/fm-release-gate.sh"
GUARD="$ROOT/bin/fm-main-merge-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-release-row)
PR7=https://github.com/acme/app/pull/7
LOGNAME_=decided.md

# make_case <name> [base] [config-line]: a stub gh with one PR (7, story sc-100) into <base>
make_case() {
  local d="$TMP_ROOT/$1" base=${2:-dev} cfg=${3-acme/app}
  mkdir -p "$d/fakebin" "$d/data" "$d/config"
  [ -z "$cfg" ] || printf '%s\n' "$cfg" > "$d/config/release-gate"
  : > "$d/data/$LOGNAME_"
  printf '# Backlog\n\n## In flight\n\n## Done\n' > "$d/data/backlog.md"
  jq -n --arg b "$base" '{baseRefName:$b,headRefName:"feature-7",title:"Add a thing sc-100",body:"body text",files:[{path:"src/app.ts"}]}' > "$d/pr-7.json"
  cat > "$d/fakebin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$CASE_DIR/gh.log"
case "$1 $2" in
  "api repos/acme/app/pulls/7") jq -r .baseRefName "$CASE_DIR/pr-7.json" ;;
  "api repos/acme/app/pulls/7/files") jq -r '.files[].path' "$CASE_DIR/pr-7.json" ;;
  "pr view")
    case "$3" in
      http*) jq '{baseRefName,headRefName}' "$CASE_DIR/pr-7.json" ;;
      *) jq 'del(.files)' "$CASE_DIR/pr-7.json" ;;
    esac ;;
  *) exit 1 ;;
esac
GH
  chmod +x "$d/fakebin/gh"
  : > "$d/gh.log"
  printf '%s\n' "$d"
}

decide() {  # <dir> <key> <text>
  printf -- '- [%s] 2026-11-04 %s\n' "$2" "$3" >> "$1/data/$LOGNAME_"
}

run_row() {  # <dir> [url]; sets OUT RC
  OUT=$(env CASE_DIR="$1" PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_DATA_OVERRIDE="$1/data" \
    FM_RELEASE_GATE_CONFIG="$1/config/release-gate" "$GATE" row "${2:-$PR7}" 2>&1)
  RC=$?
}

run_guard() {  # <dir>: the dev-merge guard with the real gate; sets OUT RC
  OUT=$(env CASE_DIR="$1" PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_DATA_OVERRIDE="$1/data" \
    FM_RELEASE_GATE_CONFIG="$1/config/release-gate" "$GUARD" github acme/app 7 false 2>&1)
  RC=$?
}

# no decision row: refused with the missing field and the exact fix command.
d=$(make_case nodec)
run_guard "$d"
[ "$RC" -eq 1 ] || fail "nodec: must refuse, got $RC: $OUT"
case "$OUT" in *"#7"*"no decision recorded"*) ;; *) fail "nodec: reason missing: $OUT" ;; esac
case "$OUT" in *"fix: bin/fm-decide.sh record "*"sc-100"*) ;; *) fail "nodec: fix command missing: $OUT" ;; esac
case "$OUT" in *waive*) fail "nodec: the dev guard must offer no waiver: $OUT" ;; esac

# a recorded current decision lets the dev merge through.
d=$(make_case withdec)
decide "$d" plan-x "approved: the plan (shortcut: sc-100 https://example.test/100)"
run_guard "$d"
[ "$RC" -eq 0 ] || fail "withdec: must pass, got $RC: $OUT"

# a superseded decision is refused as not current.
d=$(make_case stale)
printf -- '- [ ] it - x %s (kind: ship)\n' "$PR7" > "$d/data/backlog.md"
decide "$d" plan-it "approved: the plan (shortcut: sc-100 u)"
decide "$d" later "changed (supersedes: plan-it)"
run_guard "$d"
[ "$RC" -eq 1 ] || fail "stale: must refuse: $OUT"
case "$OUT" in *"NOT CURRENT"*) ;; *) fail "stale: reason missing: $OUT" ;; esac

# a data/API diff with no audit is refused with the audit fix; the audit heading passes.
d=$(make_case noaudit)
decide "$d" plan-x "approved: the plan (shortcut: sc-100 u)"
jq '.files=[{path:"schema.sql"}]' "$d/pr-7.json" > "$d/p.tmp" && mv "$d/p.tmp" "$d/pr-7.json"
run_guard "$d"
[ "$RC" -eq 1 ] || fail "noaudit: must refuse: $OUT"
case "$OUT" in *"without a reader and writer audit"*) ;; *) fail "noaudit: reason missing: $OUT" ;; esac
case "$OUT" in *"fix: add a '## Reader and writer audit' section to the PR body"*) ;; *) fail "noaudit: audit fix missing: $OUT" ;; esac
jq '.body="x\n\n## Reader and writer audit\n- reader: a"' "$d/pr-7.json" > "$d/p.tmp" && mv "$d/p.tmp" "$d/pr-7.json"
run_guard "$d"
[ "$RC" -eq 0 ] || fail "noaudit: audit heading must pass: $OUT"

# no waiver key lets a PR with no row reach dev.
d=$(make_case waiver)
decide "$d" dev-waiver-app-7 "waived: Captain 2026-11-05: ship app#7 as is"
decide "$d" release-waiver-app-7-7 "waived: Captain 2026-11-05: ship app#7 as is"
run_guard "$d"
[ "$RC" -eq 1 ] || fail "waiver: a waiver must not pass the dev guard: $OUT"

# an uncovered repo and a main-based PR are untouched by the dev row guard.
d=$(make_case uncovered dev "acme/other")
run_guard "$d"
[ "$RC" -eq 0 ] || fail "uncovered: must pass: $OUT"
d=$(make_case mainbase main)
run_guard "$d"
case "$OUT" in *"targets main"*) ;; *) fail "mainbase: main guard must still refuse: $OUT" ;; esac
run_row "$d"
[ "$RC" -eq 0 ] || fail "mainbase: row must pass untouched: $OUT"

# with no config file the default scope covers the three repos, including ai_backend.
d=$(make_case default-scope dev "")
for slug in applypass/apply_pass_backend applypass/apply_pass_frontend applypass/ai_backend; do
  run_row "$d" "https://github.com/$slug/pull/7"
  case "$OUT" in *"not covered"*) fail "default-scope: $slug must be covered: $OUT" ;; esac
done

echo "PASS: fm-release-row"
