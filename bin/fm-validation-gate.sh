#!/usr/bin/env bash
# Validation release gate: hold a ship task's full no-mistakes run until
# firstmate releases it.
#
# While a PR iterates, the worker commits, runs the tests related to the change
# plus lint and type checks, and pushes to origin. The costly full validation -
# the no-mistakes pipeline - starts only after firstmate has decided the work is
# done and has told the captain the PR is ready to merge; firstmate then runs
# `release`, and the run proceeds without waiting for the captain's merge word.
#
# MECHANISM. no-mistakes starts a run when its per-repo bare gate
# (~/.no-mistakes/repos/<id>.git) receives a push, and `no-mistakes axi run`
# pushes there with --no-verify, so a client pre-push hook never sees it. The
# gate's managed pre-receive execs hooks/pre-receive.no-mistakes-user when that
# file is executable and keeps it across init and update. `prepare` installs
# bin/fm-validation-gate-pre-receive.sh there, unchanged, as that companion.
# Task identity rides the pane: fm-spawn exports FM_VALIDATION_GATE pointing at
# state/<id>.validation-gate, and every push the worker's tools make inherits
# it. That file reads `held` or `released <sha>`; the companion's header owns
# the per-push verdict. git strips GIT_CONFIG_* and -c core.hooksPath from a
# local receive-pack, so neither those nor --no-verify skip the companion.
# The pipeline's own pushes go to origin, and it moves the gate's mirror ref
# with update-ref, so a released run is never gated against itself.
#
# SCOPE. Only a ship task in mode no-mistakes with no forge binding is held; a
# Gerrit-bound no-mistakes run skips push, pr, and ci and is left alone. Ship and
# scout panes both carry the variable, so a scout promoted to such a ship is held
# by `prepare` at promotion. A secondmate pane carries none.
#
# SWITCH. config/validation-gate (`on` or `off`) wins; otherwise the tracked
# defaults/validation-gate beside bin/ decides; neither present means off, which
# is upstream behaviour. The switch is read once, when a task is spawned or
# promoted, and the caller records the decision as `validation_gate=on` in
# state/<id>.meta; a relaunch reads that record and never the switch, so a task
# keeps the contract its brief carries. Turning the switch off therefore does not
# release tasks already held - release those.
# Under FM_TEST_SEAM=1, FM_TEST_VALIDATION_GATE_DEFAULTS names the defaults file
# instead, so the suite runs on the upstream default.
#
# ACCEPTED RESIDUAL. A same-user process can unset the variable, rewrite its gate
# file, or write into the gate repository. Each is deliberate tampering outside
# the worktree that the worker contract already forbids; the gate stops the
# default path, not a worker set on evading it. A run on a head already in the
# gate (`axi run` reattach, `no-mistakes rerun`) asks the daemon directly, which
# is safe because only an admitted head can be in the gate.
#
# Usage:
#   fm-validation-gate.sh enabled [--config <dir>]
#       Exit 0 when the switch resolves on, 1 when off.
#   fm-validation-gate.sh prepare --config <dir> --state <dir> --kind <kind>
#       --mode <mode> --forge <forge> --worktree <path> --id <task-id> [--relaunch 0|1]
#       Called by fm-spawn and fm-promote. With the switch on (on a relaunch,
#       with `validation_gate=on` in the task record): for a held scope,
#       install the companion into the worktree's no-mistakes gate and write
#       `held` (a relaunch keeps an existing file); for a ship or scout, print
#       the gate file path the pane exports, which the caller records as
#       `validation_gate=on`. Prints nothing when off. Exits
#       nonzero, and the caller stops, when the gate cannot be installed: no
#       no-mistakes remote, a gate whose pre-receive runs no companion, or a
#       companion that is not firstmate's.
#   fm-validation-gate.sh release <task-id>
#       Firstmate runs this when it tells the captain the PR is ready to merge.
#       Records `released <sha>` for the task worktree's HEAD; only that exact
#       head may then start a run, so a later change needs a new release.
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

