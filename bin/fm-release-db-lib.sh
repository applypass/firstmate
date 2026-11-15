#!/usr/bin/env bash
# fm-release-db-lib.sh - the release PR body's "## Database" section (applypass fork).
#
# apply_pass_backend's schema-applied CI check (scripts/ci-checks/schema-applied.sh) fails a PR
# into main that changes schema.sql unless its body carries a ticked line
#   - [x] schema.sql DDL applied to the prod database (schema.sql <digest>)
# where <digest> is the first 12 hex chars of the sha256 of the schema.sql lines the PR adds
# (git diff -U0 main...dev -- schema.sql, added lines only).
#
# Sourced by bin/fm-release-gate.sh. fm_release_db_section prints the section to add to a
# release body, or nothing. It never prints a ticked line: a person ticks it after applying
# the DDL, and a body that already has a Database section is left verbatim, tick state included.

# fm_release_db_digest <patch-text>: digest of the added lines in a schema.sql patch,
# the same selection as schema-applied.sh --digest.
fm_release_db_digest() {
  printf '%s\n' "$1" | grep -E '^\+[^+]|^\+$' | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-12
}

# fm_release_db_has_section <body>: 0 when the body already has a Database heading or a
# "schema.sql DDL applied to the prod database" line, ticked or not, under any heading.
fm_release_db_has_section() {
  grep -qiE '^#{1,6}[[:space:]]+Database[[:space:]]*$|schema\.sql DDL applied to the prod database' <<<"$1"
}

# fm_release_db_section <gh-cmd> <owner/repo> <body>: prints the new section, or nothing when
# the body has one, the release does not change schema.sql, or the patch cannot be read. The
# compare API lists at most 300 files and drops the patch of a large diff; either case warns.
fm_release_db_section() {
  local gh=$1 slug=$2 body=$3 patch digest
  fm_release_db_has_section "$body" && return 0
  # shellcheck disable=SC2016
  patch=$("$gh" api "repos/$slug/compare/main...dev" --paginate \
    --jq '(.files // []) as $f
      | if ($f | length) >= 300 and all($f[]; .filename != "schema.sql")
        then error("the compare lists 300 files, so schema.sql may be cut off")
        else $f[] | select(.filename == "schema.sql") | .patch // error("GitHub omitted the schema.sql patch")
        end') || {
    echo "warning: could not read schema.sql changes for $slug; no Database section added" >&2
    return 0
  }
  [ -n "$patch" ] || return 0
  digest=$(fm_release_db_digest "$patch")
  printf '## Database\n\n- [ ] schema.sql DDL applied to the prod database (schema.sql %s)\n' "$digest"
}
