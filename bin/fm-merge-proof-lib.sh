#!/usr/bin/env bash
# Fork-only: fm-merge-proof-lib.sh - the merge proof gate used by bin/fm-pr-merge.sh.
#
# A PR whose body admits that a real path was not checked must not merge
# silently. fm_merge_proof_evaluate reads one live `gh pr view --json
# body,statusCheckRollup` payload and refuses when either holds:
#   1. The body's own proof (the text before the no-mistakes appendix marker)
#      has a line matching FM_MERGE_PROOF_UNCHECKED_PATTERNS, such as
#      "Not checked here: an end-to-end resume against api-test".
#   2. The no-mistakes test step was skipped (a "**Test** - skipped" section
#      or an attestation with test status "skipped") AND no check whose name
#      contains "test" (any case) concluded SUCCESS in the rollup. The rollup
#      is read live for the current head, so "at the head" holds by
#      construction. A skipped test step alone does not block: dev-bound PRs
#      skip it by design and rely on GitHub CI.
# A caller waives a finding with --waive-proof <line> <reason> (repeatable).
# The line must appear in the body and be a substring of the finding it
# waives; the reason must be non-empty. Every used waiver is returned in
# FM_MERGE_PROOF_WAIVED as "line<TAB>reason" for the caller to record.
# Gap: only the GitHub path reads the body. GitLab and Forgejo merges do not
# apply this gate, because their reads here carry no PR description and this
# gate adds no new forge plumbing.
# Inputs: FM_MERGE_PROOF_WAIVE_LINES and FM_MERGE_PROOF_WAIVE_REASONS, two
# parallel arrays the caller owns. Outputs: FM_MERGE_PROOF_REFUSALS (one
# "  - ..." line per refusal) and FM_MERGE_PROOF_WAIVED.

# Case-insensitive extended regexes, one per line. Keep this list small.
FM_MERGE_PROOF_UNCHECKED_PATTERNS='not checked
not verified'
FM_MERGE_PROOF_APPENDIX_MARKER='<!-- no-mistakes-pr-appendix'
# Fragments of the no-mistakes body that say its test step was skipped.
FM_MERGE_PROOF_SKIP_PATTERN='\*\*Test\*\* - skipped|"step":"test","status":"skipped"'

FM_MERGE_PROOF_REFUSALS=
FM_MERGE_PROOF_WAIVED=

# Print the PR proof text: the body up to the no-mistakes appendix marker.
fm_merge_proof_text() {  # <body>
  printf '%s\n' "$1" | awk -v m="$FM_MERGE_PROOF_APPENDIX_MARKER" 'index($0, m) { exit } { print }'
}

# Print each proof line that matches an unchecked pattern.
fm_merge_proof_unchecked_lines() {  # <body>
  local pattern text
  text=$(fm_merge_proof_text "$1")
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    printf '%s\n' "$text" | grep -iE -- "$pattern" || true
  done <<EOF
$FM_MERGE_PROOF_UNCHECKED_PATTERNS
EOF
}

# Print the first fragment saying the test step was skipped, if any.
fm_merge_proof_skip_fragment() {  # <body>
  printf '%s\n' "$1" | grep -oE -- "$FM_MERGE_PROOF_SKIP_PATTERN" | head -n 1 || true
}

# Whether the rollup JSON holds a passed check whose name contains "test".
fm_merge_proof_green_test_job() {  # <pr json>
  printf '%s' "$1" | jq -e '
    [ (.statusCheckRollup // [])[]
      | select(((.name // .context // "") | ascii_downcase | contains("test"))
               and ((.conclusion // .state // "") == "SUCCESS")) ]
    | length > 0' >/dev/null 2>&1
}

fm_merge_proof_trim() {  # <text>
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Return 0 when the PR proof is acceptable, 1 after setting FM_MERGE_PROOF_REFUSALS.
fm_merge_proof_evaluate() {  # <pr json>
  local json=$1 body finding findings='' fragment i n waiver reason covered w
  local unchecked
  FM_MERGE_PROOF_REFUSALS=
  FM_MERGE_PROOF_WAIVED=
  body=$(printf '%s' "$json" | jq -r '.body // ""' 2>/dev/null) || body=

  unchecked=$(fm_merge_proof_unchecked_lines "$body")
  while IFS= read -r finding; do
    finding=$(fm_merge_proof_trim "$finding")
    [ -z "$finding" ] || findings="$findings$finding
"
  done <<EOF
$unchecked
EOF
  fragment=$(fm_merge_proof_skip_fragment "$body")
  if [ -n "$fragment" ] && ! fm_merge_proof_green_test_job "$json"; then
    findings="$findings$fragment
"
  fi

  # Validate each waiver before it can cover anything.
  n=${#FM_MERGE_PROOF_WAIVE_LINES[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    waiver=${FM_MERGE_PROOF_WAIVE_LINES[$i]}
    reason=${FM_MERGE_PROOF_WAIVE_REASONS[$i]}
    i=$((i + 1))
    if [ -z "$(fm_merge_proof_trim "$reason")" ]; then
      FM_MERGE_PROOF_REFUSALS="$FM_MERGE_PROOF_REFUSALS  - --waive-proof needs a non-empty reason for \"$waiver\"
"
    elif ! printf '%s\n' "$body" | grep -qF -- "$waiver"; then
      FM_MERGE_PROOF_REFUSALS="$FM_MERGE_PROOF_REFUSALS  - waived proof line \"$waiver\" does not appear in the PR body
"
    fi
  done
  [ -z "$FM_MERGE_PROOF_REFUSALS" ] || return 1

  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    covered=0
    i=0
    while [ "$i" -lt "$n" ]; do
      w=${FM_MERGE_PROOF_WAIVE_LINES[$i]}
      case "$finding" in
        *"$w"*)
          covered=1
          FM_MERGE_PROOF_WAIVED="$FM_MERGE_PROOF_WAIVED$w	${FM_MERGE_PROOF_WAIVE_REASONS[$i]}
"
          break
          ;;
      esac
      i=$((i + 1))
    done
    [ "$covered" -eq 0 ] || continue
    case "$finding" in
      *'Test** - skipped'*|*'"step":"test"'*)
        FM_MERGE_PROOF_REFUSALS="$FM_MERGE_PROOF_REFUSALS  - the no-mistakes test step was skipped and no check with \"test\" in its name passed at this head; pass the tests in CI, or waive with: --waive-proof '$finding' '<reason>'
"
        ;;
      *)
        FM_MERGE_PROOF_REFUSALS="$FM_MERGE_PROOF_REFUSALS  - the PR proof says a path was not checked: \"$finding\"; check it, or waive with: --waive-proof '$finding' '<reason>'
"
        ;;
    esac
  done <<EOF
$findings
EOF
  [ -z "$FM_MERGE_PROOF_REFUSALS" ]
}
