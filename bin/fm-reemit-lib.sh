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
# Those go to files under state/ and the re-emit prints a summary: the
# supervision block's Current state lines and wake-handling steps, one line per
# task in flight, counts, any public commitments, and the file pointers to read
# on demand. NEXT STEP points at the supervision file, not at a block above.
#
# Unchanged records are not resent. Each task line, the network lines and each
# context file has a content hash kept in state/.reemit-seen, keyed to the
# session lock pid. The next re-emit in the same session names the file that
# holds a record whose hash matches instead of printing it; a different session
# starts with an empty record.
#
# Files written (under state/, never tracked):
#   .reemit-supervision.txt   the supervision instructions block, every re-emit
#   .reemit-full-digest.txt   the read-once, fleet, network and context sections
#   .reemit-seen              "<lock pid>" then "<record> <hash>" lines
# A read-only re-emit does not own the helm, so it writes its two text files to
# a fresh temporary directory and leaves state/ alone.
#
# The real stdout is saved on fd 7 only while output is hidden or captured, and
# only synchronous children run then, so no detached worker inherits the hook
# pipe.
#
# Hooks, in the order bin/fm-session-start.sh calls them:
#   fm_reemit_hide       start hiding the upstream cue and header
#   fm_reemit_cue        stop hiding; print the short cue and header
#   fm_reemit_capture_supervision   send the supervision block to its file
#   fm_reemit_capture_bulk          send the rest of the bulk digest to its file
#   fm_reemit_finish     print the summary
#   fm_reemit_next_step  print the NEXT STEP section with the file pointers
#
# FM_REEMIT_SHRINK=0 turns every hook into a no-op, so --reemit prints the
# full upstream re-emit digest.

FM_REEMIT_SUP_FILE=
FM_REEMIT_FULL_FILE=
FM_REEMIT_SEEN_FILE=
FM_REEMIT_MAX_TASKS=${FM_REEMIT_MAX_TASKS:-30}

fm_reemit_active() { [ "${REEMIT:-0}" -eq 1 ] && [ "${FM_REEMIT_SHRINK:-1}" != 0 ]; }

fm_reemit_hide() {
  fm_reemit_active || return 0
  exec 7>&1 1>/dev/null
}

fm_reemit_cue() {
  fm_reemit_active || return 0
  exec 1>&7 7>&-
  printf 'RE-EMIT CUE: this is a short re-emit. If this output ends with "Output too large ... Full output saved to <path>",\n'
  printf 'read that whole file now, before acting. The summary below names the files that hold the full digest;\n'
  printf 'read data/captain.md, data/captain-shared.md, and data/learnings.md under %s when you need them.\n' "$DATA"
  section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME"
  printf 'This session already took the helm and has only lost its context. Lock ownership is\n'
  printf 're-verified. Queued wakes ARE still drained. The sweeps startup already ran\n'
  printf '(clone refresh, secondmate checks, handoff retry) are NOT repeated. The bulky sections\n'
  printf 'are summarized below with file pointers.\n'
}

