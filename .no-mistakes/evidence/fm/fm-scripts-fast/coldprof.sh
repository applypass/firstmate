#!/usr/bin/env bash
B=$(cd "$(dirname "$0")" && pwd); WT=/Users/uayyagari/.no-mistakes/worktrees/c5d69c01912a/01M6780AK9G5R621HZXY645YGB
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$H" >/dev/null; mkdir -p "$H/tmux"
for i in 1 2; do printf 'window=fmlab:fm-t%d\nkind=ship\n' $i > "$H/state/t$i.meta"; printf 'working [at=1789999999]: started\n' > "$H/state/t$i.status"; done
run() { env -u NO_MISTAKES_GATE TMUX_TMPDIR="$H/tmux" FM_HOME="$H" "$@" "$B/target/bin/fm-wake-drain.sh"; }
run >/dev/null 2>&1
for i in 1 2; do sed -n 2,2501p "$B/home-q4x2500-target/state/t$i.status" >> "$H/state/t$i.status"; done
env -u NO_MISTAKES_GATE TMUX_TMPDIR="$H/tmux" FM_HOME="$H" SHELLOPTS=xtrace PS4='+${EPOCHREALTIME} $$ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main} ' "$B/target/bin/fm-wake-drain.sh" >/dev/null 2>"$B/trace-cold.txt"
python3 "$B/prof.py" "$B/trace-cold.txt"
rm -rf "$H"
