# shellcheck shell=bash
# Shared filesystem-identity comparison for the spawn isolation guard.
# Usage: . bin/fm-worktree-identity-lib.sh; fm_wt_same_object "<a>" "<b>"
#
# ONE OWNER for the question "are these two paths the same directory?" as the
# guard in bin/fm-spawn.sh has to ask it. The guard decides whether a launch
# path is an isolated worktree by comparing three pairs of resolved paths, and
# every one of those comparisons has to answer that question, not the weaker
# question "do these two strings match?".
#
# Path text is not identity. `pwd -P` resolves symlinks but does not case-fold,
# and `git rev-parse --show-toplevel` returns the canonical spelling git holds,
# so on a case-insensitive filesystem one directory yields two different
# strings. Comparing the strings therefore produced a false refusal: a genuine
# isolated worktree entered as `.../WT1` was rejected as "not a worktree root"
# while the same worktree entered as `.../wt1` was accepted. Device and inode
# do not have that problem, so the comparison is `test -ef`.
#
# `test -ef` is false when either operand cannot be stat'd, which reads as "not
# the same object". For the guard's must-be-distinct comparisons that direction
# is unsafe: a project path that has gone away would read as distinct from the
# launch path and bless the launch. So identity is only ever claimed for two
# operands this file has first confirmed are existing directories, and a caller
# that needs "proven distinct" confirms its operands exist before comparing
# rather than reading a false return as proof of distinctness.
#
# The caller keeps its own policy: bin/fm-spawn.sh owns which pairs are
# compared, what each refusal means, and the message it prints. This file owns
# only what "the same directory" means.

# fm_wt_same_object <a> <b>: true when both paths are existing directories and
# name one filesystem object, by device and inode rather than by path text.
# False for every other case, including an operand that cannot be stat'd -
# identity is never claimed, and never denied, on evidence this cannot read.
fm_wt_same_object() {  # <a> <b>
  local a=$1 b=$2
  [ -d "$a" ] && [ -d "$b" ] && [ "$a" -ef "$b" ]
}
