#!/usr/bin/env bash
B=$(cd "$(dirname "$0")" && pwd)
TIMEFORMAT='%R %U %S'
for l in m8x60 m6x400 m4x2500; do for r in 1 2 3 4 5 6 7; do for tree in base target; do
  H=$B/home-$l-$tree
  for f in $H/state/t*.status; do echo "working [at=1799999999]: c$r" >> $f; done
  t=$( { time env -u NO_MISTAKES_GATE TMUX_TMPDIR=$H/tmux FM_HOME=$H $B/$tree/bin/fm-wake-drain.sh >/dev/null 2>&1; } 2>&1 )
  set -- $t; echo "$l $tree wall=$1 cpu=$(echo "$2 + $3" | bc)"
done; done; done
