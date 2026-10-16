#!/usr/bin/env bash
# Fork-only: fm-team-skills.sh - links the team-skills/ set into the skills folders agent tools read.
#
# usage: fm-team-skills.sh [--dry-run] install|uninstall
#        fm-team-skills.sh [--dry-run] hooks enable|disable|status
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
#
# hooks enable|disable|status manages the opt-in explain-with-example hooks from
# team-skills/hooks/ (a UserPromptSubmit reminder and the Stop hook that backs it).
# They are off by default and install/uninstall never touch settings. enable adds
# exactly those two entries to $CLAUDE_CONFIG_DIR/settings.json (default
# $HOME/.claude/settings.json), pointing at this clone; disable removes only entries
# whose command is one of those two scripts; every other key and hook is kept.
# Both are idempotent (no write when nothing changes), copy the file to
# settings.json.bak-<time> before a change, write through a symlinked settings file
# without replacing the link, and refuse (exit 1, file untouched) when the file is
# not a JSON object with an object "hooks" of arrays. Needs jq (the hook uses it too).
# status prints whether each hook is on. --dry-run reports without writing.
# Exit status: 0 when done (conflicts are reported, not an error), 1 when a link
# could not be created or removed (listed under "Failed" after the summary), 2 on
# bad usage.
set -u

DRY=0
CMD=""
SUB=""

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    install|uninstall|hooks) CMD=$arg ;;
    enable|disable|status)
      if [ "$CMD" = hooks ]; then SUB=$arg
      else echo "fm-team-skills: unknown argument '$arg'" >&2; usage >&2; exit 2; fi ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-team-skills: unknown argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$CMD" ] || { usage >&2; exit 2; }
[ "$CMD" != hooks ] || [ -n "$SUB" ] || { usage >&2; exit 2; }

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../team-skills" 2>/dev/null && pwd -P) || {
  echo "fm-team-skills: team-skills/ not found next to bin/" >&2; exit 2; }
[ -n "${HOME:-}" ] || { echo "fm-team-skills: HOME is not set" >&2; exit 2; }

# --- hooks enable|disable|status -------------------------------------------
# name:event:timeout for each hook in team-skills/hooks/.
HOOK_SPECS=("explain-with-example.sh:UserPromptSubmit:5" "no-raw-diagrams.py:Stop:10")

# jq: true when a hook entry runs team-skills/hooks/<name> (in any clone).
# shellcheck disable=SC2016 # jq program, not shell
JQ_OURS='def ours($n): (.command // "") | type == "string" and contains("/team-skills/hooks/" + $n);'

