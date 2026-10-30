#!/usr/bin/env bash
# Fork-only: standing temporary-object cleanup line for every generated worker brief (applypass fork).
# Sourced by bin/fm-brief.sh and appended to every variant (ship in each delivery mode, scout, herdr-lab).
#
#   fm_cleanup_brief_block
#
# Prints the blank-line-led "Temporary objects" section on stdout.

fm_cleanup_brief_block() {
  cat <<'EOF2'

# Temporary objects
Before you create any temporary object (table, schema, file, test account, branch, channel), name it in your first status or plan.
In your final report list each one with its exact drop command and a drop date; never leave one unannounced.
EOF2
}
