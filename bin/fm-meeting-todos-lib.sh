#!/usr/bin/env bash
# Fork-only: parser, validator and write-back helpers for the meeting to-do record
# (data/meeting-todos/<YYYY-MM-DD>.md). Sourced by bin/fm-meeting-todos-sync.sh; docs/configuration.md
# "Meeting to-do record (fork)" owns the format.
#
# Format, one section per meeting:
#   ## <meeting title> - Krisp <meeting id> <krisp link> [| doc <doc id> <content hash>]
#   > <summary line 1>
#   > <summary line 2>            (one or two summary lines)
#   | # | Task | Owner | Story | Scope | Deadline | Status | Quote |
#   |---|---|---|---|---|---|---|---|
#   | 1 | ... | ... | sc-NNNN or empty | today|week|later | YYYY-MM-DD [(moved: why)] | open|done|dropped|moved | "words" @mm:ss |
# Scope later = a soft or undated to-do: placeholder Deadline two weeks after the meeting date; a later
# transcript that states a timing sets the real date with (moved: <why>) and may change the scope.
# A cell never holds a '|'. The file name is the meeting date. The sync script writes the Story
# cell and the heading's doc suffix; everything else is the firstmate's record.
#
# Functions (all print to stdout; errors go to stderr):
#   fm_mt_validate <file>           exit 0 when the record is well formed, else 1 with one "file:line: problem" per line
#   fm_mt_records <file>            one record per line, fields separated by US (0x1f):
#                                   S idx title meeting-id link doc-id doc-hash summary1 summary2 heading-line
#                                   R section line num task owner story scope date reason status quote
#   fm_mt_set_story <file> <line> <sc-NNNN>   write the Story cell of the row on <line>
#   fm_mt_set_doc <file> <line> <id> <hash>   write the doc suffix of the heading on <line>
#   fm_mt_doc_title <YYYY-MM-DD>    'Standup Wed 4 Nov - agreed to-dos'

