#!/usr/bin/env bash
# Fork-only: reads .fork/ci-test-checks, the per-project list of CI checks that
# prove the tests ran. The file header owns the schema. Source this file.
#
#   fm_ci_test_checks_patterns <project>   print the declared patterns, one per
#     line; print nothing for a project that is absent or declared `-`.
#   fm_ci_test_checks_has <project>        succeed when at least one is declared.

FM_CITC_FILE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/.fork/ci-test-checks

fm_ci_test_checks_patterns() {  # <project>
  local project=$1 line name rest
  [ -n "$project" ] && [ -r "$FM_CITC_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    name=${line%%[[:space:]]*}
    [ "$name" = "$project" ] || continue
    rest=${line#"$name"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -z "$rest" ] || [ "$rest" = "-" ] || printf '%s\n' "$rest"
  done < "$FM_CITC_FILE"
}

fm_ci_test_checks_has() {  # <project>
  [ -n "$(fm_ci_test_checks_patterns "$1")" ]
}
