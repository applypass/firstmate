#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints "<mode> <yolo> [ticket-prefix]" to stdout, where mode is one of
# no-mistakes|direct-PR|local-only, yolo is on|off, and the optional ticket
# prefix comes from a +ticket:<prefix> flag.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [<mode> +ticket:sc] - <desc> (added <date>) -> <mode> off sc
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# A ticket prefix is part of a worker branch name, so it must be a bare token.
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# Keep bracket flags order-independent while refusing an unknown delivery mode
# rather than silently downgrading a local-only project to a pushing mode.
parsed=$(awk -v n="$NAME" '
  BEGIN { OFS="\037" }
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; ticket=""; modeset=""; misordered=""; unknown="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);
      k = split(s, a, " ");
      for (j=1; j<=k; j++) {
        if (a[j] == "no-mistakes" || a[j] == "direct-PR" || a[j] == "local-only" || a[j] == "no-mistakes-prod-only") {
          if (modeset == "") { mode=a[j]; modeset="1"; if (j != 1) misordered="1" } else unknown=unknown (unknown==""?"":" ") a[j];
        } else if (a[j] == "+yolo") yolo="on";
        else if (a[j] ~ /^\+ticket/) ticket=a[j];
        else unknown=unknown (unknown==""?"":" ") a[j];
      }
    }
    print mode, yolo, ticket, modeset, misordered, unknown; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

IFS=$'\037' read -r mode yolo ticket modeset misordered unknown <<EOF
$parsed
EOF
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "error: unknown mode \"$mode\" for $NAME; refusing to resolve a delivery mode" >&2; exit 3 ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
if [ -n "$misordered" ]; then
  echo "warn: mode \"$mode\" for $NAME follows the bracket flags; write it first as [$mode ...]" >&2
fi
if [ -n "$unknown" ]; then
  if [ -z "$modeset" ]; then
    echo "error: unknown mode or unrecognized bracket token(s) \"$unknown\" for $NAME; refusing rather than defaulting to the remote-pushing no-mistakes" >&2
    exit 3
  fi
  echo "warn: unrecognized bracket token(s) \"$unknown\" for $NAME" >&2
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
case "$ticket" in
  '') ;;
  +ticket:)
    echo "warn: malformed +ticket flag \"$ticket\" for $NAME; treating the project as ticketless" >&2
    ticket=
    ;;
  +ticket:*) ticket=${ticket#+ticket:} ;;
  +ticket*)
    echo "warn: malformed +ticket flag \"$ticket\" for $NAME; treating the project as ticketless" >&2
    ticket=
    ;;
  *)
    echo "warn: invalid +ticket prefix \"$ticket\" for $NAME; treating the project as ticketless" >&2
    ticket=
    ;;
esac
case "$ticket" in
  '') ;;
  [!A-Za-z]*|*[!A-Za-z0-9_-]*)
    echo "warn: invalid +ticket prefix \"$ticket\" for $NAME; treating the project as ticketless" >&2
    ticket=
    ;;
esac
if [ -n "$ticket" ]; then
  echo "$mode $yolo $ticket"
else
  echo "$mode $yolo"
fi
