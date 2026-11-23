#!/usr/bin/env bash
# fm-waiver-key-lib.sh - the decision-key gate for fm-pr-merge.sh waivers (applypass fork).
#
# A merge waiver (--waive-proof, --allow-red, --allow-missing, --allow-no-pipeline)
# needs the captain's explicit word. fm_waiver_key_require turns that rule into a
# check: the caller passes --decision-key <key>, and the key must be one that
# bin/fm-decide.sh recorded for this task (the key is the task id or starts with
# "<task-id>-") whose text quotes the captain's words with the word "captain" right
# before the quote: captain: "<words>" or captain said "<words>" (any case, straight
# or curly quotes, 3+ characters inside). A bare quoted span such as "lint" fails.
# It reads the entry through `fm-decide.sh show`, the one reader of decided.md.
#
# fm_waiver_key_require <task-id> <key> <waiver-flag>...
#   returns 0 when valid; otherwise prints the refusal (key problem and remedy)
#   to stderr and returns 1.
# Needs FM_HOME (and optionally FM_DATA_OVERRIDE) in the environment, as fm-decide.sh does.

fm_waiver_key_require() {
  local id=$1 key=$2 flags text here
  shift 2
  flags="$*"
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [ -z "$key" ]; then
    echo "error: $flags needs the captain's explicit word recorded as a decision; record it with: fm-decide.sh record ${id}-waiver '<what was waived> - captain: \"<the captain's exact words>\"', then pass --decision-key ${id}-waiver" >&2
    return 1
  fi
  case "$key" in
    "$id" | "$id"-*) ;;
    *)
      echo "error: --decision-key '$key' is not for task $id; its key must be '$id' or start with '$id-'; record the captain's words with: fm-decide.sh record ${id}-waiver '<what was waived> - captain: \"<the captain's exact words>\"' and pass that key" >&2
      return 1
      ;;
  esac
  if ! text=$("$here/fm-decide.sh" show "$key" 2>/dev/null) || [ -z "$text" ]; then
    echo "error: --decision-key '$key' is not recorded in data/decided.md; record the captain's words with: fm-decide.sh record $key '<what was waived> - captain: \"<the captain's exact words>\"'" >&2
    return 1
  fi
  if ! printf '%s' "$text" | grep -Eiq 'captain([[:space:]]+said)?:?[[:space:]]*("[^"]{3,}"|“[^”]{3,}”)'; then
    echo "error: decision '$key' does not quote the captain; its text must attribute the captain's exact words as captain: \"<words>\" or captain said \"<words>\"; record a new key with: fm-decide.sh record ${key}-quoted '<what was waived> - captain: \"<the captain's exact words>\"'" >&2
    return 1
  fi
  return 0
}
