#!/usr/bin/env bash
# drain-bench.sh <mates> <lines> <label>: times the real fm-wake-drain from base
# and target on identical copies of a lab home, three runs each.
set -u
B=$(cd "$(dirname "$0")" && pwd)
WT=/Users/uayyagari/.no-mistakes/worktrees/c5d69c01912a/01M6780AK9G5R621HZXY645YGB
M=$1 N=$2 LABEL=$3
make_log() {
  awk -v n="$2" -v s="$3" 'BEGIN {
    t = 1790000000 + s
    printf "needs-decision [key=open-%d] [at=%d]: still waiting on the captain\n", s, t
    for (i = 1; i <= n; i++) {
      t++
      if (i % 5 == 1) printf "needs-decision [key=k%d] [at=%d]: option %d or %d for item %d\n", i, t, i, i + 1, i
      else if (i % 5 == 2) printf "resolved [key=k%d] [at=%d]: answered: take the first\n", i - 1, t
      else if (i % 50 == 3) printf "blocked [key=b%d] [at=%d]: waiting on an external check\n", i, t
      else if (i % 97 == 4) printf "note [at=%d]: heads-up %d for the captain\n", t, i
      else printf "working [at=%d]: progress line %d with a few more words in it\n", t, i
    }
  }' > "$1"
}
now_ms() { local t=${EPOCHREALTIME/./}; printf '%s' "${t%???}"; }
SEED=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$SEED" >/dev/null
for i in $(seq 1 "$M"); do
  printf 'window=fmlab:fm-t%d\nkind=ship\n' "$i" > "$SEED/state/t$i.meta"
  printf 'working [at=1789999999]: started\n' > "$SEED/state/t$i.status"
done
for tree in base target; do
  H=$B/home-$LABEL-$tree; rm -rf "$H"; cp -R "$SEED" "$H"; mkdir -p "$H/tmux"
  run() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE TMUX_TMPDIR="$H/tmux" FM_HOME="$H" "$B/$tree/bin/fm-wake-drain.sh" "$@"; }
  run >/dev/null 2>&1   # registers every log with the presentation cursor
  for i in $(seq 1 "$M"); do make_log "$H/state/t$i.more" "$N" "$i"; cat "$H/state/t$i.more" >> "$H/state/t$i.status"; rm "$H/state/t$i.more"; done
  s=$(now_ms); run > "$B/out-$LABEL-$tree.cold" 2>&1; e=$(now_ms); cold=$((e - s))
  times=""
  for r in 1 2 3; do
    for i in $(seq 1 "$M"); do printf 'working [at=17999%05d]: run %d\n' "$r" "$r" >> "$H/state/t$i.status"; done
    s=$(now_ms); run > "$B/out-$LABEL-$tree.warm$r" 2>&1; e=$(now_ms); times="$times $((e - s))"
  done
  echo "$LABEL $tree mates=$M lines=$N unread_span_ms=$cold warm_ms:$times"
done
rm -rf "$SEED"