# One awk program serves validation (MODE=check) and parsing (MODE=records), so the two cannot drift.
# shellcheck disable=SC2016 # awk program text, no shell expansion wanted
FM_MT_AWK='
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function days(y, m, d,   yy, era, yoe, mm, doy, doe) {
  yy = y; if (m <= 2) yy--
  era = int(yy / 400); yoe = yy - era * 400
  mm = m + (m > 2 ? -3 : 9)
  doy = int((153 * mm + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}
function civil(z,   era, doe, yoe, y, doy, mp, d, m) {
  z += 719468
  era = int(z / 146097); doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153)
  d = doy - int((153 * mp + 2) / 5) + 1
  m = mp + (mp < 10 ? 3 : -9)
  if (m <= 2) y++
  return sprintf("%04d-%02d-%02d", y, m, d)
}
function dnum(s) { return days(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) }
function isdate(s) { return s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && civil(dnum(s)) == s }
function dow(s) { return (dnum(s) + 4) % 7 }   # 0 = Sunday
function err(msg) { printf "%s:%d: %s\n", FILENAME, NR, msg; bad++ }
function close_section() {
  if (!insec) return
  if (nsum == 0) { printf "%s:%d: section needs a %s line under its heading\n", FILENAME, sec_line, "'"'"'> summary'"'"'"; bad++ }
  if (nrows == 0) { printf "%s:%d: section has no task rows\n", FILENAME, sec_line; bad++ }
  insec = 0
}
function lastindex(s, needle,   pos, off, found) {
  found = 0; off = 0
  while ((pos = index(s, needle)) > 0) { found = off + pos; off = found + length(needle) - 1; s = substr(s, pos + length(needle)) }
  return found
}
BEGIN {
  FS = "\n"; SEP = sprintf("%c", 31)
  fd = dnum(FDATE); fdow = dow(FDATE)
  nextwd = fd + (fdow == 5 ? 3 : (fdow == 6 ? 2 : 1))
  friday = fd + (fdow == 6 ? 6 : (fdow == 0 ? 5 : 5 - fdow))
  nextstand = civil(nextwd); weekdue = civil(friday); laterdue = civil(fd + 14)
  HDR = "|#|Task|Owner|Story|Scope|Deadline|Status|Quote|"
}
/^## / {
  close_section()
  sec++; insec = 1; sec_line = NR; nsum = 0; nrows = 0; intable = 0; sum1 = ""; sum2 = ""; docid = ""; dochash = ""
  delete seen
  line = substr($0, 4)
  pos = lastindex(line, " - Krisp ")
  head_ok = 0
  if (pos > 0) {
    title = trim(substr(line, 1, pos - 1))
    rest = substr(line, pos + 9)
    suffix = ""
    p2 = index(rest, " | doc")
    if (p2 > 0) { suffix = substr(rest, p2 + 3); rest = substr(rest, 1, p2 - 1) }
    n = split(trim(rest), t, " ")
    if (title != "" && n == 2 && t[2] ~ /^https?:\/\/[^ ]+$/ && t[1] ~ /^[A-Za-z0-9_-]+$/) {
      head_ok = 1; mid = t[1]; link = t[2]
      if (suffix != "") {
        m = split(suffix, d, " ")
        if (m == 3 && d[1] == "doc" && d[2] ~ /^[A-Za-z0-9-]+$/ && d[3] ~ /^[0-9a-f]+$/) { docid = d[2]; dochash = d[3] }
        else { err("doc suffix must be: | doc <doc id> <content hash>"); head_ok = 0 }
      }
    }
  }
  if (!head_ok && (pos == 0 || suffix == "")) err("section heading must be: ## <meeting title> - Krisp <meeting id> <https link>")
  next
}
insec && /^>/ {
  s = $0; sub(/^>[ ]?/, "", s); s = trim(s)
  nsum++
  if (nsum > 2) err("a section takes at most 2 '"'"'> summary'"'"' lines")
  else if (nsum == 1) sum1 = s; else sum2 = s
  next
}
insec && /^[ \t]*\|/ {
  line = $0
  gsub(/[ \t]/, "", line)
  if (!intable) {
    intable = 1
    if (line != HDR) err("table header must be: | # | Task | Owner | Story | Scope | Deadline | Status | Quote |")
    next
  }
  if (line ~ /^\|[:|-]+\|$/) next
  n = split($0, c, "|")
  if (n != 10) { err("expected 8 cells, found " (n - 2 < 0 ? 0 : n - 2)); next }
  for (i = 2; i <= 9; i++) c[i] = trim(c[i])
  num = c[2]; task = c[3]; owner = c[4]; story = c[5]; scope = c[6]; ddl = c[7]; status = c[8]; quote = c[9]
  nrows++
  if (num !~ /^[0-9]+$/) err("# must be a number")
  else if (num in seen) err("duplicate row number " num)
  seen[num] = 1
  if (task == "") err("Task is empty")
  if (owner == "") err("Owner is empty")
  if (story != "" && story !~ /^sc-[0-9]+$/) err("Story must be empty or sc-NNNN")
  if (scope != "today" && scope != "week" && scope != "later") err("Scope must be today, week or later")
  if (status != "open" && status != "done" && status != "dropped" && status != "moved") err("Status must be open, done, dropped or moved")
  if (quote !~ /@[0-9]+:[0-9][0-9](:[0-9][0-9])?$/) err("Quote must end with the transcript time @mm:ss")
  date = ""; reason = ""; moved = 0
  if (ddl !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) err("Deadline must start with YYYY-MM-DD")
  else {
    date = substr(ddl, 1, 10)
    tail = trim(substr(ddl, 11))
    if (!isdate(date)) { err("Deadline " date " is not a real date"); date = "" }
    if (tail != "") {
      if (tail ~ /^\(moved:.*\)$/) {
        moved = 1; reason = trim(substr(tail, 8, length(tail) - 8))
        if (reason == "") err("moved reason is empty; write (moved: <why>)")
      } else err("Deadline may only be followed by (moved: <why>)")
    }
  }
  if (date != "" && !moved && status != "moved") {
    if (scope == "today" && date != nextstand) err("a today item is due the next standup date " nextstand " (got " date "); if it moved, write (moved: <why>)")
    if (scope == "week" && date != weekdue) err("a week item is due Friday " weekdue " (got " date "); if it moved, write (moved: <why>)")
    if (scope == "later" && date != laterdue) err("a later item has the placeholder deadline " laterdue ", two weeks after the meeting (got " date "); when a transcript states a timing, write (moved: <why>)")
  }
  if (MODE == "records") {
    if (!(sec in secout)) {
      secout[sec] = 1
      print "S" SEP sec SEP title SEP mid SEP link SEP docid SEP dochash SEP sum1 SEP sum2 SEP sec_line
    }
    print "R" SEP sec SEP NR SEP num SEP task SEP owner SEP story SEP scope SEP date SEP reason SEP status SEP quote
  }
  next
}
insec && intable { intable = 0 }
END {
  close_section()
  if (sec == 0) { printf "%s: no meeting section found (## <title> - Krisp <id> <link>)\n", FILENAME; bad++ }
  exit bad ? 1 : 0
}
'

