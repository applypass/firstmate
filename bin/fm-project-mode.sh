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
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   local-only   local branch, no remote/PR -> captain approve -> guarded local merge
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
# ticket (orthogonal) = the project mandates a tracker ticket per change, and
#   <prefix> is the tracker's id prefix. It drives the crew branch and PR-title
#   convention owned by bin/fm-brief.sh: branch <prefix>-<ticket-id>-<slug> and
#   PR title prefix "<prefix>-<ticket-id>: ". Absent means ticketless work, which
#   branches <type>/<slug> with a "<type>: " title prefix instead.
#   A prefix must be a bare token ([A-Za-z][A-Za-z0-9_-]*) because it becomes part
#   of a git branch name; anything else is warned about and dropped to ticketless.
#   A malformed flag that carries no prefix at all ("+ticket" or "+ticket:") warns
#   the same way, so an operator typo never silently reads as a ticketless project.
#
# The third word is emitted only for a ticket-mandated project, so callers that
# read only "<mode> <yolo>" are unaffected. A caller that wants the prefix reads a
# third field, which stays empty for a ticketless project.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate. An unknown mode discards the
# whole bracket, ticket prefix included, because nothing in it can be trusted.
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

# awk emits "<mode> <yolo> <ticket-flag>" (one line, the flag token verbatim and
# empty when no +ticket flag is present) or nothing if the project is absent.
# The flag is matched without its colon so a malformed one still reaches the
# shell's validation instead of being dropped as if it were never written.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; ticket="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] !~ /^\+/) mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        else if (a[j] ~ /^\+ticket/) ticket = a[j];
      }
    }
    print mode, yolo, ticket; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

read -r mode yolo ticket <<EOF
$parsed
EOF
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off; ticket= ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# The prefix becomes part of a branch name and a PR title, so reject anything
# that is not a bare token rather than scaffolding an unusable branch rule.
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
