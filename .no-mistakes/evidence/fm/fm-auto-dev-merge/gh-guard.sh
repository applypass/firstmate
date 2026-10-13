#!/usr/bin/env bash
# Read-only guard around the real gh: blocks every write; optionally rewrites
# the PR view (base and checks) to stand in for a PR to dev.
REAL=/Users/uayyagari/.asdf/shims/gh
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in "pr merge"|"pr edit"|"pr close"|"pr ready"|"pr comment"|"pr review") echo "gh-guard: blocked write: $*" >&2; exit 97;; esac
for a in "$@"; do case "$a" in -X|--method|-f|-F|--field|--raw-field) echo "gh-guard: blocked api write: $*" >&2; exit 97;; esac; done
if [ "$1 $2" = "pr view" ] && [ -n "${GH_FAKE_BASE:-}" ] && [[ "$*" == *baseRefName* ]]; then
  "$REAL" "$@" | jq -c --arg b "$GH_FAKE_BASE" '(if has("baseRefName") then .baseRefName=$b else . end)
    | (if has("statusCheckRollup") then .statusCheckRollup=[{"__typename":"CheckRun","name":"vercel-preview","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-10-13T00:00:00Z"}] else . end)'
  exit ${PIPESTATUS[0]}
fi
exec "$REAL" "$@"