hooks_main() {
  local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  command -v jq >/dev/null 2>&1 || { echo "fm-team-skills: hooks needs jq on PATH" >&2; exit 1; }
  local cur="{}"
  if [ -e "$settings" ]; then
    cur=$(cat "$settings") || { echo "fm-team-skills: cannot read $settings" >&2; exit 1; }
  fi
  if ! printf '%s' "$cur" | jq -e 'type == "object" and ((.hooks // {}) | type == "object") and all((.hooks // {})[]; type == "array")' >/dev/null 2>&1; then
    echo "fm-team-skills: $settings is not a JSON object with an object \"hooks\" of arrays; refusing to touch it" >&2
    exit 1
  fi
  local spec name event timeout cmd next="$cur" present total=0 on=0
  for spec in "${HOOK_SPECS[@]}"; do
    IFS=: read -r name event timeout <<<"$spec"
    present=$(printf '%s' "$cur" | jq -r --arg n "$name" --arg e "$event" "$JQ_OURS"' [(.hooks[$e] // [])[].hooks[]? | select(ours($n))] | length')
    total=$((total + 1)); [ "$present" -gt 0 ] && on=$((on + 1))
    case "$SUB" in
      status) if [ "$present" -gt 0 ]; then echo "$name ($event): on"; else echo "$name ($event): off"; fi ;;
      enable)
        [ -f "$SRC_ROOT/hooks/$name" ] || { echo "fm-team-skills: missing $SRC_ROOT/hooks/$name" >&2; exit 1; }
        cmd=$SRC_ROOT/hooks/$name
        case "$cmd" in *[!A-Za-z0-9_./-]*) cmd="'$cmd'" ;; esac
        next=$(printf '%s' "$next" | jq --arg n "$name" --arg e "$event" --arg c "$cmd" --argjson t "$timeout" "$JQ_OURS"'
          if ((.hooks[$e] // []) | any(.[]?; (.hooks // []) | any(ours($n))))
          then .hooks[$e] |= map(.hooks |= map(if ours($n) then .command = $c else . end))
          else .hooks[$e] = ((.hooks[$e] // []) + [{hooks: [{type: "command", command: $c, timeout: $t}]}])
          end') || exit 1 ;;
      disable)
        next=$(printf '%s' "$next" | jq --arg n "$name" --arg e "$event" "$JQ_OURS"'
          if ((.hooks[$e] // []) | any(.[]?; (.hooks // []) | any(ours($n)))) then
            .hooks[$e] |= [.[] | if ((.hooks // []) | any(ours($n))) then (.hooks |= map(select(ours($n) | not))) | select(.hooks | length > 0) else . end]
            | if (.hooks[$e] | length) == 0 then del(.hooks[$e]) else . end
            | if (.hooks | length) == 0 then del(.hooks) else . end
          else . end') || exit 1 ;;
    esac
  done
  [ "$SUB" != status ] || { echo "Settings file: $settings"; return 0; }
  if [ "$(printf '%s' "$cur" | jq -cS .)" = "$(printf '%s' "$next" | jq -cS .)" ]; then
    echo "Hooks already ${SUB}d in $settings; nothing to change."; return 0
  fi
  if [ "$DRY" = 1 ]; then say "$SUB hooks in $settings"; return 0; fi
  mkdir -p "$(dirname "$settings")" || exit 1
  if [ -e "$settings" ]; then
    local bak; bak="$settings.bak-$(date +%Y%m%d%H%M%S)-$$"
    cp -p "$settings" "$bak" || { echo "fm-team-skills: could not back up $settings" >&2; exit 1; }
    echo "Backup: $bak"
  fi
  # Write through the path so a symlinked settings file stays a symlink.
  [ -n "$next" ] || { echo "fm-team-skills: internal error, empty result; $settings untouched" >&2; exit 1; }
  local out; out=$(printf '%s\n' "$next" | jq .) || { echo "fm-team-skills: internal error, invalid result; $settings untouched" >&2; exit 1; }
  printf '%s\n' "$out" > "$settings" || { echo "fm-team-skills: write to $settings failed; restore from the backup" >&2; exit 1; }
  if [ "$SUB" = enable ]; then
    chmod +x "$SRC_ROOT"/hooks/* 2>/dev/null
    command -v python3 >/dev/null 2>&1 || echo "Warning: python3 not found; the Stop hook needs it." >&2
  fi
  echo "Hooks ${SUB}d in $settings."
}


TARGETS=("$HOME/.claude/skills" "$HOME/.agents/skills")
conflicts=()
failures=()
linked=0 kept=0 removed=0

say() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else echo "$*"; fi; }

if [ "$CMD" = hooks ]; then hooks_main; exit 0; fi

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
          failures+=("link $dest"); continue
        fi
      fi
      linked=$((linked + 1))
    else
      if [ "$owned" = 1 ]; then
        say "remove $dest"
        if [ "$DRY" = 1 ] || rm "$dest"; then
          removed=$((removed + 1))
        else
          failures+=("remove $dest")
        fi
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
if [ "${#failures[@]}" -gt 0 ]; then
  echo "Failed: ${#failures[@]}" >&2
  for f in "${failures[@]}"; do echo "  - $f" >&2; done
  exit 1
fi
exit 0
