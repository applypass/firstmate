#!/usr/bin/env bash
# Live check: real bin/fm-spawn.sh + real treehouse + isolated Herdr lab session.
set -u
ROOT=${1:?worktree root}
command -v herdr >/dev/null && command -v treehouse >/dev/null && command -v jq >/dev/null || { echo "missing tool"; exit 2; }
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-thget.XXXXXX")
SESSION="fm-lab-thget-$$"
export HERDR_SESSION="$SESSION"
WTS=()
cleanup() {
  for w in "${WTS[@]}"; do "${REAL_TH:-treehouse}" return --force "$w" >/dev/null 2>&1; done
  herdr_safe_stop_and_delete "$SESSION"
  for w in "${WTS[@]}"; do pool=$(dirname "$(dirname "$w")"); case "$pool" in "$HOME/.treehouse/proj-"*) treehouse destroy "$pool" --all --yes --include-in-use --include-unlanded >/dev/null 2>&1; rm -rf "$pool";; esac; break; done
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null; rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 1; }

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
PROJ="$TMP_ROOT/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

run_case() { # <id> <timeout-value or UNSET>
  local id=$1 val=$2 rc start end
  mkdir -p "$HOME_DIR/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nlive timeout check\n\n## Firstmate spec\nnone\n' > "$HOME_DIR/data/$id/brief.md"
  echo "=== case $id: FM_TREEHOUSE_GET_TIMEOUT=$val ==="
  start=$(date +%s)
  if [ "$val" = UNSET ]; then
    env -u FM_TREEHOUSE_GET_TIMEOUT FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "sh -c 'echo $id-launched'" --mode no-mistakes --yolo off --backend herdr \
      >"$TMP_ROOT/$id.out" 2>"$TMP_ROOT/$id.err"
  else
    FM_TREEHOUSE_GET_TIMEOUT="$val" FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "sh -c 'echo $id-launched'" --mode no-mistakes --yolo off --backend herdr \
      >"$TMP_ROOT/$id.out" 2>"$TMP_ROOT/$id.err"
  fi
  rc=$?; end=$(date +%s)
  echo "exit=$rc elapsed=$((end-start))s"
  grep -h -E "treehouse get|error:" "$TMP_ROOT/$id.err" | head -5
  if [ -f "$HOME_DIR/state/$id.meta" ]; then
    w=$(grep '^worktree=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)
    echo "meta worktree=$w"
    [ -n "$w" ] && WTS+=("$w")
  fi
  # Return any slot the pane acquired even when spawn refused.
  pane=$(grep '^herdr_pane_id=' "$HOME_DIR/state/$id.meta" 2>/dev/null | cut -d= -f2-)
}
SLOWBIN="$TMP_ROOT/slowbin"; mkdir -p "$SLOWBIN"; REAL_TH=$(command -v treehouse)
printf '#!/bin/sh
# Delays the real treehouse to stand in for a host under heavy load.
[ "$1" = get ] && sleep %s
exec %s "$@"\n' "${TH_DELAY:-70}" "$REAL_TH" > "$SLOWBIN/treehouse"; chmod +x "$SLOWBIN/treehouse"
export PATH="$SLOWBIN:$PATH"
# The pane runs an interactive zsh whose rc files rebuild PATH; a scratch
# ZDOTDIR puts the slow wrapper back in front for the lab panes only.
ZD="$TMP_ROOT/zdot"; mkdir -p "$ZD"; printf 'export PATH="%s:$PATH"\n' "$SLOWBIN" > "$ZD/.zshrc"
export ZDOTDIR="$ZD"
run_case slow240 240
run_case slowdef190 UNSET
echo "=== treehouse pool for the scratch project ==="
(cd "$PROJ" && treehouse status 2>&1 | head -20)
