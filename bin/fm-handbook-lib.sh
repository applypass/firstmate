#!/usr/bin/env bash
# Fork-only: brief block that points a firstmate-repo worker at the dispatching home's handbook (applypass fork).
# Sourced by bin/fm-brief.sh. The handbook lives in each home's private data/firstmate-handbook/
# and is never committed; a worker's worktree has an empty data/, so the brief names the absolute path.
#
#   fm_handbook_brief_block <home> <project-dir> <code-root>
#
# Prints the block when <project-dir> shares firstmate's lineage (fm_role_self_repo rc 0) and
# <home>/data/firstmate-handbook/INDEX.md exists; prints nothing otherwise.

fm_handbook_brief_block() {
  local home=$1 proj=$2 root=$3 index rc=0
  [ -n "$proj" ] || return 0
  index="${home%/}/data/firstmate-handbook/INDEX.md"
  [ -f "$index" ] || return 0
  fm_role_self_repo "$proj" "$root" || rc=$?
  [ "$rc" -eq 0 ] || return 0
  cat <<EOF2

# Firstmate handbook
Read-only: \`$index\` is the dispatching home's private handbook on how firstmate works (architecture, config, skills, hooks, messaging, multi-machine, fork delta, script map).
Consult it before researching firstmate internals; never copy its content into the repository and never edit it.
In your PR body or report, list the handbook topic file your change makes stale, or "none", so firstmate can refresh it.
EOF2
}
