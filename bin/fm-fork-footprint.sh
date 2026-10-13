#!/usr/bin/env bash
# Fork-only: fm-fork-footprint.sh - keeps the applypass fork easy to resync with kunchenguid/firstmate.
#
# usage: fm-fork-footprint.sh [--base REF] [--upstream REF] [--ledger FILE] [--max-block N] [--fetch] [--soft]
#
# Lists the files of the current branch (HEAD vs --base) that also exist in the
# upstream ref and checks how they changed. An upstream file passes when it is on
# the fork ledger (.fork/ledger.md, one "- `path` - reason" line per file) or when
# every change to it is a pure addition inside a Fork-only block:
#   - the block's first added line carries the marker "Fork-only" in a comment;
#   - an optional last line carrying "Fork-only end" closes it, otherwise the
#     block is the whole contiguous run of added lines;
#   - it holds at most --max-block lines (default 40);
#   - no upstream line is deleted or rewritten.
# Files that do not exist upstream are fork-only and always pass.
# Any other change to an upstream file exits 1 and names the file and line.
# The summary section "Fork footprint vs upstream main" is meant to be pasted into
# PR bodies. --fetch refreshes the upstream ref first (CI uses it).
# --soft turns a missing upstream or base ref into a warning and exit 0, for the
# no-mistakes lint step on a clone that has no upstream remote; CI never uses it.
# Defaults: --base origin/main (else main), --upstream upstream/main.
set -u

BASE=""
UPSTREAM="upstream/main"
LEDGER=""
MAX_BLOCK=40
FETCH=0
SOFT=0

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE=${2:?--base needs a ref}; shift 2 ;;
    --upstream) UPSTREAM=${2:?--upstream needs a ref}; shift 2 ;;
    --ledger) LEDGER=${2:?--ledger needs a file}; shift 2 ;;
    --max-block) MAX_BLOCK=${2:?--max-block needs a number}; shift 2 ;;
    --fetch) FETCH=1; shift ;;
    --soft) SOFT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-fork-footprint: unknown argument: $1" >&2; exit 2 ;;
  esac
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "fm-fork-footprint: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
[ -n "$LEDGER" ] || LEDGER=.fork/ledger.md

if [ "$FETCH" = 1 ] && [ "${UPSTREAM%%/*}" != "$UPSTREAM" ]; then
  git fetch --quiet "${UPSTREAM%%/*}" "${UPSTREAM#*/}" 2>/dev/null \
    || echo "fm-fork-footprint: warning: could not fetch $UPSTREAM; using the local ref" >&2
fi
if ! git rev-parse --verify --quiet "$UPSTREAM^{commit}" >/dev/null; then
  echo "fm-fork-footprint: upstream ref '$UPSTREAM' not found (git remote add upstream https://github.com/kunchenguid/firstmate; git fetch upstream)" >&2
  if [ "$SOFT" = 1 ]; then echo "fm-fork-footprint: --soft: skipping the footprint check" >&2; exit 0; fi
  exit 2
fi
if [ -z "$BASE" ]; then
  for c in origin/main main; do
    if git rev-parse --verify --quiet "$c^{commit}" >/dev/null; then BASE=$c; break; fi
  done
fi
if [ -z "$BASE" ] || ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  echo "fm-fork-footprint: base ref not found" >&2
  exit 2
fi

# ledger: path -> reason, from "- `path` - reason" lines
ledger_paths=""
if [ -f "$LEDGER" ]; then
  # shellcheck disable=SC2016 # the backticks are literal ledger syntax
  ledger_paths=$(sed -n 's/^- `\([^`]*\)` - .\{1,\}$/\1/p' "$LEDGER")
fi
on_ledger() { printf '%s\n' "$ledger_paths" | grep -Fxq -- "$1"; }

# upstream files this branch changed (rename detection off so a move shows as delete+add)
changed=$(git diff --no-renames --name-only "$BASE"...HEAD)

violations=0
touched=0
pr_add=0
pr_del=0
report=""

check_file() {
  local f=$1
  # awk walks the zero-context diff; prints "line: reason" for each violation
  git diff --no-renames -U0 "$BASE"...HEAD -- "$f" | awk -v max="$MAX_BLOCK" '
    function flush(   bad) {
      if (n == 0 && dels == 0) return
      if (dels > 0) { print start ": removes or rewrites " dels " upstream line(s)"; }
      else {
        if (first !~ /Fork-only/) print start ": added lines are not opened by a Fork-only marker comment"
        else if (n > max) print start ": Fork-only block is " n " lines (max " max ")"
        else if (endat > 0 && endat != n) print start + endat - 1 ": text after the Fork-only end marker is outside any block"
      }
      n = 0; dels = 0; endat = 0
    }
    /^@@/ {
      flush(); seen = 1
      split($0, h, " "); p = h[3]; sub(/^\+/, "", p); split(p, q, ","); start = q[1] + 0
      d = h[2]; sub(/^-/, "", d); split(d, r, ","); dels = (r[2] == "" ? 1 : r[2] + 0); n = 0; first = ""
      next
    }
    !seen { next }
    /^\+/ { n++; if (n == 1) first = substr($0, 2); if ($0 ~ /Fork-only end/) endat = n; next }
    END { flush() }
  '
}

while IFS= read -r f; do
  [ -n "$f" ] || continue
  git cat-file -e "$UPSTREAM:$f" 2>/dev/null || continue
  touched=$((touched + 1))
  read -r a d _ < <(git diff --no-renames --numstat "$BASE"...HEAD -- "$f")
  case "$a" in ''|-) a=0 ;; esac
  case "$d" in ''|-) d=0 ;; esac
  pr_add=$((pr_add + a)); pr_del=$((pr_del + d))
  if on_ledger "$f"; then
    report="$report- $f (+$a/-$d): on the fork ledger"$'\n'
    continue
  fi
  out=$(check_file "$f")
  if [ -z "$out" ]; then
    report="$report- $f (+$a/-$d): Fork-only block"$'\n'
  else
    violations=$((violations + 1))
    report="$report- $f (+$a/-$d): NOT ALLOWED"$'\n'
    while IFS= read -r l; do
      printf 'fm-fork-footprint: %s:%s\n' "$f" "$l" >&2
    done <<< "$out"
  fi
done <<< "$changed"

# whole-fork footprint vs upstream main
read -r tot_files tot_add tot_del < <(
  git diff --no-renames --numstat "$UPSTREAM"..."${BASE}" 2>/dev/null | awk '
    { files++; if ($1 != "-") a += $1; if ($2 != "-") d += $2 } END { print files + 0, a + 0, d + 0 }')
up_total=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  git cat-file -e "$UPSTREAM:$f" 2>/dev/null && up_total=$((up_total + 1))
done < <(git diff --no-renames --name-only "$UPSTREAM"..."$BASE")

echo "## Fork footprint vs upstream main"
echo
echo "- Upstream files touched by this change: $touched (+$pr_add/-$pr_del lines)"
if [ -n "$report" ]; then printf '%s' "$report" | sed 's/^/  /'; fi
echo "- Upstream files the fork already modifies on $BASE: $up_total of $tot_files changed files (+$tot_add/-$tot_del lines, includes fork-only files)"
if [ "$violations" -gt 0 ]; then
  echo "- Result: FAIL, $violations upstream file(s) changed outside a Fork-only block"
  echo "  Fix: move the behaviour into a fork-only file, or wrap the addition in a short '# Fork-only:' block."
  echo "  Last resort: add \"- \`path\` - reason\" to $LEDGER."
  exit 1
fi
echo "- Result: ok"
