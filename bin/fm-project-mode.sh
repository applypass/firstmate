#!/usr/bin/env bash
# Resolve a project's delivery mode, yolo flag, and ticket prefix from the
# data/projects.md registry.
# Prints "<mode> <yolo>" to stdout, plus a third word "<ticket-prefix>" when the
# project carries the +ticket:<prefix> flag. Mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                       -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)               -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)         -> <mode> on
#   - <name> [<mode> +ticket:sc] - <desc> (added <date>)    -> <mode> off sc
# The bracket flags are additive and order-independent, so
# "[direct-PR +yolo +ticket:sc]" sets both.
# The mode belongs first. A mode written after the flags is still honored, but it
# warns, because silently dropping it would resolve a local-only project to the
# remote-pushing default. Any other unrecognized bracket token warns too.
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   local-only   local branch, no remote/PR -> captain approve -> guarded local merge
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
# ticket (orthogonal) = the project mandates a tracker ticket per change; <prefix>
#   is the tracker's id prefix, which bin/fm-brief.sh puts in the crew branch name
#   (<prefix>-<ticket-id>-<slug>) for the tracker to auto-link. The prefix must be a
#   bare token ([A-Za-z][A-Za-z0-9_-]*) since it becomes part of a branch name; an
#   invalid or prefixless flag warns and drops the project to ticketless.
#
# The third word is emitted only for a ticket-mandated project, so callers that
# read only "<mode> <yolo>" are unaffected. A caller that wants the prefix reads a
# third field, which stays empty for a ticketless project.
#
# An unknown or missing project falls back to "no-mistakes off" and warns to
# stderr. An unrecognized mode NAME in a registered bracket instead REFUSES: it
# prints an error and exits non-zero (3) with no stdout, because defaulting a
# typo to the remote-pushing "no-mistakes" could push a project the captain meant
# to keep local. Callers must fail closed on that non-zero exit rather than treat
# an empty result as the default mode.
# Usage: fm-project-mode.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-mode.sh <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode> <yolo> <ticket-flag> <modeset> <unknown>" on one line (empty
# fields kept), joined with a unit separator so `read` does not fold an empty field
# into its successor. <unknown> collects any bracket token that is neither the
# position-1 mode nor a recognized flag, so the shell can rescue a misordered mode
# and warn about the rest; <modeset> is set when the mode came from position 1.
parsed=$(awk -v n="$NAME" '
  BEGIN { OFS="\037" }
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; ticket=""; modeset=""; unknown="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] !~ /^\+/) { mode = a[1]; modeset = "1" }
      for (j=1; j<=k; j++) {
        if (j==1 && modeset != "") continue;
        if (a[j]=="+yolo") yolo="on";
        else if (a[j] ~ /^\+ticket/) ticket = a[j];
        else unknown = unknown (unknown==""?"":" ") a[j];
      }
    }
    print mode, yolo, ticket, modeset, unknown; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

IFS=$'\037' read -r mode yolo ticket modeset unknown <<EOF
$parsed
EOF
# A mode written after the flags would otherwise be discarded in silence, and
# the discard resolves to the remote-pushing default - so rescue it and warn.
# Whatever is left is an operator typo and warns the way an unknown mode does.
rest=
set -f                                  # a stray token must never glob the cwd
for token in $unknown; do
  if [ -z "$modeset" ]; then
    case "$token" in
      no-mistakes|direct-PR|local-only)
        echo "warn: mode \"$token\" for $NAME follows the bracket flags; write it first as [$token ...]" >&2
        mode=$token
        modeset=1
        continue
        ;;
    esac
  fi
  rest="${rest:+$rest }$token"
done
set +f
if [ -n "$rest" ]; then
  if [ -z "$modeset" ]; then
    echo "error: unrecognized bracket token(s) \"$rest\" for $NAME with no valid mode in position 1; refusing rather than defaulting to the remote-pushing no-mistakes - a mistyped mode written after the flags must not silently push a project meant to stay local. Write the mode first as [<mode> ...]." >&2
    exit 3
  fi
  echo "warn: unrecognized bracket token(s) \"$rest\" for $NAME; expected the mode first, then +yolo or +ticket:<prefix>" >&2
fi
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "error: unknown mode \"$mode\" for $NAME; refusing to resolve a delivery mode - fix the bracket in the registry. A typo must not silently become the remote-pushing default and push a project meant to stay local." >&2; exit 3 ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# The prefix becomes part of a branch name, so reject anything that is not a bare
# token rather than scaffolding an unusable branch rule.
# A flag that carries no prefix at all is the same operator typo, so it warns too
# instead of reading as a deliberately ticketless project.
case "$ticket" in
  "") ;;
  +ticket:?*)
    ticket=${ticket#+ticket:}
    case "$ticket" in
      *[!A-Za-z0-9_-]*|[!A-Za-z]*)
        echo "warn: invalid +ticket prefix \"$ticket\" for $NAME; treating the project as ticketless" >&2
        ticket=
        ;;
    esac
    ;;
  *)
    echo "warn: malformed +ticket flag \"$ticket\" for $NAME; expected +ticket:<prefix>, treating the project as ticketless" >&2
    ticket=
    ;;
esac
if [ -n "$ticket" ]; then
  echo "$mode $yolo $ticket"
else
  echo "$mode $yolo"
fi
