#!/usr/bin/env bash
# Fork-only: reads .fork/ci-test-checks, the per-project list of CI checks that
# prove the tests ran. The file header owns the schema. Source this file.
#
#   fm_ci_test_checks_patterns <project>   print the declared patterns, one per
#     line; print nothing for a project that is absent or declared `-`.
#   fm_ci_test_checks_has <project>        succeed when at least one is declared.
#
# Lines in "${FM_HOME:-}/config/ci-test-checks" replace the tracked file's lines
# for the same project.

FM_CITC_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Patterns of <project> in one file, or "-" lines excluded; returns 1 when the
# file holds no line for the project.
fm_ci_test_checks_file_patterns() {  # <file> <project>
  local file=$1 project=$2 found=1 line name rest
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    name=${line%%[[:space:]]*}
    [ "$name" = "$project" ] || continue
    found=0
    rest=${line#"$name"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -z "$rest" ] || [ "$rest" = "-" ] || printf '%s\n' "$rest"
  done < "$file"
  return "$found"
}

fm_ci_test_checks_patterns() {  # <project>
  local project=$1 out
  [ -n "$project" ] || return 0
  if [ -n "${FM_HOME:-}" ] && out=$(fm_ci_test_checks_file_patterns "$FM_HOME/config/ci-test-checks" "$project"); then
    printf '%s' "$out"
    [ -z "$out" ] || printf '\n'
    return 0
  fi
  out=$(fm_ci_test_checks_file_patterns "$FM_CITC_ROOT/.fork/ci-test-checks" "$project") || return 0
  printf '%s' "$out"
  [ -z "$out" ] || printf '\n'
}

fm_ci_test_checks_has() {  # <project>
  [ -n "$(fm_ci_test_checks_patterns "$1")" ]
}
