#!/bin/sh
# firstmate validation release gate - no-mistakes companion pre-receive hook.
#
# bin/fm-validation-gate.sh owns the contract and installs this file, unchanged,
# as hooks/pre-receive.no-mistakes-user inside a project's no-mistakes gate
# (~/.no-mistakes/repos/<id>.git). no-mistakes' managed pre-receive execs it
# after admitting the push, with the push's ref lines on stdin. One copy serves
# every home and lane that pushes to that gate, so it carries no path back to
# any firstmate checkout and decides only from the pusher's environment:
#
#   FM_VALIDATION_GATE unset or naming no file - allow (non-fleet push, and
#     every push from a home that leaves the gate off).
#   The file reads `released <sha>` - allow a ref update to exactly <sha>.
#   Anything else, including `held` or an unreadable file - refuse.
#   A ref deletion is always allowed: no-mistakes starts no run for one.
#
# git strips GIT_CONFIG_* and -c core.hooksPath from a local receive-pack, and
# --no-verify only skips the pusher's own hooks, so neither reaches this file.
# Fork-only: daily Claude quota stop (bin/fm-daily-quota-stop.sh). Every push to
# this gate starts a new no-mistakes run, so one check here covers a run
# started by any harness or home. fm-spawn exports the variables below into each
# worker pane; a push without them (non-fleet) is never checked. A refusal
# (exit 3) rejects the push; any other check failure lets it through.
if [ -n "${FM_DAILY_QUOTA_CHECK:-}" ] && [ -x "$FM_DAILY_QUOTA_CHECK" ]; then
  set -- check nm-run
  [ -z "${FM_DAILY_QUOTA_CHECK_HOME:-}" ] || set -- "$@" --home "$FM_DAILY_QUOTA_CHECK_HOME"
  [ -z "${FM_DAILY_QUOTA_CHECK_STATUS:-}" ] || set -- "$@" --status-file "$FM_DAILY_QUOTA_CHECK_STATUS"
  "$FM_DAILY_QUOTA_CHECK" "$@" >&2
  if [ "$?" = 3 ]; then
    cat >/dev/null
    exit 1
  fi
fi
# Fork-only end
gate_file=${FM_VALIDATION_GATE:-}
if [ -z "$gate_file" ] || [ ! -e "$gate_file" ]; then
  cat >/dev/null
  exit 0
fi
verdict=
released=
if [ -r "$gate_file" ]; then
  read -r verdict released <"$gate_file" || :
fi
task=${gate_file##*/}
task=${task%.validation-gate}
status=0
while read -r old new ref; do
  : "$old"
  case $new in
  *[!0]*) ;;
  *) continue ;;
  esac
  if [ "$verdict" = released ] && [ -n "$released" ] && [ "$new" = "$released" ]; then
    continue
  fi
  if [ "$status" = 0 ]; then
    {
      printf 'firstmate validation gate: the full no-mistakes validation for task %s has not been released for %s (%s).\n' "$task" "$ref" "$new"
      printf 'While the PR iterates: commit, run the tests related to the change plus lint and type checks, push to origin, and report the PR ready.\n'
      printf 'Firstmate releases this run when you report the PR ready for final validation: fm-validation-gate.sh release %s\n' "$task"
    } >&2
  fi
  status=1
done
exit "$status"
