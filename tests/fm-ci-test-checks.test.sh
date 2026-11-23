#!/usr/bin/env bash
# shellcheck disable=SC1091
# Fork-only: behavior tests for the per-project CI test checks (.fork/ci-test-checks)
# as the merge proof (bin/fm-merge-proof-lib.sh) reads them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-merge-proof-lib.sh
. "$ROOT/bin/fm-merge-proof-lib.sh"

FM_MERGE_PROOF_WAIVE_LINES=()
FM_MERGE_PROOF_WAIVE_REASONS=()

SKIPPED_BODY=$'## Proof\n- Covered by CI.\n\n## Testing\n\n- \xe2\x8f\xad\xef\xb8\x8f **Test** - skipped'

# A PR payload whose body skipped the local test step and whose green checks are the given names.
payload() {  # <check name>...
  local names n
  names=$(for n in "$@"; do printf '%s\n' "$n"; done | jq -R '{name: ., conclusion: "SUCCESS"}' | jq -s .)
  jq -n --arg body "$SKIPPED_BODY" --argjson rollup "$names" '{body: $body, statusCheckRollup: $rollup}'
}

proof() {  # <project> <check name>...
  local project=$1
  shift
  FM_MERGE_PROOF_PROJECT=$project fm_merge_proof_evaluate "$(payload "$@")"
}

test_backend_check_names_pass_the_proof() {
  proof apply_pass_backend unit worker-image 'integration-shard (1/4)' integration gitleaks \
    || fail "backend unit + integration green should pass: $FM_MERGE_PROOF_REFUSALS"
  pass "backend-style check names (unit, integration) pass the proof"
}

test_backend_needs_every_declared_check() {
  proof apply_pass_backend unit worker-image gitleaks && fail "unit alone must not pass for backend"
  assert_contains "$FM_MERGE_PROOF_REFUSALS" 'integration' "names the missing integration check"
  proof apply_pass_backend integration && fail "integration alone must not pass for backend"
  assert_contains "$FM_MERGE_PROOF_REFUSALS" 'unit' "names the missing unit check"
  pass "backend needs every declared check green"
}

test_frontend_matrix_name_passes() {
  proof apply_pass_frontend typecheck 'test (1)' 'test (2)' build \
    || fail "frontend test (N) should pass: $FM_MERGE_PROOF_REFUSALS"
  proof apply_pass_frontend typecheck build && fail "no test check must refuse for frontend"
  pass "frontend test (N) checks pass the proof"
}

test_undeclared_project_keeps_the_test_name_match() {
  proof example/never-declared 'Unit Tests' \
    || fail "an undeclared project with a green test-named check should pass: $FM_MERGE_PROOF_REFUSALS"
  proof some-other-repo lint contest 'SLSA attestation' && fail "undeclared project with no test-named check must refuse"
  assert_contains "$FM_MERGE_PROOF_REFUSALS" 'no test check' "old refusal text kept"
  FM_MERGE_PROOF_PROJECT='' fm_merge_proof_evaluate "$(payload 'Unit Tests')" \
    || fail "no project at all keeps the old match: $FM_MERGE_PROOF_REFUSALS"
  proof ai_backend 'Unit Tests' || fail "a project declared with no checks keeps the old match"
  pass "a project that declares nothing keeps the test-name match"
}

test_unit_name_alone_is_not_a_test_check_for_undeclared_project() {
  proof some-other-repo unit integration && fail "unit and integration mean nothing without a declaration"
  pass "undeclared projects are not credited for unit or integration"
}

test_declared_pattern_matches_the_whole_job_name() {
  proof apply_pass_backend unit-lint integration && fail "unit-lint must not match unit"
  assert_contains "$FM_MERGE_PROOF_REFUSALS" 'unit' "names the missing unit check"
  proof apply_pass_backend 'lint / unit' integration && fail "lint / unit must not match unit"
  proof apply_pass_backend 'unit (1)' integration && fail "unit (1) must not match unit"
  pass "a declared pattern matches only the whole job name"
}

test_backend_check_names_pass_the_proof
test_backend_needs_every_declared_check
test_frontend_matrix_name_passes
test_undeclared_project_keeps_the_test_name_match
test_unit_name_alone_is_not_a_test_check_for_undeclared_project
test_declared_pattern_matches_the_whole_job_name
