#!/usr/bin/env bash
# Fork-only (applypass): bin/fm-context-replay.py replays a supervisor
# transcript with a context limit. A synthetic main-supervisor session grows
# from 20k to 140k tokens in 7 calls; with a 100k limit the replay hands over
# once, so the after column must show fewer weighted tokens and one handover.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-replay)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
dir="$TMP_ROOT/projects/-Users-x-workspace-firstmate"
mkdir -p "$dir"
n=0
for cr in 20000 40000 60000 80000 100000 120000 140000; do
  n=$((n + 1))
  printf '{"timestamp":"2026-10-26T10:00:0%dZ","requestId":"r%d","message":{"id":"m%d","usage":{"input_tokens":5,"output_tokens":10,"cache_read_input_tokens":%d,"cache_creation_input_tokens":0}}}\n' \
    "$n" "$n" "$n" "$cr" >> "$dir/s.jsonl"
done

out=$(python3 -I "$ROOT/bin/fm-context-replay.py" 2026-10-26 --root "$TMP_ROOT/projects" 2>&1)
row=$(printf '%s\n' "$out" | grep '^main supervisor')
assert_contains "$row" " 7 " "the replay must count the 7 calls"$'\n'"$out"
assert_contains "$row" " 1" "the replay must hand over"$'\n'"$out"
before=$(printf '%s\n' "$row" | awk '{print $(NF-4)}')
after=$(printf '%s\n' "$row" | awk '{print $(NF-3)}')
awk -v b="$before" -v a="$after" 'BEGIN { exit !(a < b) }' || fail "after ($after) must be below before ($before)"$'\n'"$out"
pass "fm-context-replay hands a growing session over once and lowers its weighted tokens"
echo "# all fm-context-replay tests passed"
