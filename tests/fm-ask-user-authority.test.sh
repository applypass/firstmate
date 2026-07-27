#!/usr/bin/env bash
# Scenario regressions for ask-user authority.
#
# Hi Bit PR 148 is motivating evidence only: yolo approved 31 ask-user finding
# groups, and a later audit classified 14 of 32 rounds as over-engineered after
# checkpoint-based gameplay verification expanded into continuous adversarial
# 60 Hz browser proof.
# The class-sweep rule has its own motivating evidence: one queue-refresh fix
# cost the captain roughly nine separate ask-user decisions, each another caller
# that ignored a swallowed failure, before the class was swept and decided once.
# The tests below enforce the general contract boundary without naming that
# project in the runtime policy.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
OWNER="$ROOT/.agents/skills/ask-user-authority/SKILL.md"
BRIEF="$ROOT/bin/fm-brief.sh"
SECONDMATE="$ROOT/.agents/skills/secondmate-provisioning/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-ask-user-authority)

approval_contract() {
  awk '
    /^### Selected delivery path and approval authority$/ { found = 1; next }
    found && /^### Validate$/ { exit }
    found { print }
  ' "$AGENTS"
}

test_owner_and_always_loaded_boundary() {
  local contract trigger_count
  contract=$(approval_contract)

  assert_contains "$contract" "only within the captain's original request and accepted task criteria" \
    "standing authority lost the accepted-contract boundary"
  assert_contains "$contract" 'never approves an ask-user Fix that would materially expand that product or engineering contract' \
    "standing authority lost the contract-expansion exception"
  assert_contains "$contract" 'destructive, irreversible, and security-sensitive choices remain stronger captain boundaries' \
    "contract expansion weakened stronger captain boundaries"
  assert_contains "$contract" 'Complexity alone is not expansion' \
    "standing authority incorrectly treats complexity as expansion"
  assert_contains "$contract" 'load `ask-user-authority`' \
    "standing authority lost the detailed-procedure trigger"
  assert_contains "$contract" 'implementation worker never answers its own finding' \
    "implementation worker can answer its own finding"

  assert_present "$OWNER" "ask-user authority owner is missing"
  assert_grep 'name: ask-user-authority' "$OWNER" "ask-user authority skill has the wrong name"
  assert_grep 'user-invocable: false' "$OWNER" "ask-user authority skill must be agent-only"
  assert_grep 'single owner of the decision procedure for ask-user findings' "$OWNER" \
    "ask-user authority skill does not declare ownership"
  assert_grep 'With `yolo` off, every ask-user finding belongs to the captain' "$OWNER" \
    "detailed procedure permits autonomous ask-user decisions with yolo off"
  trigger_count=$(grep -Fc -- '- `ask-user-authority` -' "$AGENTS")
  [ "$trigger_count" -eq 1 ] || fail "ask-user-authority must have exactly one section 13 trigger, found $trigger_count"
  assert_no_grep 'Hi Bit' "$AGENTS" "AGENTS.md encoded an incident-specific authority rule"
  assert_no_grep 'Hi Bit' "$OWNER" "authority owner encoded an incident-specific rule"
  pass "ask-user authority has one conditional owner and a concise always-loaded boundary"
}

test_concrete_required_defect_stays_autonomous() {
  assert_grep 'genuinely necessary to satisfy the accepted contract' "$OWNER" \
    "required concrete corrections no longer stay within standing authority"
  assert_grep 'Fixing a concrete defect that violates an original acceptance criterion stays within `yolo` authority' "$OWNER" \
    "concrete acceptance-criterion defect scenario is missing"
  pass "required concrete defect correction stays within yolo authority"
}

test_continuous_monitoring_expansion_escalates() {
  assert_grep 'continuous-monitoring requirement' "$OWNER" \
    "continuous monitoring is not classified as a possible contract expansion"
  assert_grep 'continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract' "$OWNER" \
    "checkpoint-to-continuous-monitoring escalation scenario is missing"
  pass "continuous frame-by-frame proof escalates when only checkpoints were requested"
}

test_repeated_same_theme_escalates_before_another_round() {
  assert_grep 'Repeated same-theme findings require escalation before another Fix' "$OWNER" \
    "same-theme findings do not stop another autonomous fix round"
  assert_grep 'preserving a questionable abstraction rather than closing independent defects' "$OWNER" \
    "same-theme escalation lost its causal distinction"
  pass "repeated abstraction-preserving findings escalate before another fix round"
}

