#!/usr/bin/env bash
# send-bench.sh: real fm-send from base and target into real tmux panes on a lab socket.
set -u
B=$(cd "$(dirname "$0")" && pwd)
WT=/Users/uayyagari/.no-mistakes/worktrees/c5d69c01912a/01M6780AK9G5R621HZXY645YGB
N=${1:-2500}
TIMEFORMAT='%R'
make_log() {
  awk -v n="$2" 'BEGIN { t = 1790000000
    printf "needs-decision [key=open-k] [at=%d]: still waiting on the captain\n", t
    for (i = 1; i <= n; i++) { t++
      if (i % 5 == 1) printf "needs-decision [key=k%d] [at=%d]: option %d or %d\n", i, t, i, i + 1
      else if (i % 5 == 2) printf "resolved [key=k%d] [at=%d]: answered: take the first\n", i - 1, t
      else printf "working [at=%d]: progress line %d with a few more words in it\n", t, i } }' > "$1"
}
for tree in base target; do
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"; LAB=$(cd "$LAB" && pwd -P)
  T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
  T new-session -d -s fmlab -n fm-t1 -x 200 -y 50 "/var/folders/vr/_90lw3_s0bs_nw2f7b6t9yrm0000gn/T//fmbench/composer.sh $LAB/pane-t1.txt"
  printf 'window=fmlab:fm-t1\nkind=ship\n' > "$LAB/state/t1.meta"
  make_log "$LAB/state/t1.status" "$N"
  sleep 1; T capture-pane -p -t fmlab:fm-t1 > "$B/pane-$tree-before.txt"
  # one drain warms the open-decision cursor the way a live home keeps it
  env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" "$B/$tree/bin/fm-wake-drain.sh" >/dev/null 2>&1
  snd() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" "$B/$tree/bin/fm-send.sh" "$@"; }
  for r in 1 2 3; do
    t=$( { time snd t1 "plain steer $r" >"$B/send-$tree-plain$r.out" 2>&1; } 2>&1 ); echo "$tree plain rc=$? wall=$t"
  done
  for k in open-k k2496 k2491; do
    t=$( { time snd t1 --resolve-key "$k" "take the first option for $k" >"$B/send-$tree-$k.out" 2>&1; } 2>&1 ); echo "$tree resolve-key $k wall=$t closed=$(grep -c "^resolved \[key=$k\]" "$LAB/state/t1.status")"
  done
  # adversarial: closing an already-closed key must still be refused/handled the same on both trees
  snd t1 --resolve-key k2 "late answer" >"$B/send-$tree-closed.out" 2>&1; echo "$tree closed-key rc=$?"
  sleep 1
  echo "$tree inbox records: $(ls "$LAB/state/t1.inbox" 2>/dev/null | wc -l | tr -d ' ')  doorbells in pane: $(wc -l < "$LAB/pane-t1.txt" | tr -d ' ')"
  T kill-server; "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; cp "$LAB/state/t1.status" "$B/send-$tree-t1.status"; rm -rf "$LAB"
done
