#!/usr/bin/env bash
# Fork-only (applypass): usage-limit sweep and auto-resume for this home's endpoints.
# Usage: fm-usage-limit-tick.sh [--now <epoch>]
# Run by bin/fm-watch.sh about every minute. For every local endpoint recorded in
# state/*.meta (mates and workers; a remote mate runs its own home's sweep):
#   1. Read the visible screen (fm_backend_visible_capture, else fm_backend_capture).
#   2. A usage-limit stop with no record writes state/<id>.usage-limit once
#      (endpoint, kind, first_seen, reset_epoch, reset_source). Detection is idempotent.
#   3. Before reset + grace nothing is sent.
#   4. After it, send the dismiss key when a waiting menu is up (never a credits,
#      extra-usage or upgrade option), then a resume steer through bin/fm-send.sh,
#      at most FM_UL_MAX_ATTEMPTS times, FM_UL_RETRY_SECS apart.
#   5. The record clears when the limit screen is gone. An endpoint still stopped
#      after all attempts prints one `stuck` line (once per incident) with endpoint,
#      first-seen, reset time and the redacted last screen lines.
# Prints nothing except a stuck line; the watcher turns that into a wake.
# Nothing is killed, torn down or discarded. Contract: docs/usage-limit-resume.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-usage-limit-lib.sh
. "$SCRIPT_DIR/fm-usage-limit-lib.sh"

FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
MAX_ATTEMPTS=${FM_UL_MAX_ATTEMPTS:-3}
RETRY_SECS=${FM_UL_RETRY_SECS:-120}
GRACE_SECS=${FM_UL_GRACE_SECS:-45}
ASSUMED_SECS=${FM_UL_ASSUMED_SECS:-900}
SEND=${FM_UL_SEND:-$SCRIPT_DIR/fm-send.sh}
NOW=${FM_USAGE_LIMIT_NOW:-$(date +%s)}
if [ "${1:-}" = --now ]; then NOW=${2:?--now needs an epoch}; fi

rec_get() { fm_meta_get "$1" "$2"; }

rec_write() {  # <file> <key=val>...   (atomic rewrite of the whole record)
  local file=$1 tmp
  shift
  tmp=$(mktemp "$file.XXXXXX") || return 1
  printf '%s\n' "$@" >"$tmp" && mv "$tmp" "$file"
}

rec_set() {  # <file> <key> <val>
  local file=$1 key=$2 val=$3 line out=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$key="*) ;; *) out+=("$line") ;; esac
  done <"$file"
  out+=("$key=$val")
  rec_write "$file" "${out[@]}"
}

redact() {  # strip secrets from screen lines
  sed -E \
    -e 's/(sk-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{8,}|gho_[A-Za-z0-9]{8,}|xox[a-z]-[A-Za-z0-9-]{8,}|AKIA[A-Z0-9]{12,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_.-]+)/[redacted]/g' \
    -e 's/((token|secret|password|passwd|api[_-]?key|authorization|bearer)[A-Za-z_]*[=: ]+)[^[:space:]]+/\1[redacted]/Ig'
}

iso() {  # <epoch>
  if date --version >/dev/null 2>&1; then date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; else date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; fi
}

capture_screen() {  # <backend> <target>
  if fm_backend_visible_capture_supported "$1"; then
    fm_backend_visible_capture "$1" "$2" 2>/dev/null
  else
    fm_backend_capture "$1" "$2" 40 2>/dev/null
  fi
}

# 16 lowercase hex from the incident, so a retried send dedups on its delivery id.
delivery_id() {  # <id> <first_seen> <attempt>
  printf '%s-%s-%s' "$1" "$2" "$3" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-16
}

resume_text() {  # <ref>
  printf 'Your Claude usage limit has reset. Continue the work you were doing before it stopped you (ref %s). If a task is already finished, say so in your status.' "$1"
}

