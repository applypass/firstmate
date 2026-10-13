#!/usr/bin/env bash
# Fork-only: resolve the 1Password service account token for `op` calls (applypass fork).
#
# Agents never use the 1Password desktop session: a bare `op read` falls back to
# the desktop app and prompts for full-account CLI access. fm_op_service_account_token
# prints OP_SERVICE_ACCOUNT_TOKEN from, in order: the environment, the active home's
# .env, then each ancestor home's .env up the local .fm-secondmate-parent chain to
# the primary home. It reads only that one key from a .env file, never sources it,
# and prints nothing and returns 1 when no token is found.
# fm_op_service_account_sources names where it looks, for error messages.

fm_op_env_file_key() {  # <env-file> <key>; prints the last value, quotes stripped
  local file=$1 key=$2 line value=''
  [ -f "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="* | "export $key="*) value=${line#*=} ;;
    esac
  done < "$file"
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

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
  local home=$1 seen='|' depth=0
  if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN"
    return 0
  fi
  while [ "$depth" -le 64 ]; do
    fm_op_env_file_key "$home/.env" OP_SERVICE_ACCOUNT_TOKEN && return 0
    seen="$seen$home|"
    home=$(fm_op_parent_home "$home") || return 1
    home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
    case "$seen" in *"|$home|"*) return 1 ;; esac
    depth=$((depth + 1))
  done
  return 1
}
