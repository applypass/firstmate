#!/usr/bin/env bash
# Lint then render a Mermaid file to PNG: render.sh diagram.mmd [out.png]
# Fails before rendering on the label mistakes that silently cut text.
set -euo pipefail
in="$1"; out="${2:-${in%.mmd}.png}"
bad=0
if grep -nE '#[0-9A-Za-z]' "$in" | grep -vE '^[0-9]+:\s*(classDef|style|%%)'; then
  echo "render.sh: '#' cuts Mermaid labels; write 'PR 705', not '#705'" >&2; bad=1; fi
if head -1 "$in" | grep -q sequenceDiagram && grep -nE ':.*;' "$in"; then
  echo "render.sh: ';' splits a sequence-diagram line; use ' - '" >&2; bad=1; fi
if head -1 "$in" | grep -q sequenceDiagram && grep -niE '<br\s*/?>' "$in"; then
  echo "render.sh: <br/> is not supported in sequence messages" >&2; bad=1; fi
[ "$bad" = 0 ] || exit 1
npx -y -p @mermaid-js/mermaid-cli@11 mmdc -i "$in" -o "$out" -w 1600 -s 2 -b white >/dev/null
echo "$out  <- now Read this PNG and check every label before sharing it"
