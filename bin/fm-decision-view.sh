set -e
B=/Users/uayyagari/workspace/firstmate/data/backlog.md
OUT=/Users/uayyagari/workspace/firstmate/data/NEED_DECISION.md
{
printf '# Decisions waiting on the captain\n\n'
printf 'Generated %s from data/backlog.md - that backlog is the source of truth, this file is a readable view of it.\n' "$(date '+%Y-%m-%d %H:%M')"
printf 'Answer any item here in chat; firstmate records the answer against the item and it moves to Answered.\n\n## Open\n\n'
awk '/^## Done/{d=1} !d && /^- \[ \]/ && /hold-kind: captain/' "$B" | while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/^- \[ \] \([a-z0-9-]*\) .*/\1/p')
  title=$(printf '%s' "$line" | sed -n 's/^- \[ \] [a-z0-9-]* - \([^(]*\).*/\1/p')
  reason=$(printf '%s' "$line" | sed -n 's/.*(hold: \(.*\)) (hold-kind.*/\1/p')
  printf -- '- **%s**\n  - id: `%s`\n  - %s\n\n' "$title" "$id" "$reason"
done
printf '## Answered\n\n(none recorded yet - answered items are appended here with the decision and date)\n'
} > "$OUT"
wc -l < "$OUT"
# Append the PRs awaiting the captain's merge - decisions are not the only thing
# that waits on him, and a view that omits merges sends him back to chat.
{
printf '\n## Pull requests awaiting your merge\n\n'
found=0
for m in /Users/uayyagari/workspace/firstmate/state/*.meta; do
  [ -f "$m" ] || continue
  pr=$(sed -n 's/^pr=//p' "$m" | head -1)
  [ -n "$pr" ] || continue
  n=${pr##*/}; repo=$(printf '%s' "$pr" | sed -n 's#https://github.com/\([^/]*/[^/]*\)/pull/.*#\1#p')
  st=$(gh pr view "$n" -R "$repo" --json state,mergeable,mergedAt -q '.state + " " + .mergeable + " merged=" + (.mergedAt // "no")' 2>/dev/null)
  case "$st" in OPEN*) printf -- '- %s\n  - %s\n' "$pr" "$st"; found=1 ;; esac
done
[ "$found" = 1 ] || printf '(none open)\n'
} >> "$OUT"
