#!/usr/bin/env bash
# Fork-only: resolve the 1Password service account token for `op` calls (applypass fork).
#
# Agents never use the 1Password desktop session: a bare `op read` falls back to
# the desktop app and prompts for full-account CLI access. fm_op_service_account_token
# prints OP_SERVICE_ACCOUNT_TOKEN from, in order: the environment, the active home's
# .env, then each ancestor home's .env up the local .fm-secondmate-parent chain to
# the primary home. It reads only that one key through fmx_env_get, never sources a .env,
# and prints nothing and returns 1 when no token is found.
# fm_op_service_account_sources names where it looks, for error messages.

# shellcheck source=bin/fm-env-lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-env-lib.sh"

fm_op_parent_home() {  # <home>; prints the local parent home of a secondmate home
  local lib
  lib="$(dirname "${BASH_SOURCE[0]}")/fm-secondmate-parent-lib.sh"
  [ -f "$lib" ] || return 1
  # shellcheck source=bin/fm-secondmate-parent-lib.sh disable=SC1091
  . "$lib"
  fm_secondmate_parent_record_parse "$1/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] && [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 1
  printf '%s' "$FM_SECONDMATE_PARENT_HOME"
}

fm_op_service_account_sources() {  # <home>
  printf 'the environment, %s/.env, and each parent home .env up its .fm-secondmate-parent chain' "$1"
}

fm_op_service_account_token() {  # <home>
  local home=$1 seen='|' depth=0 value
  if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN"
    return 0
  fi
  while [ "$depth" -le 64 ]; do
    value=$(fmx_env_get OP_SERVICE_ACCOUNT_TOKEN "$home/.env")
    [ -z "$value" ] || { printf '%s' "$value"; return 0; }
    seen="$seen$home|"
    home=$(fm_op_parent_home "$home") || return 1
    home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
    case "$seen" in *"|$home|"*) return 1 ;; esac
    depth=$((depth + 1))
  done
  return 1
}
