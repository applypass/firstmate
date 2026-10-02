#!/usr/bin/env bash
# Validation release gate: hold a ship task's full no-mistakes run until
# firstmate releases it.
#
# While a PR iterates, the worker commits, runs the tests related to the change
# plus lint and type checks, and pushes to origin. The costly full validation -
# the no-mistakes pipeline - starts only after firstmate has decided the work is
# done. When the worker reports the PR ready for final validation, firstmate
# runs `release` in that same turn, in both postures, and tells the captain the
# PR is ready to merge to dev and that final validation is now running; release
# also tells the worker to start the run, which proceeds without the captain's
# merge word.
#
# MECHANISM. no-mistakes starts a run when its per-repo bare gate
# (~/.no-mistakes/repos/<id>.git) receives a push, and `no-mistakes axi run`
# pushes there with --no-verify, so a client pre-push hook never sees it. The
# gate's managed pre-receive execs hooks/pre-receive.no-mistakes-user when that
# file is executable and keeps it across init and update. `prepare` installs
# bin/fm-validation-gate-pre-receive.sh there, unchanged, as that companion.
# Task identity rides the pane: fm-spawn exports FM_VALIDATION_GATE pointing at
# state/<id>.validation-gate, and every push the worker's tools make inherits
# it. That file's first line reads `held` or `released <sha>`; the companion's
# header owns the per-push verdict. git strips GIT_CONFIG_* and -c core.hooksPath from a
# local receive-pack, so neither those nor --no-verify skip the companion.
# The pipeline's own pushes go to origin, and it moves the gate's mirror ref
# with update-ref, so a released run is never gated against itself.
#
# SCOPE. Only a ship task in mode no-mistakes with no forge binding is held; a
# Gerrit-bound no-mistakes run skips push, pr, and ci and is left alone. A gated
# scout pane carries the variable too, so a scout promoted to such a ship is held
# by `prepare` at promotion. A secondmate pane carries none.
#
# SWITCH. config/validation-gate (`on` or `off`) wins; otherwise the tracked
# defaults/validation-gate beside bin/ decides; neither present means off, which
# is upstream behaviour. The switch is read once per task, and every later step
# follows that one decision, so the Definition of done a worker holds always
# matches its gate:
#   - A ship brief records it: bin/fm-brief.sh renders the gated Definition of
#     done, whose `Validation gate: on` line fm-spawn's `prepare` then obeys.
#   - A scout spawn reads the switch itself.
#   - fm-spawn records the result as `validation_gate=on` in state/<id>.meta, and
#     a relaunch and a promotion read that record, never the switch.
# Turning the switch off therefore does not release tasks already held - release
# those.
# Under FM_TEST_SEAM=1, FM_TEST_VALIDATION_GATE_DEFAULTS names the defaults file
# instead, so the suite runs on the upstream default.
#
# ACCEPTED RESIDUAL. A same-user process can unset the variable, rewrite its gate
# file, or write into the gate repository. Each is deliberate tampering outside
# the worktree that the worker contract already forbids; the gate stops the
# default path, not a worker set on evading it. A run on a head already in the
# gate (`axi run` reattach, `no-mistakes rerun`) asks the daemon directly, which
# is safe because only an admitted head can be in the gate. A project with no
# no-mistakes remote yet has no gate to arm: the task is still held and the
# worker told to wait, and the next `prepare` or `release` arms the gate once the
# worker's `no-mistakes init` creates it, so until then only the instruction
# holds the run.
#
# Usage:
#   fm-validation-gate.sh enabled [--config <dir>] [--task <task-id>]
#       Exit 0 when the gate is on, 1 when off. With --task and an existing
#       task record, the record decides; otherwise the switch does.
#   fm-validation-gate.sh prepare --config <dir> --state <dir> --kind <kind>
#       --mode <mode> --forge <forge> --worktree <path> --id <task-id>
#       [--brief <file>] [--recorded 0|1]
#       Called by fm-spawn and fm-promote. The gate is on when, with
#       --recorded 1 (relaunch, promotion), the task record has
#       `validation_gate=on`; otherwise, for a ship, when the --brief carries
#       `Validation gate: on`; for a scout, when the switch is on. When on: for
#       a held scope, install the companion into the worktree's no-mistakes gate
#       and write `held` (--recorded 1 keeps an existing file); print the gate
#       file path the pane exports, which the caller records as
#       `validation_gate=on`. Prints nothing when off. A worktree with no
#       no-mistakes remote yet defers the install. Exits nonzero, and the
#       caller stops, when the gate cannot be installed: a gate whose
#       pre-receive runs no companion, or a companion that is not firstmate's.
#   fm-validation-gate.sh release <task-id>
#       Firstmate runs this in the turn a gated ship reports
#       `ready for final validation`, in both postures. Arms a deferred gate,
#       then records
#       `released <sha>` for the task worktree's HEAD - only that exact head
#       may then start a run, so a later change needs a new release - then
#       steers the worker through fm-send to start /no-mistakes, and records
#       `steered <sha>` as line 2 so a repeat sends nothing. A failed send
#       leaves the release and exits nonzero; rerunning retries the steer.
#       A release that cannot find the worktree HEAD keeps `held` and notes
#       `release failed: <reason>` as line 2, so the escalation stays open.
#   fm-validation-gate.sh outcome-check <task-id> <verdict>
#       bin/fm-branch-outcome.sh calls this before storing an outcome. Exits 1
#       for verdict captain while the gate file reads only `held` and the
#       task's last status line is its ready-for-validation report.
#   fm-validation-gate.sh supervision-rule
#       Print the fixed rule bin/fm-branch-prompt.sh adds to the supervision
#       branch's prompt.
#   fm-validation-gate.sh dod <branch>
#       Print the opening of the gated no-mistakes Definition of done;
#       bin/fm-dod-lib.sh renders the rest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
COMPANION_TEMPLATE="$SCRIPT_DIR/fm-validation-gate-pre-receive.sh"
COMPANION_NAME='pre-receive.no-mistakes-user'
COMPANION_MARK='firstmate validation release gate'

