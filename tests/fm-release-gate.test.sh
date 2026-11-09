#!/usr/bin/env bash
# Behavior tests for bin/fm-release-gate.sh (applypass fork): the release gate.
# gh is a stub; the decision log and the backlog are fixtures in the shared formats.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

GATE="$ROOT/bin/fm-release-gate.sh"
GUARD="$ROOT/bin/fm-main-merge-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-release-gate)
REL=https://github.com/acme/app/pull/50
PR7=https://github.com/acme/app/pull/7
LOGNAME_=decided.md

# make_case <name>: a stubbed gh with one release PR (50) carrying PR 7 (title names sc-100)
make_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/fakebin" "$d/data" "$d/config"
  printf 'acme/app\n' > "$d/config/release-gate"
  : > "$d/data/$LOGNAME_"
  printf '# Backlog\n\n## In flight\n\n## Done\n' > "$d/data/backlog.md"
  jq -n '{baseRefName:"main",headRefName:"dev",body:"Release body\n\nkeep me"}' > "$d/release.json"
  printf 'sha1\n' > "$d/shas"
  printf '7\n' > "$d/pulls-sha1"
  mkpr "$d" 7 "Add a thing sc-100" "body text" '[{"path":"src/app.ts"}]'
  cat > "$d/fakebin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$CASE_DIR/gh.log"
