#!/usr/bin/env bash
# decide-bench.sh: real fm-decide (base vs target) in a lab home; Shortcut is a
# local fake curl that answers after DELAY seconds. Nothing reaches Shortcut.
set -u
B=$(cd "$(dirname "$0")" && pwd)
WT=/Users/uayyagari/.no-mistakes/worktrees/c5d69c01912a/01M6780AK9G5R621HZXY645YGB
. "$WT/tests/secondmate-helpers.sh" >/dev/null 2>&1 || true
DELAY=${DELAY:-3}
TIMEFORMAT='%R'
mk() {  # <tree> -> prints lab dir
  local tree=$1 LAB
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; LAB=$(cd "$LAB" && pwd -P)
  mkdir -p "$LAB/.claude"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
  printf 'owner_id=11111111-2222-4333-8444-555555555555\ntoken_ref=op://v/i/f\n' > "$LAB/config/shortcut-tickets"
  fm_fake_shortcut_curl "$LAB/fakebin"; mv "$LAB/fakebin/curl" "$LAB/fakebin/curl.fake"
  cat > "$LAB/fakebin/curl" <<'SH'
#!/usr/bin/env bash
sleep "${FAKE_CURL_DELAY:-0}"
if [ "${FAKE_CURL_COMMENT_FAIL:-}" = 1 ]; then
  out=; for a in "$@"; do [ "${prev:-}" != -o ] || out=$a
    case "$a" in */comments) printf 'POST %s\n' "$a" >> "$FAKE_CURL_LOG"; cat >/dev/null; printf '{}' > "$out"; printf 500; exit 0 ;; esac; prev=$a; done
fi
exec "$(dirname "$0")/curl.fake" "$@"
SH
  chmod +x "$LAB/fakebin/curl"; fm_fake_exit0 "$LAB/fakebin" tmux treehouse no-mistakes gh gh-axi
  : > "$LAB/curl.log"; printf '%s\n' "$LAB"
}
dec() {  # <tree> <lab> args...
  local tree=$1 LAB=$2; shift 2
  (cd "$B/$tree" && env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_SHORTCUT_TICKETS \
    FM_HOME="$LAB" SHORTCUT_API_TOKEN=tok FAKE_CURL_LOG="$LAB/curl.log" FAKE_CURL_DELAY="${FAKE_CURL_DELAY:-$DELAY}" \
    PATH="$LAB/fakebin:$PATH" "$B/$tree/bin/fm-decide.sh" "$@")
}
waitfor() { local i; for ((i = 0; i < ${3:-150}; i++)); do grep -qF -- "$1" "$2" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
for tree in base target; do
  LAB=$(mk $tree)
  t=$( { time dec $tree "$LAB" record live-1 "Ship option B." --story sc-6523 > "$B/decide-$tree-story.out" 2>&1; } 2>&1 )
  echo "$tree record --story wall=${t}s entry-now: $(grep '^- \[live-1\]' "$LAB/data/decided.md")"
  t=$( { time dec $tree "$LAB" record live-2 "No story yet." > "$B/decide-$tree-chore.out" 2>&1; } 2>&1 )
  echo "$tree record (chore) wall=${t}s entry-now: $(grep '^- \[live-2\]' "$LAB/data/decided.md")"
  if [ $tree = target ]; then
    waitfor '(shortcut: sc-6523 ' "$LAB/data/decided.md" && waitfor '[live-2] 2026' "$LAB/data/decided.md" && waitfor '(shortcut: sc-7777 ' "$LAB/data/decided.md"
    sleep 1
    echo "$tree after background: $(grep -c . "$LAB/data/decided.md") lines"; grep '^- \[' "$LAB/data/decided.md"
    echo "$tree curl calls:"; cat "$LAB/curl.log"
  fi
  cp "$LAB/data/decided.md" "$B/decide-$tree-decided.md"; cp "$LAB/curl.log" "$B/decide-$tree-curl.log"
  rm -rf "$LAB"
done
# target: final failure -> pending + one inbox note to main; then a concurrent sync race
LAB=$(mk target)
FAKE_CURL_COMMENT_FAIL=1 FM_DECIDE_SYNC_ATTEMPTS=2 FM_DECIDE_SYNC_DELAY=1 FAKE_CURL_DELAY=0 dec target "$LAB" record live-3 "Will not post." --story sc-6523 > "$B/decide-fail.out" 2>&1
waitfor 'after 2 tries' "$LAB/data/.decided-sync.log" 100 && echo "fail: job gave up"
echo "fail: entry: $(grep '^- \[live-3\]' "$LAB/data/decided.md")"
echo "fail: inbox notes for main:"; ls "$LAB/state/inbox" 2>/dev/null; cat "$LAB/state/inbox"/* 2>/dev/null | head -5
echo "fail: audit rc: $(dec target "$LAB" audit >/dev/null 2>&1; echo $?)"
: > "$LAB/curl.log"
# race: a slow pending post (job) and an operator sync at the same time
FAKE_CURL_DELAY=3 dec target "$LAB" sync > "$B/decide-race-a.out" 2>&1 &
sleep 0.5
FAKE_CURL_DELAY=3 dec target "$LAB" sync > "$B/decide-race-b.out" 2>&1
wait
echo "race: sync A: $(tr '\n' ' ' < "$B/decide-race-a.out")"; echo "race: sync B: $(tr '\n' ' ' < "$B/decide-race-b.out")"
echo "race: comment POSTs on sc-6523: $(grep -c 'stories/6523/comments' "$LAB/curl.log")"
echo "race: entry: $(grep '^- \[live-3\]' "$LAB/data/decided.md")"
cp "$LAB/data/.decided-sync.log" "$B/decide-sync.log"
rm -rf "$LAB"
