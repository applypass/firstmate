#!/usr/bin/env bash
# Fork-only: daily Claude quota stop gate (applypass fork).
#
# usage:
#   fm-daily-quota-stop.sh check <spawn|nm-run> [--home DIR] [--fleet-home DIR] [--status-file FILE]
#   fm-daily-quota-stop.sh status [--home DIR]
#   fm-daily-quota-stop.sh allow-unreadable [--home DIR]
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
#        why; it never guesses. FM_DAILY_QUOTA_ALLOW_UNREADABLE=1 on one
#        command, or a one-shot grant from `allow-unreadable`, lets a single
#        launch through when the quota is unreadable.
# --fleet-home overrides the shared-budget home (default: FM_DAILY_QUOTA_HOME,
#        then FM_PUBLIC_FOLLOWUP_PRIMARY_HOME, then --home).
# status prints today's numbers and the verdict; exit code mirrors check.
# allow-unreadable records the one-shot grant in the fleet home (the captain's
#        decision; consumed by the next unreadable-quota check).
#
# Callers: bin/fm-spawn.sh (every fresh launch, never --relaunch) and
# bin/fm-daily-quota-pretool-check.sh (a new no-mistakes run in a Claude
# worker). The library header owns the files, the day-start rule, and the
# thresholds; docs/configuration.md "Daily quota stop" owns the operator view.
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

WHAT=
if [ "$CMD" = check ]; then
  WHAT=${1:-}
  case "$WHAT" in
    spawn) WHAT=worker\ launch ;;
    nm-run) WHAT=no-mistakes\ run ;;
    *) echo "error: check needs spawn or nm-run" >&2; exit 2 ;;
  esac
  shift
fi

# FM_DAILY_QUOTA_STOP=off disables the gate; tests/lib.sh sets it so fixtures
# never read quota-axi. Operators leave it unset.
[ "${FM_DAILY_QUOTA_STOP:-}" != off ] || exit 0

HOME_DIR=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd -P)}
STATUS_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) [ "$#" -gt 1 ] || { echo "error: --home needs a value" >&2; exit 2; }; HOME_DIR=$2; shift 2 ;;
    --fleet-home) [ "$#" -gt 1 ] || { echo "error: --fleet-home needs a value" >&2; exit 2; }; export FM_DAILY_QUOTA_HOME=$2; shift 2 ;;
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

case "$CMD" in
  allow-unreadable)
    mkdir -p "$FLEET/state" && : > "$FLEET/state/daily-quota-allow-unreadable" || exit 1
    echo "granted one launch while Claude quota is unreadable ($FLEET/state/daily-quota-allow-unreadable)"
    exit 0
    ;;
  status)
    WHAT=work
    fm_dq_evaluate "$HOME_DIR"
    printf 'verdict=%s used_now=%s used_today=%s refuse_at=%s hold_at=%s\n' \
      "$FM_DQ_VERDICT" "${FM_DQ_USED_NOW:-unknown}" "${FM_DQ_USED_TODAY:-unknown}" "$FM_DQ_REFUSE_PCT" "$FM_DQ_HOLD_PCT"
    [ "$FM_DQ_VERDICT" != ok ] && fm_dq_message "$WHAT" >&2
    [ "$FM_DQ_VERDICT" = ok ]
    exit $?
    ;;
  check)
    if fm_dq_evaluate "$HOME_DIR"; then exit 0; fi
    if [ "$FM_DQ_VERDICT" = unreadable ] && fm_dq_consume_unreadable_grant "$FLEET"; then
      echo "daily quota stop: Claude quota is unreadable ($FM_DQ_REASON); proceeding on the captain's one-shot grant" >&2
      exit 0
    fi
    fm_dq_message "$WHAT" >&2
    report_once "$FM_DQ_VERDICT"
    exit 3
    ;;
  *) usage >&2; exit 2 ;;
esac
