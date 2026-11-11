#!/usr/bin/env bash
# Fork-only: keep every agent off the 1Password desktop session (applypass fork).
#
# Agents may use only the vault-scoped service account
# (bin/fm-op-service-account-lib.sh), never the captain's 1Password desktop app.
# Without OP_SERVICE_ACCOUNT_TOKEN, `op` falls back to the app, and the op
# PreToolUse hook (bin/fm-op-pretool-check.sh) sees only the command line an
# agent types, so `op` run inside a script, by a harness with no hooks, or by
# absolute path slips past it. The block therefore lives in the environment:
# OP_BIOMETRIC_UNLOCK_ENABLED=false is the 1Password CLI's documented switch that
# turns its app integration off, so every child process of an agent that starts
# with it gets "not signed in" instead of the desktop app, while a call with the
# service account token still works.
#
# Where the block is set:
#   - bin/fm-spawn.sh exports it into every worker, scout, and secondmate launch
#     on every harness and backend, fresh spawn and relaunch alike.
#   - `install <dir>` merges it into <dir>/.claude/settings.local.json `env`, so
#     a Claude session started in <dir> carries it; bin/fm-session-start.sh runs
#     it for the home, which covers a Claude primary from its next start.
#   - `check` reports when the calling session lacks it; bin/fm-session-start.sh
#     prints that report in the digest, which is how a primary on another
#     harness, or a Claude primary started before install, learns of the gap.
# Captain-run commands in the captain's own terminal are untouched and keep the
# desktop session.
#
# Usage:
#   fm-op-desktop-block.sh install <dir>
#   fm-op-desktop-block.sh check
#
# Exit: install 0 on success, 1 on failure, 2 on usage. check 0 and silent when
# OP_BIOMETRIC_UNLOCK_ENABLED=false is set in its environment, otherwise 1 with
# a report on stdout.
set -u

VAR=OP_BIOMETRIC_UNLOCK_ENABLED

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  install)
    [ "$#" -eq 2 ] && [ -d "$2" ] || { usage >&2; exit 2; }
    command -v jq >/dev/null 2>&1 || { echo "fm-op-desktop-block: jq is required" >&2; exit 1; }
    DIR=$(CDPATH='' cd -- "$2" && pwd -P) || exit 1
    FILE="$DIR/.claude/settings.local.json"
    mkdir -p "$DIR/.claude" || exit 1
    [ -f "$FILE" ] || printf '{}\n' >"$FILE"
    TMP=$(mktemp "$FILE.XXXXXX") || exit 1
    if ! jq --arg var "$VAR" '.env //= {} | .env[$var] = "false"' "$FILE" >"$TMP"; then
      rm -f "$TMP"
      echo "fm-op-desktop-block: could not merge into $FILE" >&2
      exit 1
    fi
    mv "$TMP" "$FILE"
    ;;
  check)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    [ "${OP_BIOMETRIC_UNLOCK_ENABLED:-}" != false ] || exit 0
    printf '!! 1PASSWORD DESKTOP SESSION REACHABLE: this session started without %s=false,\n' "$VAR"
    printf '!! so an op call it makes without OP_SERVICE_ACCOUNT_TOKEN - typed, inside a script, or by\n'
    printf '!! absolute path - can reach the captain'"'"'s 1Password desktop app, which agents must never use.\n'
    printf '!! Claude: a locked session start writes it to the home .claude/settings.local.json; restart to load it.\n'
    printf '!! Other harnesses: restart this session with %s=false exported in its launch environment.\n' "$VAR"
    exit 1
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
