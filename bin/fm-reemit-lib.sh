#!/usr/bin/env bash
# Fork-only (applypass): fm-reemit-lib.sh - shrinks the context re-emit of
# bin/fm-session-start.sh --reemit from the full digest to a short summary.
#
# Sourced by bin/fm-session-start.sh. Every function is a no-op unless the
# caller set REEMIT=1, so the first full session-start digest is unchanged.
#
# A re-emit keeps printing, in full and in the original order: the lock section,
# the home role, the bootstrap diagnostics, any AGENTS.md instruction refresh,
# the wake queue with its OPEN DECISIONS and WAKE_ACK_REQUIRED line, and the
# closing NEXT STEP section (read-only, away, quiet and X-mode guidance). Only
# the bulky sections change: the supervision instructions, the read-once
# contract, the fleet state, the network checks and the curated context files.
# Those go to files under state/ and the re-emit prints a summary with counts,
# one line per task in flight, and the file pointers to read on demand.
#
# Unchanged records are not resent. Each record (the supervision block, each
# task line, the network lines, each context file) has a content hash kept in
# state/.reemit-seen, keyed to the session lock pid. The next re-emit in the
# same session prints "unchanged" for records whose hash matches; a different
# session starts with an empty record.
#
# Files written (all under state/, never tracked):
#   .reemit-supervision.txt   the supervision instructions block
#   .reemit-full-digest.txt   the read-once, fleet, network and context sections
#   .reemit-seen              "<lock pid>" then "<record> <hash>" lines
#
# Hooks, in the order bin/fm-session-start.sh calls them:
#   fm_reemit_hide       start hiding the upstream cue and header
#   fm_reemit_cue        stop hiding; print the short cue and header
#   fm_reemit_capture_supervision   send the supervision block to its file
#   fm_reemit_capture_bulk          send the rest of the bulk digest to its file
#   fm_reemit_finish     print the summary

FM_REEMIT_SUP_FILE=
FM_REEMIT_FULL_FILE=
FM_REEMIT_SEEN_FILE=
FM_REEMIT_MAX_TASKS=${FM_REEMIT_MAX_TASKS:-30}

fm_reemit_active() { [ "${REEMIT:-0}" -eq 1 ]; }

fm_reemit_hide() {
  fm_reemit_active || return 0
  exec 7>&1 1>/dev/null
}

fm_reemit_cue() {
  fm_reemit_active || return 0
  exec 1>&7
  FM_REEMIT_SUP_FILE="$STATE/.reemit-supervision.txt"
  FM_REEMIT_FULL_FILE="$STATE/.reemit-full-digest.txt"
  FM_REEMIT_SEEN_FILE="$STATE/.reemit-seen"
  printf 'RE-EMIT CUE: this is a short re-emit. If this output ends with "Output too large ... Full output saved to <path>",\n'
  printf 'read that whole file now, before acting. The full digest is %s;\n' "$FM_REEMIT_FULL_FILE"
  printf 'read data/captain.md, data/captain-shared.md, and data/learnings.md under %s when you need them.\n' "$DATA"
  section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME"
  printf 'This session already took the helm and has only lost its context. Lock ownership is\n'
  printf 're-verified. Queued wakes ARE still drained. The sweeps startup already ran\n'
  printf '(clone refresh, secondmate checks, handoff retry) are NOT repeated. The bulky sections\n'
  printf 'are summarized below with file pointers.\n'
}

fm_reemit_capture_supervision() {
  fm_reemit_active || return 0
  exec 1>"$FM_REEMIT_SUP_FILE"
}

fm_reemit_capture_bulk() {
  fm_reemit_active || return 0
  exec 1>"$FM_REEMIT_FULL_FILE"
}

# fm_reemit_hash <text>: short content hash, portable (cksum is POSIX).
fm_reemit_hash() { printf '%s' "$1" | cksum | awk '{ print $1 "-" $2 }'; }

# fm_reemit_extract <file> <title>: the body of one section or subsection of
# the captured digest (see section() and subsection() in fm-session-start.sh).
fm_reemit_extract() {
  awk -v want="$2" -v rule="$RULE" -v sub_rule="$SUBRULE" '
    function flush() { if (have && cur == want) print held; have = 0 }
    $0 == rule { if (hdr) { hdr = 0; have = 0; cur = held; held = ""; next } flush(); hdr = 1; next }
    $0 == sub_rule { have = 0; cur = held; next }
    { flush(); held = $0; have = 1 }
    END { flush() }
  ' "$1"
}

# fm_reemit_seen_load: reads the hash record, dropping it when it belongs to
# another session (another lock pid).
FM_REEMIT_SEEN=
fm_reemit_seen_load() {
  local key
  key=$(cat "$STATE/.lock" 2>/dev/null || true)
  FM_REEMIT_KEY=${key:-none}
  FM_REEMIT_SEEN=
  [ -f "$FM_REEMIT_SEEN_FILE" ] || return 0
  [ "$(sed -n '1p' "$FM_REEMIT_SEEN_FILE" 2>/dev/null)" = "$FM_REEMIT_KEY" ] || return 0
  FM_REEMIT_SEEN=$(sed '1d' "$FM_REEMIT_SEEN_FILE" 2>/dev/null)
}

