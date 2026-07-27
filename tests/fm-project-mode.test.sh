#!/usr/bin/env bash
# Tests for bin/fm-project-mode.sh: the data/projects.md registry parser that
# resolves a project's delivery mode, yolo flag, and ticket prefix.
#
# The bracket flags are additive and order-independent. The optional third
# output word (the +ticket:<prefix> value) drives the crew branch and PR-title
# convention in bin/fm-brief.sh, and it must stay optional so callers that read
# only "<mode> <yolo>" keep working. An invalid or prefixless flag warns and is
# dropped to ticketless rather than scaffolding an unusable branch name.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode)

# Build a home with the given registry lines and echo its path.
make_home() {
  local name=$1 home
  shift
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data"
  printf '%s\n' "$@" > "$home/data/projects.md"
  printf '%s\n' "$home"
}

resolve() {
  local home=$1 project=$2
  FM_HOME="$home" "$PROJECT_MODE" "$project" 2>/dev/null
}

expect_resolves() {
  local home=$1 project=$2 want=$3 got
  got=$(resolve "$home" "$project")
  [ "$got" = "$want" ] || fail "$project: expected \"$want\", got \"$got\""
}

test_existing_flags_are_unchanged() {
  local home
  home=$(make_home existing \
    '- plain - no bracket flags (added 2026-07-01)' \
    '- moded [direct-PR] - mode only (added 2026-07-01)' \
    '- yolo-only [local-only +yolo] - mode and yolo (added 2026-07-01)' \
    '- bare-yolo [+yolo] - yolo without an explicit mode (added 2026-07-01)')

  expect_resolves "$home" plain "no-mistakes off"
  expect_resolves "$home" moded "direct-PR off"
  expect_resolves "$home" yolo-only "local-only on"
  expect_resolves "$home" bare-yolo "no-mistakes on"
  expect_resolves "$home" absent "no-mistakes off"
  pass "fm-project-mode.sh: mode and +yolo parsing is unchanged and emits two words"
}

test_ticket_prefix_is_an_optional_third_word() {
  local home
  home=$(make_home ticket \
    '- ticketed [no-mistakes +ticket:sc] - ticket flag only (added 2026-07-01)' \
    '- both [direct-PR +yolo +ticket:sc] - ticket and yolo (added 2026-07-01)' \
    '- reordered [direct-PR +ticket:ENG +yolo] - order-independent flags (added 2026-07-01)' \
    '- bare-ticket [+ticket:sc] - ticket without an explicit mode (added 2026-07-01)' \
    '- ticketless [direct-PR +yolo] - no ticket flag (added 2026-07-01)')

  expect_resolves "$home" ticketed "no-mistakes off sc"
  expect_resolves "$home" both "direct-PR on sc"
  expect_resolves "$home" reordered "direct-PR on ENG"
  expect_resolves "$home" bare-ticket "no-mistakes off sc"
  # Absent flag emits exactly two words, so an existing caller's exact-match
  # comparison and `read -r MODE YOLO` both keep working.
  expect_resolves "$home" ticketless "direct-PR on"
  pass "fm-project-mode.sh: +ticket:<prefix> adds a third word only when present"
}

test_third_field_reads_empty_when_ticketless() {
  local home mode yolo ticket
  home=$(make_home read-shape '- ticketless [direct-PR] - no ticket flag (added 2026-07-01)')
  read -r mode yolo ticket <<EOF
$(resolve "$home" ticketless)
EOF
  [ "$mode" = "direct-PR" ] || fail "read-shape: mode field is $mode"
  [ "$yolo" = "off" ] || fail "read-shape: yolo field is $yolo"
  [ -z "$ticket" ] || fail "read-shape: ticket field should be empty, got \"$ticket\""
  pass "fm-project-mode.sh: a ticketless project leaves a caller's third field empty"
}

test_invalid_ticket_prefix_falls_back_to_ticketless() {
  local home out err
  home=$(make_home invalid \
    '- slashy [direct-PR +ticket:sc/x] - prefix with a path separator (added 2026-07-01)' \
    '- numeric [direct-PR +ticket:42] - prefix that does not start with a letter (added 2026-07-01)')

  for project in slashy numeric; do
    err=$(FM_HOME="$home" "$PROJECT_MODE" "$project" 2>&1 >/dev/null)
    out=$(resolve "$home" "$project")
    [ "$out" = "direct-PR off" ] || fail "$project: an invalid prefix must fall back to ticketless, got \"$out\""
    assert_contains "$err" "invalid +ticket prefix" "$project: an invalid prefix must warn to stderr"
  done
  pass "fm-project-mode.sh: an unusable ticket prefix warns and drops to ticketless"
}