die() {
  echo "error: fm-validation-gate: $*" >&2
  exit 1
}

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' >&2
  exit 2
}

home_dir() { printf '%s' "${FM_HOME:-${FM_ROOT_OVERRIDE:-$CODE_ROOT}}"; }
state_dir() { printf '%s' "${FM_STATE_OVERRIDE:-$(home_dir)/state}"; }
config_dir() { printf '%s' "${FM_CONFIG_OVERRIDE:-$(home_dir)/config}"; }

defaults_file() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_VALIDATION_GATE_DEFAULTS:-}" ]; then
    printf '%s' "$FM_TEST_VALIDATION_GATE_DEFAULTS"
  else
    printf '%s' "$CODE_ROOT/defaults/validation-gate"
  fi
}

# First non-blank line of a switch file, trimmed; empty when absent.
switch_word() {  # <file>
  [ -f "$1" ] || return 0
  awk 'NF { print $1; exit }' "$1"
}

gate_enabled() {  # <config-dir>
  local word
  word=$(switch_word "$1/validation-gate")
  [ -n "$word" ] || word=$(switch_word "$(defaults_file)")
  case "$word" in
  on) return 0 ;;
  off | '') return 1 ;;
  *)
    echo "error: fm-validation-gate: switch value '$word' is neither on nor off" >&2
    return 2
    ;;
  esac
}