fm_mt_file_date() {  # <file> -> the date in the file name, or nothing
  local base
  base=$(basename "$1")
  case "$base" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md) printf '%s' "${base%.md}" ;;
  esac
}

fm_mt_run() {  # <mode> <file>
  local mode=$1 file=$2 fdate
  [ -r "$file" ] || { printf '%s: cannot read the file\n' "$file" >&2; return 1; }
  fdate=$(fm_mt_file_date "$file")
  if [ -z "$fdate" ]; then
    printf '%s: file name must be YYYY-MM-DD.md (the meeting date)\n' "$file" >&2
    return 1
  fi
  awk -v MODE="$mode" -v FDATE="$fdate" "$FM_MT_AWK" "$file"
}

fm_mt_validate() {  # <file>
  fm_mt_run check "$1" >&2 || return 1
}

fm_mt_records() {  # <file>
  fm_mt_run records "$1"
}

fm_mt_replace() {  # <file> <awk-program> [awk args...]; rewrite the file in place and atomically
  local file=$1 prog=$2 tmp
  shift 2
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if awk "$@" "$prog" "$file" > "$tmp"; then
    cat "$tmp" > "$file" && rm -f "$tmp"
  else
    rm -f "$tmp"
    return 1
  fi
}

fm_mt_set_story() {  # <file> <line> <sc-NNNN>
  # shellcheck disable=SC2016 # awk program text
  fm_mt_replace "$1" '
    NR == LN {
      n = split($0, c, "|")
      if (n != 10) exit 1
      c[5] = " " SC " "
      out = c[1]
      for (i = 2; i <= n; i++) out = out "|" c[i]
      print out
      next
    }
    { print }' -v LN="$2" -v SC="$3"
}

fm_mt_set_doc() {  # <file> <line> <doc id> <hash>
  # shellcheck disable=SC2016 # awk program text
  fm_mt_replace "$1" '
    NR == LN {
      p = index($0, " | doc")
      if (p > 0) $0 = substr($0, 1, p - 1)
      print $0 " | doc " ID " " H
      next
    }
    { print }' -v LN="$2" -v ID="$3" -v H="$4"
}

fm_mt_doc_title() {  # <YYYY-MM-DD>
  local d=$1 wd day mon
  wd=$(awk -v D="$d" '
    function days(y, m, dd,   yy, era, yoe, mm, doy, doe) {
      yy = y; if (m <= 2) yy--
      era = int(yy / 400); yoe = yy - era * 400
      mm = m + (m > 2 ? -3 : 9)
      doy = int((153 * mm + 2) / 5) + dd - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    BEGIN {
      split("Sun Mon Tue Wed Thu Fri Sat", W, " ")
      print W[(days(substr(D, 1, 4) + 0, substr(D, 6, 2) + 0, substr(D, 9, 2) + 0) + 4) % 7 + 1]
    }')
  day=$((10#${d:8:2}))
  case "${d:5:2}" in
    01) mon=Jan ;; 02) mon=Feb ;; 03) mon=Mar ;; 04) mon=Apr ;; 05) mon=May ;; 06) mon=Jun ;;
    07) mon=Jul ;; 08) mon=Aug ;; 09) mon=Sep ;; 10) mon=Oct ;; 11) mon=Nov ;; 12) mon=Dec ;;
  esac
  printf 'Standup %s %s %s - agreed to-dos' "$wd" "$day" "$mon"
}