case "$1 $2" in
  "api repos/"*/compare/main...dev) [ ! -e "$CASE_DIR/compare-fails" ] || exit 1; cat "$CASE_DIR/shas" ;;
  "api repos/"*/commits/*/pulls) cat "$CASE_DIR/pulls-$(basename "$(dirname "$2")")" ;;
  "api repos/"*/commits/*) cat "$CASE_DIR/files-$(basename "$2")" ;;
  "api repos/"*/pulls/*) jq -r '.files[].path' "$CASE_DIR/pr-$(basename "$(dirname "$2")").json" ;;
  "pr view")
    case "$3" in
      http*)
        [ ! -e "$CASE_DIR/release-unreadable" ] || exit 1
        if [ "$5" = body ]; then jq -r .body "$CASE_DIR/release.json"; else cat "$CASE_DIR/release.json"; fi ;;
      *) jq 'del(.files)' "$CASE_DIR/pr-$3.json" ;;
    esac ;;
  "pr edit") cp "$5" "$CASE_DIR/edited.md" ;;
  *) exit 1 ;;
esac
GH
  chmod +x "$d/fakebin/gh"
  : > "$d/gh.log"
  printf '%s\n' "$d"
}

mkpr() {  # <dir> <n> <title> <body> <files-json>
  jq -n --arg t "$3" --arg b "$4" --argjson f "$5" --arg br "feature-$2" \
    '{title:$t,body:$b,headRefName:$br,files:$f}' > "$1/pr-$2.json"
}

decide() {  # <dir> <key> <text>
  printf -- '- [%s] 2026-11-04 %s\n' "$2" "$3" >> "$1/data/$LOGNAME_"
}

run_gate() {  # <dir> <sub> [url]; sets OUT RC
  local d=$1 sub=$2 url=${3:-$REL}
  OUT=$(CASE_DIR="$d" PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_DATA_OVERRIDE="$d/data" \
    FM_STATE_OVERRIDE="$d/state" FM_RELEASE_GATE_CONFIG="$d/config/release-gate" "$GATE" "$sub" "$url" 2>&1)
  RC=$?
}

# passing row: decision stamped on the PR's story, no data change.
d=$(make_case pass)
decide "$d" plan-x "approved: the plan (shortcut: sc-100 https://example.test/100)"
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "pass: exit $RC: $OUT"
run_gate "$d" table
case "$OUT" in *"[#7]($PR7)"*"sc-100"*"plan-x"*"| yes |"*) ;; *) fail "pass: table row wrong: $OUT" ;; esac

# decision column: no decision -> fail naming the PR and the waiver command.
d=$(make_case nodec)
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "nodec: must exit 1, got $RC: $OUT"
case "$OUT" in *"#7"*"no decision recorded"*) ;; *) fail "nodec: reason missing: $OUT" ;; esac
case "$OUT" in *"bin/fm-decide.sh record release-waiver-app-50-7"*) ;; *) fail "nodec: waiver command missing: $OUT" ;; esac

# decision found through the PR's backlog item (plan-<item> and <item>-*), not the story.
d=$(make_case viaitem)
mkpr "$d" 7 "No story here" "no story" '[]'
printf -- '- [ ] my-item - Do it %s (repo: app) (kind: ship)\n' "$PR7" > "$d/data/backlog.md"
decide "$d" plan-my-item "approved: yes"
decide "$d" my-item-1 "answer given"
run_gate "$d" table
case "$OUT" in *"plan-my-item my-item-1"*) ;; *) fail "viaitem: decisions not listed: $OUT" ;; esac

# current column: a later supersedes suffix naming the decision fails the row.
d=$(make_case stale)
printf -- '- [ ] it - x %s (kind: ship)\n' "$PR7" > "$d/data/backlog.md"
decide "$d" plan-it "approved: pills (shortcut: sc-100 u)"
decide "$d" dropdown-again "single pick (supersedes: plan-it) (shortcut: sc-9 u)"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "stale: must exit 1: $OUT"
case "$OUT" in *"NOT CURRENT: superseded by dropdown-again"*) ;; *) fail "stale: reason missing: $OUT" ;; esac

# an earlier supersedes entry does not count (the decision is newer).
d=$(make_case newer)
printf -- '- [ ] it - x %s (kind: ship)\n' "$PR7" > "$d/data/backlog.md"
decide "$d" early "old (supersedes: plan-it)"
decide "$d" plan-it "approved: new"
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "newer: an earlier supersede must not fail: $OUT"

# supersede by story ref and by repo#PR ref.
for ref in sc-100 app#7; do
  d=$(make_case "story-${ref//#/-}")
  decide "$d" plan-a "approved: a (shortcut: sc-100 u)"
  decide "$d" later "b (supersedes: $ref)"
  run_gate "$d" check
  [ "$RC" -eq 1 ] || fail "supersede $ref: must exit 1: $OUT"
done

# sc-9018 replay, no re-check item: a reversal stamped on the PR's own story is not
# the PR's decision; it supersedes the multi-select decision, so the row is not current.
d=$(make_case sc9018)
mkpr "$d" 7 "Multi-select alt languages sc-8740 sc-9018" "body" '[]'
decide "$d" plan-jsp-multi-alt-langs "approved: multi-select (shortcut: sc-8740 u)"
decide "$d" secondary-language-dropdown-again \
  "single dropdown (shortcut: sc-8740 u) (supersedes: plan-jsp-multi-alt-langs, sc-8740, apply_pass_frontend#443)"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "sc9018: must exit 1: $OUT"
case "$OUT" in *"NOT CURRENT: superseded by secondary-language-dropdown-again"*) ;; *) fail "sc9018: reason missing: $OUT" ;; esac
run_gate "$d" table
case "$OUT" in *"| plan-jsp-multi-alt-langs |"*) ;; *) fail "sc9018: only the old decision must be listed: $OUT" ;; esac

# sc-9018 replay with a <repo>#<N> ref: the reversal names the PR, not the story.
d=$(make_case sc9018-repo)
mkpr "$d" 823 "Multi-select alt languages sc-8740" "body" '[]'
printf '823\n' > "$d/pulls-sha1"
decide "$d" plan-jsp-multi-alt-langs "approved: multi-select (shortcut: sc-8740 u)"
decide "$d" secondary-language-dropdown-again "single dropdown (shortcut: sc-8740 u) (supersedes: APP#823)"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "sc9018-repo: must exit 1: $OUT"
case "$OUT" in *"NOT CURRENT: superseded by secondary-language-dropdown-again"*) ;; *) fail "sc9018-repo: reason missing: $OUT" ;; esac

# re-check items: open fails; all done passes a superseded PR.
d=$(make_case recheck)
decide "$d" plan-a "approved: a (shortcut: sc-100 u)"
decide "$d" later "b (supersedes: plan-a)"
{
  printf -- '- [ ] recheck-later-app-7 - recheck (kind: recheck)\n  pr=%s\n  old=plan-a\n  new=later\n' "$PR7"
  printf '\n## Done\n'
} > "$d/data/backlog.md"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "recheck open: must exit 1: $OUT"
case "$OUT" in *"open re-check recheck-later-app-7"*) ;; *) fail "recheck open: item not named: $OUT" ;; esac
sed -i.bak 's/^- \[ \] recheck/- [x] recheck/' "$d/data/backlog.md"
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "recheck done: must pass: $OUT"

# data/API column: a schema change without an audit fails; each audit form passes.
d=$(make_case data)
mkpr "$d" 7 "Add col sc-100" "body" '[{"path":"schema.sql"}]'
decide "$d" plan-a "approved (shortcut: sc-100 u)"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "data: must exit 1: $OUT"
case "$OUT" in *"reader and writer audit"*) ;; *) fail "data: reason missing: $OUT" ;; esac
mkpr "$d" 7 "Add col sc-100" $'body\n\n## Reader and writer audit\n- reader x' '[{"path":"scripts/a.sql"}]'
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "data: body audit must pass: $OUT"
mkpr "$d" 7 "Add col sc-100" "body" '[{"path":"migrations/001/up.sql"}]'
printf -- '- [ ] it - x %s (kind: ship)\n' "$PR7" > "$d/data/backlog.md"
decide "$d" plan-it "approved"
mkdir -p "$d/data/it"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "data: no audit file yet: $OUT"
echo audit > "$d/data/it/reader-writer-audit.md"
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "data: audit file must pass: $OUT"
# a glob stays a pattern even when the current directory holds a file it matches.
mkpr "$d" 7 "Add col sc-100" "body" '[{"path":"scripts/b.sql"}]'
mkdir -p "$d/cwd/scripts"
: > "$d/cwd/scripts/a.sql"
rm "$d/data/it/reader-writer-audit.md"
OUT=$(cd "$d/cwd" && CASE_DIR="$d" PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_DATA_OVERRIDE="$d/data" \
  FM_RELEASE_GATE_CONFIG="$d/config/release-gate" "$GATE" check "$REL" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 1 ] || fail "cwd glob: scripts/b.sql must count as a data change: $OUT"
case "$OUT" in *"data/API change (scripts/b.sql)"*) ;; *) fail "cwd glob: reason missing: $OUT" ;; esac
echo audit > "$d/data/it/reader-writer-audit.md"
# config globs per repo override the default.
printf 'acme/app custom/*.x\n' > "$d/config/release-gate"
mkpr "$d" 7 "Add col sc-100" "body" '[{"path":"schema.sql"}]'
rm "$d/data/it/reader-writer-audit.md"
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "globs: schema.sql is not in the custom list: $OUT"

# a PR url names only that PR: PR 7 does not take PR 70's backlog item or re-check items.
d=$(make_case prefix)
printf '7\n70\n' > "$d/pulls-sha1"
mkpr "$d" 7 "No story" "none" '[]'
mkpr "$d" 70 "Other" "none" '[]'
printf -- '- [ ] other - x https://github.com/acme/app/pull/70 (kind: ship)\n' > "$d/data/backlog.md"
decide "$d" plan-other "approved"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "prefix: PR 7 must not borrow PR 70's decision: $OUT"
case "$OUT" in *"#7  none - no decision recorded"*) ;; *) fail "prefix: #7 reason missing: $OUT" ;; esac
case "$OUT" in *"#70 "*) fail "prefix: #70 must pass: $OUT" ;; esac
mkpr "$d" 7 "Thing sc-100" "none" '[]'
decide "$d" plan-a "approved (shortcut: sc-100 u)"
decide "$d" later "b (supersedes: plan-a)"
printf -- '- [x] recheck-later-app-70 - recheck (kind: recheck)\n  pr=https://github.com/acme/app/pull/70\n' >> "$d/data/backlog.md"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "prefix: PR 70's done re-check must not make PR 7 current: $OUT"
case "$OUT" in *"#7 sc-100"*"NOT CURRENT: superseded by later"*) ;; *) fail "prefix: #7 must be superseded: $OUT" ;; esac

# an unreadable forge fails the gate: the compare, a commit's PRs, or the release PR.
d=$(make_case forge)
decide "$d" plan-a "approved (shortcut: sc-100 u)"
: > "$d/compare-fails"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "forge: a failed compare must refuse: $OUT"
rm "$d/compare-fails"
printf 'sha1\nsha2\n' > "$d/shas"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "forge: a failed commit read must refuse: $OUT"
printf 'sha1\n' > "$d/shas"
: > "$d/release-unreadable"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "forge: an unreadable release PR must refuse: $OUT"
rm "$d/release-unreadable"
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "forge: readable again must pass: $OUT"

# a carried commit with no PR: a note row, unless it touches a data/API glob; a named waiver passes it.
d=$(make_case lone)
decide "$d" plan-a "approved (shortcut: sc-100 u)"
printf 'sha1\nabcdef1234567\n' > "$d/shas"
: > "$d/pulls-abcdef1234567"
printf 'src/x.ts\n' > "$d/files-abcdef1234567"
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "lone: a plain commit must pass: $OUT"
run_gate "$d" table
case "$OUT" in *"| commit abcdef1: no PR | | | | no | | note |"*) ;; *) fail "lone: note row missing: $OUT" ;; esac
printf 'src/x.ts\nmigrations/9/up.sql\n' > "$d/files-abcdef1234567"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "lone: a data-touching commit must fail: $OUT"
case "$OUT" in *"commit abcdef1: no PR - data/API change (migrations/9/up.sql)"*"record release-waiver-app-50-abcdef1"*) ;; *) fail "lone: reason or waiver missing: $OUT" ;; esac
decide "$d" release-waiver-app-50-abcdef1 "waived: Captain 2026-11-04: ship as is"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "lone: a waiver not naming the sha must not pass: $OUT"
decide "$d" release-waiver-app-50-abcdef1 "waived: Captain 2026-11-04: ship commit abcdef1"
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "lone: a waiver naming the sha must pass: $OUT"
run_gate "$d" table
case "$OUT" in *"| commit abcdef1: no PR | | | | yes (migrations/9/up.sql) | | waived |"*) ;; *) fail "lone: waived row missing: $OUT" ;; esac

# every failing row is listed, not just the first.
d=$(make_case many)
printf '7\n8\n' > "$d/pulls-sha1"
mkpr "$d" 8 "Other sc-200" "b" '[]'
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "many: must exit 1"
case "$OUT" in *"#7 "*"#8 "*) ;; *) fail "many: both rows must be listed: $OUT" ;; esac

# waiver: names that PR; another PR's waiver or non-waived text does not pass it.
d=$(make_case waiver)
decide "$d" release-waiver-app-50-8 "waived: Captain: PR 8"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "waiver: other PR's waiver must not pass: $OUT"
decide "$d" release-waiver-app-50-7 "ship as is"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "waiver: text must start with waived:: $OUT"
decide "$d" release-waiver-app-50-7 "waived: Captain 2026-11-04: ship as is"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "waiver: a general ship-as-is must not pass: $OUT"
decide "$d" release-waiver-app-50-7 "waived: Captain 2026-11-04: ship PR 70 and #71"
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "waiver: naming another PR must not pass: $OUT"
for words in "ship PR 7" "ship app#7 as is" "ok #7." "ship $PR7"; do
  d=$(make_case "waiver-${words//[^a-z0-9]/-}")
  decide "$d" release-waiver-app-50-7 "waived: Captain 2026-11-04: $words"
  run_gate "$d" check
  [ "$RC" -eq 0 ] || fail "waiver: '$words' must pass: $OUT"
done

# repo not listed: passes with a note and reads nothing.
d=$(make_case uncovered)
printf 'acme/other\n' > "$d/config/release-gate"
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "uncovered: must pass: $OUT"
case "$OUT" in *"not covered"*) ;; *) fail "uncovered: note missing: $OUT" ;; esac
[ ! -s "$d/gh.log" ] || fail "uncovered: must not call gh"

# a non-dev head into main is a single-PR release: that PR is its only row.
d=$(make_case hotfix)
jq -n '{baseRefName:"main",headRefName:"hotfix/sc-300",body:""}' > "$d/release.json"
mkpr "$d" 50 "Hotfix sc-300" "body" '[{"path":"schema.sql"}]'
run_gate "$d" check
[ "$RC" -eq 1 ] || fail "hotfix: must be gated: $OUT"
case "$OUT" in *"#50 sc-300 none - no decision recorded; data/API change (schema.sql)"*) ;; *) fail "hotfix: row wrong: $OUT" ;; esac
case "$OUT" in *"#7 "*) fail "hotfix: must not carry dev's PRs: $OUT" ;; esac
grep -q compare "$d/gh.log" && fail "hotfix: must not compare main...dev"
decide "$d" plan-h "approved (shortcut: sc-300 u)"
mkpr "$d" 50 "Hotfix sc-300" $'body\n\n## Reader and writer audit\n- r' '[{"path":"schema.sql"}]'
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "hotfix: a decided, audited hotfix must pass: $OUT"

# a base other than main: passes with a note.
d=$(make_case notmain)
jq -n '{baseRefName:"dev",headRefName:"feature",body:""}' > "$d/release.json"
run_gate "$d" check
[ "$RC" -eq 0 ] || fail "notmain: must pass: $OUT"
case "$OUT" in *"not main"*) ;; *) fail "notmain: note missing: $OUT" ;; esac

# refresh: rewrites only the marked block; a second run keeps one block and the rest intact.
d=$(make_case refresh)
decide "$d" plan-a "approved (shortcut: sc-100 u)"
run_gate "$d" refresh
[ "$RC" -eq 0 ] || fail "refresh: exit $RC: $OUT"
grep -q 'Release body' "$d/edited.md" || fail "refresh: body lost"
grep -q 'keep me' "$d/edited.md" || fail "refresh: body lost"
grep -q 'fm-release-gate:start' "$d/edited.md" || fail "refresh: no block"
grep -q 'plan-a' "$d/edited.md" || fail "refresh: table missing"
jq -n --rawfile b "$d/edited.md" '{baseRefName:"main",headRefName:"dev",body:$b}' > "$d/release.json"
decide "$d" plan-b "approved (shortcut: sc-100 u)"
run_gate "$d" refresh
[ "$(grep -c 'fm-release-gate:start' "$d/edited.md")" -eq 1 ] || fail "refresh: block duplicated"
grep -q 'plan-b' "$d/edited.md" || fail "refresh: block not updated"
grep -q 'keep me' "$d/edited.md" || fail "refresh: text outside the block changed"
jq -n --rawfile b "$d/edited.md" '{baseRefName:"main",headRefName:"dev",body:($b + "\nafter block\n")}' > "$d/release.json"
run_gate "$d" refresh
grep -q 'after block' "$d/edited.md" || fail "refresh: text after the block lost"

# main-merge guard runs the check when the base is main and refuses on a failing check.
d=$(make_case guard)
cat > "$d/check" <<'C'
#!/usr/bin/env bash
echo "$*" >> "$CASE_DIR/check.log"
exit "$(cat "$CASE_DIR/check-rc")"
C
chmod +x "$d/check"
printf '#!/usr/bin/env bash\necho main\n' > "$d/fakebin/gh"
: > "$d/check.log"
echo 0 > "$d/check-rc"
run_guard() {  # <number> <release-main>
  OUT=$(CASE_DIR="$d" PATH="$d/fakebin:$PATH" FM_RELEASE_GATE_CMD="$d/check" "$GUARD" github acme/app "$1" "$2" 2>&1)
  RC=$?
}
run_guard 50 true
[ "$RC" -eq 0 ] || fail "guard: passing check must allow: $OUT"
grep -qx "check $REL" "$d/check.log" || fail "guard: check not called with the PR url: $(cat "$d/check.log")"
echo 1 > "$d/check-rc"
run_guard 50 true
[ "$RC" -eq 1 ] || fail "guard: failing check must refuse: $OUT"
run_guard 50 false
[ "$RC" -eq 1 ] || fail "guard: no --release-main must still refuse"
: > "$d/check.log"
printf '#!/usr/bin/env bash\necho develop\n' > "$d/fakebin/gh"
run_guard 51 true
[ "$RC" -eq 0 ] || fail "guard: non-main base must pass: $OUT"
[ ! -s "$d/check.log" ] || fail "guard: check must not run for a non-main base"

# release open/refresh: a failing carried PR appends a needs-decision status line naming it and
# its fix command; a clean release appends nothing; an unchanged failure is not repeated.
d=$(make_case status-fail)
SF="$d/state/release-main-app-50.status"
run_gate "$d" refresh
[ "$RC" -eq 0 ] || fail "status-fail: refresh must still succeed: $OUT"
[ -f "$SF" ] || fail "status-fail: no status file"
[ "$(wc -l < "$SF" | tr -d ' ')" -eq 1 ] || fail "status-fail: want one line: $(cat "$SF")"
grep -Eq '^needs-decision \[at=[0-9]+\] \[key=release-gate-app-50\]: ' "$SF" || fail "status-fail: wrong shape: $(cat "$SF")"
grep -q "$REL" "$SF" || fail "status-fail: release url missing: $(cat "$SF")"
grep -q '#7' "$SF" || fail "status-fail: failing PR not named: $(cat "$SF")"
grep -q 'fix: bin/fm-decide.sh record' "$SF" || fail "status-fail: fix command missing: $(cat "$SF")"
run_gate "$d" refresh
[ "$(wc -l < "$SF" | tr -d ' ')" -eq 1 ] || fail "status-fail: an unchanged failure repeated the line: $(cat "$SF")"
d=$(make_case status-clean)
decide "$d" plan-x "approved: the plan (shortcut: sc-100 u)"
run_gate "$d" refresh
[ ! -e "$d/state/release-main-app-50.status" ] || fail "status-clean: a clean release must emit nothing"

# with no config file, an ai_backend release with a failing row raises at open.
d=$(make_case status-ai-default)
rm "$d/config/release-gate"
run_gate "$d" refresh https://github.com/applypass/ai_backend/pull/50
[ "$RC" -eq 0 ] || fail "status-ai-default: refresh must succeed: $OUT"
grep -q '#7' "$d/state/release-main-ai_backend-50.status" 2>/dev/null \
  || fail "status-ai-default: failing row not raised: $OUT"

# ship brief carries the audit heading rule; the scout brief does not.
bh="$TMP_ROOT/brief-home"
mkdir -p "$bh/data"
FM_HOME="$bh" "$ROOT/bin/fm-brief.sh" rg-ship1 firstmate --mode local-only >/dev/null 2>&1 || fail "brief: ship scaffold failed"
grep -q '## Reader and writer audit' "$bh/data/rg-ship1/brief.md" || fail "brief: ship brief lacks the audit rule"
FM_HOME="$bh" "$ROOT/bin/fm-brief.sh" rg-scout1 firstmate --scout >/dev/null 2>&1 || fail "brief: scout scaffold failed"
grep -q 'Reader and writer audit' "$bh/data/rg-scout1/brief.md" && fail "brief: scout brief must not carry the audit rule"

echo "PASS: fm-release-gate"