write_atomic() {  # <file> <content>
  local file=$1 tmp
  tmp=$(mktemp "${file%/*}/.${file##*/}.XXXXXX") || return 1
  if printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$file"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Resolve the worktree's no-mistakes gate and install the companion there; a
# worktree with no no-mistakes remote yet has no gate, so the install waits.
install_companion() {  # <worktree>
  local wt=$1 url gate pre companion tmp
  url=$(git -C "$wt" remote get-url no-mistakes 2>/dev/null) || return 0
  gate=${url#file://}
  case "$gate" in
  /*) ;;
  *) die "no-mistakes remote '$url' is not a local gate path" ;;
  esac
  [ -d "$gate/hooks" ] || die "no-mistakes gate $gate has no hooks directory"
  pre="$gate/hooks/pre-receive"
  grep -qF "$COMPANION_NAME" "$pre" 2>/dev/null ||
    die "no-mistakes gate $gate does not run a $COMPANION_NAME companion; update no-mistakes"
  companion="$gate/hooks/$COMPANION_NAME"
  if [ -e "$companion" ]; then
    grep -qF "$COMPANION_MARK" "$companion" ||
      die "$companion exists and is not firstmate's; refusing to replace it"
    if cmp -s "$COMPANION_TEMPLATE" "$companion" && [ -x "$companion" ]; then
      return 0
    fi
  fi
  tmp=$(mktemp "$gate/hooks/.fm-validation-gate.XXXXXX") || die "cannot write into $gate/hooks"
  if cp "$COMPANION_TEMPLATE" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$companion"; then
    return 0
  fi
  rm -f "$tmp"
  die "could not install $companion"
}

cmd_enabled() {
  local config id='' meta
  config=$(config_dir)
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --config) config=${2:-}; shift 2 || usage ;;
    --task) id=${2:-}; shift 2 || usage ;;
    *) usage ;;
    esac
  done
  meta="$(state_dir)/$id.meta"
  if [ -n "$id" ] && [ -e "$meta" ]; then
    grep -qx 'validation_gate=on' "$meta"
    return
  fi
  gate_enabled "$config"
}

cmd_prepare() {
  local config='' state='' kind='' mode='' forge=none wt='' id='' brief='' recorded=0 file status
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --config) config=${2-}; shift 2 || usage ;;
    --state) state=${2-}; shift 2 || usage ;;
    --kind) kind=${2-}; shift 2 || usage ;;
    --mode) mode=${2-}; shift 2 || usage ;;
    --forge) forge=${2:-none}; shift 2 || usage ;;
    --worktree) wt=${2-}; shift 2 || usage ;;
    --id) id=${2-}; shift 2 || usage ;;
    --brief) brief=${2-}; shift 2 || usage ;;
    --recorded) recorded=${2-}; shift 2 || usage ;;
    *) usage ;;
    esac
  done
  [ -n "$config" ] && [ -n "$state" ] && [ -n "$kind" ] && [ -n "$id" ] || usage
  case "$kind" in
  ship | scout) ;;
  *) return 0 ;;
  esac
  state=$(cd "$state" && pwd -P) || die "state directory $state is not accessible"
  if [ "$recorded" = 1 ]; then
    grep -qx 'validation_gate=on' "$state/$id.meta" 2>/dev/null || return 0
  elif [ "$kind" = ship ]; then
    [ -n "$brief" ] || usage
    grep -qx 'Validation gate: on' "$brief" 2>/dev/null || return 0
  else
    gate_enabled "$config"
    status=$?
    [ "$status" = 0 ] || { [ "$status" = 1 ] && return 0; exit 1; }
  fi
  file="$state/$id.validation-gate"
  if [ "$kind" = ship ] && [ "$mode" = no-mistakes ] && [ "$forge" = none ]; then
    [ -n "$wt" ] || usage
    install_companion "$wt"
    if [ "$recorded" = 0 ] || [ ! -e "$file" ]; then
      write_atomic "$file" held || die "could not write $file"
    fi
  fi
  printf '%s\n' "$file"
}

# Keep the task held and note why, so outcome-check stops refusing a captain
# verdict for a release that could not happen.
release_failed() {  # <gate-file> <reason>
  if [ "$(head -n 1 "$1" 2>/dev/null)" = held ]; then
    write_atomic "$1" "held"$'\n'"release failed: $2" || true
  fi
  die "$2"
}

cmd_release() {
  local id=${1:-} state meta file wt full verdict='' steered=''
  [ -n "$id" ] && [ "$#" -eq 1 ] || usage
  state=$(state_dir)
  file="$state/$id.validation-gate"
  [ -e "$file" ] || die "task $id is not gated (no $file)"
  meta="$state/$id.meta"
  wt=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | head -n 1)
  [ -n "$wt" ] && [ -d "$wt" ] || release_failed "$file" "task $id has no readable worktree in $meta"
  full=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}') ||
    release_failed "$file" "$wt has no HEAD commit"
  (install_companion "$wt") || release_failed "$file" "could not arm the no-mistakes gate for $id"
  { read -r verdict; read -r steered; } <"$file" || true
  if [ "$verdict" = "released $full" ] && [ "$steered" = "steered $full" ]; then
    echo "$id is already released at $full and the worker was told to start"
    return 0
  fi
  write_atomic "$file" "released $full" || die "could not write $file"
  FM_HOME=$(home_dir) "$SCRIPT_DIR/fm-send.sh" "$id" "$(start_steer "$full")" >/dev/null ||
    die "released $id at $full, but the start instruction could not be sent; rerun release to retry"
  write_atomic "$file" "released $full"$'\n'"steered $full" || die "could not write $file"
  echo "released $id at $full and told the worker to run /no-mistakes on that head"
}

start_steer() {  # <sha>
  printf '%s' "Firstmate released the final validation of $1. Run /no-mistakes now on that exact head, as your Definition of done says, and drive it through to CI green."
}

# Refuse a captain verdict for a ready-for-validation report the gate still
# holds: firstmate releases it before reporting a captain outcome.
cmd_outcome_check() {
  local id=${1:-} verdict=${2:-} state last
  [ -n "$id" ] && [ -n "$verdict" ] && [ "$#" -eq 2 ] || usage
  [ "$verdict" = captain ] || return 0
  state=$(state_dir)
  [ "$(cat "$state/$id.validation-gate" 2>/dev/null)" = held ] || return 0
  last=$(awk 'NF { line = $0 } END { print line }' "$state/$id.status" 2>/dev/null)
  case "$last" in
  done*'ready for final validation'*) ;;
  *) return 0 ;;
  esac
  echo "error: $id reported ready for final validation; release it before reporting a captain outcome." >&2
  echo "Run bin/fm-validation-gate.sh release $id (it starts the worker's run), then report verdict captain: the PR is ready to merge to dev and final validation is running." >&2
  return 1
}

cmd_supervision_rule() {
  [ "$#" -eq 0 ] || usage
  cat <<'EOF'

# Validation release gate

When a ship reports `done [at=<epoch>]: PR <url> ready for final validation`, firstmate releases it in the same turn, in both postures: claim the task's lease and run `bin/fm-validation-gate.sh release <task>`, which lifts the gate on the worker's current head and sends the worker the instruction to start /no-mistakes.
Then report verdict captain with the PR's URL: the PR is ready to merge to dev, and its final validation is now running without waiting for the captain's merge word.
The worker's later `done: PR <url> checks green` is a follow-up that clears the merge.
The report surface refuses a captain verdict for a ready report the gate still holds, so release first; if release itself fails, report verdict captain with its exact error.
EOF
}

cmd_dod() {
  local branch=${1:-}
  [ -n "$branch" ] && [ "$#" -eq 1 ] || usage
  cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
Validation gate: on
Ship branch: $branch
The full no-mistakes validation runs once, on the final version, after firstmate releases it; until then a gate on the pipeline refuses to start it.
While the PR iterates, commit on your branch and run the tests related to the change - the unit and integration tests for the changed code and the code it affects - plus lint and type checks, not the whole repository suite.
Then push your branch to origin and open or update a pull request with \`gh-axi\` that is ready for review, not a draft.
When you believe it is complete, append \`done [at=<epoch>]: PR {url} ready for final validation\` to the status file and stop.
Do NOT run /no-mistakes before firstmate releases it; the gate refuses that push.
Firstmate then releases that exact head, which sends you the instruction to run /no-mistakes on it.
If you change the branch after that, report it; firstmate releases the new head.

EOF
}

CMD=${1:-}
[ "$#" -gt 0 ] && shift
case "$CMD" in
enabled) cmd_enabled "$@" ;;
prepare) cmd_prepare "$@" ;;
release) cmd_release "$@" ;;
dod) cmd_dod "$@" ;;
outcome-check) cmd_outcome_check "$@" ;;
supervision-rule) cmd_supervision_rule "$@" ;;
-h | --help | '') usage ;;
*) usage ;;
esac
