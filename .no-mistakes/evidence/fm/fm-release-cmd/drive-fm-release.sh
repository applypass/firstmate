#!/usr/bin/env bash
# Drives the real bin/fm-release.sh -> real bin/fm-pr-merge.sh -> real
# bin/fm-pr-check.sh chain in a disposable lab FM_HOME. Only the forge CLI (gh,
# gh-axi) is a local stand-in for GitHub; nothing reaches a real forge.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
cp "$WT/.tasks.toml" "$LAB/.tasks.toml" 2>/dev/null || true
mkdir -p "$LAB/data" "$LAB/fakebin"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
# Real clone with dev and main; directory name differs from repo name, origin is mixed case.
C="$LAB/projects/acme-app-checkout"
git init -q -b main "$C"; git -C "$C" -c user.name=t -c user.email=t@e commit -q --allow-empty -m init
git -C "$C" update-ref refs/remotes/origin/main HEAD
git -C "$C" checkout -q -b dev; git -C "$C" -c user.name=t -c user.email=t@e commit -q --allow-empty -m "add a thing"
git -C "$C" update-ref refs/remotes/origin/dev HEAD
git -C "$C" remote add origin git@github.com:Acme/App.git
HEAD_OID=$(git -C "$C" rev-parse HEAD)
echo "$HEAD_OID" > "$LAB/head"
echo '[]' > "$LAB/checks"   # rollup
echo '{"name":"main","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}' > "$LAB/branch.json"
cat > "$LAB/fakebin/gh" <<'GH'
#!/usr/bin/env bash
L=$FM_LAB_FORGE
printf '%s\n' "$*" >> "$L/gh.log"
head=$(cat "$L/head")
case "$1 $2" in
  "pr list") [ -e "$L/existing" ] && cat "$L/existing"; exit 0 ;;
  "pr create") echo https://github.com/acme/app/pull/10; exit 0 ;;
  "pr view")
    case "$*" in
      *statusCheckRollup*) jq -nc --arg h "$head" --argjson r "$(cat "$L/checks")" \
        '{state:"OPEN",isDraft:false,mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",headRefOid:$h,baseRefName:"main",statusCheckRollup:$r}' ;;
      *"-q .headRefOid"*) echo "$head" ;;
      *baseRefName,headRefName*) jq -nc --arg h "$head" --arg b "$(cat "$L/base" 2>/dev/null || echo main)" \
        '{baseRefName:$b,headRefName:"dev",headRefOid:$h,state:"OPEN"}' ;;
      *isDraft*) echo '{"isDraft":false}' ;;
      *) echo "{}" ;;
    esac; exit 0 ;;
  "pr merge") [ -e "$L/merged" ] || : > "$L/merged"; echo "merged"; exit 0 ;;
  "api graphql") if [ -e "$L/merged" ]; then printf 'state=MERGED\nmerged=true\nqueued=false\nbase=main\n'; else printf 'state=OPEN\nmerged=false\nqueued=false\nbase=main\n'; fi; exit 0 ;;
esac
case "$*" in
  *compare/main...dev*) echo "- add a thing"; exit 0 ;;
  *check-runs*) echo '{"total_count":0,"check_runs":[]}'; exit 0 ;;
  *rules/branches*) echo '[]'; exit 0 ;;
  *"/branches/"*) cat "$L/branch.json"; exit 0 ;;
  *merge_queue*|*repos/*) echo '{}'; exit 0 ;;
esac
exit 0
GH
cat > "$LAB/fakebin/gh-axi" <<'GH'
#!/usr/bin/env bash
exit 1
GH
chmod +x "$LAB/fakebin/gh" "$LAB/fakebin/gh-axi"
REL() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
  FM_LAB_FORGE="$LAB" FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" "$WT/bin/fm-release.sh" "$@"; }
step() { echo; echo "=== $* ==="; }
URL=https://github.com/acme/app/pull/9
META="$LAB/state/release-main-app-9.meta"

step "1. open by project name (dir name != repo name)"
REL open acme-app-checkout; echo "exit=$?"; grep 'pr create' "$LAB/gh.log"
step "2. open when a release PR is already open"
echo https://github.com/acme/app/pull/10 > "$LAB/existing"; : > "$LAB/gh.log"
REL open acme/app; echo "exit=$?"; grep -c 'pr create' "$LAB/gh.log" | sed 's/^/pr create calls: /'
step "3. merge without captain's word"
REL merge $URL; echo "exit=$?"; ls "$LAB/state" | grep -c release- | sed 's/^/release metas: /'
step "4. merge with blank captain's word"
REL merge $URL --captain-authorized "   "; echo "exit=$?"
step "5. merge of a non dev-to-main PR"
echo develop > "$LAB/base"; REL merge $URL --captain-authorized "go"; echo "exit=$?"; rm "$LAB/base"
step "6. merge with a red check (real fm-pr-merge.sh guard)"
echo '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]' > "$LAB/checks"; : > "$LAB/gh.log"
REL merge $URL --captain-authorized "merge the release"; echo "exit=$?"; grep -c '^pr merge' "$LAB/gh.log" | sed 's/^/gh pr merge calls: /'
step "7. merge, green, captain authorized (real fm-pr-merge.sh + fm-pr-check.sh)"
echo '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]' > "$LAB/checks"; : > "$LAB/gh.log"
REL merge $URL --captain-authorized "Captain: merge the release to main"; echo "exit=$?"
echo "--- gh pr merge call:"; grep '^pr merge' "$LAB/gh.log"
echo "--- written meta ($META):"; cat "$META"
echo "--- meta parses as PR identity:"
( . "$WT/bin/fm-pr-lib.sh"; fm_pr_metadata_identity_parse "$META" && echo "url=$FM_PR_META_URL" ) || echo PARSE-FAILED
rm -rf "$LAB"; echo; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
