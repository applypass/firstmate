#!/usr/bin/env bash
# Fork-only: print the 1Password service account token for one home (applypass fork).
#
# Thin bash entry point over bin/fm-op-service-account-lib.sh for callers that
# are not bash scripts. The op guard's deny reason (bin/fm-op-command-policy.mjs)
# tells an agent to run this inside a command substitution, and an agent's shell
# may be zsh, where sourcing the library fails because it locates its siblings
# through BASH_SOURCE. The shebang pins bash, so the same remedy line works from
# any shell. Prints the token and exits 0, or prints nothing and exits 1 when no
# token is found, so `OP_SERVICE_ACCOUNT_TOKEN=$(...) && op ...` stops before op.
#
# Usage: bin/fm-op-service-account-token.sh <home>
set -euo pipefail
[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: fm-op-service-account-token.sh <home>" >&2; exit 2; }
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-op-service-account-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-op-service-account-lib.sh"
fm_op_service_account_token "$1"