send_resume() {  # <id> <kind> <first_seen> <attempt>
  local id=$1 kind=$2 first=$3 attempt=$4 ref text did
  ref="ul-$first-$attempt"
  text=$(resume_text "$ref")
  if [ "$kind" = mate ]; then
    did=$(delivery_id "$id" "$first" "$attempt")
    FM_HOME="$FM_HOME" "$SEND" "$id" --fire-and-forget "$did" "$text" >/dev/null 2>&1
  else
    FM_HOME="$FM_HOME" "$SEND" "$id" "$text" >/dev/null 2>&1
  fi
}

handle_endpoint() {  # <meta>
  local meta=$1 id backend target kind harness rec screen first reset attempts last
  local source stuck_text
  id=$(basename "$meta" .meta)
  case "$id" in ''|*[!A-Za-z0-9._-]*|.*) return 0 ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 0
  harness=$(fm_meta_get "$meta" harness)
  kind=worker
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] && kind=mate
  rec="$STATE/$id.usage-limit"

  screen=$(capture_screen "$backend" "$target") || return 0
  [ -n "$screen" ] || return 0
  fm_usage_limit_detect "$screen" "$NOW"

  if [ "$FM_UL_STOPPED" != 1 ]; then
    # Limit screen gone: the endpoint resumed (or the stop was never real).
    [ ! -f "$rec" ] || rm -f "$rec"
    return 0
  fi

  if [ ! -f "$rec" ]; then
    reset=$FM_UL_RESET source=screen
    if [ -z "$reset" ]; then
      reset=$(fm_usage_limit_quota_reset "$harness" "$NOW" 2>/dev/null || true)
      source=quota
    fi
    if [ -z "$reset" ]; then
      reset=$((NOW + ASSUMED_SECS)) source=assumed
    fi
    rec_write "$rec" "endpoint=$id" "kind=$kind" "first_seen=$NOW" "reset_epoch=$reset" \
      "reset_source=$source" "attempts=0" "last_attempt=0" "surfaced=0" || return 0
  fi

  first=$(rec_get "$rec" first_seen)
  reset=$(rec_get "$rec" reset_epoch)
  source=$(rec_get "$rec" reset_source)
  attempts=$(rec_get "$rec" attempts)
  last=$(rec_get "$rec" last_attempt)
  : "${attempts:=0}" "${last:=0}"

  # A better reset time on screen refines a guessed one.
  if [ "$source" != screen ] && [ -n "$FM_UL_RESET" ] && [ "$FM_UL_RESET" != "$reset" ]; then
    rec_set "$rec" reset_epoch "$FM_UL_RESET" && rec_set "$rec" reset_source screen
    reset=$FM_UL_RESET
  fi

  [ "$NOW" -ge $((reset + GRACE_SECS)) ] || return 0   # nothing is sent before reset

  # Still stopped after the last attempt: surface once, never retry again.
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    if [ "$(rec_get "$rec" surfaced)" != 1 ] && [ "$NOW" -ge $((last + RETRY_SECS)) ]; then
      rec_set "$rec" surfaced 1
      stuck_text=$(printf '%s\n' "$screen" | grep -v '^[[:space:]]*$' | tail -n 6 | redact | tr '\n' '|')
      printf 'usage-limit stuck: endpoint=%s kind=%s first_seen=%s reset=%s attempts=%s last_screen=%s\n' \
        "$id" "$kind" "$(iso "$first")" "$(iso "$reset")" "$attempts" "$stuck_text"
    fi
    return 0
  fi
  [ "$NOW" -ge $((last + RETRY_SECS)) ] || return 0

  attempts=$((attempts + 1))
  rec_set "$rec" attempts "$attempts" && rec_set "$rec" last_attempt "$NOW" || return 0
  # Dismiss a menu only when its highlighted option waits; never a credits option.
  case "$FM_UL_KEY" in
    Enter|Escape) FM_HOME="$FM_HOME" "$SEND" "$id" --key "$FM_UL_KEY" >/dev/null 2>&1 || true ;;
  esac
  send_resume "$id" "$kind" "$first" "$attempts" || true
}

[ -d "$STATE" ] || exit 0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  handle_endpoint "$meta"
done
exit 0
