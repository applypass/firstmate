#!/usr/bin/env bash
# Fork-only: print the claude flags that give a task worker a lean MCP tool set.
#
# usage: fm-claude-lean-mcp.sh <config-dir> <state-dir> [<kind>]
#
# Every Claude launch otherwise loads every MCP server the account carries
# (claude.ai connectors, plugins, user servers), which adds tens of thousands
# of tool-definition tokens to the first turn of every worker run. A ship or
# scout never needs them, so by default the worker gets --strict-mcp-config
# with an empty --mcp-config: no MCP server loads. The captain's own Claude
# config files are never edited; the flags only scope this one launch.
#
# Widening, first match wins:
#   FM_WORKER_MCP=all           inherit the full MCP set (no flags printed)
#   FM_WORKER_MCP=<file>        an --mcp-config JSON file for this launch only
#   <config-dir>/claude-worker-mcp.json
#                               the home's standing allowlist, same JSON shape
#                               as claude's --mcp-config ({"mcpServers":{...}})
#   otherwise                   the empty set
# A named file that is missing or unreadable stops the launch (exit 1) rather
# than silently falling back to a different tool set.
#
# The launch also carries --disallowedTools=<list> (the = form: a space would let
# claude's variadic flag swallow the next argument) for Artifact, Workflow,
# AskUserQuestion and ScheduleWakeup, whose fixed tool text rides every turn
# and which a ship or final-run worker never calls. A scout (<kind> scout)
# keeps Artifact for its report pages and is otherwise unchanged. Set
# FM_WORKER_TOOLS=all to launch with the full built-in tool set.
#
# Prints flags with a trailing space, ready to splice into a launch command.
set -euo pipefail

config_dir=${1:?usage: fm-claude-lean-mcp.sh <config-dir> <state-dir> [<kind>]}
state_dir=${2:?usage: fm-claude-lean-mcp.sh <config-dir> <state-dir> [<kind>]}
kind=${3:-ship}

quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

if [ "$kind" != scout ] && [ "${FM_WORKER_TOOLS:-}" != all ]; then
  printf -- '--disallowedTools=Artifact,Workflow,AskUserQuestion,ScheduleWakeup '
fi

pick=${FM_WORKER_MCP:-}
if [ "$pick" = all ]; then
  exit 0
fi
if [ -z "$pick" ] && [ -e "$config_dir/claude-worker-mcp.json" ]; then
  pick=$config_dir/claude-worker-mcp.json
fi
if [ -z "$pick" ]; then
  pick=$state_dir/claude-worker-mcp-none.json
  mkdir -p "$state_dir"
  [ -f "$pick" ] || printf '{"mcpServers":{}}\n' >"$pick"
fi
if [ ! -f "$pick" ] || [ ! -r "$pick" ]; then
  echo "error: worker MCP config '$pick' is not a readable file" >&2
  exit 1
fi
printf -- '--strict-mcp-config --mcp-config %s ' "$(quote "$pick")"