# Resolve the worktree's no-mistakes gate and install the companion there.
install_companion() {  # <worktree>
  local wt=$1 url gate pre companion tmp
  url=$(git -C "$wt" remote get-url no-mistakes 2>/dev/null) ||
    die "$wt has no no-mistakes remote; run no-mistakes init in the project first so the gate exists"
  gate=${url#file://}
  case "$gate" in
  /*) ;;
  *) die "no-mistakes remote '$url' is not a local gate path" ;;
  esac
  [ -d "$gate/hooks" ] || die "no-mistakes gate $gate has no hooks directory; run no-mistakes init in the project first"
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
  local config
  config=$(config_dir)
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --config) config=${2:-}; shift 2 || usage ;;
    *) usage ;;
    esac
  done
  gate_enabled "$config"
}

cmd_prepare() {
  local config='' state='' kind='' mode='' forge=none wt='' id='' relaunch=0 file status
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --config) config=${2-}; shift 2 || usage ;;
    --state) state=${2-}; shift 2 || usage ;;
    --kind) kind=${2-}; shift 2 || usage ;;
    --mode) mode=${2-}; shift 2 || usage ;;
    --forge) forge=${2:-none}; shift 2 || usage ;;
    --worktree) wt=${2-}; shift 2 || usage ;;
    --id) id=${2-}; shift 2 || usage ;;
    --relaunch) relaunch=${2-}; shift 2 || usage ;;
    *) usage ;;
    esac
  done
  [ -n "$config" ] && [ -n "$state" ] && [ -n "$kind" ] && [ -n "$id" ] || usage
  case "$kind" in
  ship | scout) ;;
  *) return 0 ;;
  esac
  state=$(cd "$state" && pwd -P) || die "state directory $state is not accessible"
  if [ "$relaunch" = 1 ]; then
    grep -qx 'validation_gate=on' "$state/$id.meta" 2>/dev/null || return 0
  else
    gate_enabled "$config"
    status=$?
    [ "$status" = 0 ] || { [ "$status" = 1 ] && return 0; exit 1; }
  fi
  file="$state/$id.validation-gate"
  if [ "$kind" = ship ] && [ "$mode" = no-mistakes ] && [ "$forge" = none ]; then
    [ -n "$wt" ] || usage
    install_companion "$wt"
    if [ "$relaunch" = 0 ] || [ ! -e "$file" ]; then
      write_atomic "$file" held || die "could not write $file"
    fi
  fi
  printf '%s\n' "$file"
}

cmd_release() {
  local id=${1:-} state meta file wt full
  [ -n "$id" ] && [ "$#" -eq 1 ] || usage
  state=$(state_dir)
  file="$state/$id.validation-gate"
  [ -e "$file" ] || die "task $id is not gated (no $file)"
  meta="$state/$id.meta"
  wt=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | head -n 1)
  [ -n "$wt" ] && [ -d "$wt" ] || die "task $id has no readable worktree in $meta"
  full=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}') ||
    die "$wt has no HEAD commit"
  write_atomic "$file" "released $full" || die "could not write $file"
  echo "released $id at $full; tell the worker to run /no-mistakes on that head"
}

cmd_dod() {
  local branch=${1:-}
  [ -n "$branch" ] && [ "$#" -eq 1 ] || usage
  cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: $branch
The full no-mistakes validation runs once, on the final version, after firstmate releases it; until then a gate on the pipeline refuses to start it.
While the PR iterates, commit on your branch and run the tests related to the change - the unit and integration tests for the changed code and the code it affects - plus lint and type checks, not the whole repository suite.
Then push your branch to origin and open or update a pull request with \`gh-axi\` that is ready for review, not a draft.
When you believe it is complete, append \`done [at=<epoch>]: PR {url} ready for final validation\` to the status file and stop.
Do NOT run /no-mistakes before firstmate releases it; the gate refuses that push.
Firstmate releases the final validation when it tells the captain the PR is ready to merge, then instructs you to run /no-mistakes on that exact head.
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
-h | --help | '') usage ;;
*) usage ;;
esac
