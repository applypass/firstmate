#!/usr/bin/env bash
# Fork-only: daily Claude quota stop gate (applypass fork).
#
# usage:
#   fm-daily-quota-stop.sh check <spawn|nm-run> [--home DIR] [--status-file FILE]
#
# check  exits 0 when new work may start and 3 when it is refused, printing the
#        reason on stderr. The fleet shares one daily budget measured against
#        the weekly Claude quota (quota-axi): at 20% used today new work is
#        refused, at 25% it is held until the next local day. Running work is
#        never checked here. A refusal is reported once per home, day, and
#        level: a secondmate home appends one line to its parent channel, a
#        gate given --status-file (a worker's own status file) appends one
#        there, and a main home's caller (firstmate) reads the stderr message.
#        When quota-axi cannot read Claude quota the check refuses and says
#        why; it never guesses and has no override.
#        The shared budget lives in the main home, reached through each home's
#        durable parent binding.
#
# Callers: bin/fm-spawn.sh (every fresh launch, never --relaunch), the
# no-mistakes pre-receive companion (bin/fm-validation-gate-pre-receive.sh,
# every new run start from any harness or home), and
# bin/fm-daily-quota-pretool-check.sh (`no-mistakes rerun` in a Claude worker).
# The library header owns the files and the day-start rule; docs/configuration.md
# "Daily quota stop" owns the operator view.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
# shellcheck source=bin/fm-daily-quota-lib.sh
. "$SCRIPT_DIR/fm-daily-quota-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

CMD=${1:-}
[ -n "$CMD" ] || { usage >&2; exit 2; }
shift
case "$CMD" in -h|--help) usage; exit 0 ;; esac
[ "$CMD" = check ] || { usage >&2; exit 2; }

WHAT=${1:-}
case "$WHAT" in
  spawn) WHAT=worker\ launch ;;
  nm-run) WHAT=no-mistakes\ run ;;
  *) echo "error: check needs spawn or nm-run" >&2; exit 2 ;;
esac
shift

# FM_DAILY_QUOTA_STOP=off disables the gate; tests/lib.sh sets it so fixtures
# never read quota-axi. Operators leave it unset.
[ "${FM_DAILY_QUOTA_STOP:-}" != off ] || exit 0

HOME_DIR=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd -P)}
STATUS_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) [ "$#" -gt 1 ] || { echo "error: --home needs a value" >&2; exit 2; }; HOME_DIR=$2; shift 2 ;;
    --status-file) [ "$#" -gt 1 ] || { echo "error: --status-file needs a value" >&2; exit 2; }; STATUS_FILE=$2; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
FLEET=$(fm_dq_fleet_home "$HOME_DIR")

report_once() {  # <level>
  local level=$1 now day marker_dir marker tag line until_utc
  now=$(fm_dq_now)
  day=$(fm_dq_date %F "$now") || return 0
  marker_dir="$FLEET/state/daily-quota-reported"
  tag=$(printf '%s' "$HOME_DIR$STATUS_FILE" | cksum | cut -d' ' -f1)
  marker="$marker_dir/$day-$level-$tag"
  mkdir -p "$marker_dir" 2>/dev/null || return 0
  ( set -o noclobber; : > "$marker" ) 2>/dev/null || return 0
  if [ "$level" = hold ]; then
    until_utc=$(TZ=UTC fm_dq_date '%Y-%m-%dT%H:%MZ' "$(( $(fm_dq_midnight "$now") + 86400 ))")
    line="paused [at=$now]: $(fm_dq_message "$WHAT" | tr -d '\n') until $until_utc"
  else
    line="blocked [at=$now]: $(fm_dq_message "$WHAT" | tr -d '\n')"
  fi
  line=$(fm_parent_channel_clean_note "$line")
  if [ -n "$STATUS_FILE" ]; then
    printf '%s\n' "$line" >> "$STATUS_FILE" 2>/dev/null || true
  elif fm_parent_channel_home_id "$HOME_DIR" >/dev/null 2>&1; then
    fm_parent_channel_report "$HOME_DIR" "$HOME_DIR/state" "$line" >/dev/null 2>&1 || true
  fi
}

if fm_dq_evaluate "$HOME_DIR"; then exit 0; fi
fm_dq_message "$WHAT" >&2
report_once "$FM_DQ_VERDICT"
exit 3
