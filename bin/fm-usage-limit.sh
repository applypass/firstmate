#!/usr/bin/env bash
# Fork-only (applypass): detect a usage-limit stop in captured pane text.
# Usage: fm-usage-limit.sh [<file>|-] [--harness <name>] [--now <epoch>]
#   Reads the text from <file>, or stdin when omitted or "-". Prints key=value lines:
#     usage_limit=yes|no
#     kind=limit|credits|wait          (only when yes)
#     reset=<epoch>                    (only when a reset is known)
#     reset_source=screen|quota        (only when reset is printed)
#     key=Enter|Escape                 (only when the screen is an option menu)
#   Exit 0 when a usage-limit stop is shown, 1 when not.
# The reset is parsed from the screen, honoring a timezone shown there. When the
# screen names none and --harness is given, quota-axi (read-only) supplies it.
# Capture the pane through bin/fm-peek.sh; this script never reads a pane itself.
# Contract and the resume flow: docs/usage-limit-resume.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-usage-limit-lib.sh
. "$SCRIPT_DIR/fm-usage-limit-lib.sh"

src=- harness='' now=$(date +%s)
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) harness=${2:?--harness needs a name}; shift 2 ;;
    --now) now=${2:?--now needs an epoch}; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) src=$1; shift ;;
  esac
done
if [ "$src" = - ]; then text=$(cat); else text=$(cat "$src") || exit 2; fi

fm_usage_limit_detect "$text" "$now"
if [ "$FM_UL_STOPPED" != 1 ]; then
  echo usage_limit=no
  exit 1
fi
echo usage_limit=yes
echo "kind=$FM_UL_KIND"
reset=$FM_UL_RESET src_name=screen
if [ -z "$reset" ] && [ -n "$harness" ]; then
  reset=$(fm_usage_limit_quota_reset "$harness" "$now" 2>/dev/null || true)
  src_name=quota
fi
if [ -n "$reset" ]; then
  echo "reset=$reset"
  echo "reset_source=$src_name"
fi
[ -z "$FM_UL_KEY" ] || echo "key=$FM_UL_KEY"
exit 0
