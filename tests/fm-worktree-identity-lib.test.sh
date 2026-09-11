#!/usr/bin/env bash
# tests/fm-worktree-identity-lib.test.sh - unit tests for the shared
# filesystem-identity comparison the spawn isolation guard uses
# (bin/fm-worktree-identity-lib.sh). A pure function, no git and no backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-worktree-identity-lib.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/fm-wt-identity.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/wt1" "$T/other"
ln -s "$T/wt1" "$T/link-to-wt1"
: >"$T/plainfile"

# --- the ordinary cases -----------------------------------------------------

fm_wt_same_object "$T/wt1" "$T/wt1" || fail "a directory must be the same object as itself"
pass "fm_wt_same_object is true for one directory named twice"

! fm_wt_same_object "$T/wt1" "$T/other" || fail "two distinct directories must not compare same"
pass "fm_wt_same_object is false for two distinct directories"

# --- identity, not path text ------------------------------------------------

# A symlinked spelling reaches the same inode. This is the property that makes
# the comparison identity rather than string equality, and it holds on every
# filesystem, so it is asserted unconditionally.
fm_wt_same_object "$T/link-to-wt1" "$T/wt1" \
  || fail "a symlinked spelling must compare same as its target directory"
pass "fm_wt_same_object sees through a symlinked spelling to one object"

# The case-variant spelling is the reported defect: `pwd -P` does not case-fold,
# so `.../WT1` and `.../wt1` are different strings for one directory and the
# guard's old text compare refused a genuine worktree. Only a case-insensitive
# filesystem can produce that pair, so probe for one rather than assume it.
mkdir "$T/CaseProbe"
if [ -d "$T/caseprobe" ]; then
  fm_wt_same_object "$T/WT1" "$T/wt1" \
    || fail "a case-variant spelling of one directory must compare same"
  pass "fm_wt_same_object sees through a case-variant spelling to one object"
else
  echo "# skip: case-sensitive filesystem, case-variant spellings cannot occur here"
fi

# --- what it refuses to claim ----------------------------------------------

# `test -ef` alone is false when an operand cannot be stat'd, which a caller
# asking "are these distinct?" would read as proof of distinctness. Identity is
# only claimed for two operands confirmed present, so every unreadable operand
# is false here and the caller confirms presence itself before trusting a false.
! fm_wt_same_object "$T/wt1" "$T/gone" || fail "a missing operand must not compare same"
! fm_wt_same_object "$T/gone" "$T/wt1" || fail "a missing operand must not compare same"
! fm_wt_same_object "$T/gone" "$T/gone" || fail "two missing operands must not compare same"
pass "fm_wt_same_object never claims identity for an operand it cannot stat"

! fm_wt_same_object "$T/plainfile" "$T/plainfile" \
  || fail "a regular file is not a directory and must not compare same"
pass "fm_wt_same_object is false for a path that is not a directory"

! fm_wt_same_object "" "$T/wt1" || fail "an empty operand must not compare same"
! fm_wt_same_object "$T/wt1" "" || fail "an empty operand must not compare same"
! fm_wt_same_object "" "" || fail "two empty operands must not compare same"
pass "fm_wt_same_object is false for an empty operand"

echo "# fm-worktree-identity-lib.test.sh: all assertions passed"