# fm_reemit_unchanged <record> <hash>: true when the record was already sent
# with this hash. Always records the hash for the next re-emit.
FM_REEMIT_NEXT=
fm_reemit_unchanged() {
  local name=$1 hash=$2
  FM_REEMIT_NEXT="${FM_REEMIT_NEXT}${name} ${hash}
"
  printf '%s\n' "$FM_REEMIT_SEEN" | grep -qxF -- "$name $hash"
}

fm_reemit_finish() {
  fm_reemit_active || return 0
  exec 1>&7 7>&-
  local sup sup_hash tasks line id n_same=0 n_tasks=0 net net_hash n_ctx=0 n_ctx_same=0
  local path label size lines hash fname backlog afk
  fm_reemit_seen_load
  FM_REEMIT_NEXT=

  subsection "FLEET STATE (re-emit summary)"
  printf 'Full digest of this re-emit: %s\n' "$FM_REEMIT_FULL_FILE"

  # Supervision instructions: the one record a model needs verbatim to resume
  # the watch, so it is resent in full unless unchanged since the last re-emit.
  sup=$(cat "$FM_REEMIT_SUP_FILE" 2>/dev/null || true)
  sup_hash=$(fm_reemit_hash "$sup")
  subsection "Supervision instructions"
  if fm_reemit_unchanged supervision "$sup_hash"; then
    printf 'unchanged since the last re-emit in this session (not resent); read %s to see it again.\n' "$FM_REEMIT_SUP_FILE"
  else
    printf '%s\n' "$sup"
  fi

  subsection "Work in flight (one line per task: id | endpoint | last status line)"
  tasks=$(fm_reemit_extract "$FM_REEMIT_FULL_FILE" "Work under way (state/*.meta)" | awk '
    function out() { if (id != "") printf "%s | %s | %.70s\n", id, (ep == "" ? "unknown" : ep), last }
    /^--- .* ---$/ { out(); id = $2; ep = ""; last = ""; intail = 0; next }
    /^endpoint: / { ep = $2; next }
    /^status tail/ { intail = 1; next }
    intail && NF { last = $0 }
    END { out() }
  ')
  if [ -z "$tasks" ]; then
    printf '(none)\n'
  else
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n_tasks=$((n_tasks + 1))
      id=${line%% | *}
      if [ "$n_tasks" -gt "$FM_REEMIT_MAX_TASKS" ]; then
        continue
      elif fm_reemit_unchanged "task:$id" "$(fm_reemit_hash "$line")"; then
        n_same=$((n_same + 1))
      else
        printf '%s\n' "$line"
      fi
    done <<EOF
$tasks
EOF
    [ "$n_tasks" -le "$FM_REEMIT_MAX_TASKS" ] || printf '(%s more task line(s) not listed; see the full digest)\n' "$((n_tasks - FM_REEMIT_MAX_TASKS))"
    [ "$n_same" -eq 0 ] || printf '(%s of %s task line(s) unchanged since the last re-emit, not resent; full tails: %s)\n' "$n_same" "$n_tasks" "$FM_REEMIT_FULL_FILE"
  fi

  subsection "Backlog counts"
  backlog=$(fm_reemit_extract "$FM_REEMIT_FULL_FILE" "data/backlog.md" | grep -E '^(tasks: |count: |ready\[|\(shown )' | head -8)
  printf '%s\n' "${backlog:-(no counts found)}"
  printf 'Task bodies: bin/fm-tasks-axi.sh show <id> --full, or data/backlog.md.\n'

  subsection "AFK"
  afk=$(fm_reemit_extract "$FM_REEMIT_FULL_FILE" "AFK" | head -3)
  printf '%s\n' "${afk:-(unknown)}"

  net=$(fm_reemit_extract "$FM_REEMIT_FULL_FILE" "NETWORK CHECKS" | grep . | head -12)
  net_hash=$(fm_reemit_hash "$net")
  subsection "Network checks"
  if [ -z "$net" ]; then
    printf '(nothing reported)\n'
  elif fm_reemit_unchanged network "$net_hash"; then
    printf 'unchanged since the last re-emit (not resent).\n'
  else
    printf '%s\n' "$net"
  fi

  subsection "Context files (read on demand)"
  for fname in projects.md secondmates.md captain.md captain-shared.md learnings.md; do
    path="$DATA/$fname"
    label="data/$fname"
    n_ctx=$((n_ctx + 1))
    if [ ! -f "$path" ]; then
      printf '%s: ABSENT\n' "$label"
      continue
    fi
    size=$(wc -c < "$path" | tr -d ' ')
    lines=$(wc -l < "$path" | tr -d ' ')
    hash=$(cksum < "$path" | awk '{ print $1 "-" $2 }')
    if fm_reemit_unchanged "file:$fname" "$hash"; then
      n_ctx_same=$((n_ctx_same + 1))
    else
      printf '%s: %s bytes, %s lines\n' "$label" "$size" "$lines"
    fi
  done
  [ "$n_ctx_same" -eq 0 ] || printf '(%s of %s context file(s) unchanged since the last re-emit, not listed)\n' "$n_ctx_same" "$n_ctx"

  # Remember what was sent, for this session only. A read-only session does not
  # own the helm, so it writes nothing.
  if [ "${READ_ONLY:-0}" -eq 0 ]; then
    { printf '%s\n' "$FM_REEMIT_KEY"; printf '%s' "$FM_REEMIT_NEXT"; } > "$FM_REEMIT_SEEN_FILE" 2>/dev/null || true
  fi
}