test_defect_class_is_swept_and_decided_once() {
  local brief_contract sweep_owners
  assert_grep 'Sweep the defect class, decide once' "$OWNER" \
    "class-sweep rule is missing from its owner"
  assert_grep 'Enumerate that whole class before deciding the instance in front of you' "$OWNER" \
    "class-sweep rule no longer enumerates the class up front"
  assert_grep 'bring one decision that covers the class to whoever owns it under the numbered procedure above' "$OWNER" \
    "class-sweep rule lost the single batched decision routed to its authority owner"
  assert_grep 'sweep it with "Sweep the defect class, decide once" below rather than routing the next instance, without relaxing this step'"'"'s own escalation requirement' "$OWNER" \
    "same-theme step cross-reference can be read as replacing its own escalation"
  assert_grep 'Enumerating the class is not contract expansion' "$OWNER" \
    "class-sweep rule no longer distinguishes enumeration from contract expansion"
  assert_grep 'still follows the numbered procedure above, including its stronger destructive, irreversible, and security-sensitive captain boundaries' "$OWNER" \
    "class-sweep rule stopped deferring authority to the numbered procedure and its stronger boundaries"
  assert_grep "Step 7's questionable-abstraction escalation still fires when the class is swept" "$OWNER" \
    "sweeping a class can skip the questionable-abstraction escalation"
  assert_grep 'never authorizes batch-patching a class autonomously in place of that escalation' "$OWNER" \
    "folding corrections into one round reads as autonomous batch-patching authority"

  brief_contract=$(awk '
    /^## 11\. Crewmate briefs$/ { found = 1; next }
    found && /^## 12\./ { exit }
    found { print }
  ' "$AGENTS")
  assert_contains "$brief_contract" 'enumerate every occurrence of that class and report them as one set' \
    "brief contract does not require systemic work to be swept in one set"
  assert_contains "$brief_contract" '`ask-user-authority` owns the matching one-batched-decision rule' \
    "brief contract does not point at the class-sweep owner"
  sweep_owners=$(grep -Fc 'Enumerate that whole class before deciding the instance in front of you' "$AGENTS")
  [ "$sweep_owners" -eq 0 ] || fail "AGENTS.md carries a second copy of the class-sweep procedure instead of pointing at its owner"
  pass "a defect class is enumerated up front and decided in one batched decision"
}

test_stronger_security_boundary_survives() {
  assert_grep 'genuinely security-sensitive choices always escalate' "$OWNER" \
    "security-sensitive choices no longer use the stronger captain boundary"
  assert_grep 'genuinely security-sensitive action requires the captain under the stronger existing boundary' "$OWNER" \
    "security-sensitive scenario is missing"
  pass "genuinely security-sensitive action still escalates"
}

test_explicit_complex_architecture_stays_in_scope() {
  assert_grep 'complex architecture that the captain explicitly requested' "$OWNER" \
    "explicitly requested complex architecture is not protected from complexity-only escalation"
  assert_grep 'does not escalate merely because it is complex' "$OWNER" \
    "complexity alone still triggers escalation"
  pass "explicitly requested complex architecture stays autonomous"
}

test_reviewer_labels_are_evidence_not_authority() {
  for label in correctness security fail-closed high-risk required; do
    assert_grep "$label" "$OWNER" "reviewer-label evidence rule is missing '$label'"
  done
  assert_grep 'never as authority to broaden the task' "$OWNER" \
    "reviewer labels can still broaden the accepted contract"
  pass "reviewer risk labels remain evidence rather than expansion authority"
}

test_captain_escalation_is_decision_ready() {
  for phrase in \
    'original requirement or accepted task criterion' \
    'proposed product or engineering contract expansion' \
    'smallest alternative that complies with the accepted contract' \
    'consequences of accepting and declining the expansion' \
    'recommendation with the reason'; do
    assert_grep "$phrase" "$OWNER" "captain-facing escalation lost '$phrase'"
  done
  pass "contract-expansion escalation carries all five decision elements"
}

test_primary_and_secondmate_instruction_generation() {
  local home ship charter
  home="$TMP_ROOT/home"
  mkdir -p "$home/data"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$BRIEF" authority-worker sample >/dev/null 2>&1
  ship="$home/data/authority-worker/brief.md"
  assert_grep 'ask-user findings are never yours to answer' "$ship" \
    "generated implementation brief lets the worker own an ask-user decision"
  assert_grep "Firstmate applies the authority contract in its \`AGENTS.md\`" "$ship" \
    "generated implementation brief bypasses the primary authority owner"
  assert_grep "silently bypass the authority check firstmate applies and any required captain escalation" "$ship" \
    "generated implementation brief permits silent ask-user auto-resolution"
  assert_no_grep 'the captain, not you, owns the ask-user decisions' "$ship" \
    "generated implementation brief retained conflicting captain-only wording"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='Handle sample work.' \
    "$BRIEF" authority-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/authority-mate/brief.md"
  assert_grep 'The local `AGENTS.md` is your job description' "$charter" \
    "generated secondmate charter does not load the tracked authority boundary"
  assert_grep 'purely local fast-forward of tracked files' "$SECONDMATE" \
    "secondmate update owner no longer carries tracked instructions into homes"
  assert_grep 'AGENTS.md re-read' "$SECONDMATE" \
    "running secondmates are not told to re-read updated tracked authority"
  assert_no_grep 'continuous frame-by-frame monitoring' "$charter" \
    "generated secondmate charter duplicated the detailed authority procedure"
  pass "primary workers and secondmates receive the authority rule through their normal instruction owners"
}

test_owner_and_always_loaded_boundary
test_concrete_required_defect_stays_autonomous
test_continuous_monitoring_expansion_escalates
test_repeated_same_theme_escalates_before_another_round
test_defect_class_is_swept_and_decided_once
test_stronger_security_boundary_survives
test_explicit_complex_architecture_stays_in_scope
test_reviewer_labels_are_evidence_not_authority
test_captain_escalation_is_decision_ready
test_primary_and_secondmate_instruction_generation
