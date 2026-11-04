#!/usr/bin/env bash
# Fork-only: reader-and-writer audit rule for generated ship briefs (applypass fork).
# Sourced by bin/fm-brief.sh and appended to the ship variants. The release gate
# (bin/fm-release-gate.sh) looks for this heading in the PR body.
#
#   fm_release_audit_brief_block
#
# Prints the blank-line-led rule on stdout.

fm_release_audit_brief_block() {
  cat <<'EOF2'

# Stored data and API fields
If the PR changes stored data or an API field, add a `## Reader and writer audit` section to the PR body that lists every reader and writer of each changed field and what each one does with the change.
The release gate refuses to ship a PR that changes schema, SQL scripts or the API spec without that exact heading.
EOF2
}