fm_reemit_capture_supervision() {
  local dir="$STATE"
  fm_reemit_active || return 0
  if [ "${READ_ONLY:-0}" -eq 1 ]; then
    dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-reemit-read-only.XXXXXX" 2>/dev/null) || dir=/dev/null
  fi
  if [ "$dir" = /dev/null ]; then
    FM_REEMIT_SUP_FILE=/dev/null
    FM_REEMIT_FULL_FILE=/dev/null
  else
    FM_REEMIT_SUP_FILE="$dir/.reemit-supervision.txt"
    FM_REEMIT_FULL_FILE="$dir/.reemit-full-digest.txt"
  fi
  FM_REEMIT_SEEN_FILE="$STATE/.reemit-seen"
  exec 7>&1 1>"$FM_REEMIT_SUP_FILE"
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
# another session (another lock pid). A read-only session never received the
# owner's records, so it reads none.
FM_REEMIT_SEEN=
fm_reemit_seen_load() {
  local key
  key=$(cat "$STATE/.lock" 2>/dev/null || true)
  FM_REEMIT_KEY=${key:-none}
  FM_REEMIT_SEEN=
  [ "${READ_ONLY:-0}" -eq 0 ] || return 0
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
  local sup_state sup_steps tasks line id same='' n_tasks=0 net net_hash
  local path size lines hash fname backlog afk public n_orphans
  fm_reemit_seen_load
  FM_REEMIT_NEXT=

  subsection "FLEET STATE (re-emit summary)"
  printf 'Full digest of this re-emit: %s\n' "$FM_REEMIT_FULL_FILE"

  # Supervision instructions: the full block is always in its file; the lines a
  # model needs to resume the watch are always printed here.
  subsection "Supervision instructions"
  printf 'Full block: %s (read it before arming, repairing, or changing supervision).\n' "$FM_REEMIT_SUP_FILE"
  sup_state=$(awk '/^Current state:$/ { p = 1 } p && /^$/ { exit } p' "$FM_REEMIT_SUP_FILE" 2>/dev/null)
  printf '%s\n' "${sup_state:-(no Current state lines found; read the full block)}"
  # shellcheck disable=SC2016  # the backticks are literal text in the block
  sup_steps=$(grep -E 'Drain first with|WAKE_ACK_REQUIRED|Do not run `bin/fm-watch-arm.sh`' "$FM_REEMIT_SUP_FILE" 2>/dev/null | head -4)
  if [ -n "$sup_steps" ]; then
    printf 'Ordinary-wake handling:\n%s\n' "$sup_steps"
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
        same="$same $id"
      else
        printf '%s\n' "$line"
      fi
    done <<EOF
$tasks
EOF
    [ -z "$same" ] || printf 'unchanged since the last re-emit, not resent:%s (each in %s/<id>.status and %s/<id>.meta)\n' "$same" "$STATE" "$STATE"
    [ "$n_tasks" -le "$FM_REEMIT_MAX_TASKS" ] || printf '(%s more task line(s) not listed; see the full digest)\n' "$((n_tasks - FM_REEMIT_MAX_TASKS))"
  fi
  n_orphans=$(fm_reemit_extract "$FM_REEMIT_FULL_FILE" "Orphan status logs (state/*.status without matching .meta)" | grep -c '^--- .* ---$')
  [ "$n_orphans" -eq 0 ] || printf 'Orphan status logs (state/*.status without matching .meta): %s; tails in the full digest.\n' "$n_orphans"

  subsection "Backlog counts"
  # tasks-axi prints each group as a "<label>:" line, then a bare "count: N";
  # join them as "label: N" so each count says which group it is. The manual
  # listing has no groups and ends with one "(shown N in-flight, ...)" line.
  backlog=$(fm_reemit_extract "$FM_REEMIT_FULL_FILE" "data/backlog.md" | awk '
    /^[^[:space:]].*:$/ && !/[[{]/ { label = $0; sub(/:$/, "", label); sub(/ [(].*$/, "", label); next }
    /^count: / && label != "" { n = $0; sub(/^count: /, "", n); counts = counts (counts == "" ? "" : ", ") label ": " n; label = ""; next }
    /^[(]shown [0-9]+ in-flight/ { manual = $0 }
    END { if (counts != "") print counts; if (manual != "") print manual }')
  printf '%s\n' "${backlog:-(no counts found)}"
  printf 'Task bodies: bin/fm-tasks-axi.sh show <id> --full, or data/backlog.md.\n'

  subsection "AFK"
  afk=$(fm_reemit_extract "$FM_REEMIT_FULL_FILE" "AFK" | head -3)
  printf '%s\n' "${afk:-(unknown)}"

  public=$(fm_reemit_extract "$FM_REEMIT_FULL_FILE" "Public commitments")
  if [ -n "$public" ]; then
    subsection "Public commitments"
    printf '%s\n' "$public"
  fi

  net=$(fm_reemit_extract "$FM_REEMIT_FULL_FILE" "NETWORK CHECKS" | grep . | head -12)
  net_hash=$(fm_reemit_hash "$net")
  subsection "Network checks"
  if [ -z "$net" ]; then
    printf '(nothing reported)\n'
  elif fm_reemit_unchanged network "$net_hash"; then
    printf 'unchanged since the last re-emit; see NETWORK CHECKS in %s.\n' "$FM_REEMIT_FULL_FILE"
  else
    printf '%s\n' "$net"
  fi

  subsection "Context files (read on demand)"
  for fname in projects.md secondmates.md captain.md captain-shared.md learnings.md; do
    path="$DATA/$fname"
    if [ ! -f "$path" ]; then
      printf '%s: ABSENT\n' "$path"
      continue
    fi
    size=$(wc -c < "$path" | tr -d ' ')
    lines=$(wc -l < "$path" | tr -d ' ')
    hash=$(cksum < "$path" | awk '{ print $1 "-" $2 }')
    if fm_reemit_unchanged "file:$fname" "$hash"; then
      printf '%s: unchanged since the last re-emit\n' "$path"
    else
      printf '%s: %s bytes, %s lines\n' "$path" "$size" "$lines"
    fi
  done

  # Remember what was sent, for this session only. A read-only session does not
  # own the helm, so it writes nothing.
  if [ "${READ_ONLY:-0}" -eq 0 ]; then
    { printf '%s\n' "$FM_REEMIT_KEY"; printf '%s' "$FM_REEMIT_NEXT"; } > "$FM_REEMIT_SEEN_FILE" 2>/dev/null || true
  fi
}

# fm_reemit_next_step: the re-emit NEXT STEP section. It names the supervision
# file instead of a block above, because the summary does not print the block.
fm_reemit_next_step() {
  local sup="block in $FM_REEMIT_SUP_FILE (its key lines are in the summary above)"
  section "NEXT STEP"
  if [ "$READ_ONLY" -eq 1 ]; then
    cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
  elif [ "$AFK_PRESENT" -eq 1 ] && [ "$AFK_MODE" = quiet ]; then
    cat <<EOF
Quiet mode is active. Follow the supervision operating instructions
$sup: load /quiet and ensure the daemon is running, because the daemon owns
watcher supervision. Ordinary captain chat does not exit it; only an
explicit /quiet off does.

EOF
  elif [ "$AFK_PRESENT" -eq 1 ]; then
    cat <<EOF
Away mode is active. Follow the supervision operating instructions $sup:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
  elif [ -f "$CONFIG/x-mode.env" ]; then
    cat <<EOF
Follow the supervision operating instructions $sup for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
  else
    cat <<EOF
Follow the supervision operating instructions $sup for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
  fi
  cat <<EOF
The digest above is complete for this session start. The READ-ONCE CONTRACT
section in $FM_REEMIT_FULL_FILE governs what may still be read from disk.
EOF
}
