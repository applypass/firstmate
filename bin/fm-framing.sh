#!/usr/bin/env bash
# Fork-only: fm-framing.sh - the framing list (eight questions asked before any solution) in one place (applypass fork).
#
# usage:
#   fm-framing.sh brief-block <fm-root>
#   fm-framing.sh ship-block <fm-root> <data-dir> <task-id>
#   fm-framing.sh check <report.md>
#   fm-framing.sh gate <report.md> <task-id>
#
# The eight labels live only in FRAMING_LABELS below, so the brief text and the
# check cannot drift apart. This is Gate 0 of the SDLC: research answers the
# eight questions before any solution, and each later review rejects work
# whose framing answers are missing.
#
# brief-block  prints the "# Framing" section for a scout brief (reviews
#          included): answer all eight in a "## Framing" section of the report,
#          one row per item for a review, or "Not applicable: <reason>" for a
#          pure data pull. It names the absolute check command under <fm-root>.
#          bin/fm-brief.sh appends it to every scout brief.
# ship-block  prints the short form (the eight labels on one line) for a ship
#          brief, and only when the home's data/decided.md has no approved
#          plan for the task: an entry "- [plan-<task-id>] <date> <text>" whose
#          text starts with approved:, small: or waived: (the plan gate in
#          bin/fm-task-ledger.sh reads the same entry). A ship with an
#          approved plan already passed Gate 0, so it gets nothing extra.
# check    reads headings and labels only, never meaning. It passes (exit 0,
#          no output) when the report's "## Framing" section, up to the next
#          "## " heading, holds one of:
#            - "Not applicable: <reason>" with at least 10 characters of reason;
#            - list form: every label as "Label: answer" (an optional bullet
#              and bold are fine; "Label - answer" works too);
#            - table form: a header row naming every label and at least one
#              row with no empty cell (one row per item in a review).
#          "unknown - <cheapest way to find out>" is a valid answer; a bare
#          "unknown" or an empty answer is not. It exits 1 naming each missing
#          label (or the missing section), and 2 on a usage error.
#          Limit: it proves the answers exist, not that they are right or that
#          every item of a review got a row.
# gate     the scout cleanup backstop (bin/fm-teardown.sh), mode from
#          FM_FRAMING_GATE:
#            warn (default)  prints "WARNING:" and the check message to stderr, exits 0;
#            fail            prints "REFUSED:" and the check message, exits 1;
#            off             skips the check, exits 0.
#          Any other value exits 2.
#
# Callers: bin/fm-brief.sh (brief-block, ship-block), bin/fm-teardown.sh (gate),
# and the worker, who runs check before reporting done. tests/lib.sh sets
# FM_FRAMING_GATE=off for fixtures. docs/configuration.md "Framing gate" owns the
# operator view.
set -u

FRAMING_LABELS=(
  "Five whys"
  "Need"
  "Who and how many"
  "How often"
  "Manual vs automated ROI"
  "Product change"
  "Non-code way"
  "Metric owner"
)

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# labels_joined <separator>: the labels joined by the separator.
labels_joined() {
  local sep=$1 out='' l
  for l in "${FRAMING_LABELS[@]}"; do
    out="${out:+$out$sep}$l"
  done
  printf '%s' "$out"
}

cmd_brief_block() {
  local root=${1:-}
  [ -n "$root" ] || { echo "fm-framing.sh: brief-block needs <fm-root>" >&2; return 2; }
  printf '\n# Framing\n'
  printf 'Before naming any solution, answer these in a `## Framing` section of your report, with evidence:\n'
  printf '%s.\n' "$(labels_joined ', ')"
  printf 'Write each as `Label: answer`; "unknown - <cheapest way to find out>" counts, an empty answer does not.\n'
  printf 'If you review a plan, page, or set of items, answer them for each item (one row per item, one column per label).\n'
  printf 'If the task is a pure data pull, write `Not applicable: <reason>` instead.\n'
  printf 'Run `%s/bin/fm-framing.sh check <your report>` before you report done.\n' "$root"
}

# plan_approved <data-dir> <task-id>: 0 when decided.md holds an approved plan for the task.
plan_approved() {
  local decided="$1/decided.md" text
  [ -f "$decided" ] || return 1
  text=$(FM_KEY="plan-$2" awk '
    BEGIN { p = "- [" ENVIRON["FM_KEY"] "] " }
    index($0, p) == 1 { print substr($0, length(p) + 12); exit }
  ' "$decided")
  case "$text" in approved:* | small:* | waived:*) return 0 ;; esac
  return 1
}

