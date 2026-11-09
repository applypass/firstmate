#!/usr/bin/env bash
# Live drive: real fm-send.sh + real fm-new-task-guard.sh + real tasks-axi, lab homes, lab tmux socket.
set -u
WT=$PWD
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null
LAB=$(cd "$LAB" && pwd -P)
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
T="tmux -L fm-lab"
$T new-session -d -s firstmate -n main 'cat'
seed_backlog() { printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$1/data/backlog.md"; }
seed_backlog "$LAB"
# Write In flight rows in the markdown backlog format tasks-axi reads (fm-tasks-axi refuses add --start
# without a dispatch record); every read below goes through the real tasks-axi.
inflight() { # home prefix n
  local i rows=''
  for ((i=1;i<=$3;i++)); do rows="$rows- [ ] $2-w$i - task $i of $2 (repo: lab)"$'\n'; done
  printf '# Backlog\n\n## In flight\n\n%s\n## Queued\n\n## Done\n' "$rows" > "$1/data/backlog.md"
}
: > "$LAB/data/secondmates.md"
mk_mate() { # id n_inflight
  local id=$1 n=$2 h="$LAB/mates/$1" i
  mkdir -p "$(dirname "$h")"; bin/fm-lab-home.sh create "$h" >/dev/null
  seed_backlog "$h"; printf '%s\n' "$id" > "$h/.fm-secondmate-home"
  h=$(cd "$h" && pwd -P)
  inflight "$h" "$id" "$n"
  printf -- '- %s - lab mate (home: %s; scope: lab; projects: none; added 2026-11-09)\n' "$id" "$h" >> "$LAB/data/secondmates.md"
  $T new-window -d -t firstmate -n "fm-$id" 'cat'
  cat > "$LAB/state/$id.meta" <<M
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$h
project=$h
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$h
projects=none
M
}
send() { echo "\$ fm-send.sh $*"; FM_HOME="$LAB" FM_SEND_SETTLE=0 bin/fm-send.sh "$@" 2>&1; echo "[exit $?]"; }
inbox() { ls "$LAB/state/$1.inbox" 2>/dev/null | wc -l | tr -d ' '; }

echo "=== S1: core-backend has 1 in-flight item (real tasks-axi list) ==="
mk_mate core-backend 1
FM_HOME="$LAB/mates/core-backend" bin/fm-tasks-axi.sh list --state in_flight
send core-backend --new-task "From firstmate (captain asked): build feature B"
echo "inbox messages for core-backend: $(inbox core-backend)"
echo
echo "=== S2: --same-task to busy core-backend ==="
send core-backend --same-task "From firstmate (captain asked): also handle edge case"
echo "inbox messages for core-backend: $(inbox core-backend)"
echo
echo "=== S3: --new-task to idle mate fresh-mate ==="
mk_mate fresh-mate 0
send fresh-mate --new-task "From firstmate (captain asked): build feature C"
echo "inbox messages for fresh-mate: $(inbox fresh-mate)"
echo
echo "=== S4: fleet at cap: 6 busy mates + core-backend busy + main 1 in flight, idle target idle-a ==="
for i in 1 2 3 4 5 6; do mk_mate "busy-$i" 1; done
inflight "$LAB" main 1; FM_HOME="$LAB" bin/fm-tasks-axi.sh list --state in_flight
mk_mate idle-a 0
before=$(inbox idle-a)
send idle-a --new-task "From firstmate (captain asked): build feature D"
echo "inbox messages for idle-a: before=$before after=$(inbox idle-a)"
echo
echo "=== S5: stale registry entry (home deleted) below cap does not block idle target ==="
inflight "$LAB" main 0
for i in 3 4 5 6; do inflight "$LAB/mates/busy-$i" "busy-$i" 0; done
mk_mate gone-mate 0; rm -rf "$LAB/mates/gone-mate"
send idle-a --new-task "From firstmate (captain asked): build feature E"
echo "inbox messages for idle-a: $(inbox idle-a)"
echo
echo "=== S6: target mate's own home missing -> refuse ==="
send gone-mate --new-task "From firstmate (captain asked): x"
echo
echo "=== S7: legacy send without flags still works to busy mate (fm-send itself does not refuse) ==="
send core-backend "plain steer"
$T kill-server
rm -rf "$LAB"
echo "lab removed: $( [ -e "$LAB" ] && echo no || echo yes)"
