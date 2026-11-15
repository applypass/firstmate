#!/usr/bin/env bash
# Read-only gh shim: real GitHub reads; compare main...dev pinned to release #859's range;
# pr view body optionally replaced from $BODY_FILE; pr edit captured locally, never sent.
set -u
echo "gh $*" >> "$LAB/gh.log"
args=()
for a in "$@"; do
  case "$a" in -X|--method|-f|-F|--field|--raw-field|--input) echo "shim: refused write flag $a" >&2; exit 9;; esac
  args+=("${a/compare\/main...dev/compare/$CMP_RANGE}")
done
case "$1 ${2:-}" in
  "pr edit") shift 2; while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$LAB/edited.md"; shift; done; exit 0;;
esac
if [ "$1 ${2:-}" = "pr view" ] && [ "${3:-}" = "$REL_URL" ] && [ -n "${BODY_FILE:-}" ]; then
  # emulate --json body --jq '.body // ""' (and any other --jq) on a local body
  jqexpr=.; prev=; for a in "$@"; do [ "$prev" = --jq ] && jqexpr=$a; prev=$a; done
  jq -n --rawfile b "$BODY_FILE" '{body:$b,baseRefName:"main",headRefName:"dev"}' | jq -r "$jqexpr"; exit
fi
case "$1" in api|pr) ;; *) echo "shim: refused gh $1" >&2; exit 9;; esac
exec "$REAL_GH" "${args[@]}"