cmd_ship_block() {
  [ $# -eq 3 ] || { echo "fm-framing.sh: ship-block needs <fm-root> <data-dir> <task-id>" >&2; return 2; }
  plan_approved "$2" "$3" && return 0
  printf '\n# Framing\n'
  printf 'This task has no approved plan. Before building, answer these from evidence in your first status or plan:\n'
  printf '%s.\n' "$(labels_joined ', ')"
  printf 'If the evidence shows the work is not needed, or a smaller change removes the need, stop and report that.\n'
}

# check_report <report>: prints OK, NOSECTION, TABLE, or MISSING:<labels, comma-joined>.
check_report() {
  awk -v labels="$(labels_joined '|')" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function empty_answer(a,   t) {
      t = tolower(trim(a))
      sub(/[ \t]*[-:.]*[ \t]*$/, "", t)
      return t == "" || t == "unknown"
    }
    BEGIN { n = split(labels, L, "|") }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^##[ \t]/) {
        if (tolower(line) ~ /^##[ \t]+framing([ \t:].*)?$/) { insec = 1; found = 1; next }
        insec = 0
      }
      if (!insec) next
      plain = trim(line)
      sub(/^[-*+][ \t]+/, "", plain)
      gsub(/\*\*/, "", plain)
      if (plain == "") next

      if (tolower(substr(plain, 1, 15)) == "not applicable:") {
        if (length(trim(substr(plain, 16))) >= 10) optout = 1
        next
      }

      if (plain ~ /^\|/) {
        if (!hdr) {
          low = tolower(plain)
          ok = 1
          for (i = 1; i <= n; i++) if (index(low, tolower(L[i])) == 0) ok = 0
          if (ok) hdr = 1
          next
        }
        if (plain ~ /^\|[ \t:|-]+$/) next
        m = split(plain, C, "|")
        last = (plain ~ /\|[ \t]*$/) ? m - 1 : m
        good = (last - 1 >= n)
        for (i = 2; i <= last; i++) if (trim(C[i]) == "") good = 0
        if (good) tableok = 1
        next
      }

      for (i = 1; i <= n; i++) {
        len = length(L[i])
        if (tolower(substr(plain, 1, len)) != tolower(L[i])) continue
        rest = substr(plain, len + 1)
        if (rest ~ /^[ \t]*:/) ans = substr(rest, index(rest, ":") + 1)
        else if (rest ~ /^[ \t]+-[ \t]/) ans = substr(rest, index(rest, "-") + 1)
        else continue
        if (!empty_answer(ans)) got[i] = 1
      }
    }
    END {
      if (!found) { print "NOSECTION"; exit }
      if (optout || tableok) { print "OK"; exit }
      miss = ""; anygot = 0
      for (i = 1; i <= n; i++) {
        if (got[i]) anygot = 1
        else miss = miss (miss == "" ? "" : ", ") L[i]
      }
      if (miss == "") { print "OK"; exit }
      if (hdr && !anygot) { print "TABLE"; exit }
      print "MISSING:" miss
    }
  ' "$1"
}

cmd_check() {
  local report=${1:-} res hint
  [ $# -eq 1 ] || { echo "fm-framing.sh: check needs <report.md>" >&2; return 2; }
  [ -f "$report" ] || { echo "fm-framing.sh: no such report: $report" >&2; return 2; }
  res=$(check_report "$report")
  hint='Add a labelled answer for each (use "unknown - <cheapest way to find out>" if you cannot answer), or write "Not applicable: <reason>" under ## Framing. (bin/fm-framing.sh)'
  case "$res" in
    OK) return 0 ;;
    NOSECTION)
      printf 'framing check: %s has no ## Framing section\n%s\n' "$report" "$hint" >&2 ;;
    TABLE)
      printf 'framing check: %s has a ## Framing table with no row that fills every cell\n%s\n' "$report" "$hint" >&2 ;;
    MISSING:*)
      printf 'framing check: %s is missing ## Framing answers: %s\n%s\n' "$report" "${res#MISSING:}" "$hint" >&2 ;;
    *)
      echo "fm-framing.sh: unexpected check result: $res" >&2; return 2 ;;
  esac
  return 1
}

cmd_gate() {
  local report=${1:-} id=${2:-} mode msg rc
  [ $# -eq 2 ] || { echo "fm-framing.sh: gate needs <report.md> <task-id>" >&2; return 2; }
  mode=${FM_FRAMING_GATE:-warn}
  case "$mode" in
    off) return 0 ;;
    warn | fail) ;;
    *) echo "fm-framing.sh: FM_FRAMING_GATE must be warn, fail, or off (got: $mode)" >&2; return 2 ;;
  esac
  msg=$(cmd_check "$report" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 2 ]; then
    printf '%s\n' "$msg" >&2
    return 2
  fi
  if [ "$mode" = fail ]; then
    printf 'REFUSED: scout task %s report lacks framing answers.\n%s\n' "$id" "$msg" >&2
    return 1
  fi
  printf 'WARNING: scout task %s report lacks framing answers (FM_FRAMING_GATE=warn; set fail to refuse).\n%s\n' "$id" "$msg" >&2
  return 0
}

case "${1:-}" in
  brief-block) shift; cmd_brief_block "$@" ;;
  ship-block) shift; cmd_ship_block "$@" ;;
  check) shift; cmd_check "$@" ;;
  gate) shift; cmd_gate "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac
