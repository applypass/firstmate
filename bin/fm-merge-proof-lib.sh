#!/usr/bin/env bash
# Fork-only: fm-merge-proof-lib.sh - the merge proof gate used by bin/fm-pr-merge.sh.
#
# A PR whose body admits that a real path was not checked must not merge
# silently. fm_merge_proof_evaluate reads one live `gh pr view --json
# body,statusCheckRollup` payload and refuses when either holds:
#   1. The body's own proof has a line matching FM_MERGE_PROOF_UNCHECKED_PATTERN,
#      such as "Not checked here: an end-to-end resume against api-test". The
#      proof is the "## Proof" section (any case) of the text before the
#      no-mistakes appendix marker, or all of that text when it has no such
#      section.
#   2. The no-mistakes test step was skipped (a "**Test** - skipped" section
#      or an attestation with test status "skipped") AND no check whose name
#      has "test" or "tests" as a word (any case) concluded SUCCESS in the
#      rollup. The rollup
#      is read live for the current head, so "at the head" holds by
#      construction. A skipped test step alone does not block: dev-bound PRs
#      skip it by design and rely on GitHub CI.
# A caller waives a finding with --waive-proof <line> <reason> (repeatable).
# The line must equal one whole finding, as the refusal prints it, after
# trimming; the reason must be non-empty. Every waived finding is returned in
# FM_MERGE_PROOF_WAIVED as "finding<TAB>reason" for the caller to record.
# Gap: only the GitHub path reads the body. GitLab and Forgejo merges do not
# apply this gate, because their reads here carry no PR description and this
# gate adds no new forge plumbing.
# Inputs: FM_MERGE_PROOF_WAIVE_LINES and FM_MERGE_PROOF_WAIVE_REASONS, two
# parallel arrays the caller owns. Outputs: FM_MERGE_PROOF_REFUSALS (one
# "  - ..." line per refusal) and FM_MERGE_PROOF_WAIVED.

# Case-insensitive extended regex. Keep it small.
FM_MERGE_PROOF_UNCHECKED_PATTERN='not checked|not verified'
FM_MERGE_PROOF_APPENDIX_MARKER='<!-- no-mistakes-pr-appendix'
# Fragments of the no-mistakes body that say its test step was skipped.
FM_MERGE_PROOF_SKIP_PATTERN='\*\*Test\*\* - skipped|"step":"test","status":"skipped"'

FM_MERGE_PROOF_REFUSALS=
FM_MERGE_PROOF_WAIVED=

# Print the PR proof text: the "## Proof" section of the body before the
# no-mistakes appendix marker, or all of that text when it has no such section.
fm_merge_proof_text() {  # <body>
  printf '%s\n' "$1" | awk -v m="$FM_MERGE_PROOF_APPENDIX_MARKER" '
    index($0, m) { exit }
    { all = all $0 "\n" }
    /^##[ \t]/ { in_proof = tolower($0) ~ /^##[ \t]+proof([^a-z]|$)/; if (in_proof) found = 1 }
    in_proof { proof = proof $0 "\n" }
    END { printf "%s", found ? proof : all }'
}

# Print each proof line that matches the unchecked pattern.
fm_merge_proof_unchecked_lines() {  # <body>
  fm_merge_proof_text "$1" | grep -iE -- "$FM_MERGE_PROOF_UNCHECKED_PATTERN" || true
}

# Print the first fragment saying the test step was skipped, if any.
fm_merge_proof_skip_fragment() {  # <body>
  printf '%s\n' "$1" | grep -oE -- "$FM_MERGE_PROOF_SKIP_PATTERN" | head -n 1 || true
}

# Whether the rollup JSON holds a passed check with "test" or "tests" as a word in its name.
fm_merge_proof_green_test_job() {  # <pr json>
  printf '%s' "$1" | jq -e '
    [ (.statusCheckRollup // [])[]
      | select(((.name // .context // "") | ascii_downcase | test("(^|[^a-z])tests?([^a-z]|$)"))
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
    [ -n "$finding" ] || continue
    case "
$findings" in
      *"
$finding
"*) ;;
      *) findings="$findings$finding
" ;;
    esac
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
    else
      case "
$findings" in
        *"
$(fm_merge_proof_trim "$waiver")
"*) ;;
        *) FM_MERGE_PROOF_REFUSALS="$FM_MERGE_PROOF_REFUSALS  - waived proof line \"$waiver\" is not a whole finding line of this PR; pass the line exactly as the refusal prints it
" ;;
      esac
    fi
  done
  [ -z "$FM_MERGE_PROOF_REFUSALS" ] || return 1

  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    covered=0
    i=0
    while [ "$i" -lt "$n" ]; do
      w=$(fm_merge_proof_trim "${FM_MERGE_PROOF_WAIVE_LINES[$i]}")
      if [ "$finding" = "$w" ]; then
        covered=1
        FM_MERGE_PROOF_WAIVED="$FM_MERGE_PROOF_WAIVED$finding	${FM_MERGE_PROOF_WAIVE_REASONS[$i]}
"
        break
      fi
      i=$((i + 1))
    done
    [ "$covered" -eq 0 ] || continue
    case "$finding" in
      *'Test** - skipped'*|*'"step":"test"'*)
        FM_MERGE_PROOF_REFUSALS="$FM_MERGE_PROOF_REFUSALS  - the no-mistakes test step was skipped and no test check (a name with \"test\" or \"tests\" as a word) passed at this head; pass the tests in CI, or waive with: --waive-proof '$finding' '<reason>'
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