# A flag that carries no prefix at all is the operator typo the flag exists to
# catch, so it must warn rather than read as a deliberately ticketless project.
test_prefixless_ticket_flag_warns() {
  local home out err
  home=$(make_home prefixless \
    '- spacey [direct-PR +ticket:] - colon with an empty prefix (added 2026-07-01)' \
    '- colonless [direct-PR +ticket] - flag with no colon at all (added 2026-07-01)')

  for project in spacey colonless; do
    err=$(FM_HOME="$home" "$PROJECT_MODE" "$project" 2>&1 >/dev/null)
    out=$(resolve "$home" "$project")
    [ "$out" = "direct-PR off" ] || fail "$project: a prefixless flag must fall back to ticketless, got \"$out\""
    assert_contains "$err" "malformed +ticket flag" "$project: a prefixless +ticket flag must warn to stderr"
  done
  pass "fm-project-mode.sh: a +ticket flag with no prefix warns and drops to ticketless"
}

# An unrecognized mode NAME in a registered bracket must REFUSE, not default to
# the remote-pushing "no-mistakes": a typo of a local-only project must never
# silently become a push-and-PR project. It exits non-zero with no stdout.
test_unknown_mode_refuses() {
  local home out err rc
  home=$(make_home unknown-mode '- bogus [sideways +ticket:sc] - unknown delivery mode (added 2026-07-01)')
  out=$(FM_HOME="$home" "$PROJECT_MODE" bogus 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "unknown mode must refuse with a non-zero exit, got rc=$rc"
  [ -z "$out" ] || fail "unknown mode must emit no mode on stdout, got \"$out\""
  err=$(FM_HOME="$home" "$PROJECT_MODE" bogus 2>&1 >/dev/null || true)
  assert_contains "$err" "unknown mode" "unknown mode must explain the refusal on stderr"
  assert_contains "$err" "refusing" "unknown mode must state that it refuses"

  # A typo'd mode written AFTER a flag lands in the leftover-token path, not the
  # position-1 mode check, so it must refuse there too rather than warn-and-default
  # to the remote-pushing no-mistakes (a mistyped local-only must never push).
  home=$(make_home flag-first-typo '- appA [+yolo locl-only] - typo mode after a flag (added 2026-07-01)')
  out=$(FM_HOME="$home" "$PROJECT_MODE" appA 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "a typo'd mode after a flag must refuse, got rc=$rc"
  [ -z "$out" ] || fail "a typo'd mode after a flag must emit no mode, got \"$out\""
  err=$(FM_HOME="$home" "$PROJECT_MODE" appA 2>&1 >/dev/null || true)
  assert_contains "$err" "refusing" "a typo'd mode after a flag must state that it refuses"
  pass "fm-project-mode.sh: an unrecognized mode name refuses instead of defaulting to no-mistakes"
}

# A mode written after the bracket flags used to be discarded in silence, which
# resolved a captain-declared local-only project to the remote-pushing default.
# It must still be honored, and it must say so.
test_misordered_mode_is_honored_and_warns() {
  local home out err
  home=$(make_home misordered \
    '- late-mode [+ticket:sc local-only] - mode written after the flags (added 2026-07-01)' \
    '- junk [direct-PR +yolo sideways] - a token that is neither mode nor flag (added 2026-07-01)')

  err=$(FM_HOME="$home" "$PROJECT_MODE" late-mode 2>&1 >/dev/null)
  out=$(resolve "$home" late-mode)
  [ "$out" = "local-only off sc" ] \
    || fail "late-mode: a misordered mode must not be downgraded, got \"$out\""
  assert_contains "$err" "follows the bracket flags" "late-mode: a misordered mode must warn to stderr"

  err=$(FM_HOME="$home" "$PROJECT_MODE" junk 2>&1 >/dev/null)
  out=$(resolve "$home" junk)
  [ "$out" = "direct-PR on" ] || fail "junk: an unrecognized token must not change the mode, got \"$out\""
  assert_contains "$err" "unrecognized bracket token" "junk: an unrecognized bracket token must warn to stderr"

  pass "fm-project-mode.sh: a misordered mode is honored with a warning, junk tokens warn"
}

test_existing_flags_are_unchanged
test_ticket_prefix_is_an_optional_third_word
test_misordered_mode_is_honored_and_warns
test_third_field_reads_empty_when_ticketless
test_invalid_ticket_prefix_falls_back_to_ticketless
test_prefixless_ticket_flag_warns
test_unknown_mode_refuses
