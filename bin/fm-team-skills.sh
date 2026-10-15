#!/usr/bin/env bash
# Fork-only: fm-team-skills.sh - links the team-skills/ set into the skills folders agent tools read.
#
# usage: fm-team-skills.sh [--dry-run] install|uninstall
#
# For each team-skills/<name> directory that holds a SKILL.md, install creates a
# symlink "<name>" in both $HOME/.claude/skills and $HOME/.agents/skills (made if
# missing) pointing at this clone's directory. Because the links point into the
# clone, a git pull updates every skill in place.
# install never overwrites anything: a path that already exists as a real file or
# directory, or as a link pointing elsewhere, is skipped and listed under
# "Conflicts" at the end. A link that already points at this clone is left alone,
# so install is idempotent.
# uninstall removes only links that point at this clone's team-skills/<name>;
# anything else at that path stays.
# --dry-run prints what would happen and changes nothing.
# Exit status: 0 when done (conflicts are reported, not an error), 2 on bad usage.
set -u

DRY=0
CMD=""

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    install|uninstall) CMD=$arg ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-team-skills: unknown argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$CMD" ] || { usage >&2; exit 2; }

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../team-skills" 2>/dev/null && pwd -P) || {
  echo "fm-team-skills: team-skills/ not found next to bin/" >&2; exit 2; }
[ -n "${HOME:-}" ] || { echo "fm-team-skills: HOME is not set" >&2; exit 2; }

TARGETS=("$HOME/.claude/skills" "$HOME/.agents/skills")
conflicts=()
linked=0 kept=0 removed=0

say() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else echo "$*"; fi; }

for src in "$SRC_ROOT"/*/; do
  src=${src%/}
  [ -f "$src/SKILL.md" ] || continue
  name=$(basename "$src")
  for tdir in "${TARGETS[@]}"; do
    dest="$tdir/$name"
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
      owned=1
    else
      owned=0
    fi
    if [ "$CMD" = install ]; then
      if [ "$owned" = 1 ]; then
        kept=$((kept + 1)); continue
      fi
      if [ -e "$dest" ] || [ -L "$dest" ]; then
        if [ -L "$dest" ]; then
          conflicts+=("$dest (link to $(readlink "$dest"))")
        else
          conflicts+=("$dest (existing file or directory)")
        fi
        continue
      fi
      say "link $dest -> $src"
      if [ "$DRY" = 0 ]; then
        if ! mkdir -p "$tdir" || ! ln -s "$src" "$dest"; then
          echo "fm-team-skills: could not link $dest" >&2; continue
        fi
      fi
      linked=$((linked + 1))
    else
      if [ "$owned" = 1 ]; then
        say "remove $dest"
        [ "$DRY" = 1 ] || rm "$dest"
        removed=$((removed + 1))
      fi
    fi
  done
done

if [ "$CMD" = install ]; then
  if [ "$DRY" = 1 ]; then verb="Would install"; else verb="Installed"; fi
  echo "$verb: $linked new link(s), $kept already in place."
  if [ "${#conflicts[@]}" -gt 0 ]; then
    echo "Conflicts (skipped, left untouched): ${#conflicts[@]}"
    for c in "${conflicts[@]}"; do echo "  - $c"; done
    echo "Move or remove those paths yourself, then run install again."
  fi
else
  if [ "$DRY" = 1 ]; then verb="Would remove"; else verb="Removed"; fi
  echo "$verb: $removed link(s). Links not created by this script were left alone."
fi
exit 0
